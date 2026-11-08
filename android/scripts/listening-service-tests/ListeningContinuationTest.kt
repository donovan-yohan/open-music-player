package com.soundq.android.playback.listening
import android.os.Bundle
import androidx.media3.common.*
import com.soundq.android.playback.*
import com.soundq.android.playback.system.ServiceTransportPlayer
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest=Config.NONE,sdk=[28],application=android.app.Application::class)
internal class ListeningContinuationTest {
 @Test fun naturalThreeFetchesTwoAndResumesSameOwnerAtExhaustedJoin() {
  ServiceProbe(rolling=true).use {h->
   h.graph.listeningPreferences.load()
   var requests=0
   h.tls.server.dispatcher=object:Dispatcher(){override fun dispatch(r:RecordedRequest):MockResponse {
    check(r.headers["Authorization"]=="Bearer a");requests++
    return MockResponse.Builder().body("""{"tracks":[{"id":90,"title":"Next90","duration_ms":10000},{"id":91,"title":"Next91","duration_ms":10000}],"total":2,"limit":100,"offset":0}""").build()
   }}
   val player=h.player;val transport=ServiceTransportPlayer(player){h.graph.session.current(h.scope)}
   val continuation=ServiceLibraryContinuation(player,transport,h.graph,h.jobs){tracks,valid->
    tracks.map {t->
     check(valid());val uri=android.net.Uri.parse("soundq://track/${t.id.value}/continued-${t.id.value}")
     h.grants[uri.toString()]=MediaGrant(h.scope,t.id,false)
     MediaItem.Builder().setMediaId("continued-${t.id.value}").setUri(uri).setMediaMetadata(MediaMetadata.Builder().setTitle(t.title).setExtras(Bundle().apply{putLong("trackId",t.id.value);putLong("durationMs",t.durationMs);putString("origin","Continuation")}).build()).build()
    }
   }
   transport.onIntentChanged=continuation::command
   player.addListener(object:Player.Listener {
    override fun onTimelineChanged(t:Timeline,r:Int)=continuation.timelineChanged()
    override fun onIsPlayingChanged(v:Boolean)=continuation.playingChanged(v)
    override fun onMediaItemTransition(m:MediaItem?,r:Int)=continuation.transition()
    override fun onPositionDiscontinuity(a:Player.PositionInfo,b:Player.PositionInfo,r:Int)=continuation.positionChanged(r)
    override fun onPlaybackStateChanged(s:Int)=continuation.ended(s)
    override fun onRepeatModeChanged(r:Int)=continuation.repeatChanged()
   })
   try {
    val original=h.items+ h.items.first().buildUpon().setMediaId("visit-c").build()
    val completed=mutableListOf<String>();h.onCompletion{completed+=it}
    player.setMediaItems(original,0,0);player.prepare();player.play();h.ready()
    h.present(8500);h.present(15500);h.present(24000,Player.STATE_ENDED)
    h.settle{!continuation.pending}
    assertEquals("actual exhausted append must not be refused by pausedMutation",5,player.mediaItemCount)
    assertEquals(1,requests);assertEquals(3,player.currentMediaItemIndex)
    assertEquals(0L,player.currentPosition);assertTrue("intent error=${player.playerError?.cause?.stackTraceToString()} physical=${h.physicalState} seeks=${h.seekCalls} requests=$requests",player.playWhenReady)
    assertEquals(original.map{it.mediaId},completed)
    original.forEachIndexed{i,item->assertSame(item,player.getMediaItemAt(i))}
    assertEquals(listOf("Continuation","Continuation"),(3..4).map{player.getMediaItemAt(it).mediaMetadata.extras!!.getString("origin")})
    assertEquals(24000L,h.seekCalls.last());assertEquals(1,h.outputItems)
    h.physicalState=Player.STATE_READY;h.present(24000);assertEquals(3,player.currentMediaItemIndex)
    assertEquals(original.map{it.mediaId},completed)
    continuation.ended(Player.STATE_ENDED);assertEquals(1,requests)
   } finally {continuation.close()}
  }
 }

