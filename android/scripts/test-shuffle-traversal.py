#!/usr/bin/env python3
"""Execute explicitly selected legacy factory traversal with real pinned ShuffleOrder.
Host player facade only: production selects NativeCallbackPlayer, not this fixture.
No Android/ExoPlayer/native runtime claim. --service/--queue permit baseline replay.
"""
import argparse, hashlib, json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--generate',type=Path,required=True);p.add_argument('--service',type=Path);p.add_argument('--queue',type=Path);a=p.parse_args()
base=Path(__file__).resolve().parents[1]/'app/src/main/kotlin/com/soundq/android/playback'
service=(a.service or base/'SoundQLibraryService.kt').read_text()
app=(base.parent/'SoundQApplication.kt').read_text()
factory_start=app.index('    internal open fun createLibraryPlayer(')
factory_end=app.index('\n\n',factory_start)
factory=app[factory_start:factory_end]
assert factory.count('= com.soundq.android.playback.ServiceQueuePlayer(output)')==1
# Explicit legacy selection, NOT extracted production construction. Execute the
# retained application's actual factory expression against the host output facade.
factory_expression=factory.split('): androidx.media3.common.Player = ',1)[1].strip()
factory_expression=factory_expression.replace('com.soundq.android.playback.','')
construction='val output=ExoPlayer.Builder(factory).build();player=createLibraryPlayer(output)'
if not a.service:
 assert '(application as SoundQApplication).createCallbackLibraryPlayer(grants, jobs)' in service
 assert 'ExoPlayer.Builder(' not in service
 assert '): androidx.media3.common.Player = com.soundq.android.playback.nativeengine.NativeCallbackPlayer(graph, grants, jobs)' in app
