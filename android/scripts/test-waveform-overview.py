#!/usr/bin/env python3
"""Execute initial-fit law against the real viewport/clip models (no Compose)."""
from pathlib import Path
import argparse,subprocess
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args()
r=Path(__file__).resolve().parents[1];a.output.mkdir(parents=True,exist_ok=True)
helper=r/'app/src/main/kotlin/com/soundq/android/product/timeline/WaveformOverview.kt'
assert helper.exists(),'Initial shared viewport must fit both sequential source extents'
(a.output/'FitTest.kt').write_text('''package com.soundq.android.product.timeline
import com.soundq.android.data.timeline.*
fun main(){
 val clips=sequentialTimeline(listOf(TimelineSource("a",7,"A",360000,QueueSegment.Context),TimelineSource("b",7,"B",360000,QueueSegment.Context),TimelineSource("c",8,"C",500000,QueueSegment.Context)))
 val fit=WaveformOverview();val initial=TimelineViewport(1220000,1f)
 check(fit.update(initial,clips,1f)==initial)
 val first=fit.update(initial,clips,360f)
 check(first.x(clips[0].globalStartMs)==0f)
 check(first.x(clips[1].globalStartMs)>0f&&first.x(clips[1].globalEndMs)<=360.01f)
 val zoomed=first.zoom(2f,180f).pan(20f)
 check(fit.update(zoomed,clips.map {it.copy(globalStartMs=it.globalStartMs+100)},360f)==zoomed)
 val resized=fit.update(zoomed,clips,412f);check(resized.pixelsPerSecond==zoomed.pixelsPerSecond)
 println("PASS one-time measured-width fit includes both sequential clips, late document/tick cannot reset user zoom")
}
''')
# Real geometry depends on the remaining real timeline models/parser/phase functions.
data=r/'app/src/main/kotlin/com/soundq/android/data/timeline'
(a.output/'Facade.kt').write_text('package com.soundq.android.data\n@JvmInline value class TrackId(val value:Long)\n')
cache=Path.home()/'.gradle/caches/modules-2/files-2.1'
cp=':'.join(str(next((cache/'org.jetbrains.kotlinx'/n/'1.7.3').glob('*/*.jar'))) for n in ['kotlinx-serialization-json-jvm','kotlinx-serialization-core-jvm'])
cp+=':'+str(next((cache/'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.8.1').glob('*/*.jar')))
files=[data/f for f in ['Timeline.kt','TimelineOwner.kt','Waveform.kt','LinkedPhase.kt','TimelineGeometry.kt','TempoTransition.kt']]
for cmd in [['kotlinc','-J-Xmx512m','-J-XX:ActiveProcessorCount=1',str(helper),str(a.output/'FitTest.kt'),str(a.output/'Facade.kt'),*map(str,files),'-cp',cp,'-include-runtime','-d',str(a.output/'fit.jar')],['java','-XX:ActiveProcessorCount=1','-cp',str(a.output/'fit.jar')+':'+cp,'com.soundq.android.product.timeline.FitTestKt']]:
 result=subprocess.run(cmd,capture_output=True,text=True);print(result.stdout+result.stderr)
 if result.returncode:raise SystemExit(result.returncode)
