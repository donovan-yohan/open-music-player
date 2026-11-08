#!/usr/bin/env python3
"""Execute exact production recovery/dispatch/observation bodies with boundary facades.
No Android/Media3 runtime claim. Parent owns the mounted instrumentation journey.
--source-root replays the same fixture on preserved production. Pre-recovery API
snapshots retain the original observer-only behavioral probe, not a compile RED.
"""
import argparse
from pathlib import Path
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--build', type=Path, required=True)
p.add_argument('--source-root', type=Path, help='preserved Android production root')
a = p.parse_args()
root = a.source_root if a.source_root else Path(__file__).resolve().parents[1]
source = (root / 'app/src/main/kotlin/com/soundq/android/playback/nativeengine/NativeCallbackPlayer.kt').read_text()
owner = (root / 'app/src/main/kotlin/com/soundq/android/playback/nativeengine/NativeCallbackOwner.kt').read_text()


def method(text, marker):
    start = text.index(marker)
    brace = text.index('{', start)
    depth = 1
    at = brace + 1
    while depth:
        if text[at] == '{':
            depth += 1
        if text[at] == '}':
            depth -= 1
        at += 1
    return text[start:at]


has_recovery = '    suspend fun recoverOutput(' in owner
fail_old = method(source, '    private fun fail(message: String)')
fail = (method(source, '    private fun failOutput()') if '    private fun failOutput()' in source else
        fail_old.replace('private fun fail(message: String)', 'private fun failOutput(message: String = "Audio output is unavailable")'))
dispatch = method(source, '    private fun dispatchIntent(')
recover = method(owner, '    suspend fun recoverOutput(') if has_recovery else ''
entry = method(source, '    override fun handleSetPlayWhenReady(').replace('override fun', 'fun')
observe = method(source, '    private fun observe(').replace('private fun', 'fun')
pause_ack = method(source, '    private fun acknowledgePausePosition(') if '    private fun acknowledgePausePosition(' in source else ''
clock_receipt = source[source.index('    private class ClockSeekReceipt'):source.index('    /** One indexed seek,')] if '    private class ClockSeekReceipt' in source else ''
pause_ack += '\n'+clock_receipt
assignment = source[
    source.index('    private fun assignmentCurrent()'):source.index('    private fun selected()')]
if has_recovery:
    preparation = method(source, '    internal suspend fun prepareArrangement(')
    prepare_recovery = preparation[preparation.index('        val beforeRecovery ='):preparation.index('        val budget =')]
    assert 'owner.recoverOutput(::current)' in method(source, '    override fun handlePrepare(')
else:
    prepare_recovery = '        error("not executed in predecessor observer probe")'
