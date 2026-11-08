package com.soundq.android.playback.listening

import android.content.ContextWrapper
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.media3.common.*
import androidx.media3.exoplayer.ExoPlayer
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import com.soundq.android.playback.MediaGrant
import kotlinx.coroutines.*
import java.io.File
import java.util.UUID
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs

/** Real factory/cache/progressive extractor/sole actual Exo output. SDK compilation is not runtime. */
@RunWith(AndroidJUnit4::class)
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class ListeningRollingQueueTest {
 private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
 private fun main(block:()->Unit){val failure=AtomicReference<Throwable>();instrumentation.runOnMainSync{try{block()}catch(t:Throwable){failure.set(t)}};failure.get()?.let{throw it}}
 private inner class Fixture(val count:Int):AutoCloseable {
  val root=File(instrumentation.targetContext.cacheDir,"listening-rolling-${UUID.randomUUID()}").apply{check(mkdirs())}
  val context=object:ContextWrapper(instrumentation.targetContext){override fun getNoBackupFilesDir()=root}
  val store=object:SessionStore{override fun load(endpoint:ApiEndpoint):SecretTokens?=null;override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){};override fun clear(){}}
  val graph=AppGraph(context,ApiEndpoint.parse("https://fixture.invalid/api/v1"),store=store)
  val grants=ConcurrentHashMap<String,MediaGrant>()
  val owner=SupervisorJob();val jobs=CoroutineScope(owner+Dispatchers.Main)
  val items:List<MediaItem>
  lateinit var output:ExoPlayer
  lateinit var player:ListeningServicePlayer
  val completions=mutableListOf<String>()
  val transitions=mutableListOf<String>()
  init {
   check(graph.session.accept(graph.session.beginIntent(),SecretTokens("fixture-access","fixture-refresh","fixture-rolling")))
   val scope=requireNotNull(graph.session.capture())
   listOf(1L to "stereo.mp3",2L to "mono.mp3").forEach{(id,name)->
    val bytes=instrumentation.context.assets.open("listening-mp3/$name").use{it.readBytes()}
    requireNotNull(graph.temporaryAudio.begin(scope,TrackId(id),bytes.size.toLong())).use{it.append(bytes,0,bytes.size);check(it.finish())}
   }
   items=(0 until count).map{i->
    val id=if(i==2)2L else 1L;val occurrence="rolling-visit-$i";val uri=Uri.parse("soundq://track/$id/$occurrence")
    grants[uri.toString()]=MediaGrant(scope,TrackId(id),false)
    val extras=Bundle().apply{putLong("trackId",id);putString("occurrenceId",occurrence);putLong("durationMs",3000);putBoolean("localOnly",false);putBoolean("manual",i==1);putString("origin",if(i==1)"Manual" else if(i>=3)"Continuation" else "Context")}
    MediaItem.Builder().setMediaId(occurrence).setUri(uri).setMimeType("audio/*").setMediaMetadata(MediaMetadata.Builder().setTitle("Rolling MP3 $i").setArtist("Synthetic fixture").setIsPlayable(true).setIsBrowsable(false).setExtras(extras).build()).build()
   }
   main {
    output=ExoPlayer.Builder(graph.applicationContext).setLooper(Looper.getMainLooper()).build()
    player=ListeningServicePlayer.createRollingMp3(output,graph,grants,jobs,1000)
    player.addCompletionListener{completions+=it.mediaId}
    player.addListener(object:Player.Listener{override fun onMediaItemTransition(item:MediaItem?,reason:Int){item?.let{transitions+=it.mediaId}}})
   }
  }
  fun await(label:String,predicate:()->Boolean){
   val handler=Handler(Looper.getMainLooper());val done=CountDownLatch(1);val failure=AtomicReference<Throwable>();val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(25)
   val poll=object:Runnable{override fun run(){try{check(player.playerError==null && output.playerError==null){"$label error ${player.playerError}/${output.playerError}"};if(predicate())done.countDown() else if(System.nanoTime()>end){failure.set(AssertionError("$label logical=${player.playbackState} physical=${output.playbackState} index=${player.currentMediaItemIndex} local=${player.currentPosition} global=${output.currentPosition} residency=${player.residency()}"));done.countDown()}else handler.postDelayed(this,10)}catch(t:Throwable){failure.set(t);done.countDown()}}}
   handler.post(poll);try{assertTrue(label,done.await(26,TimeUnit.SECONDS));failure.get()?.let{throw it}}finally{handler.removeCallbacks(poll)}
   main{Log.i("ListeningRollingQueue","$label pid=${android.os.Process.myPid()} global=${output.currentPosition} local=${player.currentPosition} index=${player.currentMediaItemIndex} residency=${player.residency()}")}
  }
  fun ready()=await("actual rolling ready"){player.preparationSettled && player.playbackState==Player.STATE_READY && output.playbackState==Player.STATE_READY}
  fun prepare(){
   main{player.setMediaItems(items,0,0);assertEquals(count,player.mediaItemCount);assertEquals(0,copies());player.prepare()};ready()
   main{
    assertEquals(1,output.mediaItemCount);assertEquals("soundqlistening",output.currentMediaItem!!.localConfiguration!!.uri.scheme)
    assertEquals((count*2000+1000).toLong(),output.duration);assertEquals(3000L,player.duration)
    assertEquals("audio/raw",output.audioFormat!!.sampleMimeType);assertEquals(48000,output.audioFormat!!.sampleRate);assertEquals(2,output.audioFormat!!.channelCount)
    items.forEachIndexed{i,item->assertEquals(item,player.getMediaItemAt(i));assertEquals(3000L,player.currentTimeline.getWindow(i,Timeline.Window()).durationMs)}
    witness()
   }
  }
  fun copies()=graph.directory.listFiles()?.count{it.name.startsWith("listening-")}?:0
  fun witness(){val s=requireNotNull(player.residency());assertTrue(s.slots<=2);assertTrue(s.slotHighWater<=2);assertTrue(s.reservedBytes<=RollingListeningRoot.LIMIT);assertTrue(s.byteHighWater<=RollingListeningRoot.LIMIT);assertTrue(s.actualBytes<=RollingListeningRoot.LIMIT);assertTrue(s.actualByteHighWater>0);assertTrue(s.actualByteHighWater<=RollingListeningRoot.LIMIT);assertTrue(copies()<=2)}
  fun progress(index:Int){var before=0L;var buffers=0;main{before=output.currentPosition;buffers=output.audioDecoderCounters?.renderedOutputBufferCount?:0;player.play()};await("positive rolling output $index"){output.audioDecoderCounters?.ensureUpdated();output.isPlaying && player.currentMediaItemIndex==index && output.currentPosition>before+80 && (output.audioDecoderCounters?.renderedOutputBufferCount?:0)>buffers && abs(player.currentPosition-(output.currentPosition-index*2000))<=30}}
  override fun close(){
   main{player.release();assertTrue(output.isReleased)}
   runBlocking{withTimeout(20000){owner.cancelAndJoin()}}
   val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(20);while(copies()>0 && System.nanoTime()<end)Thread.sleep(5)
   assertEquals("concrete drain removes all own copies",0,copies());assertTrue(player.preparationSettled);assertFalse(owner.isActive);assertTrue(owner.children.none())
   val cleared=graph.temporaryAudio.clear();assertEquals(0,cleared.deferredFiles);assertEquals(0,cleared.failedFiles)
   Log.i("ListeningRollingQueue","drained pid=${android.os.Process.myPid()} preparation=true privateCopies=0 outputReleased=true jobs=0")
   graph.close();assertTrue(root.deleteRecursively())
  }
 }
 private fun natural(count:Int){Fixture(count).use{f->
  f.prepare()
  val checks=(1 until count).map{i->
   val done=CountDownLatch(1);val failure=AtomicReference<Throwable>()
   main{f.output.createMessage{_,_->try{
    assertEquals(i,f.player.currentMediaItemIndex);assertEquals((0 until i-1).map{"rolling-visit-$it"},f.completions)
    assertEquals(3000L,f.player.duration);assertTrue(abs(f.player.currentPosition-(f.output.currentPosition-i*2000))<=30);f.witness()
   }catch(t:Throwable){failure.set(t)}finally{done.countDown()}}.setLooper(f.output.applicationLooper).setPosition(0,i*2000L+650).send()};
   {assertTrue("actual midpoint $i",done.await(20,TimeUnit.SECONDS));failure.get()?.let{throw it}}
  }
  f.progress(0);checks.forEach{it()}
  f.await("actual fixed$count full EOF"){f.player.playbackState==Player.STATE_ENDED && f.output.playbackState==Player.STATE_ENDED}
  main{assertEquals(f.items.map{it.mediaId},f.completions);assertEquals(count-1,f.player.currentMediaItemIndex);assertEquals(3000L,f.player.currentPosition);assertEquals(3000L,f.player.duration);assertTrue(f.transitions.containsAll(f.items.map{it.mediaId}));assertFalse(f.transitions.any{it.startsWith("render:")});assertEquals((0 until count).map{"rolling-visit-$it"},f.player.residency()!!.acquisitions);f.witness()}
 }}
 @Test fun actualFixedThreeDuplicateRowsCrossBothOverlapsAndCompleteInSourceOrder()=natural(3)
 @Test fun actualFixedFiveRetainsContinuationMetadataAndReachesFullEof()=natural(5)
 @Test fun actualBackwardEvictionReacquisitionSourceTailNavigationAndStopPrepare(){Fixture(5).use{f->
  f.prepare();f.progress(0)
  val first="rolling-visit-0";var rootRender="";var initial=emptyList<String>();var evicted=emptyList<String>()
  f.await("occurrence0 positively acquired"){f.player.residency()!!.acquisitions.contains(first)}
  main{rootRender=f.output.currentMediaItem!!.mediaId;initial=f.player.residency()!!.acquisitions;assertEquals(1,initial.count{it==first})}
  main{f.player.pause();f.player.seekTo(4,1200)};f.ready();f.progress(4)
  f.await("occurrence0 positively evicted"){
   val s=f.player.residency()!!
   s.acquisitions.contains("rolling-visit-4") && first !in s.residentOccurrences
  }
  main{val s=f.player.residency()!!;assertEquals(rootRender,f.output.currentMediaItem!!.mediaId);assertEquals(initial,s.acquisitions.take(initial.size));evicted=s.acquisitions;assertEquals(1,evicted.count{it==first});f.witness()}
  main{f.player.pause();f.player.seekTo(0,2900);assertEquals(0,f.player.currentMediaItemIndex);assertEquals(2900L,f.player.currentPosition)};f.ready()
  f.await("occurrence0 same-root backward reacquisition"){
   val s=f.player.residency()!!
   s.acquisitions.take(evicted.size)==evicted && s.acquisitions.drop(evicted.size).contains(first)
  }
  main{val s=f.player.residency()!!;assertEquals(rootRender,f.output.currentMediaItem!!.mediaId);assertEquals(2,s.acquisitions.count{it==first});f.witness();Log.i("ListeningRollingQueue","reacquired pid=${android.os.Process.myPid()} root=$rootRender initial=$initial evicted=$evicted reacquired=${s.acquisitions} resident=${s.residentOccurrences}")}
  main{assertEquals(0,f.player.currentMediaItemIndex);assertEquals(2900L,f.player.currentPosition);assertTrue(f.completions.isEmpty());f.player.seekTo(1,0)};f.ready()
  main{assertEquals(1,f.player.currentMediaItemIndex);assertEquals(0L,f.player.currentPosition);assertEquals(2000L,f.output.currentPosition);f.player.seekToPreviousMediaItem()};f.ready()
  main{assertEquals(0,f.player.currentMediaItemIndex);f.player.seekToNextMediaItem()};f.ready()
  main{assertEquals(1,f.player.currentMediaItemIndex);f.player.repeatMode=Player.REPEAT_MODE_ALL;f.player.seekTo(4,0);f.player.seekToNextMediaItem()};f.ready()
  main{assertEquals(0,f.player.currentMediaItemIndex);f.player.repeatMode=Player.REPEAT_MODE_OFF}
  f.progress(0);var saved=0L;var render=""
  main{f.player.pause();saved=f.player.currentPosition;render=f.output.currentMediaItem!!.mediaId;f.player.stop();assertEquals(saved,f.player.currentPosition);f.player.prepare()};f.ready()
  main{assertEquals(saved,f.player.currentPosition);assertNotEquals(render,f.output.currentMediaItem!!.mediaId);assertFalse(f.player.playWhenReady);assertTrue(f.completions.isEmpty());f.witness()};f.progress(0)
 }}
}
