#!/usr/bin/env python3
"""Compile the actual narrow waveform load helper; coroutine cancellation stays real."""
from pathlib import Path
import argparse,subprocess
p=argparse.ArgumentParser();p.add_argument('--output',required=True,type=Path);a=p.parse_args()
r=Path(__file__).resolve().parents[1];a.output.mkdir(parents=True,exist_ok=True)
helper=r/'app/src/main/kotlin/com/soundq/android/product/timeline/WaveformLoad.kt'
assert helper.exists(),'Missing owned read state; null/cancellation must not be swallowed'
(a.output/'LoadTest.kt').write_text('''package com.soundq.android.product.timeline
import kotlinx.coroutines.*
import com.soundq.android.data.SafeFailure
import com.soundq.android.data.timeline.TrackWaveform
fun main()=runBlocking {
 var ready=false;var fetches=0
 suspend fun attempt()=loadWaveform({ready}) {fetches++;TrackWaveform(listOf(1))}
 check(attempt()===WaveformLoad.Waiting&&fetches==0)
 ready=true;check(attempt() is WaveformLoad.Loaded&&fetches==1)
 check(loadWaveform({true}) {null}===WaveformLoad.Waiting)
 check(loadWaveform({true}) {TrackWaveform(emptyList())}===WaveformLoad.Unavailable)
 check((loadWaveform({true}) {throw SafeFailure(SafeFailure.Reason.Network)} as WaveformLoad.Failed).message=="Could not reach server")
 check((loadWaveform({true}) {error("secret token, URL, response body")} as WaveformLoad.Failed).message=="Could not load waveform")
 check(loadWaveform({true}) {throw SafeFailure(SafeFailure.Reason.Retired)}===WaveformLoad.Waiting)
 check(loadWaveform({ready}) {ready=false;TrackWaveform(listOf(1))}===WaveformLoad.Waiting)
 val cancel=CancellationException("cancel")
 check(runCatching {loadWaveform({true}) {throw cancel}}.exceptionOrNull()===cancel)
 println("PASS waiting→legitimate retry, loaded/unavailable, safe network/failure, retired publication and cancellation")
}
''')
(a.output/'Facade.kt').write_text('''package com.soundq.android.data
class SafeFailure(val reason:Reason):Exception() {enum class Reason {Network,InvalidResponse,Refused,Retired,Endpoint,ServiceUnavailable}}
''')
(a.output/'WaveFacade.kt').write_text('package com.soundq.android.data.timeline\ndata class TrackWaveform(val tiers:List<Int>)\n')
cache=Path.home()/'.gradle/caches/modules-2/files-2.1'
cp=str(next((cache/'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.8.1').glob('*/*.jar')))
for cmd in [['kotlinc','-J-Xmx512m','-J-XX:ActiveProcessorCount=1',str(helper),*[str(a.output/n) for n in ['LoadTest.kt','Facade.kt','WaveFacade.kt']],'-cp',cp,'-include-runtime','-d',str(a.output/'load.jar')],['java','-XX:ActiveProcessorCount=1','-cp',str(a.output/'load.jar')+':'+cp,'com.soundq.android.product.timeline.LoadTestKt']]:
 result=subprocess.run(cmd,capture_output=True,text=True);print(result.stdout+result.stderr)
 if result.returncode:raise SystemExit(result.returncode)