jam=next(l.strip() for l in service.splitlines() if 'player.addMediaItem(QueuePolicy.manualInsert(' in l)
continuation=(base/'ServiceLibraryContinuation.kt').read_text()
ordinary='else {player.addMediaItems(items);player.seekTo(start,0);player.prepare();player.play()}'
assert continuation.count(ordinary)==1
commit='run '+ordinary.removeprefix('else ')
policy=(base/'QueuePolicy.kt').read_text().split('object QueuePolicy {',1)[1]
queue=a.queue or base/'ServiceQueuePlayer.kt'
body=queue.read_text() if queue.exists() else ''
body='\n'.join(l for l in body.splitlines() if not l.startswith(('package ','import ','@androidx.'))).replace('internal class ','private class ')
prelude='''@file:Suppress("PARAMETER_NAME_CHANGED_ON_OVERRIDE", "UNNECESSARY_SAFE_CALL")
package com.soundq.android.shuffleprobe
import androidx.media3.exoplayer.source.ShuffleOrder
import kotlin.random.Random
import org.junit.Test
import org.junit.Assert.*
private class Bundle(private val manual:Boolean=false,private val origin:String="Context") {fun getBoolean(k:String)=manual;fun getString(k:String)=origin}
private class Metadata(val extras:Bundle?)
private class MediaItem(val mediaId:String,val track:Long=1,val manual:Boolean=false,val origin:String=if(manual)"Manual" else "Context") {val mediaMetadata=Metadata(Bundle(manual,origin));class Local(val uri:Uri);val localConfiguration:Local?=Local(Uri("soundq"))}
private class Uri(val scheme:String)
private object C {const val INDEX_UNSET=-1;const val TIME_UNSET=-9223372036854775807L;const val USAGE_MEDIA=1;const val AUDIO_CONTENT_TYPE_MUSIC=2}
private object AudioAttributes {class Builder {fun setUsage(i:Int)=this;fun setContentType(i:Int)=this;fun build()=this}}
private class DefaultMediaSourceFactory(v:Any)
private class Timeline(private val p:ExoPlayer) {val isEmpty get()=p.mediaItemCount==0;fun getFirstWindowIndex(shuffle:Boolean)=if(shuffle)p.shuffleOrder.firstIndex else if(isEmpty)-1 else 0;fun getNextWindowIndex(i:Int,repeat:Int,shuffle:Boolean)=if(shuffle)p.shuffleOrder.getNextIndex(i) else (i+1).takeIf{it<p.mediaItemCount} ?: -1}
private open class Player {
 companion object {const val REPEAT_MODE_OFF=0}
 open val mediaItemCount:Int get()=error("boundary");open val currentMediaItemIndex:Int get()=error("boundary");open val currentPosition:Long get()=error("boundary");open val currentMediaItem:MediaItem? get()=error("boundary");open val currentTimeline:Timeline get()=error("boundary")
 open fun getShuffleModeEnabled():Boolean=error("boundary");open fun setShuffleModeEnabled(v:Boolean){error("boundary")}
 open fun getMediaItemAt(i:Int):MediaItem=error("boundary")
 open fun setMediaItems(v:List<MediaItem>) {setMediaItems(v,true)}
 open fun setMediaItems(v:List<MediaItem>,reset:Boolean) {setMediaItems(v,if(reset)0 else currentMediaItemIndex,if(reset)0 else currentPosition)}
 open fun setMediaItems(v:List<MediaItem>,i:Int,p:Long) {error("boundary")}
 open fun setMediaItem(v:MediaItem) {setMediaItems(listOf(v))};open fun setMediaItem(v:MediaItem,p:Long){setMediaItems(listOf(v),0,p)};open fun setMediaItem(v:MediaItem,reset:Boolean){setMediaItems(listOf(v),reset)}
 open fun addMediaItems(v:List<MediaItem>){addMediaItems(mediaItemCount,v)};open fun addMediaItems(i:Int,v:List<MediaItem>){error("boundary")};open fun addMediaItem(v:MediaItem){addMediaItems(listOf(v))};open fun addMediaItem(i:Int,v:MediaItem){addMediaItems(i,listOf(v))}
 open fun removeMediaItems(f:Int,t:Int){error("boundary")};open fun removeMediaItem(i:Int){removeMediaItems(i,i+1)};open fun clearMediaItems(){removeMediaItems(0,mediaItemCount)}
 open fun moveMediaItems(f:Int,t:Int,n:Int){error("boundary")};open fun moveMediaItem(f:Int,t:Int){moveMediaItems(f,f+1,t)}
 open fun replaceMediaItems(f:Int,t:Int,v:List<MediaItem>){error("boundary")};open fun replaceMediaItem(i:Int,v:MediaItem){replaceMediaItems(i,i+1,listOf(v))}
 open fun prepare(){error("boundary")};open fun play(){error("boundary")}
 open fun seekTo(i:Int,p:Long){error("boundary")}
}
private open class ForwardingPlayer(protected val delegate:Player):Player() {
 override val mediaItemCount get()=delegate.mediaItemCount;override val currentMediaItemIndex get()=delegate.currentMediaItemIndex;override val currentPosition get()=delegate.currentPosition;override val currentMediaItem get()=delegate.currentMediaItem;override val currentTimeline get()=delegate.currentTimeline
 override fun getShuffleModeEnabled()=delegate.getShuffleModeEnabled();override fun setShuffleModeEnabled(v:Boolean){delegate.setShuffleModeEnabled(v)}
 override fun getMediaItemAt(i:Int)=delegate.getMediaItemAt(i)
 override fun setMediaItems(v:List<MediaItem>,i:Int,p:Long)=delegate.setMediaItems(v,i,p)
 override fun setMediaItems(v:List<MediaItem>,reset:Boolean)=delegate.setMediaItems(v,reset)
 override fun addMediaItems(i:Int,v:List<MediaItem>)=delegate.addMediaItems(i,v)
 override fun removeMediaItems(f:Int,t:Int)=delegate.removeMediaItems(f,t)
 override fun moveMediaItems(f:Int,t:Int,n:Int)=delegate.moveMediaItems(f,t,n)
 override fun replaceMediaItems(f:Int,t:Int,v:List<MediaItem>)=delegate.replaceMediaItems(f,t,v)
 override fun prepare()=delegate.prepare();override fun play()=delegate.play()
 override fun seekTo(i:Int,p:Long)=delegate.seekTo(i,p)
}
// The following is the hardware boundary only. Clone call ordering is pinned by
// ExoPlayerImpl 1.11.1 bytecode. Assertions observe the permutation AT dispatch.
private class ExoPlayer:Player() {
 var rows=listOf<MediaItem>();var selected=0;var position=1700L;var playing=true;var pauses=0;var prepares=0;var seeks=0;var modeWrites=0;var orderWrites=0;var traversalEvents=0;var traversalOnlyEvents=0;var dispatched=emptyList<Int>()
 @JvmField var shuffleOrder:ShuffleOrder=ShuffleOrder.DefaultShuffleOrder(intArrayOf(),0L)
 fun setAudioAttributes(v:Any,b:Boolean){}
 override fun prepare(){prepares++};override fun play(){playing=true}
 class Builder(v:Any){fun setMediaSourceFactory(v:Any)=this;fun build()=ExoPlayer().also{last=it}}
 companion object {lateinit var last:ExoPlayer}
 override val mediaItemCount get()=rows.size;override val currentMediaItemIndex get()=selected;override val currentPosition get()=position;override val currentMediaItem get()=rows.getOrNull(selected);override val currentTimeline get()=Timeline(this)
 private var mode=false
 override fun getShuffleModeEnabled()=mode;override fun setShuffleModeEnabled(v:Boolean){if(v==mode)return;modeWrites++;mode=v}
 override fun getMediaItemAt(i:Int)=rows[i]
 fun setShuffleOrder(v:ShuffleOrder){orderWrites++;shuffleOrder=v;traversalEvents++;if(owner?.javaClass?.declaredMethods?.firstOrNull{it.name=="getChangingTraversal"}?.also{it.isAccessible=true}?.invoke(owner)==true)traversalOnlyEvents++}
 var owner:Player?=null
 private fun dispatched(){dispatched=order();check(dispatched.sorted()==rows.indices.toList())}
 fun order():List<Int> {val v=mutableListOf<Int>();var i=shuffleOrder.firstIndex;while(i!=-1){check(i !in v);v.add(i);i=shuffleOrder.getNextIndex(i)};return v}
 override fun setMediaItems(v:List<MediaItem>,i:Int,p:Long) {rows=v.toList();shuffleOrder=shuffleOrder.cloneAndSet(v.size,i);selected=if(v.isEmpty())0 else i.coerceIn(v.indices);position=p;dispatched()}
 override fun addMediaItems(i:Int,v:List<MediaItem>){val id=currentMediaItem?.mediaId;rows=rows.toMutableList().apply{addAll(i,v)};shuffleOrder=shuffleOrder.cloneAndInsert(i,v.size);selected=rows.indexOfFirst{it.mediaId==id}.coerceAtLeast(0);dispatched()}
 override fun removeMediaItems(f:Int,t:Int){val id=currentMediaItem?.mediaId;rows=rows.toMutableList().apply{subList(f,t).clear()};shuffleOrder=shuffleOrder.cloneAndRemove(f,t);selected=rows.indexOfFirst{it.mediaId==id}.takeIf{it>=0} ?: f.coerceAtMost((rows.size-1).coerceAtLeast(0));dispatched()}
 override fun moveMediaItems(f:Int,t:Int,n:Int){val id=currentMediaItem?.mediaId;rows=rows.toMutableList().apply{val moved=subList(f,t).toList();subList(f,t).clear();addAll(n,moved)};shuffleOrder=shuffleOrder.cloneAndMove(f,t,n);selected=rows.indexOfFirst{it.mediaId==id};dispatched()}
 override fun replaceMediaItems(f:Int,t:Int,v:List<MediaItem>){addMediaItems(t,v);removeMediaItems(f,t)}
 override fun seekTo(i:Int,p:Long){selected=i;position=p;seeks++}
}
private object QueuePolicy {POLICY
// Legacy factory fixture only; this is not SoundQLibraryService construction.
private class Service {val factory=Any();lateinit var player:Player;fun createLibraryPlayer(output:ExoPlayer):Player=FACTORY_EXPRESSION;fun create(){CONSTRUCTION}
 fun jam(item:MediaItem){val origins=(0 until player.mediaItemCount).map{player.getMediaItemAt(it).mediaMetadata.extras?.getBoolean("manual")==true};JAM}
 fun continueWith(items:List<MediaItem>){val start=player.mediaItemCount;var committing=true;COMMIT}
}
private fun fixture():Pair<Player,ExoPlayer> {val s=Service();s.create();ExoPlayer.last.owner=s.player;return s.player to ExoPlayer.last}
class ShuffleTraversalExtractedTest {
 @Test fun explicitLegacyFactorySelectionEnablesCurrentFirstNonlinearTraversalWithoutPlaybackMutation() {
  val (p,e)=fixture();val rows=List(5){MediaItem("occ-$it")};p.setMediaItems(rows,2,1700);val source=p.currentMediaItem;val events=e.traversalOnlyEvents
  p.setShuffleModeEnabled(true)
  assertEquals("selected occurrence must be traversal head",2,e.order().first());assertEquals(events+1,e.traversalOnlyEvents);assertNotEquals(listOf(0,1,3,4),e.order().drop(1));assertSame(source,p.currentMediaItem);assertEquals(rows,e.rows);assertEquals(1700L,p.currentPosition);assertTrue(e.playing);assertEquals(0,e.seeks)
 }
 @Test fun manualBatchAndSecondRequestPrecedeContextAtActualCloneDispatch() {
  val (p,e)=fixture();p.setMediaItems(List(5){MediaItem("context-$it")},2,1700);p.setShuffleModeEnabled(true)
  val old=e.order().map{e.rows[it].mediaId};p.addMediaItems(3,listOf(MediaItem("m1",7,true),MediaItem("m2",7,true)))
  assertEquals(listOf("m1","m2"),e.dispatched.dropWhile{e.rows[it].mediaId!="context-2"}.drop(1).take(2).map{e.rows[it].mediaId})
  p.addMediaItem(5,MediaItem("m3",7,true));assertEquals(listOf("m1","m2","m3"),e.dispatched.drop(1).take(3).map{e.rows[it].mediaId})
  assertEquals(old,e.order().map{e.rows[it].mediaId}.filter{it.startsWith("context")});assertEquals(8,e.rows.map{it.mediaId}.distinct().size);assertEquals(1700L,p.currentPosition);assertTrue(e.playing)
 }
 @Test fun continuationAppendsAfterRetainedHistoryAndModeCommandsAreAbsolute() {
  val (p,e)=fixture();p.setMediaItems(List(5){MediaItem("c$it")},2,1700);p.setShuffleModeEnabled(true)
  val order=e.order();val writes=e.orderWrites;val modes=e.modeWrites;p.setShuffleModeEnabled(true)
  assertEquals(order,e.order());assertEquals(writes,e.orderWrites);assertEquals(modes,e.modeWrites)
  p.seekTo(order[2],1700);val retained=e.order().map{e.rows[it].mediaId};p.addMediaItems(listOf(MediaItem("a",1,false,"Continuation"),MediaItem("b",1,false,"Continuation")))
  assertEquals(retained+listOf("a","b"),e.dispatched.map{e.rows[it].mediaId});assertEquals(1700L,p.currentPosition)
  p.setShuffleModeEnabled(false);assertEquals(e.rows.indices.toList(),e.order());val off=e.orderWrites;p.setShuffleModeEnabled(false);assertEquals(off,e.orderWrites)
 }
 @Test fun replacementCarriedManualRemoveMoveAndEmptyUseReferenceScope() {
  val (p,e)=fixture();p.setMediaItems(List(5){MediaItem("c$it")},2,1700);p.setShuffleModeEnabled(true)
  p.setMediaItems(listOf(MediaItem("new"),MediaItem("carried",7,true),MediaItem("other")),0,1700)
  assertEquals(listOf(0,1,2),e.dispatched)
  p.addMediaItem(2,MediaItem("request",7,true));assertEquals(listOf("carried","request"),e.dispatched.drop(1).take(2).map{e.rows[it].mediaId})
  val selected=p.currentMediaItem;p.moveMediaItem(3,1);assertSame(selected,p.currentMediaItem);assertEquals(p.currentMediaItemIndex,e.dispatched.first());p.removeMediaItem(1);assertSame(selected,p.currentMediaItem);assertEquals(p.currentMediaItemIndex,e.dispatched.first())
  p.clearMediaItems();assertTrue(e.order().isEmpty());p.setShuffleModeEnabled(false);p.setShuffleModeEnabled(true);p.addMediaItem(MediaItem("single",7,true));assertEquals(listOf(0),e.dispatched)
 }
 @Test fun directJamAndNaturalContinuationConsumeTheSameServiceBoundary() {
  val s=Service();s.create();val p=s.player;val e=ExoPlayer.last
  p.setMediaItems(List(5){MediaItem("ctx$it")},2,1700);p.setShuffleModeEnabled(true)
  s.jam(MediaItem("jam1",7,true));s.jam(MediaItem("jam2",7,true))
  assertEquals(listOf("jam1","jam2"),e.dispatched.drop(1).take(2).map{e.rows[it].mediaId})
  val history=e.order().map{e.rows[it].mediaId};s.continueWith(listOf(MediaItem("continuation",7,false,"Continuation")))
  assertEquals(history+"continuation",e.order().map{e.rows[it].mediaId});assertEquals("continuation",p.currentMediaItem!!.mediaId);assertEquals(1,e.prepares)
 }
 @Test fun malformedMutationRefusesBeforeOutputAndMixedSingleStaysAuthored() {
  val (p,e)=fixture();p.setMediaItems(listOf(MediaItem("mixed")),0,1700);p.setShuffleModeEnabled(true);assertEquals(listOf(0),e.order())
  val before=e.rows;try {p.addMediaItem(3,MediaItem("bad"));fail()}catch(_:RuntimeException){};assertEquals(before,e.rows)
 }
}
'''.replace('FACTORY_EXPRESSION',factory_expression).replace('CONSTRUCTION',construction).replace('POLICY',policy).replace('JAM',jam).replace('COMMIT',commit)
# Execute the composed restoration statements with the real queue wrapper too.
# Coroutine/account admission remains covered by the independent persistence probe.
def block(text,marker):
 s=text.index(marker);i=text.index('{',s)+1;depth=1
 while depth:
  depth+=(text[i]=='{')-(text[i]=='}');i+=1
 return text[s:i]
