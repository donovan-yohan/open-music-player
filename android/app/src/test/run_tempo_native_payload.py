#!/usr/bin/env python3
"""Compile real native payload/domain/MixJson with transport-only boundary shapes. No Gradle."""
import os
import argparse
import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "scripts"))
from host_probe import directory, gradle_cache, kotlin_plugin, android_jar
import subprocess
import tempfile
parser=argparse.ArgumentParser()
parser.add_argument('--export',type=Path,help='Export real serialized Kotlin payload JSON for the native runner')
parser.add_argument('--native-runner',type=Path,help='Execute the exported payload through the real V2 Host')
args=parser.parse_args()
r=Path(__file__).resolve().parents[3]
c=gradle_cache()/'modules-2/files-2.1'
def jar(g,n,v):return next((c/g/n/v).glob('**/*.jar'))
cp=os.pathsep.join(map(str,[jar('junit','junit','4.13.2'),jar('org.hamcrest','hamcrest-core','1.3'),jar('org.jetbrains.kotlinx','kotlinx-serialization-core-jvm','1.9.0'),jar('org.jetbrains.kotlinx','kotlinx-serialization-json-jvm','1.9.0'),jar('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.10.2')]))
with tempfile.TemporaryDirectory(prefix='tempo-native-payload-',dir=os.environ['TMPDIR']) as d:
    d=Path(d);main=r/'app/src/main/kotlin/com/soundq/android'
    (d/'TrackId.kt').write_text('package com.soundq.android.data\n@JvmInline value class TrackId(val value:Long)')
    text=(main/'playback/ControllerProjection.kt').read_text()
    occurrence=next(line for line in text.splitlines() if 'data class QueueOccurrence(' in line)
    (d/'TransportBoundary.kt').write_text('''package com.soundq.android.playback
import com.soundq.android.data.timeline.*
import kotlinx.serialization.Serializable
'''+occurrence+'''
enum class PlaybackSource {Queue,Arrangement,SavedMix}
data class PlaybackProjection(val connection:Connection=Connection.Connected,val source:PlaybackSource=PlaybackSource.Queue,val queue:List<QueueOccurrence> = emptyList(),val arrangement:AcceptedArrangement?=null) {enum class Connection {Connected,Connecting,Disconnected}}
''')
    sources=[main/'data/timeline'/x for x in ['Timeline.kt','TimelineOwner.kt','TimelineGeometry.kt','LinkedPhase.kt','TempoTransition.kt','Waveform.kt']]
    sources += [main/'playback/Arrangement.kt',main/'playback/QueueOrigin.kt',main/'data/mix/MixPlan.kt',d/'TrackId.kt',d/'TransportBoundary.kt',r/'app/src/test/kotlin/com/soundq/android/playback/NativeArrangementPayloadTest.kt']
    subprocess.run(['kotlinc','-J-XX:ActiveProcessorCount=1',*map(str,sources),'-cp',cp,'-Xplugin='+kotlin_plugin('kotlinx-serialization-compiler-plugin.jar'),'-d',str(d/'tests.jar')],check=True)
    subprocess.run(['kotlin','-J-XX:ActiveProcessorCount=1','-cp',str(d/'tests.jar')+os.pathsep+cp,'org.junit.runner.JUnitCore','com.soundq.android.playback.NativeArrangementPayloadTest'],check=True)
    if args.export or args.native_runner:
        export=args.export or d/'payloads.json'
        export.parent.mkdir(parents=True,exist_ok=True)
        subprocess.run(['kotlin','-J-XX:ActiveProcessorCount=1','-cp',str(d/'tests.jar')+os.pathsep+cp,'com.soundq.android.playback.NativeTempoPolicyFixtures',str(export)],check=True)
        payloads=json.loads(export.read_text())
        assert len(payloads)==7
        if args.native_runner:
            # Lossless textual handoff of the parsed producer JSON. No replacement vectors.
            wire=''.join(f"{p['name']} {len(p['values'])//6}\n"+' '.join(map(str,p['values']))+'\n'+' '.join(map(str,p['tempo']))+'\n'+' '.join(map(str,p['positions']))+'\n' for p in payloads)
            subprocess.run([str(args.native_runner),'--producer'],input=wire,text=True,check=True)