 private class Harness:AutoCloseable {
  val h=ServiceProbe(rolling=true)
  val player=h.player
  val transport=ServiceTransportPlayer(player){h.graph.session.current(h.scope)}
  val entered=java.util.concurrent.CountDownLatch(1)
  val release=java.util.concurrent.CountDownLatch(1)
  var held=false
  var failure=false
  var duration=10000L
  var fetches=0
  var resolved=0
  val originals=h.items+h.items[0].buildUpon().setMediaId("third").build()
  val continuation:ServiceLibraryContinuation
  init {
   h.graph.listeningPreferences.load()
   h.tls.server.dispatcher=object:Dispatcher(){override fun dispatch(r:RecordedRequest):MockResponse {
    check(r.headers["Authorization"]=="Bearer a");fetches++;entered.countDown()
    if(held)check(release.await(10,java.util.concurrent.TimeUnit.SECONDS))
    if(failure)return MockResponse.Builder().code(503).build()
    return MockResponse.Builder().body("""{"tracks":[{"id":90,"title":"Next90","duration_ms":$duration},{"id":91,"title":"Next91","duration_ms":$duration}],"total":2,"limit":100,"offset":0}""").build()
   }}
   continuation=ServiceLibraryContinuation(player,transport,h.graph,h.jobs){tracks,valid->
    resolved++;tracks.map{track->check(valid());val uri=android.net.Uri.parse("soundq://track/${track.id.value}/continued-$resolved-${track.id.value}")
     h.grants[uri.toString()]=MediaGrant(h.scope,track.id,false)
     h.items[0].buildUpon().setMediaId("continued-$resolved-${track.id.value}").setUri(uri).setMediaMetadata(h.items[0].mediaMetadata.buildUpon().setExtras(Bundle().apply{putLong("trackId",track.id.value);putLong("durationMs",track.durationMs);putString("origin","Continuation")}).build()).build()
    }
   }
   transport.onIntentChanged=continuation::command
   player.addListener(object:Player.Listener {
    override fun onTimelineChanged(t:Timeline,r:Int)=continuation.timelineChanged()
    override fun onIsPlayingChanged(v:Boolean)=continuation.playingChanged(v)
    override fun onMediaItemTransition(m:MediaItem?,r:Int)=continuation.transition()
    override fun onPositionDiscontinuity(a:Player.PositionInfo,b:Player.PositionInfo,r:Int)=continuation.positionChanged(r)
    override fun onPlaybackStateChanged(s:Int)=continuation.ended(s)
    override fun onRepeatModeChanged(r:Int)=continuation.repeatChanged()
   })
  }
  fun start(){player.setMediaItems(originals,0,0);player.prepare();player.play();h.ready()}
  fun end(){h.present(8500);h.present(15500);h.present(24000,Player.STATE_ENDED)}
  fun cancel(action:String){when(action){
   "pause"->transport.pause()
   "stop"->transport.stop()
   "seek"->{transport.retire();player.seekTo(0,0)}
   "replacement"->transport.setMediaItems(originals.take(1),0,0)
   "repeat"->{transport.retire();player.repeatMode=Player.REPEAT_MODE_ALL}
   "mode"->{val prefs=h.graph.listeningPreferences;check(prefs.setMode(prefs.capture()!!,com.soundq.android.data.preferences.EndOfQueue.Off){true})}
   "account"->h.graph.session.retire()
   "lock"->check(h.graph.session.lockLocal())
  }}
  fun settled()=h.settle{!continuation.pending && h.preparationSettled}
  override fun close(){release.countDown();continuation.close();h.close()}
 }
 @Test fun heldAuthenticatedFetchCannotPublishAfterPauseStopSeekReplacementRepeatModeAccountOrLock(){
  for(action in listOf("pause","stop","seek","replacement","repeat","mode","account","lock"))Harness().use{f->
   f.held=true;f.start();f.end();assertTrue(f.entered.await(3,java.util.concurrent.TimeUnit.SECONDS));f.cancel(action);f.release.countDown();f.settled()
   assertEquals("no resolver after $action",0,f.resolved);assertEquals(1,f.fetches);assertFalse((0 until f.player.mediaItemCount).any{f.player.getMediaItemAt(it).mediaId.startsWith("continued")})
  }
 }
 @Test fun heldRetiredRootFencesNewPreparationAndCancellationBeforeAutoplay(){
  for(action in listOf("pause","stop","seek","replacement","repeat","mode","account","lock"))Harness().use{f->
   f.start()
   val old=f.h.render();old.open(androidx.media3.datasource.DataSpec(android.net.Uri.parse("soundqlistening://render/held")))
   try{
    val before=f.h.playCalls;f.end();f.h.settle{f.player.mediaItemCount==5 && !f.h.preparationSettled}
    assertEquals(0,f.h.outputItems);assertEquals(Player.STATE_BUFFERING,f.player.playbackState);assertEquals(before,f.h.playCalls)
    f.cancel(action);old.close();f.settled();assertEquals("no late autoplay after $action",before,f.h.playCalls);assertFalse(f.h.playing)
   }finally{old.close()}
  }
 }
 @Test fun secondNaturalBatchRearmsOnlyAfterNewOutputAndNeverReplaysCompletedHistory(){Harness().use{f->
  val completed=mutableListOf<String>();f.h.onCompletion{completed+=it};f.start();f.end();f.settled()
  assertEquals(5,f.player.mediaItemCount);assertEquals(1,f.fetches)
  f.h.present(24000);assertEquals(f.originals.map{it.mediaId},completed)
  f.h.present(32500);f.h.present(41000,Player.STATE_ENDED);f.settled()
  assertEquals(6,f.player.mediaItemCount);assertEquals(2,f.fetches);assertEquals(5,f.player.currentMediaItemIndex)
  assertEquals(5,completed.size);assertEquals(5,completed.distinct().size)
  f.h.present(41000);assertEquals(5,completed.size)
 }}
 @Test fun rejectedDurationRiffAndWholeBatchCapacityPreserveOldOutputCursorIntent(){
  for(kind in listOf("invalid","riff","capacity","failure"))Harness().use{f->
   if(kind=="capacity"){
    val rows=(0 until 499).map{f.originals[it%3].buildUpon().setMediaId("capacity-$it").setMediaMetadata(f.originals[it%3].mediaMetadata.buildUpon().setExtras(Bundle(f.originals[it%3].mediaMetadata.extras).apply{putLong("durationMs",1)}).build()).build()}
    f.player.setMediaItems(rows,498,0);f.player.prepare();f.player.play();f.h.ready();f.continuation.playingChanged(true)
   }else f.start()
   if(kind=="invalid")f.duration=0
   if(kind=="riff")f.duration=604800000
   if(kind=="failure")f.failure=true
   val count=f.player.mediaItemCount;val physical=f.h.physicalItems;val before=f.h.playCalls;val grants=f.h.grants.toMap()
   if(kind=="capacity")f.h.present(499,Player.STATE_ENDED) else f.end()
   f.settled();assertEquals(grants,f.h.grants.toMap());assertEquals(count,f.player.mediaItemCount);assertSame(physical,f.h.physicalItems);assertEquals(before,f.h.playCalls);assertTrue(f.player.playWhenReady);assertNull(f.player.playerError)
  }
 }


