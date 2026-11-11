package com.soundq.android

import android.content.*
import android.os.*
import android.util.Log
import androidx.media3.common.*
import androidx.media3.session.*
import com.google.common.util.concurrent.ListenableFuture
import com.soundq.android.data.*
import com.soundq.android.data.preferences.EndOfQueue
import com.soundq.android.playback.*
import com.soundq.android.playback.listening.RollingListeningRoot
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs

/** Android must create the real service. Cached MP3 bytes, authenticated selector, real Exo output. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class ListeningServiceJourneyTest {
 private val instrumentation get()=androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
 private val context get()=instrumentation.targetContext
 private val app get()=context.applicationContext as ListeningServiceFixtureApplication
 private val graph get()=app.graph
 private fun main(block:()->Unit) {val failure=AtomicReference<Throwable>();instrumentation.runOnMainSync{try{block()}catch(t:Throwable){failure.set(t)}};failure.get()?.let{throw it}}
 private fun await(label:String,seconds:Long=25,predicate:()->Boolean) {
  val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(seconds)
  while(System.nanoTime()<deadline){var done=false;main{done=predicate()};if(done)return;Thread.sleep(10)}
  throw AssertionError("$label deadline pid=${android.os.Process.myPid()}")
 }
 private fun <T> call(action:()->ListenableFuture<T>):T {lateinit var f:ListenableFuture<T>;main{f=action()};return f.get(10,TimeUnit.SECONDS)}
 private var observed:SoundQLibraryService?=null
 private var observation:ServiceConnection?=null
 private fun connect():MediaBrowser {
  lateinit var f:ListenableFuture<MediaBrowser>
  main{f=MediaBrowser.Builder(context,SessionToken(context,ComponentName(context,SoundQLibraryService::class.java))).setApplicationLooper(Looper.getMainLooper()).buildAsync()}
  val browser=f.get(10,TimeUnit.SECONDS)
  if(observation!=null)return browser
  val connected=CountDownLatch(1)
  val connection=object:ServiceConnection {
   override fun onServiceConnected(name:ComponentName,binder:IBinder) {
    val field=binder.javaClass.getDeclaredField("serviceReference").apply{isAccessible=true}
    observed=(field.get(binder) as java.lang.ref.WeakReference<*>).get() as SoundQLibraryService
    connected.countDown()
   }
   override fun onServiceDisconnected(name:ComponentName){observed=null}
  }
  main{check(context.bindService(Intent(context,SoundQLibraryService::class.java).setAction(MediaSessionService.SERVICE_INTERFACE),connection,Context.BIND_AUTO_CREATE));observation=connection}
  assertTrue(connected.await(10,TimeUnit.SECONDS))
  return browser
 }
 private fun setup(held:Boolean=false):MediaBrowser {
  check(context.applicationContext is ListeningServiceFixtureApplication){"Select registered ListeningServiceFixtureRunner, not ProductFixtureRunner"}
  // Retire the automatic product controller so actual Browser release can unbind the service.
  main{graph.controller.close()}
  assertTrue(graph.api.authenticate("synthetic@example.test","test-only-password"))
  graph.listeningPreferences.load()
  assertTrue(graph.listeningPreferences.setMode(graph.listeningPreferences.capture()!!,EndOfQueue.ShuffleLibrary){true})
  graph.queueSettings.load()
  val scope=graph.session.capture()!!
  for((id,name) in listOf(1L to "stereo.mp3",2L to "mono.mp3",90L to "stereo.mp3",91L to "mono.mp3")) {
   val bytes=instrumentation.context.assets.open("listening-mp3/$name").use{it.readBytes()}
   graph.temporaryAudio.begin(scope,TrackId(id),bytes.size.toLong())!!.use{it.append(bytes,0,bytes.size);assertTrue(it.finish())}
  }
  graph.library.refine(LibraryQuery())
  graph.rememberTracks(graph.library.state.value.rows)
  ListeningServiceTransport.reset(held)
  val browser=connect()
  await("service account grants offered"){browser.isCommandAvailable(Player.COMMAND_PLAY_PAUSE)}
  assertEquals(listOf("library:1","library:2","library:3"),call{browser.getChildren(SoundQLibraryService.LIBRARY,0,20,null)}.value!!.map{it.mediaId})
  return browser
 }
 private fun requests()=listOf(1L,1L,2L).mapIndexed {i,id->MediaItem.Builder().setMediaId(id.toString()).setRequestMetadata(MediaItem.RequestMetadata.Builder().setExtras(Bundle().apply{putBoolean("manual",i==1)}).build()).build()}
 private fun play(browser:MediaBrowser) {main{browser.setMediaItems(requests(),0,0);browser.prepare();browser.play()}}
 private fun rows(browser:MediaBrowser)=(0 until browser.mediaItemCount).map{browser.getMediaItemAt(it).mediaId}
 private fun actualService():SoundQLibraryService=checkNotNull(observed)
 private fun privateCopies()=graph.directory.listFiles()?.count{it.name.startsWith("listening-")} ?: 0
 private fun residency(c:ListeningServiceFixtureApplication.Construction) {
  c.observeRender();val snapshot=c.player.residency()!!
  assertTrue(snapshot.slots<=2);assertTrue(snapshot.slotHighWater<=2)
  assertTrue(snapshot.reservedBytes<=RollingListeningRoot.LIMIT);assertTrue(snapshot.byteHighWater<=RollingListeningRoot.LIMIT)
  assertTrue(snapshot.actualByteHighWater>0);assertTrue(snapshot.actualByteHighWater<=RollingListeningRoot.LIMIT);assertTrue(privateCopies()<=2)
 }
 private fun drain(browser:MediaBrowser,c:ListeningServiceFixtureApplication.Construction) {
  ListeningServiceTransport.release.countDown()
  var recorderJob:Job?=null
  var retiredRecorder:Any?=null
  main{
   val recorder=SoundQLibraryService::class.java.getDeclaredField("recorder").apply{isAccessible=true}.get(actualService())
   retiredRecorder=recorder
   recorderJob=(recorder.javaClass.getDeclaredField("io").apply{isAccessible=true}.get(recorder) as CoroutineScope).coroutineContext[Job]
  }
  main{browser.release();observation?.let{context.unbindService(it)};observation=null;observed=null;context.stopService(Intent(context,SoundQLibraryService::class.java))}
  await("actual service onDestroy released sole output"){c.output.isReleased}
  // Real cleanup receipts, not onDestroy return or a fabricated service await API.
  runBlocking{withTimeout(20000){c.jobs.coroutineContext[Job]!!.join();recorderJob!!.join()}}
  assertTrue(retiredRecorder!!.javaClass.getDeclaredField("closed").apply{isAccessible=true}.getBoolean(retiredRecorder))
  assertFalse(recorderJob!!.isActive);assertTrue(recorderJob!!.children.none())
  c.renders.forEach{it.released.get(20,TimeUnit.SECONDS)}
  val until=System.nanoTime()+TimeUnit.SECONDS.toNanos(20)
  while((privateCopies()!=0 || !c.player.preparationSettled) && System.nanoTime()<until)Thread.sleep(5)
  assertEquals(0,privateCopies());assertTrue(c.player.preparationSettled)
  assertFalse(c.jobs.coroutineContext[Job]!!.isActive);assertTrue(c.jobs.coroutineContext[Job]!!.children.none())
  val clear=graph.temporaryAudio.clear();assertEquals(0,clear.deferredFiles);assertEquals(0,clear.failedFiles)
  Log.i("ListeningServiceJourney","drained pid=${android.os.Process.myPid()} outputReleased=true preparedReceipts=${c.renders.size} preparation=true copies=0 jobs=0 deferred=0 failed=0")
 }
 @Test fun actualServiceNaturalThreeFetchesTwoOutputsFiveAndDrains() {
  val browser=setup();val c=app.constructions.last();val constructions=app.constructions.size
  val events=mutableSetOf<Int>();val completionsBefore=ProductTransportFixture.recordedPlays.size
  val listener=object:Player.Listener {override fun onEvents(player:Player,flags:Player.Events){for(i in 0 until flags.size())events+=flags[i]}}
  main{browser.addListener(listener)}
  try {
   play(browser)
   await("initial service MP3 output"){c.output.audioDecoderCounters?.ensureUpdated();browser.mediaItemCount==3 && c.output.isPlaying && c.output.currentPosition>100 && (c.output.audioDecoderCounters?.renderedOutputBufferCount?:0)>0}
   lateinit var original:List<String>;lateinit var stale:SessionCommand
   main {
    original=rows(browser);assertEquals(3,original.distinct().size);assertEquals(original,(0..2).map{c.player.getMediaItemAt(it).mediaId})
    assertEquals(listOf("Context","Manual","Context"),(0..2).map{c.player.getMediaItemAt(it).mediaMetadata.extras!!.getString("origin")})
    val service=actualService()
    assertSame(c.player,SoundQLibraryService::class.java.getDeclaredField("player").apply{isAccessible=true}.get(service))
    assertEquals(3000L,browser.duration);assertEquals(1,c.output.mediaItemCount);assertTrue(c.output.currentMediaItem!!.mediaId.startsWith("render:"))
    assertFalse(browser.isCommandAvailable(Player.COMMAND_SET_SHUFFLE_MODE));assertEquals(3,c.grants.size);residency(c)
   }
   await("current Like acknowledged"){browser.mediaButtonPreferences.any{it.sessionCommand?.customAction?.startsWith(SoundQLibraryService.LIKE)==true}}
   main{stale=browser.mediaButtonPreferences.first{it.sessionCommand!=null}.sessionCommand!!}
   assertEquals(SessionResult.RESULT_SUCCESS,call{browser.sendCustomCommand(stale,Bundle.EMPTY)}.resultCode)
   await("first dominance before outgoing source EOF"){browser.currentMediaItemIndex==1 && c.output.currentPosition<3000}
   assertTrue(ProductTransportFixture.recordedPlays.drop(completionsBefore).isEmpty())
   assertNotEquals(SessionResult.RESULT_SUCCESS,call{browser.sendCustomCommand(stale,Bundle.EMPTY)}.resultCode)
   await("actual natural initial EOF and suffix output",30){c.output.audioDecoderCounters?.ensureUpdated();browser.mediaItemCount==5 && browser.currentMediaItemIndex==3 && c.output.isPlaying && c.output.currentPosition>7100 && (c.output.audioDecoderCounters?.renderedOutputBufferCount?:0)>0}
   main {
    assertEquals(constructions,app.constructions.size);assertEquals(original,rows(browser).take(3));assertEquals(5,rows(browser).distinct().size)
    assertEquals(original,c.completions);assertEquals(0L,c.appendedLocal);assertEquals(12000L,c.output.duration)
    assertTrue(abs(browser.currentPosition-(c.output.currentPosition-7000))<=150)
    assertEquals(setOf(90L,91L),(3..4).map{browser.getMediaItemAt(it).mediaMetadata.extras!!.getLong("trackId")}.toSet())
    assertEquals(5,c.grants.size);assertEquals(1,ListeningServiceTransport.selectors.size);residency(c)
   }
   // Actual service preference, only after positive appended output. No continuation.close takeover.
   assertTrue(graph.listeningPreferences.setMode(graph.listeningPreferences.capture()!!,EndOfQueue.Off){true})
   await("all five source EOF",25){browser.playbackState==Player.STATE_ENDED && c.output.playbackState==Player.STATE_ENDED}
   await("source EOF recorder posts"){ProductTransportFixture.recordedPlays.drop(completionsBefore).size==4}
   main {
    assertEquals(rows(browser),c.completions);assertEquals(listOf(1L,2L,90L,91L),ProductTransportFixture.recordedPlays.drop(completionsBefore).sorted())
    assertEquals(1,ListeningServiceTransport.selectors.size);assertTrue(events.contains(Player.EVENT_TIMELINE_CHANGED));assertTrue(events.contains(Player.EVENT_MEDIA_ITEM_TRANSITION));assertTrue(events.contains(Player.EVENT_POSITION_DISCONTINUITY))
   }
   lateinit var projection:ControllerProjection
   main{projection=ControllerProjection(context)}
   try{await("production controller projection logical convergence"){projection.state.value.queue.map{it.occurrenceId}==rows(browser) && projection.state.value.durationMs==3000L}}finally{main{projection.close()}}
   val second=connect()
   try{await("reconnected controller logical convergence"){rows(second)==rows(browser) && second.duration==3000L}}finally{main{second.release()}}
   Log.i("ListeningServiceJourney","SERVICE_ROLLING_CONTINUATION_3_TO_5 pid=${android.os.Process.myPid()} factoryCount=$constructions rows=5 selectors=1 sourceEOF=5 history=4 realOutput=true")
  }finally{drain(browser,c)}
 }
 @Test fun actualControllerPauseRetiresHeldAuthenticatedContinuation()=heldContinuation("pause")
 @Test fun actualAccountRetirementRejectsHeldContinuation()=heldContinuation("account")
 @Test fun actualLocalLockRejectsHeldContinuation()=heldContinuation("lock")
 private fun heldContinuation(action:String) {
  val browser=setup(true);val c=app.constructions.last();val history=ProductTransportFixture.recordedPlays.size
  try {
   play(browser)
   await("positive initial output"){c.output.isPlaying && c.output.currentPosition>100}
   assertTrue("actual authenticated selector held",ListeningServiceTransport.entered.await(20,TimeUnit.SECONDS))
   await("source EOF recorder settled before retirement"){ProductTransportFixture.recordedPlays.drop(history).size==2}
   when(action){
    "pause"->main{browser.pause()}
    "account"->graph.session.retire()
    "lock"->assertTrue(graph.session.lockLocal())
   }
   await("retirement reaches raw service owner"){!c.player.playWhenReady}
   await("initial source EOF recorder settled"){ProductTransportFixture.recordedPlays.drop(history).size==2}
   val completed=c.completions.toList();val recorded=ProductTransportFixture.recordedPlays.drop(history).toList()
   ListeningServiceTransport.release.countDown()
   val request=ListeningServiceTransport.selectors.single();assertEquals("Bearer synthetic-fixture-access",request.headers["Authorization"])
   // Await actual continuation job retirement, not a sleep claiming late response arrived.
   await("held selector retires"){val field=SoundQLibraryService::class.java.getDeclaredField("continuation").apply{isAccessible=true};!(field.get(actualService()) as ServiceLibraryContinuation).pending}
   main{assertEquals(if(action=="account")0 else 3,c.player.mediaItemCount);assertFalse(c.player.playWhenReady);assertFalse(c.output.isPlaying);assertEquals(completed,c.completions)}
   assertEquals(recorded,ProductTransportFixture.recordedPlays.drop(history))
  }finally{drain(browser,c)}
 }
 @Test fun actualServiceHeldPredecessorCannotAutoplayAfterControllerPause() {
  val browser=setup();val c=app.constructions.last()
  var held:com.soundq.android.playback.listening.PreparedListening?=null
  try {
   play(browser);await("positive output for predecessor"){c.output.isPlaying && c.output.currentPosition>100}
   main{c.observeRender();held=c.renders.last()}
   val old=held!!
   val lock=old.javaClass.getDeclaredField("lock").apply{isAccessible=true}.get(old)
   val operations=old.javaClass.getDeclaredField("operations").apply{isAccessible=true}
   synchronized(lock){operations.setInt(old,operations.getInt(old)+1)} // Hold concrete operation-exit receipt, not audio clock.
   await("actual service append waiting predecessor drain",30){browser.mediaItemCount==5 && !c.player.preparationSettled}
   main{assertFalse(old.released.isDone);assertEquals(0,c.output.mediaItemCount);browser.pause()}
   await("pause accepted before predecessor release"){!c.player.playWhenReady}
   synchronized(lock){operations.setInt(old,operations.getInt(old)-1)}
   old.javaClass.getDeclaredMethod("cleanupLater").apply{isAccessible=true}.invoke(old)
   old.released.get(20,TimeUnit.SECONDS);held=null
   await("successor preparation settled after pause"){c.player.preparationSettled}
   main{assertFalse(c.player.playWhenReady);assertFalse(c.output.isPlaying);assertEquals(0,c.output.mediaItemCount);assertEquals(3,c.completions.size)}
  }finally{
   held?.let{old->val lock=old.javaClass.getDeclaredField("lock").apply{isAccessible=true}.get(old);val operations=old.javaClass.getDeclaredField("operations").apply{isAccessible=true};synchronized(lock){operations.setInt(old,operations.getInt(old)-1)};old.javaClass.getDeclaredMethod("cleanupLater").apply{isAccessible=true}.invoke(old)}
   drain(browser,c)
  }
 }
 @Test fun actualServiceCapabilityRefusalsLeaveQueueGrantsAndRequestsUntouched() {
  val browser=setup();val c=app.constructions.last()
  try {
   play(browser);await("service positive output before refusal"){c.output.isPlaying && c.output.currentPosition>100}
   main{browser.pause()};await("pause reaches service"){!c.player.playWhenReady}
   val before=ProductTransportFixture.requests.size
   main {
    val service=actualService()
    val callback=Class.forName("com.soundq.android.playback.SoundQLibraryService\$Callback").getDeclaredConstructor(SoundQLibraryService::class.java).apply{isAccessible=true}.newInstance(service) as androidx.media3.session.MediaLibraryService.MediaLibrarySession.Callback
    val session=SoundQLibraryService::class.java.getDeclaredField("session").apply{isAccessible=true}.get(service) as MediaSession
    val info=session.connectedControllers.first{it.uid==context.applicationInfo.uid}
    val ids=rows(browser);val grants=c.grants.toMap()
    for(action in listOf(SoundQLibraryService.PLAY_MIX,SoundQLibraryService.APPLY_ARRANGEMENT,SoundQLibraryService.RETURN_SOURCES,SoundQLibraryService.JAM_ADMIT)) {
     assertFalse(browser.isSessionCommandAvailable(SessionCommand(action,Bundle.EMPTY)))
     assertEquals(SessionError.ERROR_NOT_SUPPORTED,callback.onCustomCommand(session,info,SessionCommand(action,Bundle.EMPTY),Bundle.EMPTY).get().resultCode)
    }
    assertEquals(ids,rows(browser));assertEquals(grants,c.grants.toMap());assertFalse(c.player.playWhenReady)
    graph.rememberTracks(listOf(Track(TrackId(99),"Rejected duration",durationMs=0)))
    assertTrue(runCatching{callback.onSetMediaItems(session,info,listOf(MediaItem.Builder().setMediaId("99").build()),0,0).get()}.isFailure)
    val transport=SoundQLibraryService::class.java.getDeclaredField("transport").apply{isAccessible=true}.get(service) as com.soundq.android.playback.system.ServiceTransportPlayer
    transport.prepare();transport.play()
    assertFalse(c.player.playWhenReady);assertEquals(ids,rows(browser));assertEquals(grants,c.grants.toMap())
   }
   assertEquals(before,ProductTransportFixture.requests.size)
  }finally{drain(browser,c)}
 }
 @Test fun registeredFocusLossCallbackPausesActualService() {
  val browser=setup();val c=app.constructions.last()
  try {
   play(browser);await("positive output before focus callback"){c.output.isPlaying && c.output.currentPosition>100}
   main {
    val interruption=SoundQLibraryService::class.java.getDeclaredField("interruptions").apply{isAccessible=true}.get(actualService())
    val request=interruption.javaClass.getDeclaredField("request").apply{isAccessible=true}.get(interruption) as android.media.AudioFocusRequest
    val callback=request.javaClass.getDeclaredField("mFocusListener").apply{isAccessible=true}.get(request) as android.media.AudioManager.OnAudioFocusChangeListener
    callback.onAudioFocusChange(android.media.AudioManager.AUDIOFOCUS_LOSS)
   }
   await("registered focus loss callback paused sole owner"){!c.player.playWhenReady && !c.output.isPlaying}
  }finally{drain(browser,c)}
 }
 @Test fun registeredNoisyCallbackPausesActualServiceWithoutResuming() {
  val browser=setup();val c=app.constructions.last()
  try {
   play(browser);await("positive output before noisy callback"){c.output.isPlaying && c.output.currentPosition>100}
   main {
    val interruption=SoundQLibraryService::class.java.getDeclaredField("interruptions").apply{isAccessible=true}.get(actualService())
    val receiver=interruption.javaClass.getDeclaredField("noisy").apply{isAccessible=true}.get(interruption) as BroadcastReceiver
    receiver.onReceive(context,Intent(android.media.AudioManager.ACTION_AUDIO_BECOMING_NOISY))
   }
   await("registered noisy callback paused sole owner"){!c.player.playWhenReady && !c.output.isPlaying}
  }finally{drain(browser,c)}
 }
 @Test fun actualServiceRejectsSavedShuffleWithoutGrantsOrOverwrite() {
  var browser=setup();var c=app.constructions.last()
  val scope=graph.session.capture()!!
  val file=SoundQLibraryService::class.java.getDeclaredMethod("queueFile",AccountScope::class.java).apply{isAccessible=true}.let{method->var result:File?=null;main{result=method.invoke(actualService(),scope) as File};result!!}
  val saved=QueueSnapshot(graph.endpoint.identity,scope.accountId,listOf(SavedOccurrence("incompatible",1,"Fixture","MP3",false,false,3000)),0,0,true)
  drain(browser,c);val raw=saved.encode();file.writeText(raw)
  val count=app.constructions.size
  browser=connect();await("recreated service with incompatible bytes"){app.constructions.size==count+1};c=app.constructions.last()
  try {
   await("restore refusal acknowledged"){SoundQLibraryService::class.java.getDeclaredField("rejectedQueue").apply{isAccessible=true}.getBoolean(actualService())}
   main{assertEquals(0,browser.mediaItemCount);assertTrue(c.grants.isEmpty());assertFalse(c.player.playWhenReady);assertEquals(0,c.output.mediaItemCount)}
   assertEquals(raw,file.readText())
  }finally{drain(browser,c)}
 }
 @Test fun actualFailedSearchThenUndoRestoresExplicitPlayback() {
  val browser=setup();val c=app.constructions.last()
  try {
   play(browser);await("positive output before failure"){c.output.isPlaying && c.output.currentPosition>100}
   main{browser.pause()};await("paused before failed replacement"){!c.player.playWhenReady}
   lateinit var ids:List<String>
   main {
    ids=rows(browser)
    // Capture the real service Undo through ordinary change-items admission.
    browser.moveMediaItem(1,2)
   }
   await("accepted paused mutation"){rows(browser)!=ids}
   val searches=ListeningServiceTransport.searches.size
   main {
    browser.setMediaItem(MediaItem.Builder().setRequestMetadata(MediaItem.RequestMetadata.Builder().setSearchQuery("no such fixture").build()).build())
    browser.prepare();browser.play()
   }
   await("failed async search closes current read"){
    val t=SoundQLibraryService::class.java.getDeclaredField("transport").apply{isAccessible=true}.get(actualService()) as com.soundq.android.playback.system.ServiceTransportPlayer;
    ListeningServiceTransport.searches.size>searches && !t.resolving
   }
   main{browser.prepare();browser.play()}
   await("failed search never replays retained queue"){!c.player.playWhenReady && !c.output.isPlaying}
   assertEquals(SessionResult.RESULT_SUCCESS,call{browser.sendCustomCommand(SessionCommand(SoundQLibraryService.UNDO,Bundle.EMPTY),Bundle.EMPTY)}.resultCode)
   main{browser.prepare();browser.play()}
   await("Undo restored usable actual output"){c.player.playWhenReady && c.output.isPlaying && c.output.currentPosition>100}
  }finally{drain(browser,c)}
 }
 @Test fun actualServiceRejectsAggregateRiffRestoreAndPreservesBytesOnSave() {
  var browser=setup();var c=app.constructions.last();val scope=graph.session.capture()!!
  val method=SoundQLibraryService::class.java.getDeclaredMethod("queueFile",AccountScope::class.java).apply{isAccessible=true}
  lateinit var file:File;main{file=method.invoke(actualService(),scope) as File}
  drain(browser,c)
  val raw=QueueSnapshot(graph.endpoint.identity,scope.accountId,(0 until 48).map{SavedOccurrence("aggregate-$it",it+1L,"Saved","MP3",false,false,240000)},0,0).encode()
  file.writeText(raw);val count=app.constructions.size;browser=connect()
  await("new aggregate restore owner"){app.constructions.size==count+1};c=app.constructions.last()
  try {
   await("aggregate saved bytes refused"){SoundQLibraryService::class.java.getDeclaredField("rejectedQueue").apply{isAccessible=true}.getBoolean(actualService())}
   main{assertTrue(c.grants.isEmpty());assertEquals(0,c.player.mediaItemCount);assertEquals(0,c.output.mediaItemCount);assertFalse(c.player.playWhenReady);browser.repeatMode=Player.REPEAT_MODE_ONE}
   main{SoundQLibraryService::class.java.getDeclaredMethod("scheduleSave").apply{isAccessible=true}.invoke(actualService())}
   assertEquals(raw,file.readText())
  }finally{drain(browser,c)}
 }
 @Test fun actualServicePausedSnapshotRestoresWithoutPreparationAndExplicitPlayWorks() {
  var browser=setup();var c=app.constructions.last()
  play(browser);await("positive output before paused snapshot"){c.output.isPlaying && c.output.currentPosition>300}
  main{browser.pause()};await("paused logical owner"){!c.player.playWhenReady}
  lateinit var ids:List<String>;var position=0L
  main{ids=rows(browser);position=c.player.currentPosition}
  await("queue file exists"){graph.directory.listFiles()?.any{it.name.matches(Regex("queue-[0-9a-f]{64}[.]json"))}==true}
  val file=graph.directory.listFiles()!!.single{it.name.matches(Regex("queue-[0-9a-f]{64}[.]json"))}
  await("paused snapshot persisted"){QueueSnapshot.decode(file.readText(),graph.endpoint.identity,graph.session.capture()!!.accountId)?.let{it.items.map{r->r.occurrence}==ids && it.position==position}==true}
  val raw=file.readText();drain(browser,c)
  val count=app.constructions.size
  browser=connect();await("new actual service factory invocation"){app.constructions.size==count+1};c=app.constructions.last()
  try {
   await("actual new service paused restore"){rows(browser)==ids}
   main{assertEquals(position,browser.currentPosition);assertFalse(browser.playWhenReady);assertEquals(Player.STATE_IDLE,c.player.playbackState);assertEquals(0,c.output.mediaItemCount);assertEquals(raw,file.readText());assertFalse(browser.shuffleModeEnabled);assertEquals(Player.REPEAT_MODE_OFF,browser.repeatMode)}
   // Cache was cleared by destruction check. Rewarm the same authorized fixture source bytes.
   val scope=graph.session.capture()!!
   for((id,name) in listOf(1L to "stereo.mp3",2L to "mono.mp3")){val bytes=instrumentation.context.assets.open("listening-mp3/$name").use{it.readBytes()};graph.temporaryAudio.begin(scope,TrackId(id),bytes.size.toLong())!!.use{it.append(bytes,0,bytes.size);assertTrue(it.finish())}}
   main{browser.prepare();browser.play()};await("explicit post-restore output"){c.output.isPlaying && c.output.currentPosition>position+100}
  }finally{drain(browser,c)}
 }
}
