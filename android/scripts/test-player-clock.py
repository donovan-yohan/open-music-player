#!/usr/bin/env python3
"""Compile exact clock command bodies. Android/session/JNI are explicit facades.
No production command body is rewritten except its concrete native type name.
"""
import argparse, hashlib, json
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('--generate',type=Path,required=True)
p.add_argument('--source',type=Path)
a=p.parse_args()
root=a.source or Path(__file__).resolve().parents[1]
k=root/'app/src/main/kotlin/com/soundq/android'
def block(text,marker):
    start=text.index(marker);i=text.index('{',start)+1;depth=1
    while depth:
        depth+=(text[i]=='{')-(text[i]=='}');i+=1
    return text[start:i]
s=(k/'playback/SoundQLibraryService.kt').read_text()
c=(k/'playback/ControllerProjection.kt').read_text()
n=(k/'playback/nativeengine/NativeCallbackPlayer.kt').read_text()
service='\n'.join(block(s,m) for m in ['    private fun clockProjection(', '    private fun seekClock(']).replace('com.soundq.android.playback.nativeengine.NativeCallbackPlayer','ServicePlayer')
controller=block(c,'    fun seekClock(')
native=n[n.index('    private class ClockSeekReceipt'):n.index('    private fun seekNative(')]
source='''package com.soundq.android.clockprobe
import com.soundq.android.playback.*
import com.google.common.util.concurrent.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.Json
import org.junit.Test
import org.junit.Assert.*
import java.util.concurrent.Executor
private class Bundle {val strings=mutableMapOf<String,String>();fun putString(k:String,v:String){strings[k]=v};fun getString(k:String)=strings[k];companion object {val EMPTY=Bundle()}}
private class SessionCommand(val action:String,val extras:Bundle)
private class SessionResult(val resultCode:Int) {companion object {const val RESULT_SUCCESS=0}}
private object SessionError {const val ERROR_INVALID_STATE=-2}
private class Scope(val epoch:Long)
private class Session {var scope=Scope(4);fun current(s:Scope)=scope===s}
private class Cancel {var count=0;fun command(){count++};fun retire(){count++};fun cancelAudition(){count++}}
private class FadePreference(var ready:Boolean=true,var error:Boolean=false,var seconds:Int=0)
private class FadePreferences {class State {val value=FadePreference()};val state=State()}
private class Graph {val session=Session();val timeline=Cancel();val contextStarts=Cancel();val crossfadePreferences=FadePreferences()}
private class Item(val mediaId:String) {val localConfiguration=Local();class Local {val uri=Uri()};class Uri {val scheme="soundq"}}
private class ServicePlayer {
 val rows=mutableListOf(Item("a1"),Item("b"),Item("a2"));var index=1;var currentPosition=5000L;val duration=20000L
 val currentMediaItem get()=rows.getOrNull(index);val mediaItemCount get()=rows.size;fun getMediaItemAt(i:Int)=rows[i]
 var spans:List<ClockSpan>?=listOf(ClockSpan("a1",10000),ClockSpan("b",20000),ClockSpan("a2",10000))
 fun acceptedClockSpans()=spans
 val calls=mutableListOf<Pair<Int,Long>>();var receipt=true;var during:()->Unit={}
 suspend fun seekClock(i:Int,p:Long,current:()->Boolean):Boolean {if(!current())return false;calls+=i to p;index=i;currentPosition=p;during();return receipt&&current()}
}
private class Service {
 val graph=Graph();var player:Any=ServicePlayer();var account:Scope?=graph.session.scope
 val serviceIncarnation="service";var sourceQueueIncarnation="queue";var clockRevision=8L;var selectionEpoch=0L
 var acceptedArrangement:Any?=null;var pendingArrangement:Any?=null
 val continuation=Cancel();val interruptions=Cancel();val transport=Cancel()
 var work:(suspend ()->SessionResult)?=null;var result:SettableFuture<SessionResult>?=null
 fun future(body:suspend ()->SessionResult):ListenableFuture<SessionResult> {work=body;return SettableFuture.create<SessionResult>().also{result=it}}
 fun publishSessionExtras(){}
 SERVICE
 fun projection()=clockProjection()
 fun send(request:ClockSeek)=seekClock(Bundle().apply{putString("clockSeek",Json.encodeToString(request))})
 fun raw(v:String)=seekClock(Bundle().apply{putString("clockSeek",v)})
 suspend fun finish(){val body=work!!;work=null;result!!.set(body())}
}
private class ControllerPort {
 var available=true;var sent=0;var request:ClockSeek?=null;val reply=SettableFuture.create<SessionResult>()
 fun isSessionCommandAvailable(c:SessionCommand)=available
 fun sendCustomCommand(c:SessionCommand,b:Bundle):ListenableFuture<SessionResult> {sent++;request=Json.decodeFromString(b.getString("clockSeek")!!);return reply}
}
private class Connection {var live=true;fun accepts(c:ControllerPort)=live}
private class State(var value:PlaybackProjection)
private class Handler {fun post(r:Runnable){r.run()}}
private class Controller(p:PlaybackProjection) {
 var controller:ControllerPort?=ControllerPort();var closed=false;val connection=Connection();val state=State(p);val handler=Handler();var clockRequest=0L;var scratch=0
 fun retireScratch(){scratch++};fun publish(){}
 CONTROLLER
}
private object Player {const val STATE_IDLE=1;const val STATE_READY=3;const val STATE_ENDED=4;const val STATE_BUFFERING=2}
private class Native {
 val items=listOf("a1","b","a2");var index=1;var position=5000L;var epoch=1L;var transportRevision=1L;var released=false;var error:String?=null
 var selectedLoaded=true;var pending:Any?=null;var desiredSeek:Long?=null;var playback=Player.STATE_READY;var intent=false
 var dispatches=0;var prepares=0
 fun seekTo(i:Int,p:Long){dispatches++;index=i;transportRevision++;desiredSeek=p}
 fun prepare(){prepares++;playback=Player.STATE_BUFFERING}
 fun snapshot(ready:Boolean,cursor:Long){acknowledgeClockSeek(ready,cursor)}
 NATIVE
}
// Bridge only for the real-Compose consumer regression. Executes the exact native
// wait body above with no cursor acknowledgement; JNI/player remain declared facades.
internal suspend fun unobservedClockDeadline():Pair<Boolean,Int> {
 val native=Native()
 val result=native.seekClock(2,2500){true}
 return result to native.dispatches
}
class PlayerClockCommandTest {
 private fun request(s:Service,mode:PlayerClockMode=PlayerClockMode.Queue,position:Long=32500):ClockSeek {val p=s.projection()!!;return ClockSeek(p.clockAuthority!!,mode,position,projectPlayerClock(p,mode).destination(position)!!)}
 @Test fun acceptedCustomSeekRetiresPreIoContextBeforeDeferredNativeDispatch()=runBlocking {
  val s=Service();val native=s.player as ServicePlayer;val reply=s.send(request(s))
  assertEquals(1,s.graph.contextStarts.count);assertFalse(reply.isDone);assertTrue(native.calls.isEmpty())
  s.finish();assertEquals(0,reply.get().resultCode);assertEquals(1,native.calls.size)
 }
 @Test fun plannedFadeOrUnknownPreferenceWithholdsQueueInverseButKeepsTruthfulSongClock()=runBlocking {
  for(change in listOf<(FadePreference)->Unit>({it.seconds=3},{it.ready=false},{it.error=true})) {
   val s=Service();change(s.graph.crossfadePreferences.state.value)
   val p=s.projection()!!;assertNull(p.clockAuthority!!.spans)
   assertNull(projectPlayerClock(p,PlayerClockMode.Queue).totalMs);assertNull(projectPlayerClock(p,PlayerClockMode.Queue).destination(0))
   assertEquals(20000L,projectPlayerClock(p,PlayerClockMode.Song).totalMs)
   assertEquals(ClockDestination("b",5000),projectPlayerClock(p,PlayerClockMode.Song).destination(5000))
   val reply=s.send(request(s,PlayerClockMode.Song,5000));s.finish();assertEquals(0,reply.get().resultCode)
  }
 }
 @Test fun oversizedWholeContextAuthorityKeepsSongSeekWithoutInventingQueueTotal()=runBlocking {
  val s=Service();val native=s.player as ServicePlayer
  native.spans=(0 until 10000).map {ClockSpan("long-occurrence-identifier-$it",12000)}
  val p=s.projection()!!;assertNull(p.clockAuthority!!.spans)
  assertNull(projectPlayerClock(p,PlayerClockMode.Queue).totalMs)
  val reply=s.send(request(s,PlayerClockMode.Song,5000));s.finish()
  assertEquals(0,reply.get().resultCode);assertEquals(listOf(1 to 5000L),native.calls)
 }
 @Test fun exactOccurrenceIndexedSeekAndServiceReceiptNotSelectThenSeek()=runBlocking {
  val s=Service();val p=s.player as ServicePlayer;val r=s.send(request(s));assertFalse(r.isDone);assertTrue(p.calls.isEmpty())
  s.finish();assertEquals(0,r.get().resultCode);assertEquals(listOf(2 to 2500L),p.calls);assertEquals("a2",p.currentMediaItem!!.mediaId)
 }
 @Test fun malformedForeignAndStaleRequestsHaveNoTransportEffects()=runBlocking {
  for(change in listOf<(Service)->Unit>({it.account=null},{it.graph.session.scope=Scope(4)},{it.clockRevision++},{it.sourceQueueIncarnation="replacement"},{(it.player as ServicePlayer).index=0},{it.acceptedArrangement=Any()})) {
   val s=Service();val p=s.player as ServicePlayer;val req=request(s);change(s)
   assertEquals(-2,s.send(req).get().resultCode);assertTrue(p.calls.isEmpty());assertEquals(0,s.transport.count);assertEquals(0,s.graph.contextStarts.count)
  }
  val s=Service();assertEquals(-2,s.raw("not-json").get().resultCode);assertEquals(-2,s.raw("x".repeat(100000)).get().resultCode)
  val req=request(s);assertEquals(-2,s.send(req.copy(destination=ClockDestination("a1",2500))).get().resultCode)
 }
 @Test fun heldDispatchRechecksRevisionAndOwnerBeforeOneNativeCall()=runBlocking {
  for(change in listOf<(Service)->Unit>({it.clockRevision++},{it.selectionEpoch++},{it.sourceQueueIncarnation="replacement"},{it.graph.session.scope=Scope(4)})) {
   val s=Service();val p=s.player as ServicePlayer;val r=s.send(request(s));change(s);s.finish()
   assertEquals(-2,r.get().resultCode);assertTrue(p.calls.isEmpty())
  }
 }
 @Test fun decoderRefusalAndRetiredCompletionCannotReportSuccess()=runBlocking {
  for(retire in listOf(false,true)) {val s=Service();val p=s.player as ServicePlayer
   if(retire)p.during={s.selectionEpoch++}else p.receipt=false
   val r=s.send(request(s));s.finish();assertEquals(-2,r.get().resultCode);assertEquals(1,p.calls.size)
  }
 }
 @Test fun controllerUsesCapturedAuthorityAndChecksCompletionLifetime() {
  val s=Service();val captured=s.projection()!!;val c=Controller(captured);val port=c.controller!!;var result:Boolean?=null
  c.seekClock(captured,PlayerClockMode.Queue,32500,{true}){result=it}
  assertEquals(1,port.sent);assertEquals(ClockDestination("a2",2500),port.request!!.destination);assertNull(result)
  c.state.value=captured.copy(sourceQueueIncarnation="new")
  port.reply.set(SessionResult(0));assertEquals(false,result)
 }
 @Test fun controllerRefusesStaleSelectionAuthorityOrModeLifetimeBeforeSending() {
  val p=Service().projection()!!
  for(change in listOf<(Controller)->Unit>({it.state.value=p.copy(selectionIncarnation=1)},{it.state.value=p.copy(clockAuthority=null)},{it.connection.live=false},{it.closed=true},{it.controller!!.available=false})) {
   val c=Controller(p);change(c);var result:Boolean?=null;c.seekClock(p,PlayerClockMode.Queue,32500,{true}){result=it};assertEquals(false,result);assertEquals(0,c.controller!!.sent)
  }
  val c=Controller(p);c.seekClock(p,PlayerClockMode.Queue,32500,{false}){assertFalse(it)};assertEquals(0,c.controller!!.sent)
 }
 @Test fun nativeWaitsForReadyCursorAndPreservesPausedOrPlayingIntent()=runBlocking {
  for(playing in listOf(false,true)) {val n=Native();n.intent=playing
   val task=async {n.seekClock(2,2500){true}};yield();assertFalse(task.isCompleted);assertEquals(1,n.dispatches)
   n.position=2500;n.desiredSeek=null;n.selectedLoaded=false;delay(20);assertFalse(task.isCompleted)
   n.selectedLoaded=true;n.playback=Player.STATE_BUFFERING;delay(20);assertFalse(task.isCompleted)
   n.playback=Player.STATE_READY;n.snapshot(true,2500);n.position=7000;assertTrue(task.await());assertEquals(playing,n.intent)
  }
 }
 @Test fun nativeRetiresOnNewTransportSourceOrOwnerAndPreparesStoppedQueuePaused()=runBlocking {
  for(change in listOf<(Native)->Unit>({it.transportRevision++},{it.epoch++},{it.released=true},{it.error="failed"},{it.index=0})) {
   val n=Native();val task=async{n.seekClock(2,2500){true}};yield();change(n);assertFalse(task.await());assertEquals(1,n.dispatches)
  }
  val n=Native();n.selectedLoaded=false;n.playback=Player.STATE_IDLE;val task=async {n.seekClock(2,2500){true}};yield();assertEquals(1,n.prepares);assertFalse(n.intent)
  n.position=2500;n.selectedLoaded=true;n.desiredSeek=null;n.playback=Player.STATE_READY;n.snapshot(true,2500);assertTrue(task.await());assertFalse(n.intent)
  val stale=Native();assertFalse(stale.seekClock(2,2500){false});assertEquals(0,stale.dispatches)
 }
}
'''.replace(' SERVICE',' '+service).replace(' CONTROLLER',' '+controller).replace(' NATIVE',' '+native)
# Service's player is one concrete native collaborator in this probe; its type
# check is retained and actual non-native refusal is covered in device integration.
source=source.replace('var player:Any=ServicePlayer()','var player=ServicePlayer()')
a.generate.mkdir(parents=True,exist_ok=True)
(a.generate/'PlayerClockCommandTest.kt').write_text(source)
(a.generate/'source-manifest.json').write_text(json.dumps({name:hashlib.sha256(body.encode()).hexdigest() for name,body in [('service',service),('controller',controller),('native',native)]},indent=2))
print('Generated exact service/controller/native clock command probes',a.generate)