 @Test fun duplicateMissingGrantAnd501AdmissionCannotChangeExhaustedOwner(){ServiceProbe(rolling=true).use{h->
  val player=h.player as ListeningServicePlayer;h.install();h.ready();h.present(17000,Player.STATE_ENDED)
  val originals=(0 until player.mediaItemCount).map{player.getMediaItemAt(it)};val physical=h.physicalItems;val before=h.playCalls;val position=player.currentPosition;val grants=h.grants.toMap()
  val missing=h.items[0].buildUpon().setMediaId("missing").setUri(android.net.Uri.parse("soundq://track/7/missing")).build()
  for(rows in listOf(listOf(h.items[0]),listOf(missing),List(499){h.items[0].buildUpon().setMediaId("overflow-$it").build()})){
   try{player.continueExhaustedQueue(rows,{true},{true});fail("invalid batch rejected")}catch(_:IllegalArgumentException){}catch(_:IllegalStateException){}
   assertEquals(originals,(0 until player.mediaItemCount).map{player.getMediaItemAt(it)});assertSame(physical,h.physicalItems);assertEquals(before,h.playCalls);assertEquals(position,player.currentPosition);assertTrue(player.playWhenReady);assertEquals(grants,h.grants.toMap())
  }
 }}


 @Test fun exhaustedAppendCannotBypassFailedPredecessorCustody(){Harness().use{f->
  f.start()
  fun field(type:Class<*>,name:String)=type.getDeclaredField(name).also{it.isAccessible=true}
  val logical=f.player as ListeningServicePlayer
  val prepared=field(ListeningServicePlayer::class.java,"prepared").get(logical) as PreparedListening
  val root=field(PreparedListening::class.java,"rolling").get(prepared) as RollingListeningRoot
  val generation=field(PreparedListening::class.java,"pcm").get(prepared) as RollingListeningPcm
  val failure=java.io.IOException("retained exhaustion predecessor")
  val slot=root.reserve(root.schedule.occurrences.first());slot.failure=failure
  @Suppress("UNCHECKED_CAST") val slots=field(RollingListeningPcm::class.java,"slots").get(generation) as MutableMap<String,RollingListeningRoot.Slot>
  slots[slot.occurrence.source.occurrence]=slot
  val before=f.h.playCalls;f.end();f.h.settle{f.player.mediaItemCount==5 && !f.h.preparationSettled}
  val deadline=System.nanoTime()+java.util.concurrent.TimeUnit.SECONDS.toNanos(20)
  while(!logical.preparationSettled && System.nanoTime()<deadline){org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();Thread.yield()}
  f.settled();assertEquals(before,f.h.playCalls);assertEquals(0,f.h.outputItems);assertFalse(f.player.playWhenReady);assertNull("unrequested deadline failure stays silent",f.player.playerError)
  assertFalse(prepared.released.isDone);assertEquals(1,root.snapshot().slots)
  assertSame(failure,slot.failure);assertSame(prepared,(field(ListeningServicePlayer::class.java,"retiredRenders").get(logical) as List<*>).single())
 }}

}