restore=block(service,'    private fun restoreModes(').replace('private fun','fun',1)
# Exact restoration callback extraction needs the current native branch symbol.
# Declared out-of-scope facade: never instantiated by this legacy-only fixture.
restoring=block(service,'    private fun <T> Player.restoringShuffle(').replace('com.soundq.android.playback.nativeengine.NativeCallbackPlayer','NativeCallbackPlayer')
startup=next(l.strip() for l in service.splitlines() if 'player.pause();player.' in l and 'never prepare/play on restore' in l)
resume=next(l.strip() for l in service.splitlines() if 'try {restoreModes(saved);' in l and 'transport.complete(owner,items,saved.selected,saved.position)' in l)
prelude=prelude.replace('companion object {const val REPEAT_MODE_OFF=0}', 'companion object {const val REPEAT_MODE_OFF=0;const val REPEAT_MODE_ONE=1;const val REPEAT_MODE_ALL=2}\n var repeatMode=0')
prelude=prelude.replace('open fun prepare(){error("boundary")};open fun play(){error("boundary")}', 'open fun pause(){error("boundary")};open fun prepare(){error("boundary")};open fun play(){error("boundary")}')
prelude=prelude.replace('override fun prepare()=delegate.prepare();override fun play()=delegate.play()', 'override fun pause()=delegate.pause();override fun prepare()=delegate.prepare();override fun play()=delegate.play()')
prelude=prelude.replace('override fun prepare(){prepares++};override fun play(){playing=true}', 'override fun pause(){playing=false;pauses++};override fun prepare(){prepares++};override fun play(){playing=true}')
composition='''
private var Player.shuffleModeEnabled:Boolean
 get()=getShuffleModeEnabled()
 set(v){setShuffleModeEnabled(v)}
private enum class SavedRepeatMode {Off,One,All}
private class QueueSnapshot(val selected:Int=2,val position:Long=2300,val shuffleEnabled:Boolean=true,val loopMode:SavedRepeatMode=SavedRepeatMode.All)
private class RestoreTransport(val player:ServiceQueuePlayer) {fun complete(owner:Any,items:List<MediaItem>,index:Int,position:Long){player.setMediaItems(items,index,position)}}
// Out of scope: native callback behavior has independent runtime coverage.
private class NativeCallbackPlayer:Player() {fun <T> restoringShuffle(enabled:Boolean,action:()->T):T=error("native callback is outside legacy shuffle fixture")}
private class RestoreComposition(val player:ServiceQueuePlayer) {
 val owner=Any()
 val transport=RestoreTransport(player)
 RESTORING
 RESTORE
 fun startup(saved:QueueSnapshot,items:List<MediaItem>){STARTUP
 restoreModes(saved)}
 fun resume(saved:QueueSnapshot,items:List<MediaItem>){RESUME finally {}}
}
class ShuffleRestoreCompositionTest {
 private fun verify(resumption:Boolean,alreadyEnabled:Boolean) {
  val (p,e)=fixture();val queue=p as ServiceQueuePlayer
  p.setMediaItems(List(5){MediaItem("old-$it")},1,1700)
  if(alreadyEnabled)p.setShuffleModeEnabled(true)
  p.pause();val rows=List(5){MediaItem("saved-$it")};val saved=QueueSnapshot()
  val restore=RestoreComposition(queue)
  if(resumption)restore.resume(saved,rows) else restore.startup(saved,rows)
  assertTrue(p.shuffleModeEnabled);assertEquals(Player.REPEAT_MODE_ALL,p.repeatMode)
  assertEquals("saved current occurrence must head restored shuffle",2,e.order().first())
  assertNotEquals(listOf(0,1,3,4),e.order().drop(1));assertEquals(rows,e.rows)
  assertEquals("saved-2",p.currentMediaItem!!.mediaId);assertEquals(2300L,p.currentPosition)
  assertFalse(e.playing);assertEquals(0,e.prepares);assertEquals(0,e.seeks)
 }
 @Test fun startupSavedShuffleRestoresThroughWrapperPaused(){verify(false,false)}
 @Test fun startupAlreadyEnabledReplacesTimelineWithRestoredTraversal(){verify(false,true)}
 @Test fun resumptionSavedShuffleRestoresThroughWrapperPaused(){verify(true,false)}
 @Test fun resumptionAlreadyEnabledReplacesTimelineWithRestoredTraversal(){verify(true,true)}
}
'''.replace('RESTORING',restoring).replace('RESTORE',restore).replace('STARTUP',startup).replace('RESUME',resume)
a.generate.mkdir(parents=True,exist_ok=True)
(a.generate/'ShuffleTraversalExtractedTest.kt').write_text(prelude.replace('class ShuffleTraversalExtractedTest',body+'\n'+composition+'\nclass ShuffleTraversalExtractedTest'))
(a.generate/'extraction.json').write_text(json.dumps({'serviceSha256':hashlib.sha256(service.encode()).hexdigest(),'constructionSha256':hashlib.sha256(construction.encode()).hexdigest(),'factorySha256':hashlib.sha256(factory.encode()).hexdigest(),'fixtureSelection':'explicit retained SoundQApplication.createLibraryPlayer legacy factory; not production service selection','productionSelection':'SoundQApplication.createCallbackLibraryPlayer -> NativeCallbackPlayer' if not a.service else 'baseline replay; current production selection not asserted','queueSha256':hashlib.sha256(body.encode()).hexdigest(),'boundary':'legacy host player facade; real pinned Media3 ShuffleOrder; native callback facade out of scope and never instantiated'},indent=2))
