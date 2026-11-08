#!/usr/bin/env python3
"""Run exact Queue primaryAction + controller Apply + native service install bodies.

Only Android/Media3, asynchronous acquisition and native hardware are facades.
The native player is deliberately a boundary facade here; its real deferred seek
and cancellation path are qualified separately by test-overlap-compile.py.
No Gradle, device, network or shared build writes. --source-root accepts a frozen
predecessor so identical regression bytes can demonstrate causal RED/GREEN.
"""
import argparse
import os
from pathlib import Path
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--build', type=Path, required=True)
p.add_argument('--source-root', type=Path)
a = p.parse_args()
root = a.source_root or Path(__file__).resolve().parents[1]
base = root / 'app/src/main/kotlin/com/soundq/android'

def block(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

queue = (base / 'product/QueuePanel.kt').read_text()
controller = (base / 'playback/ControllerProjection.kt').read_text()
service = (base / 'playback/SoundQLibraryService.kt').read_text()
primary = block(queue, '    fun primaryAction()')
apply = block(controller, '    fun applyArrangement(')
install_marker = '                                    native.installArrangement('
install_start = service.index(install_marker)
install_end = service.index('                                    installed=true', install_start)
install = service[install_start:install_end]
# Preserve service payload parsing/preflight statements up to native preparation.
start = service.index('                    val raw=args.getString("document")')
end = service.index('                    val identity=ArrangementIdentity(', start)
preflight = service[start:end]
# This facade owns already-qualified source rows. Keep real document, request,
# source/track/duration and start-position admission statements intact.

fixture = r'''package queueresume
import java.util.concurrent.Executor
import kotlin.math.*
import com.soundq.android.data.timeline.*

object Player {const val STATE_IDLE=1}
object SoundQLibraryService {const val APPLY_ARRANGEMENT="apply"}
class Bundle {
 val fields=mutableMapOf<String,Any>();fun putString(k:String,v:String){fields[k]=v};fun putLong(k:String,v:Long){fields[k]=v}
 fun getString(k:String)=fields[k] as? String;fun getLong(k:String,d:Long=0)=fields[k] as? Long ?: d
 companion object {val EMPTY=Bundle()}
}
class SessionCommand(val action:String,val extras:Bundle)
class SessionResult(val resultCode:Int,val extras:Bundle=Bundle()) {companion object {const val RESULT_SUCCESS=0}}
class Future(val value:SessionResult) {fun get()=value;fun addListener(action:()->Unit,executor:Executor){executor.execute(Runnable(action))}}
class Handler {fun post(action:Runnable){action.run()}}
class MediaItem(val mediaId:String)
data class Scope(val epoch:Long=1)
data class ArrangementIdentity(val revision:Long,val install:String="new")
data class AcceptedArrangement(val identity:ArrangementIdentity,val document:TimelineDocument,val sources:List<Source> = document.clips.map {Source(it.occurrence,it.track,it.sourceDurationMs)})
data class PlaybackProjection(val arrangement:AcceptedArrangement?=null,val selectedOccurrence:String?="a",val positionMs:Long=0,
 val isPlaying:Boolean=false,val preparing:Boolean=false,val canAuditionArrangement:Boolean=true,
 val arrangementService:String="service",val sourceQueueIncarnation:String="queue",val accountEpoch:Long=1)
class Value<T>(var value:T)
object Json {
 var document=TimelineDocument(1,listOf(TimelineClip("a",7,"A",10000,1000,9000,4000,QueueSegment.Context)))
 var accepted:AcceptedArrangement?=null
 inline fun <reified T> decodeFromString(raw:String):T = (if(T::class==TimelineDocument::class)document else accepted!!) as T
}
fun Json.encodeToString(document:TimelineDocument)="document"
val TimelineDocument.duration get()=clips.maxOf {it.globalEndMs}
fun TimelineDocument.arrangementPlan()=this
fun TimelineDocument.matchesOccurrences(sources:List<Pair<String,Long>>)=clips.map{it.occurrence to it.track}==sources
class Session {fun current(scope:Scope)=true}
class Timeline(val current:Value<TimelineDocument>) {
 var live=true;var request="request";var pending:(()->Boolean)?=null
 fun captureAudition(scope:Scope,document:TimelineDocument,valid:()->Boolean):String? {if(!live||!valid())return null;pending=valid;return request}
 fun accepts(scope:Scope,document:TimelineDocument)=live&&current.value==document
 fun admitsAudition(id:String,scope:Scope,document:TimelineDocument)=id==request&&accepts(scope,document)&&pending?.invoke()==true
 fun retireAudition(id:String){if(id==request)pending=null}
}
class Graph(val timeline:Timeline) {val session=Session()}
class BoundaryPlayer {
 var position=0L;var playing=false;var seekCalls=0;var installs=0;var ready=false
 fun installArrangement(candidate:TimelineDocument,item:MediaItem,sources:List<MediaItem>){installs++;position=0;playing=false;ready=false}
 fun seekTo(ms:Long){seekCalls++;position=ms}
 fun bindPerformance(identity:ArrangementIdentity){}
}
class BoundaryController(val graph:Graph,val state:Value<PlaybackProjection>) {
 var currentMediaItem:MediaItem?=MediaItem("a");var currentPosition=3250L
 var isPlaying=false;var playWhenReady=false;var playbackState=3;val playerError:Any?=null
 var sent:Bundle?=null;val player=BoundaryPlayer();var accepted:AcceptedArrangement?=null;var pendingReady=false
 fun isSessionCommandAvailable(command:SessionCommand)=true
 fun prepare(){}
 fun play(){isPlaying=true;playWhenReady=true}
 fun pause(){isPlaying=false;playWhenReady=false;pendingReady=false;graph.timeline.pending=null}
 fun seekTo(index:Int,ms:Long){currentMediaItem=MediaItem(if(index==0)"a" else "b");currentPosition=ms}
 fun sendCustomCommand(command:SessionCommand,args:Bundle):Future {
  sent=args
  val scope=Scope();val qualifiedSources=Json.document.clips.map {Source(it.occurrence,it.track,it.sourceDurationMs)}
  val acceptedArrangement=this.accepted
  fun sourceOccurrences()=qualifiedSources
  PREFLIGHT
  val candidate=document;val item=MediaItem("new");val sourceItems=listOf(MediaItem("a"));val native=player
  val identity=ArrangementIdentity(document.revision)
  INSTALL
  val next=AcceptedArrangement(identity,document);this.accepted=next;Json.accepted=next
  currentMediaItem=item;currentPosition=player.position
  state.value=state.value.copy(arrangement=next,selectedOccurrence="new",positionMs=player.position)
  pendingReady=true
  return Future(SessionResult(0,Bundle().apply{putString("acceptedArrangement","accepted")}))
 }
 fun ready(){player.ready=true;if(pendingReady&&graph.timeline.pending?.invoke()==true){player.playing=true;isPlaying=true};pendingReady=false}
}
data class Source(val occurrenceId:String,val trackId:Long,val durationMs:Long)
class Connection {fun accepts(c:BoundaryController)=true}
class Controller(val graph:Graph,p:PlaybackProjection) {
 val state=Value(p);val device=BoundaryController(graph,state);val controller:BoundaryController?=device
 val handler=Handler();val connection=Connection();val closed=false
 fun publish(){}
 fun retireScratch(){}
 fun toggle(){controller?.let{if(it.isPlaying||it.playWhenReady)it.pause() else{if(it.playbackState==Player.STATE_IDLE||it.playerError!=null)it.prepare();it.play()}}}
 fun pause(){controller?.pause()}
 APPLY
}
class TimelineState(val document:TimelineDocument)
class Model(document:TimelineDocument,p:PlaybackProjection) {
 val timeline=Value(TimelineState(document));val graph=Graph(Timeline(Value(document)));val controller=Controller(graph,p)
}
class Admission(val predicate:()->Boolean) {fun get()=predicate}
class Queue(val model:Model,var playback:PlaybackProjection) {
 var showTimeline=true;val scope:Scope?=Scope();var alive=true
 val valid:()->Boolean={alive};val timelineAdmission=Admission{alive}
 var auditionRequest:String?=null;var auditionMessage:String?=null
 PRIMARY
}
fun scenario(name:String,body:()->Unit){try{body();println("PASS $name")}catch(t:Throwable){System.err.println("FAIL $name: ${t.message}");throw t}}
fun main(){
 val doc=Json.document
 scenario("Queue waveform scrub then Play maps actual source cursor through moved/trimmed occurrence") {
  val model=Model(doc,PlaybackProjection(positionMs=0));val q=Queue(model,model.controller.state.value)
  model.controller.device.currentPosition=3250 // MediaController masking is newer than 500ms projection tick.
  q.primaryAction()
  check(model.controller.device.player.position==6250L){"Requested source 3250 in moved clip must resume at global 6250, actual=${model.controller.device.player.position}"}
  check(!model.controller.device.player.playing);model.controller.device.ready();check(model.controller.device.player.playing)
 }
 scenario("Changed installed document retains accepted global cursor") {
  val old=AcceptedArrangement(ArrangementIdentity(0,"old"),doc.copy(revision=0))
  val model=Model(doc,PlaybackProjection(arrangement=old,selectedOccurrence="old",positionMs=100))
  model.controller.device.currentMediaItem=MediaItem("old");model.controller.device.currentPosition=7200
  val q=Queue(model,model.controller.state.value);q.primaryAction()
  check(model.controller.device.player.position==7200L){"Changed arrangement restarted at ${model.controller.device.player.position}"}
 }
 scenario("Ordinary paused matching-document resume never reinstalls or seeks") {
  val accepted=AcceptedArrangement(ArrangementIdentity(1),doc);val model=Model(doc,PlaybackProjection(arrangement=accepted))
  model.controller.device.currentMediaItem=MediaItem("new");model.controller.device.currentPosition=6200
  val q=Queue(model,model.controller.state.value);q.primaryAction()
  check(model.controller.device.player.installs==0);check(model.controller.device.currentPosition==6200L);check(model.controller.device.isPlaying)
 }
 scenario("Cancel pending waveform Play keeps deferred READY silent") {
  val model=Model(doc,PlaybackProjection());val q=Queue(model,model.controller.state.value);q.primaryAction()
  q.auditionRequest="request" // Installation ACK does not mean native READY.
  q.primaryAction();model.controller.device.ready();check(!model.controller.device.player.playing)
 }
 scenario("Retired route never installs") {
  val model=Model(doc,PlaybackProjection());val q=Queue(model,model.controller.state.value);q.alive=false;q.primaryAction()
  check(model.controller.device.player.installs==0)
 }
}
'''
fixture = fixture.replace('\n  PREFLIGHT\n', '\n'+preflight+'\n').replace('\n  INSTALL\n', '\n'+install+'\n').replace('\n APPLY\n', '\n'+apply+'\n').replace('\n PRIMARY\n', '\n'+primary+'\n')
# Only type boundaries are rebound, not callback statements.
fixture = fixture.replace('com.soundq.android.playback.PlaybackProjection', 'PlaybackProjection')
# Real timeline types/mapping are compiled with a declaration-only Serializable facade.
a.build.mkdir(parents=True, exist_ok=True)
kt = a.build / 'QueueWaveformResume.kt'
kt.write_text(fixture)
annotation = a.build / 'Serializable.kt'
annotation.write_text('package kotlinx.serialization\nannotation class Serializable\n')
document_type=a.build/'TimelineDocument.kt'
document_type.write_text('package com.soundq.android.data.timeline\ndata class TimelineDocument(val revision:Long=0,val clips:List<TimelineClip> = emptyList())\n')
jar = a.build / 'probe.jar'
env = dict(os.environ, TMPDIR=str(a.build))
subprocess.run(['kotlinc', '-J-Xmx512m', '-J-XX:ActiveProcessorCount=1', str(annotation), str(document_type), str(base/'data/timeline/Timeline.kt'), str(kt), '-include-runtime', '-d', str(jar)], check=True, env=env)
subprocess.run(['java', '-XX:ActiveProcessorCount=1', '-jar', str(jar)], check=True, env=env)
