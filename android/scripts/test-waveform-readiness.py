#!/usr/bin/env python3
"""Execute real lane producer in an explicit keyed-effect lifetime facade.

Models Compose key equality, cancellation/disposal and renewed producer binding.
Not mounted Android/Compose lifecycle proof. No polling or credentials.
"""
from pathlib import Path
import argparse,subprocess
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--lane',type=Path);a=p.parse_args()
r=Path(__file__).resolve().parents[1];o=a.output;o.mkdir(parents=True,exist_ok=True)
s=(a.lane or r/'app/src/main/kotlin/com/soundq/android/product/timeline/StackedTimeline.kt').read_text()
a1=s.index('                        value=if(readReady)');b1=s.index('\n                    }',a1)
producer=s[a1:b1]
keyline=next(line.strip() for line in s.splitlines() if 'val readKey=listOf(' in line)
keyexpr=keyline.split('=',1)[1]
(o/'Readiness.kt').write_text('''package com.soundq.android.product.timeline
import com.soundq.android.data.*
import com.soundq.android.data.timeline.*
import kotlinx.coroutines.*
import java.io.File
private data class Graph(val timeline:TimelineRepository)
private data class Model(val graph:Graph)
private class Slot {var value:WaveformLoad=WaveformLoad.Waiting}
fun main()=runBlocking {
 val session=AccountSession();val scope=AccountScope()
 var fetches=0
 val repo=TimelineRepository(session,File("UNUSED")){_,_,_,valid->check(valid());fetches++;TrackWaveform(TrackId(7),"measured",10000,listOf(PeakTier("detail",floatArrayOf(-0.5f),floatArrayOf(0.8f))))}
 val sources=listOf(TimelineSource("a",7,"A",10000,QueueSegment.Context));repo.observe(scope,sources)
 val model=Model(Graph(repo));val document=repo.state.value.document;val clip=document.clips.single()
 val retry=0;var readEpoch=0L;var lifecycleState="CREATED";var readReady=false;val readSources=sources
 var incarnation=0;var latestReadAdmission:()->Boolean={false}
 var heldKeys:List<Any?>?=null;var job:Job?=null;var runs=0;val slot=Slot()
 suspend fun recompose(){
  val generation=incarnation
  val readAdmission={readReady&&generation==incarnation}
  latestReadAdmission=readAdmission
  val readKey=KEY
  val keys=listOf(readKey,clip.track,clip.sourceDurationMs,retry)
  if(keys!=heldKeys){job?.cancelAndJoin();heldKeys=keys;runs++;job=launch {
   with(slot) {PRODUCER}
  };job!!.join()}
 }
 recompose();check(slot.value===WaveformLoad.Waiting&&fetches==0)
 lifecycleState="RESUMED";readReady=true;recompose()
 check(slot.value is WaveformLoad.Loaded&&fetches==1)
 repeat(100){recompose()};check(runs==2&&fetches==1)
 // A stop/resume conflated to RESUMED must still renew via the stable lifetime epoch.
 incarnation++;readEpoch++;recompose();check(slot.value is WaveformLoad.Loaded&&runs==3)
 readReady=false;lifecycleState="CREATED";incarnation++;readEpoch++;recompose();check(slot.value===WaveformLoad.Waiting)
 readReady=true;lifecycleState="RESUMED";recompose();check(slot.value is WaveformLoad.Loaded)
 job?.cancelAndJoin();println("PASS actual producer: pre-ready refusal→resume loaded, 100 unchanged-key recompositions no retry, stop/resume epoch renews, retirement waiting→fresh read")
}
'''.replace('KEY',keyexpr).replace('PRODUCER',producer))
(o/'Session.kt').write_text('''package com.soundq.android.data
@JvmInline value class TrackId(val value:Long)
class AccountScope(val accountId:String="fixture",val epoch:Long=1)
class Endpoint(val identity:String="https://fixture.invalid/api/v1")
class AccountSession {val endpoint=Endpoint();fun current(s:AccountScope)=true;fun remoteCurrent(s:AccountScope)=true}
class SafeFailure(val reason:Reason):Exception(){enum class Reason {Network,InvalidResponse,Refused,Retired,Endpoint}}
''')
data=r/'app/src/main/kotlin/com/soundq/android/data/timeline'
files=[data/n for n in ['Timeline.kt','TimelineOwner.kt','TimelineRepository.kt','Waveform.kt','LinkedPhase.kt','TimelineGeometry.kt','TempoTransition.kt']]
files += [r/'app/src/main/kotlin/com/soundq/android/product/timeline/WaveformLoad.kt',o/'Readiness.kt',o/'Session.kt']
c=Path.home()/'.gradle/caches/modules-2/files-2.1'
cp=':'.join(str(next((c/'org.jetbrains.kotlinx'/n/v).glob('*/*.jar'))) for n,v in [('kotlinx-serialization-json-jvm','1.7.3'),('kotlinx-serialization-core-jvm','1.7.3'),('kotlinx-coroutines-core-jvm','1.8.1')])
for cmd in [['kotlinc','-J-Xmx512m','-J-XX:ActiveProcessorCount=1',*map(str,files),'-cp',cp,'-include-runtime','-d',str(o/'readiness.jar')],['java','-XX:ActiveProcessorCount=1','-cp',str(o/'readiness.jar')+':'+cp,'com.soundq.android.product.timeline.ReadinessKt']]:
 result=subprocess.run(cmd,capture_output=True,text=True);print(result.stdout+result.stderr)
 if result.returncode:raise SystemExit(result.returncode)
