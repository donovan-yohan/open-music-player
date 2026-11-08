#!/usr/bin/env python3
"""Replay the exact lane pointer body on a host event queue. Not mounted Compose.

Android tests in TimelineIdentityTouchJourneyTest drive the actual composable.
This cheap loop uses declaration-only pointer/clip collaborators and the real
TimelineGesture and VinylStroke implementations. No Gradle, ADB or live writes.
"""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--lane',type=Path)
a=p.parse_args()
root=Path(__file__).resolve().parents[1]
lane=a.lane or root/'app/src/main/kotlin/com/soundq/android/product/timeline/StackedTimeline.kt'
s=lane.read_text()
start=s.index('                if(!busy)awaitEachGesture {')
end=s.index('\n            }) {',start)
body=s[start:end]
a.output.mkdir(parents=True,exist_ok=True)
# Declarations model only the collaborators of the unchanged production body.
prelude=r'''
package com.soundq.android.product.timeline
import com.soundq.android.data.timeline.*
import kotlin.math.*
object T {const val MOTION_GESTURE_AXIS_RATIO=1.25f}
data class Offset(val x:Float,val y:Float) {
 operator fun plus(o:Offset)=Offset(x+o.x,y+o.y)
 operator fun minus(o:Offset)=Offset(x-o.x,y-o.y)
 companion object {val Zero=Offset(0f,0f)}
}
data class Rect(val left:Float,val top:Float,val right:Float,val bottom:Float) {
 fun contains(p:Offset)=p.x>=left&&p.x<right&&p.y>=top&&p.y<bottom
}
class Slot<T>(var value:T)
class Change(val position:Offset,val pressed:Boolean,val uptimeMillis:Long,var isConsumed:Boolean=false,val id:Int=0) {
 val historical=emptyList<Historical>()
 fun consume(){isConsumed=true}
}
class Historical(val position:Offset,val uptimeMillis:Long)
class Event(val changes:List<Change>) {
 fun calculateZoom()=1f
 fun calculateCentroid()=changes.first().position
 fun calculatePan()=Offset.Zero
}
class Events(val queue:ArrayDeque<Event>) {
 fun awaitFirstDown(requireUnconsumed:Boolean)=awaitPointerEvent().changes.first()
 fun awaitPointerEvent():Event=checkNotNull(queue.removeFirstOrNull()) {"event queue exhausted"}
 fun awaitEachGesture(block:Events.()->Unit)=block()
}
class Scratch(val armed:Boolean=true,val ready:Boolean=true,val sourceRate:Double=1.0) {
 var begins=0;val finishes=mutableListOf<Boolean>();val rates=mutableListOf<Double>()
 fun begin(time:Long):Boolean {begins++;return true}
 fun move(rate:Double,time:Long){rates+=rate}
 fun finish(time:Long,cancel:Boolean){finishes+=cancel}
}
class Probe {
 var busy=false;val revision=1L;var snap=SnapMode.Free;val wave:Any?=null
 val viewport=Slot(Viewport());var clip=TimelineClip();val target=48f;val slop=8f
 var latestSelected=false;var latestPhaseDocument:Document?=null
 var latestScratch:Scratch?=null;var preview:TimelineEdit?=null;var reason:String?=null
 var activePointer=false;var selections=0;var held:Float?=null;var active:(()->Unit)?=null
 val edits=mutableListOf<TimelineEdit>();val gesture=TimelineGesture({EditDecision(true)},{edits+=it})
 val identityBounds:Rect?=Rect(8f,8f,184f,56f)
 val bpmBounds:Rect?=Rect(192f,8f,304f,56f)
 val moreBounds:Rect?=Rect(304f,8f,352f,56f)
 fun onSelect(){selections++}
 fun onHeld(x:Float?){held=x}
 fun onActive(cancel:(()->Unit)?){active=cancel}
 fun latestPhasePreview(edit:TimelineEdit?){}
 fun cancel(){activePointer=false;gesture.cancel();preview=null;onHeld(null);onActive(null)}
 fun run(vararg events:Event) {with(Events(ArrayDeque(events.toList()))) {
'''
postlude=r'''
 }}
}
private fun event(x:Float,y:Float,pressed:Boolean=true,time:Long=0,consumed:Boolean=false)=Event(listOf(Change(Offset(x,y),pressed,time+1,consumed)))
private fun checkCase(name:String,block:()->Unit) {try{block();println("PASS $name")}catch(t:Throwable){throw AssertionError(name,t)}}
fun main() {
 checkCase("painted identity starts placement") {
  val p=Probe();p.run(event(80f,30f),event(160f,30f,time=10),event(160f,30f,false,20))
  check(p.edits.singleOrNull()?.let {it.kind==EditKind.Placement&&it.valueMs==2000L}==true) {"identity contact failed to commit placement: ${p.edits}"}
 }
 checkCase("captured body crosses identity BPM and More") {
  val p=Probe();p.run(event(80f,80f),event(140f,80f,time=10),event(140f,30f,time=20),event(328f,30f,time=30),event(248f,30f,time=40),event(248f,30f,false,50))
  check(p.edits.size==1);check(p.held==null&&p.active==null)
 }
 checkCase("accepted identity edit cancellation and reused pointer recover") {
  val p=Probe();p.run(event(80f,30f),event(160f,30f,time=10),event(160f,30f,false,20,true))
  check(p.edits.isEmpty()&&p.preview==null&&p.active==null&&p.held==null)
  p.run(event(80f,30f),event(160f,30f,time=30),event(160f,30f,false,40));check(p.edits.size==1)
 }
 checkCase("empty timeline behind identity pans") {
  val p=Probe();p.clip=TimelineClip(globalStartMs=20000);p.run(event(80f,30f),event(20f,30f,time=10),event(20f,30f,false,20))
  check(p.edits.isEmpty());check(p.viewport.value.offsetMs>0)
 }
 checkCase("selected trim starts on identity backing") {
  val p=Probe();p.latestSelected=true;p.run(event(20f,30f),event(80f,30f,time=10),event(80f,30f,false,20))
  check(p.edits.singleOrNull()?.let {it.kind==EditKind.TrimIn&&it.valueMs==1500L}==true)
 }
 checkCase("actual BPM and More down rectangles stay excluded") {
  for(x in listOf(248f,328f)) {
   val p=Probe();p.latestScratch=Scratch();p.run(event(x,30f),event(x+40f,30f,time=10),event(x+40f,30f,false,20))
   check(p.edits.isEmpty()&&p.latestScratch!!.begins==0&&p.selections==0)
  }
 }
 checkCase("identity scratch cancellation retires audio contact") {
  val p=Probe();val scratch=Scratch();p.latestScratch=scratch
  p.run(event(80f,30f),event(90f,30f,time=10),event(70f,30f,time=20),event(70f,30f,false,30,true))
  check(scratch.begins==1&&scratch.finishes==listOf(true)) {"scratch cancel misclassified: ${scratch.finishes}"}
  check(scratch.rates.any {it>0}&&scratch.rates.any {it<0});check(p.edits.isEmpty())
 }
 println("PASS 7 extracted pointer-body cases. Mounted hit testing remains Android instrumentation.")
}
'''
facade=r'''
package com.soundq.android.data.timeline
import kotlin.math.*
enum class EditKind {Placement,TrimIn,TrimOut}
enum class SnapMode {Free}
data class EditDecision(val accepted:Boolean,val reason:String?=null)
class Rates {fun sourceDelta(a:Long,b:Long)=b-a}
data class TimelineClip(val globalStartMs:Long=0,val sourceInMs:Long=0,val sourceOutMs:Long=10000,val occurrence:String="identity") {
 val globalEndMs get()=globalStartMs+sourceOutMs-sourceInMs
 val rates=Rates()
}
data class TimelineEdit(val revision:Long,val original:TimelineClip,val kind:EditKind,val valueMs:Long)
class Link {fun contains(id:String)=false}
class Document(val phaseLink:Link?=null)
data class Viewport(val offsetMs:Long=0,val pixelsPerSecond:Double=40.0) {
 fun x(ms:Long)=((ms-offsetMs)*pixelsPerSecond/1000).toFloat()
 fun time(x:Float)=offsetMs+(x/pixelsPerSecond*1000).roundToLong()
 fun pan(px:Float)=copy(offsetMs=(offsetMs+px/pixelsPerSecond*1000).roundToLong().coerceAtLeast(0))
 fun zoom(zoom:Float,x:Float)=this
}
fun snapEditValue(clip:TimelineClip,kind:EditKind,raw:Long,snap:SnapMode,wave:Any?)=raw
'''
(a.output/'PointerProbe.kt').write_text(prelude+body+postlude)
(a.output/'Boundary.kt').write_text(facade)
stroke=root/'app/src/main/kotlin/com/soundq/android/product/timeline/VinylStroke.kt'
assert stroke.exists(),stroke
files=[a.output/'PointerProbe.kt',a.output/'Boundary.kt',stroke,root/'app/src/main/kotlin/com/soundq/android/data/timeline/TimelineGesture.kt']
(a.output/'provenance.json').write_text(json.dumps({'lane':str(lane),'lane_sha256':hashlib.sha256(lane.read_bytes()).hexdigest(),'pointer_body_sha256':hashlib.sha256(body.encode()).hexdigest(),'boundary':'host declaration facades, not Compose hit testing'},indent=2)+'\n')
subprocess.run(['kotlinc','-J-Xmx512m','-J-XX:ActiveProcessorCount=1',*map(str,files),'-include-runtime','-d',str(a.output/'probe.jar')],check=True)
subprocess.run(['java','-XX:ActiveProcessorCount=1','-cp',str(a.output/'probe.jar'),'com.soundq.android.product.timeline.PointerProbeKt'],check=True)
# Keep paint read-only and ensure the two explicit action cells coexist.
lane_source=s[s.index('@Composable internal fun TimelineLane'):s.index('@Composable private fun TimingInspector')]
assert '.combinedClickable' not in lane_source,'Identity must not own a competing click recognizer'
assert 'identityBounds' not in lane_source,'Painted identity must not exclude body contact'
assert 'bpmBounds?.contains(down.position)' in lane_source
assert 'moreBounds?.contains(down.position)' in lane_source
assert 'else TimelineTool("More for' not in lane_source,'BPM must not replace More'
print('PASS read-only identity / separate explicit BPM and More source contracts')