fixture = '''
import kotlinx.coroutines.*
object Player {const val STATE_IDLE=1;const val STATE_BUFFERING=2;const val STATE_READY=3;const val STATE_ENDED=4;const val COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM=5}
class PlaybackException(s:String,c:Throwable?,v:Int):Exception(s){companion object{const val ERROR_CODE_IO_UNSPECIFIED=1}}
class ListenableFuture<T>
val String.mediaId:String get()=this
class Grant(val scope:Int)
class Session {var scope=1;fun current(s:Int)=s==scope}
class Graph {val session=Session()}
class NativeCallbackDeck(val identity:Long=3,val generation:Long=3,val positionMs:Long=1200,val durationMs:Long=5000,
 val sourceRate:Int=48000,val sourceFrames:Long=240000,val ready:Boolean=true,val playing:Boolean=false,
 val eofCount:Long=0,val error:Int=0,val scratching:Boolean=false,val syncState:Int=0)
class NativeCallbackSnapshot(val error:Int,val deck:NativeCallbackDeck=NativeCallbackDeck(),
 val decks:List<NativeCallbackDeck> = listOf(deck),val scheduleRevision:Long=0,val globalPositionMs:Long=1200,
 val scheduleDurationMs:Long=5000,val scheduleEnded:Boolean=false,val scheduleReady:Boolean=true,val schedulePlaying:Boolean=false)
class NativeCallbackArrangement(val revision:Long=7)
object NativeCallbackTraversal {fun next(o:List<Int>,i:Int,r:Int,e:Boolean):Int?=error("unexpected EOF")}
class Calls {
 var error=-899;val operations=mutableListOf<Int>();var entered:CompletableDeferred<Unit>?=null;var hold:CompletableDeferred<Unit>?=null
 var failRecovery=false;var throwRecovery=false;var playing=false
 suspend fun control(h:Long,op:Int,d:Int,v:Double,n:Long):Boolean {
  operations.add(op)
  if(op==9 && error!=0) {
   entered?.complete(Unit);hold?.await()
   if(throwRecovery)throw IllegalStateException("native recovery failed")
   if(failRecovery)return false
   error=0;playing=false
  }
  if(op==1)playing=true
  if(op==2)playing=false
  return true
 }
 fun snapshot()=NativeCallbackSnapshot(error,NativeCallbackDeck(playing=playing),schedulePlaying=playing)
}
class Owner(val calls:Calls) {
 val dispatcher=Dispatchers.Unconfined;var closing=false;var handle=1L;var observationRevision=0L
 RECOVER
 suspend fun control(op:Int,current:()->Boolean):Boolean {if(closing||!current())return false;return calls.control(1,op,0,0.0,0)}
 suspend fun arrangement(op:Int,current:()->Boolean)=control(op,current)
 suspend fun snapshot(current:()->Boolean):NativeCallbackSnapshot?=if(!closing&&current())calls.snapshot()else null
}
class Probe(val owner:Owner,val lifetime:CoroutineScope) {
 var released=false;var epoch=3L;var transportRevision=4L;var selectedLoaded=true;var arrangement:NativeCallbackArrangement?=null
 var desiredSeek:Long?=null;var submittedSeek:Long?=100;var acknowledgedSeekPosition:Long?=null
 var pausePosition:Long?=null;var acknowledgedPausePosition:Long?=null
 var performanceTransportHeld=false;var performanceDecks=emptyMap<String,String>()
 var intent=true;var acknowledgedPlaying=true;var playback=Player.STATE_READY;var outputUnavailable=false;var outputRecoveryRevision:Long?=null;var error:PlaybackException?=null
 var index=0;val items=listOf("a","b");var position=1200L;var retired=0;var performanceRevoked=0
 val graph=Graph();var queueScope:Int?=1;var activeUri:String?="source";var activeGrant:Grant?=Grant(1)
 val grants=mutableMapOf("source" to activeGrant!!);var arrangementGrants=grants.toMap()
 val durations=mutableMapOf<String,Long>();var eofCount=0L;var repeat=0;val completions=mutableListOf<(String)->Unit>()
 fun currentScope()=queueScope?.let(graph.session::current)==true
 ASSIGNMENT
 fun selected()=items.getOrNull(index)
 fun activeOrder()=items.indices.toList()
 fun observeTempo(snapshot:NativeCallbackSnapshot) {} // no tempo lease in this ordinary recovery fixture
 val onPerformanceChanged:(()->Unit)?=null
 fun publishPerformance(s:NativeCallbackSnapshot,a:NativeCallbackArrangement,notify:Boolean=true){}
 fun handlePrepare(){error("unexpected source preparation")}
 fun revokePerformance(){performanceRevoked++}
 fun invalidateState(){}
 fun seekNative(t:Long){submittedSeek=t}
 fun handleSeek(i:Int,p:Long,c:Int){error("unexpected seek")}
 fun done()=ListenableFuture<Unit>()
 suspend fun prepareRecovery() {
  fun valid()=!released&&assignmentCurrent()
 PREPARE_RECOVERY
 }
 fun retireSelection(){selectedLoaded=false;retired++;epoch++;transportRevision++}
 FAIL_OLD
 FAIL
 DISPATCH
 ENTRY
 PAUSE_ACK
 OBSERVE
}
suspend fun CoroutineScope.settle() {
 val admitted=coroutineContext[Job]!!.children.toList()
 withTimeout(5000) {admitted.joinAll()}
}
suspend fun CoroutineScope.retentionAndExplicitPlay() {
 val calls=Calls();val owner=Owner(calls);val p=Probe(owner,this)
 p.observe(NativeCallbackSnapshot(-899))
 check(p.selectedLoaded && p.position==1200L && p.retired==0 && !p.intent && p.outputUnavailable)
 p.observe(NativeCallbackSnapshot(0));check(calls.operations.isEmpty())
 p.handleSetPlayWhenReady(true);p.observe(NativeCallbackSnapshot(-899));settle()
 check(calls.operations==listOf(9,1));check(p.intent && !p.outputUnavailable && p.retired==0)
 println("PASS retained cursor, no observer replay, queued route error fenced, explicit recovery/Play")
}
suspend fun CoroutineScope.pauseCompletion(schedule:Boolean) {
 val calls=Calls();val owner=Owner(calls);val p=Probe(owner,this)
 if(schedule)p.arrangement=NativeCallbackArrangement()
 p.observe(NativeCallbackSnapshot(-899))
 calls.entered=CompletableDeferred();calls.hold=CompletableDeferred()
 p.handleSetPlayWhenReady(true);withTimeout(5000){calls.entered!!.await()}
 p.handleSetPlayWhenReady(false);calls.hold!!.complete(Unit);settle()
 check(1 !in calls.operations && !p.intent && p.retired==0)
 check(!p.outputUnavailable && p.error==null && p.outputRecoveryRevision==null) {"Pause stranded recovered output: unavailable=${p.outputUnavailable}, error=${p.error?.message}, recovery=${p.outputRecoveryRevision}"}
 p.observe(if(schedule)NativeCallbackSnapshot(0,scheduleRevision=7)else calls.snapshot())
 check(p.playback==Player.STATE_READY && !p.acknowledgedPlaying && !p.intent && p.position==1200L)
 calls.entered=null;calls.hold=null;calls.operations.clear()
 p.handleSetPlayWhenReady(true);settle()
 check(calls.operations==listOf(9,1) && calls.playing && p.intent && p.error==null)
 println("PASS held recovery + Pause settles READY paused, then fresh Play (schedule=$schedule)")
}
suspend fun CoroutineScope.failedRecovery(throwing:Boolean) {
 val calls=Calls();val owner=Owner(calls);val p=Probe(owner,this)
 p.observe(NativeCallbackSnapshot(-899));val message=p.error!!.message
 calls.entered=CompletableDeferred();calls.hold=CompletableDeferred();calls.failRecovery=!throwing;calls.throwRecovery=throwing
 p.handleSetPlayWhenReady(true);withTimeout(5000){calls.entered!!.await()}
 p.handleSetPlayWhenReady(false);calls.hold!!.complete(Unit);settle()
 check(p.outputUnavailable && p.error?.message==message && !p.intent && p.outputRecoveryRevision==null && 1 !in calls.operations)
 calls.entered=null;calls.hold=null;calls.failRecovery=false;calls.throwRecovery=false
 p.handleSetPlayWhenReady(true);settle()
 check(calls.operations.count{it==9}==2 && calls.playing && !p.outputUnavailable && p.error==null)
 println("PASS failed recovery preserves route error and allows explicit retry (throwing=$throwing)")
}
suspend fun CoroutineScope.lateSuccess(ownerChange:String,schedule:Boolean,replaceError:Boolean) {
 val calls=Calls();val owner=Owner(calls);val p=Probe(owner,this)
 if(schedule)p.arrangement=NativeCallbackArrangement()
 p.observe(NativeCallbackSnapshot(-899));calls.entered=CompletableDeferred();calls.hold=CompletableDeferred()
 p.handleSetPlayWhenReady(true);withTimeout(5000){calls.entered!!.await()}
 when(ownerChange) {
  "account" -> p.graph.session.scope=2
  "source" -> p.grants["source"]=Grant(1)
  "queue" -> {p.epoch++;p.transportRevision++}
  "release" -> {p.released=true;p.epoch++}
  "selection" -> p.selectedLoaded=false
  "source-aba" -> {p.retireSelection();p.selectedLoaded=true}
 }
 if(replaceError)p.error=PlaybackException("replacement $ownerChange error",null,1)
 val replacement=p.error
 calls.hold!!.complete(Unit);settle()
 check(p.error===replacement && p.outputUnavailable && p.outputRecoveryRevision==null && 1 !in calls.operations) {"late recovery cleared $ownerChange owner error"}
 println("PASS late success cannot clear $ownerChange error or submit Play (schedule=$schedule,replaceError=$replaceError)")
}
suspend fun CoroutineScope.newerRecoveryMarker() {
 val calls=Calls();val owner=Owner(calls);val p=Probe(owner,this)
 p.observe(NativeCallbackSnapshot(-899));calls.entered=CompletableDeferred();calls.hold=CompletableDeferred()
 p.handleSetPlayWhenReady(true);withTimeout(5000){calls.entered!!.await()}
 val successor=p.transportRevision+1;p.transportRevision=successor;p.outputRecoveryRevision=successor
 p.error=PlaybackException("successor recovery error",null,1);val replacement=p.error
 calls.hold!!.complete(Unit);settle()
 check(p.outputRecoveryRevision==successor && p.error===replacement && p.outputUnavailable && 1 !in calls.operations)
 println("PASS obsolete recovery cannot clear newer recovery token/error")
}
fun main()=runBlocking {
 retentionAndExplicitPlay()
 pauseCompletion(false)
 pauseCompletion(true)
 failedRecovery(false)
 failedRecovery(true)
 for(schedule in listOf(false,true)) {
  for(change in listOf("account","source","queue","release","selection","source-aba")) {
   lateSuccess(change,schedule,false)
   lateSuccess(change,schedule,true)
  }
  lateSuccess("new-error",schedule,true)
 }
 newerRecoveryMarker()
 val calls=Calls();val owner=Owner(calls);val applying=Probe(owner,this)
 applying.prepareRecovery()
 check(!applying.intent && applying.selectedLoaded && applying.retired==0 && calls.operations==listOf(9))
 calls.operations.clear();owner.closing=true
 check(!owner.recoverOutput{true});check(calls.operations.isEmpty())
 owner.closing=false;check(!owner.recoverOutput{false});check(calls.operations.isEmpty())
 println("PASS arrangement prepare-recovery, closing and revoked owner refusal")
}
'''.replace('PREPARE_RECOVERY', prepare_recovery).replace('FAIL_OLD', fail_old).replace('RECOVER', recover).replace('FAIL', fail).replace('DISPATCH', dispatch).replace('ENTRY', entry).replace('OBSERVE', observe).replace('PAUSE_ACK', pause_ack).replace('ASSIGNMENT', assignment)
if not has_recovery:
    # Preserve the original pre-recovery observer selection/cursor RED. No absent
    # recovery API is compiled/called and no downstream recovery assertions run.
    fixture = fixture[:fixture.index('suspend fun CoroutineScope.retentionAndExplicitPlay()')] + '''
fun main()=runBlocking {
 val calls=Calls();val p=Probe(Owner(calls),this)
 p.observe(NativeCallbackSnapshot(-899))
 check(p.selectedLoaded && p.position==1200L && p.retired==0 && !p.intent && p.outputUnavailable)
}
'''
a.build.mkdir(parents=True, exist_ok=True)
kt = a.build / 'Recovery.kt'
kt.write_text(fixture)
compiler = Path(subprocess.check_output(['which', 'kotlinc'], text=True).strip()).resolve()
coroutines = compiler.parents[1] / 'lib/kotlinx-coroutines-core-jvm.jar'
if not coroutines.exists():
    candidates = list(compiler.parents[2].rglob('kotlinx-coroutines-core-jvm.jar'))
    assert candidates, 'kotlin compiler coroutines missing'
    coroutines = candidates[0]
jar = a.build / 'recovery.jar'
subprocess.run(['kotlinc', '-J-Xmx512m', '-J-XX:ActiveProcessorCount=1', str(kt), '-cp', str(coroutines), '-include-runtime', '-d', str(jar)], check=True)
subprocess.run(['java', '-XX:ActiveProcessorCount=1', '-cp', f'{jar}:{coroutines}', 'RecoveryKt'], check=True)
