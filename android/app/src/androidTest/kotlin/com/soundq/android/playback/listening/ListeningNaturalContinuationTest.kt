package com.soundq.android.playback.listening

import android.content.ContextWrapper
import android.net.Uri
import android.os.*
import android.util.Log
import androidx.media3.common.*
import androidx.media3.exoplayer.ExoPlayer
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import com.soundq.android.playback.*
import com.soundq.android.playback.system.ServiceTransportPlayer
import kotlinx.coroutines.*
import mockwebserver3.*
import okhttp3.OkHttpClient
import okhttp3.tls.*
import java.io.File
import java.util.UUID
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs

/** Real factory, continuation, transport and authenticated loopback selector. No fake clock/output. */
@RunWith(AndroidJUnit4::class)
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class ListeningNaturalContinuationTest {
 private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
 private fun main(block:()->Unit){val failure=AtomicReference<Throwable>();instrumentation.runOnMainSync{try{block()}catch(t:Throwable){failure.set(t)}};failure.get()?.let{throw it}}
 @Test fun actualNaturalThreeFetchesTwoAndOutputsFiveRowsOnSamePlayer(){
  val root=File(instrumentation.targetContext.cacheDir,"listening-continuation-${UUID.randomUUID()}").apply{check(mkdirs())}
  val context=object:ContextWrapper(instrumentation.targetContext){override fun getNoBackupFilesDir()=root}
  val server=MockWebServer();val requests=CopyOnWriteArrayList<RecordedRequest>()
  val certificate=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
  server.useHttps(HandshakeCertificates.Builder().heldCertificate(certificate).build().sslSocketFactory())
  server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
   requests+=request
   check(request.headers["Authorization"]=="Bearer continuation-fixture-access")
   check(request.url.encodedPath=="/api/v1/library")
   return MockResponse.Builder().body("""{"tracks":[{"id":90,"title":"Continued90","duration_ms":3000},{"id":91,"title":"Continued91","duration_ms":3000}],"total":2,"limit":100,"offset":0}""").build()
  }}
  server.start()
  val trust=HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
  val client=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
  val store=object:SessionStore{override fun load(endpoint:ApiEndpoint):SecretTokens?=null;override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){};override fun clear(){}}
  val graph=AppGraph(context,ApiEndpoint.parse(server.url("/api/v1").toString()),client,store,client)
  val grants=ConcurrentHashMap<String,MediaGrant>();val owner=SupervisorJob();val jobs=CoroutineScope(owner+Dispatchers.Main)
  check(graph.session.accept(graph.session.beginIntent(),SecretTokens("continuation-fixture-access","continuation-fixture-refresh","continuation-fixture")))
  graph.listeningPreferences.load();val scope=requireNotNull(graph.session.capture())
  for((id,name) in listOf(1L to "stereo.mp3",2L to "mono.mp3",90L to "stereo.mp3",91L to "mono.mp3")){
   val bytes=instrumentation.context.assets.open("listening-mp3/$name").use{it.readBytes()}
   requireNotNull(graph.temporaryAudio.begin(scope,TrackId(id),bytes.size.toLong())).use{it.append(bytes,0,bytes.size);check(it.finish())}
  }
  fun item(id:Long,occurrence:String,origin:String):MediaItem {
   val uri=Uri.parse("soundq://track/$id/$occurrence");grants[uri.toString()]=MediaGrant(scope,TrackId(id),false)
   return MediaItem.Builder().setMediaId(occurrence).setUri(uri).setMimeType("audio/*").setMediaMetadata(MediaMetadata.Builder().setTitle("Continuation fixture $id").setExtras(Bundle().apply{putLong("trackId",id);putLong("durationMs",3000);putString("occurrenceId",occurrence);putString("origin",origin);putBoolean("manual",origin=="Manual");putBoolean("localOnly",false)}).build()).build()
  }
  lateinit var output:ExoPlayer;lateinit var player:ListeningServicePlayer;lateinit var continuation:ServiceLibraryContinuation
  val completed=mutableListOf<String>();val initial=listOf(item(1,"natural-0","Context"),item(1,"natural-1","Manual"),item(2,"natural-2","Context"))
  val ended=CountDownLatch(1);var exhaustedGlobal=-1L;var exhaustedDuration=-1L;var exhaustedLocal=-1L;var exhaustedSourceDuration=-1L;var oldRender=""
  fun copies()=graph.directory.listFiles()?.count{it.name.startsWith("listening-")}?:0
  fun witness(){val s=requireNotNull(player.residency());assertTrue(s.slots<=2);assertTrue(s.slotHighWater<=2);assertTrue(s.reservedBytes<=RollingListeningRoot.LIMIT);assertTrue(s.byteHighWater<=RollingListeningRoot.LIMIT);assertTrue(s.actualByteHighWater>0);assertTrue(s.actualByteHighWater<=RollingListeningRoot.LIMIT);assertTrue(copies()<=2)}
  fun await(label:String,predicate:()->Boolean){
   val handler=Handler(Looper.getMainLooper());val done=CountDownLatch(1);val failure=AtomicReference<Throwable>();val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(35)
   val poll=object:Runnable{override fun run(){try{check(player.playerError==null && output.playerError==null){"$label error ${player.playerError}/${output.playerError}"};if(predicate())done.countDown() else if(System.nanoTime()>deadline){failure.set(AssertionError("$label state=${player.playbackState} rows=${player.mediaItemCount} global=${output.currentPosition} requests=${requests.size}"));done.countDown()}else handler.postDelayed(this,10)}catch(t:Throwable){failure.set(t);done.countDown()}}}
   handler.post(poll);try{assertTrue(label,done.await(36,TimeUnit.SECONDS));failure.get()?.let{throw it}}finally{handler.removeCallbacks(poll)}
   main{Log.i("ListeningContinuation","$label pid=${android.os.Process.myPid()} rows=${player.mediaItemCount} global=${output.currentPosition} local=${player.currentPosition} index=${player.currentMediaItemIndex} residency=${player.residency()}")}
  }
  main {
   output=ExoPlayer.Builder(graph.applicationContext).setLooper(Looper.getMainLooper()).build()
   player=ListeningServicePlayer.createRollingMp3(output,graph,grants,jobs,1000)
   val transport=ServiceTransportPlayer(player){graph.session.current(scope)}
   continuation=ServiceLibraryContinuation(player,transport,graph,jobs){tracks,valid->check(valid());tracks.map{item(it.id.value,"continued-${UUID.randomUUID()}","Continuation")}}
   transport.onIntentChanged=continuation::command
   player.addCompletionListener{completed+=it.mediaId}
   player.addListener(object:Player.Listener{
    override fun onTimelineChanged(timeline:Timeline,reason:Int)=continuation.timelineChanged()
    override fun onIsPlayingChanged(isPlaying:Boolean)=continuation.playingChanged(isPlaying)
    override fun onPositionDiscontinuity(old:Player.PositionInfo,next:Player.PositionInfo,reason:Int)=continuation.positionChanged(reason)
    override fun onMediaItemTransition(item:MediaItem?,reason:Int)=continuation.transition()
    override fun onRepeatModeChanged(repeatMode:Int)=continuation.repeatChanged()
    override fun onPlaybackStateChanged(state:Int){if(state==Player.STATE_ENDED && player.mediaItemCount==3){exhaustedGlobal=output.currentPosition;exhaustedDuration=output.duration;exhaustedLocal=player.currentPosition;exhaustedSourceDuration=player.duration;ended.countDown()};continuation.ended(state)}
   })
   player.setMediaItems(initial,0,0);player.prepare();player.play()
  }
  try {
   await("initial sole output positive"){output.isPlaying && output.currentPosition>100 && (output.audioDecoderCounters?.renderedOutputBufferCount?:0)>0}
   main{oldRender=output.currentMediaItem!!.mediaId;assertEquals(3,player.mediaItemCount);assertTrue(requests.isEmpty());witness()}
   assertTrue("natural physical EOF without seek",ended.await(20,TimeUnit.SECONDS))
   await("actual fetched two and appended output"){output.audioDecoderCounters?.ensureUpdated();player.mediaItemCount==5 && player.currentMediaItemIndex==3 && output.isPlaying && output.currentPosition>7100 && (output.audioDecoderCounters?.renderedOutputBufferCount?:0)>0}
   main {
    assertEquals(7000L,exhaustedDuration);assertTrue(exhaustedGlobal>=exhaustedDuration);assertEquals(3000L,exhaustedLocal);assertEquals(3000L,exhaustedSourceDuration);assertEquals(1,requests.size);assertEquals("100",requests.single().url.queryParameter("limit"))
    assertEquals(initial.map{it.mediaId},completed);initial.forEachIndexed{i,item->assertSame(item,player.getMediaItemAt(i))}
    assertEquals(5,(0..4).map{player.getMediaItemAt(it).mediaId}.distinct().size)
    assertEquals(listOf("Context","Manual","Context","Continuation","Continuation"),(0..4).map{player.getMediaItemAt(it).mediaMetadata.extras!!.getString("origin")})
    assertEquals(setOf(90L,91L),(3..4).map{player.getMediaItemAt(it).mediaMetadata.extras!!.getLong("trackId")}.toSet())
    assertTrue(abs(player.currentPosition-(output.currentPosition-7000))<=30);assertEquals(12000L,output.duration)
    assertEquals(1,output.mediaItemCount);assertNotEquals(oldRender,output.currentMediaItem!!.mediaId);witness()
    continuation.close() // This fixture qualifies one fetch; full final EOF must not dispatch a second.
   }
   await("all five natural EOF"){player.playbackState==Player.STATE_ENDED && output.playbackState==Player.STATE_ENDED}
   main{assertEquals((0..4).map{player.getMediaItemAt(it).mediaId},completed);assertEquals(1,requests.size);witness()}
  } finally {
   main{continuation.close();player.release();assertTrue(output.isReleased)}
   runBlocking{withTimeout(20000){owner.cancelAndJoin()}}
   val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(20);while(copies()>0 && System.nanoTime()<deadline)Thread.sleep(5)
   assertEquals(0,copies());assertTrue(player.preparationSettled);assertFalse(owner.isActive);assertTrue(owner.children.none())
   val clear=graph.temporaryAudio.clear();assertEquals(0,clear.deferredFiles);assertEquals(0,clear.failedFiles)
   Log.i("ListeningContinuation","drained pid=${android.os.Process.myPid()} preparation=true privateCopies=0 outputReleased=true jobs=0")
   graph.close();server.close();assertTrue(root.deleteRecursively())
  }
 }
}
