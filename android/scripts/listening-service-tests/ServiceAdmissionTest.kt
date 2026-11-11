package com.soundq.android.playback.listening

import android.os.Bundle
import androidx.media3.common.*
import com.soundq.android.data.*
import com.soundq.android.playback.*
import com.soundq.android.playback.system.ServiceTransportPlayer
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest=Config.NONE,sdk=[28],application=android.app.Application::class)
internal class ServiceAdmissionTest {
 private fun field(name:String)=SoundQLibraryService::class.java.getDeclaredField(name).apply{isAccessible=true}
 private fun service(h:ServiceProbe)=SoundQLibraryService().also {
  field("graph").set(it,h.graph);field("player").set(it,h.player);field("account").set(it,h.scope)
  field("grants").set(it,h.grants);field("transport").set(it,ServiceTransportPlayer(h.player){true})
 }
 private fun file(s:SoundQLibraryService,h:ServiceProbe)=SoundQLibraryService::class.java.getDeclaredMethod("queueFile",AccountScope::class.java).apply{isAccessible=true}.invoke(s,h.scope) as java.io.File
 private fun read(s:SoundQLibraryService,h:ServiceProbe):Any? {
  val method=SoundQLibraryService::class.java.getDeclaredMethod("readSavedQueue",AccountScope::class.java,kotlin.coroutines.Continuation::class.java).apply{isAccessible=true}
  return runBlocking {kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn<Any?> {method.invoke(s,h.scope,it)}}
 }
 private fun callback(s:SoundQLibraryService):Pair<androidx.media3.session.MediaLibraryService.MediaLibrarySession.Callback,androidx.media3.session.MediaSession.ControllerInfo> {
  android.content.ContextWrapper::class.java.getDeclaredMethod("attachBaseContext",android.content.Context::class.java).apply{isAccessible=true}.invoke(s,org.robolectric.RuntimeEnvironment.getApplication())
  val ctor=androidx.media3.session.MediaSession.ControllerInfo::class.java.declaredConstructors.single{it.parameterCount==8}.apply{isAccessible=true}
  val remote=ctor.parameterTypes[0].getConstructor(String::class.java,Int::class.javaPrimitiveType,Int::class.javaPrimitiveType).newInstance("fixture",android.os.Process.myPid(),s.applicationInfo.uid)
  val controller=ctor.newInstance(remote,1,1,true,null,Bundle.EMPTY,0,true) as androidx.media3.session.MediaSession.ControllerInfo
  val cb=Class.forName("com.soundq.android.playback.SoundQLibraryService\$Callback").getDeclaredConstructor(SoundQLibraryService::class.java).apply{isAccessible=true}.newInstance(s) as androidx.media3.session.MediaLibraryService.MediaLibrarySession.Callback
  return cb to controller
 }
 @Test fun aggregateRiffRestoreIsRejectedBeforeGrantsAndLaterSavePreservesExactBytes() {
  ServiceProbe(rolling=true).use {h->
   val s=service(h);h.grants.clear()
   val rows=(0 until 48).map{SavedOccurrence("saved-$it",it+1L,"Saved","Fixture",false,false,240000)}
   val raw=QueueSnapshot(h.graph.endpoint.identity,h.scope.accountId,rows,0,0,false).encode()
   val f=file(s,h);f.writeText(raw)
   try {
    assertNull("full aggregate schedule must be refused by actual saved read",read(s,h))
    assertTrue(field("rejectedQueue").getBoolean(s));assertTrue(h.grants.isEmpty())
    SoundQLibraryService::class.java.getDeclaredMethod("restoreQueue",AccountScope::class.java).apply{isAccessible=true}.invoke(s,h.scope)
    org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
    SoundQLibraryService::class.java.getDeclaredMethod("scheduleSave").apply{isAccessible=true}.invoke(s)
    org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(400))
    assertEquals(raw,f.readText());assertEquals(0,h.player.mediaItemCount);assertFalse(h.player.playWhenReady)
    assertEquals(Player.STATE_IDLE,h.player.playbackState);assertEquals(0,h.playCalls)
   }finally{(field("jobs").get(s) as CoroutineScope).cancel()}
  }
 }
 @Test fun aggregateResolveRefusesBeforePublishingAnyNewGrant() {
  ServiceProbe(rolling=true).use {h->
   val s=service(h);val before=h.grants.toMap()
   val tracks=(0 until 48).map{Track(TrackId(it+1L),"Saved","Fixture",durationMs=240000)}
   h.graph.rememberTracks(tracks)
   val requests=tracks.map{MediaItem.Builder().setMediaId(it.id.value.toString()).build()}
   val method=SoundQLibraryService::class.java.declaredMethods.single{it.name=="resolve"}.apply{isAccessible=true}
   assertTrue("metadata-only aggregate refusal before capabilities",runCatching{if(method.parameterCount==1)method.invoke(s,requests) else method.invoke(s,requests,0,0L,null)}.isFailure)
   assertEquals(before,h.grants)
   (field("jobs").get(s) as CoroutineScope).cancel()
  }
 }
 @Test fun failedAuthoritativeReadNeverLendsLaterPreparePlayToOldQueueAndFreshReadRecovers() {
  for(failure in 0..2)ServiceProbe(rolling=true).use {h->
   h.player.setMediaItems(h.items,1,1700)
   val t=ServiceTransportPlayer(h.player){true}
   val owner=t.begin{true};t.handoff();t.setMediaItems(emptyList(),-1,C.TIME_UNSET)
   t.prepare();t.play();assertFalse(h.player.playWhenReady)
   when(failure) {
    0->t.complete(owner,emptyList(),0,0)
    1->t.fail(owner)
    else->{val bad=h.items.first().buildUpon().setMediaMetadata(h.items.first().mediaMetadata.buildUpon().setExtras(Bundle(h.items.first().mediaMetadata.extras).apply{putLong("durationMs",0)}).build()).build();runCatching{t.complete(owner,listOf(bad),0,0)};t.fail(owner)}
   }
   t.prepare();t.play()
   assertFalse("read failure $failure must close later old-queue admission",h.player.playWhenReady)
   assertEquals(1,h.player.currentMediaItemIndex);assertEquals(1700L,h.player.currentPosition)
   val fresh=t.begin{true};t.prepare();t.play();t.complete(fresh,h.items,0,0)
   assertTrue("fresh pending read captures intent despite previous refusal",h.player.playWhenReady)
   t.fail(owner);assertTrue("stale failure cannot poison accepted selection",h.player.playWhenReady)
  }
 }
 @Test fun everyLegalSetOverloadRefusesFailedReplacementAndRecoversOnSuccess() {
  val calls=listOf<(ServiceTransportPlayer,MediaItem)->Unit>(
   {t,m->t.setMediaItems(listOf(m))},{t,m->t.setMediaItems(listOf(m),true)},
   {t,m->t.setMediaItems(listOf(m),0,0)},{t,m->t.setMediaItem(m)},
   {t,m->t.setMediaItem(m,0L)},{t,m->t.setMediaItem(m,true)})
  val failures=mutableListOf<Int>()
  calls.forEachIndexed {index,call->ServiceProbe(rolling=true).use {h->
   h.player.setMediaItems(h.items,1,1700);val t=ServiceTransportPlayer(h.player){true}
   val bad=h.items.first().buildUpon().setMediaMetadata(h.items.first().mediaMetadata.buildUpon().setExtras(Bundle(h.items.first().mediaMetadata.extras).apply{putLong("durationMs",0)}).build()).build()
   assertTrue(runCatching{call(t,bad)}.isFailure);t.prepare();t.play()
   if(h.player.playWhenReady)failures+=index
   h.player.pause();t.rejectSelection();call(t,h.items.first());t.prepare();t.play()
   if(!h.player.playWhenReady)failures+=index+10
  }}
  assertEquals("overload failure/recovery indices",emptyList<Int>(),failures)
 }
 @Test fun actualCustomUndoAfterRejectedSetRestoresUsableSelection() {
  ServiceProbe(rolling=true).use {h->
   val s=service(h)
   val attach=android.content.ContextWrapper::class.java.getDeclaredMethod("attachBaseContext",android.content.Context::class.java).apply{isAccessible=true}
   attach.invoke(s,org.robolectric.RuntimeEnvironment.getApplication())
   h.player.setMediaItems(h.items,1,1700)
   field("undo").set(s,h.items);field("undoScope").set(s,h.scope);field("undoIndex").setInt(s,1);field("undoPosition").setLong(s,1700)
   val t=field("transport").get(s) as ServiceTransportPlayer;t.rejectSelection()
   val ctor=androidx.media3.session.MediaSession.ControllerInfo::class.java.declaredConstructors.single{it.parameterCount==8}.apply{isAccessible=true}
   val remote=ctor.parameterTypes[0].getConstructor(String::class.java,Int::class.javaPrimitiveType,Int::class.javaPrimitiveType).newInstance("fixture",android.os.Process.myPid(),s.applicationInfo.uid)
   val controller=ctor.newInstance(remote,1,1,true,null,Bundle.EMPTY,0,true) as androidx.media3.session.MediaSession.ControllerInfo
   val callback=Class.forName("com.soundq.android.playback.SoundQLibraryService\$Callback").getDeclaredConstructor(SoundQLibraryService::class.java).apply{isAccessible=true}.newInstance(s) as androidx.media3.session.MediaLibraryService.MediaLibrarySession.Callback
   val session=androidx.media3.session.MediaSession.Builder(s,t).build()
   try {
    assertEquals(0,callback.onCustomCommand(session,controller,androidx.media3.session.SessionCommand(SoundQLibraryService.UNDO,Bundle.EMPTY),Bundle.EMPTY).get().resultCode)
    assertEquals(1,h.player.currentMediaItemIndex);assertEquals(1700L,h.player.currentPosition)
    t.prepare();t.play();assertTrue("accepted actual Undo must reopen transport admission",h.player.playWhenReady)
   }finally{session.release();(field("jobs").get(s) as CoroutineScope).cancel()}
  }
 }
 @Test fun acceptedClearAddRecoversButFailedInsertionCannotAuthorizeRetainedRows() {
  for(overload in 0..3)ServiceProbe(rolling=true).use {h->
   h.player.setMediaItems(h.items,1,1700);val t=ServiceTransportPlayer(h.player){true};t.rejectSelection()
   val bad=h.items.first().buildUpon().setMediaMetadata(h.items.first().mediaMetadata.buildUpon().setExtras(Bundle(h.items.first().mediaMetadata.extras).apply{putLong("durationMs",0)}).build()).build()
   fun add(item:MediaItem)=when(overload){0->t.addMediaItem(item);1->t.addMediaItem(0,item);2->t.addMediaItems(listOf(item));else->t.addMediaItems(0,listOf(item))}
   assertTrue(runCatching{add(bad)}.isFailure);t.prepare();t.play();assertFalse(h.player.playWhenReady)
   t.addMediaItems(emptyList());t.prepare();t.play();assertFalse("empty insertion is not accepted replacement",h.player.playWhenReady)
   t.clearMediaItems();assertEquals(0,h.player.mediaItemCount);add(h.items.first());t.prepare();t.play()
   assertTrue("accepted add overload $overload on empty replacement must recover",h.player.playWhenReady)
  }
 }
 @Test fun restoreInstallFailureIsContainedAndRollsBackOnlyStagedCapabilities() {
  ServiceProbe(rolling=true).use {h->
   val s=service(h);val before=h.grants.toMap()
   val rejecting=object:ForwardingPlayer(h.player) {override fun setMediaItems(items:List<MediaItem>,index:Int,position:Long){throw IllegalArgumentException("synthetic install refusal")}}
   field("player").set(s,rejecting)
   val raw=QueueSnapshot(h.graph.endpoint.identity,h.scope.accountId,listOf(SavedOccurrence("saved",7,"Saved","Fixture",false,false,10000)),0,0).encode()
   val f=file(s,h);f.writeText(raw)
   val caught=java.util.concurrent.CopyOnWriteArrayList<Throwable>()
   val jobs=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate+CoroutineExceptionHandler {_,error->caught+=error})
   field("jobs").set(s,jobs)
   try {
    SoundQLibraryService::class.java.getDeclaredMethod("restoreQueue",AccountScope::class.java).apply{isAccessible=true}.invoke(s,h.scope)
    val deadline=System.nanoTime()+5_000_000_000L
    while(jobs.coroutineContext[Job]!!.children.any{it.isActive} && System.nanoTime()<deadline){org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();Thread.sleep(2)}
    assertTrue("install refusal must not escape service coroutine",caught.isEmpty())
    assertEquals("only staged saved capabilities may retire",before,h.grants)
    assertTrue(field("rejectedQueue").getBoolean(s));assertEquals(raw,f.readText())
   }finally{jobs.cancel()}
  }
 }
 @Test fun actualSetPreflightsManualCarryTogetherBeforePublishingGrants() {
  ServiceProbe(rolling=true).use {h->
   val s=service(h);val (cb,controller)=callback(s)
   // Both batches fit separately, only their composed final schedule exceeds RIFF.
   val old=h.items.map {it.buildUpon().setMediaMetadata(it.mediaMetadata.buildUpon().setExtras(Bundle(it.mediaMetadata.extras).apply{putLong("durationMs",240000);putBoolean("manual",true)}).build()).build()}
   h.player.setMediaItems(old,0,0)
   val tracks=(0 until 47).map{Track(TrackId(it+10L),"Saved","Fixture",durationMs=240000)};h.graph.rememberTracks(tracks)
   val before=h.grants.toMap();val session=androidx.media3.session.MediaSession.Builder(s,h.player).build()
   try {
    val result=cb.onSetMediaItems(session,controller,tracks.map{MediaItem.Builder().setMediaId(it.id.value.toString()).build()},0,0)
    assertTrue("final schedule includes carried manual source",runCatching{result.get()}.isFailure)
    assertEquals(before,h.grants);assertEquals(old,(0 until h.player.mediaItemCount).map(h.player::getMediaItemAt))
   }finally{session.release();(field("jobs").get(s) as CoroutineScope).cancel()}
  }
 }
 @Test fun actualAsyncSearchEmptyErrorAndInvalidMetadataCloseLaterPlayAndFreshReadRecovers() {
  for(kind in 0..3)ServiceProbe(rolling=true).use {h->
   val s=service(h);val (cb,controller)=callback(s)
   h.player.setMediaItems(h.items,1,1700)
   val entered=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1)
   field("catalog").set(s,com.soundq.android.playback.system.SystemMediaCatalog(h.graph.session,{_,_,_->
    entered.countDown();check(release.await(5,java.util.concurrent.TimeUnit.SECONDS))
    when(kind){0->LibraryPage(emptyList(),0,20,0);1->throw java.io.IOException("synthetic search failure");else->LibraryPage(listOf(Track(TrackId(20),"Invalid",durationMs=if(kind==2)0 else 12000000)),1,20,0)}
   },{emptyList()}))
   val t=field("transport").get(s) as ServiceTransportPlayer
   val session=androidx.media3.session.MediaSession.Builder(s,t).build()
   try {
    val query=MediaItem.Builder().setRequestMetadata(MediaItem.RequestMetadata.Builder().setSearchQuery("fixture").build()).build()
    val reply=cb.onSetMediaItems(session,controller,listOf(query),0,0).get()
    t.setMediaItems(reply.mediaItems,reply.startIndex,reply.startPositionMs)
    org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
    assertTrue(entered.await(5,java.util.concurrent.TimeUnit.SECONDS));t.prepare();t.play();assertFalse(h.player.playWhenReady)
    release.countDown()
    val deadline=System.nanoTime()+5_000_000_000L
    while(t.resolving && System.nanoTime()<deadline){org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();Thread.sleep(2)}
    assertFalse(t.resolving);t.prepare();t.play();assertFalse("actual search failure $kind",h.player.playWhenReady)
    assertEquals(1,h.player.currentMediaItemIndex);assertEquals(1700L,h.player.currentPosition)
    val fresh=t.begin{true};t.prepare();t.play();t.complete(fresh,h.items,0,0);assertTrue(h.player.playWhenReady)
   }finally{release.countDown();session.release();(field("jobs").get(s) as CoroutineScope).cancel()}
  }
 }
 @Test fun actualAddPreflightsCompleteQueueBeforeGrantPublication() {
  ServiceProbe(rolling=true).use {h->
   val s=service(h);val (cb,controller)=callback(s)
   val old=h.items.take(1).map {it.buildUpon().setMediaMetadata(it.mediaMetadata.buildUpon().setExtras(Bundle(it.mediaMetadata.extras).apply{putLong("durationMs",6000000)}).build()).build()}
   h.player.setMediaItems(old,0,0);h.graph.rememberTracks(listOf(Track(TrackId(50),"New",durationMs=6000000)))
   val before=h.grants.toMap();val session=androidx.media3.session.MediaSession.Builder(s,h.player).build()
   try {
    val result=cb.onAddMediaItems(session,controller,listOf(MediaItem.Builder().setMediaId("50").build()))
    assertTrue("aggregate insertion refusal before grant",runCatching{result.get()}.isFailure)
    assertEquals(before,h.grants);assertEquals(old,(0 until h.player.mediaItemCount).map(h.player::getMediaItemAt))
   }finally{session.release();(field("jobs").get(s) as CoroutineScope).cancel()}
  }
 }
 @Test fun failedUndoInstallReturnsFailureKeepsUndoAndRollsBackOnlyNewGrants() {
  ServiceProbe(rolling=true).use {h->
   val s=service(h);val (cb,controller)=callback(s);h.player.setMediaItems(h.items,1,1700)
   val before=h.grants.toMap()
   val saved=h.items.map {it.buildUpon().setMediaId(it.mediaId+"-undo").setUri(android.net.Uri.parse(it.localConfiguration!!.uri.toString()+"-undo")).build()}
   field("undo").set(s,saved);field("undoScope").set(s,h.scope)
   field("player").set(s,object:ForwardingPlayer(h.player){override fun setMediaItems(items:List<MediaItem>,index:Int,position:Long){throw IllegalArgumentException("synthetic Undo install failure")}})
   val t=field("transport").get(s) as ServiceTransportPlayer;val session=androidx.media3.session.MediaSession.Builder(s,t).build()
   try {
    val result=cb.onCustomCommand(session,controller,androidx.media3.session.SessionCommand(SoundQLibraryService.UNDO,Bundle.EMPTY),Bundle.EMPTY).get()
    assertNotEquals(0,result.resultCode);assertSame(saved,field("undo").get(s));assertEquals(before,h.grants)
    t.prepare();t.play();assertFalse(h.player.playWhenReady)
   }finally{session.release();(field("jobs").get(s) as CoroutineScope).cancel()}
  }
 }
}
