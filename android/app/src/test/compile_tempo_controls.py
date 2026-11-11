#!/usr/bin/env python3
"""Compile exact tempo controls with real Compose compiler/APIs, no Gradle/device.
Waveform/clip identity declarations are boundary-only facades; design system is
parent's existing compiled release. This is compilation, not mounted UI acceptance.
"""
import argparse
import os
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "scripts"))
from host_probe import directory, gradle_cache, kotlin_plugin, android_jar
import subprocess
import zipfile
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
r=Path(__file__).resolve().parents[3]
cache=gradle_cache()/'modules-2/files-2.1'
def jar(group,name,version):
    return next((cache/group/name/version).glob('**/*.jar'))
cp=[]
for group,names,version in [
    ('androidx.compose.ui',['ui-android','ui-unit-android','ui-geometry-android','ui-graphics-android','ui-text-android','ui-util-android'], '1.12.1'),
    ('androidx.compose.runtime',['runtime-android','runtime-saveable-android'],'1.12.1'),
    ('androidx.compose.foundation',['foundation-android','foundation-layout-android'],'1.12.1'),
    ('androidx.compose.animation',['animation-android','animation-core-android'],'1.12.1'),
    ('androidx.compose.material3',['material3-android'],'1.4.0')]:
    for name in names:
        aar=next((cache/group/name/version).glob('**/*.aar'))
        output=a.output/(name+'.jar')
        with zipfile.ZipFile(aar) as archive:output.write_bytes(archive.read('classes.jar'))
        cp.append(output)
cp += [android_jar(),
    r/'designsystem/build/intermediates/compile_library_classes_jar/debug/bundleLibCompileToJarDebug/classes.jar',
    jar('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.10.2'),
    jar('org.jetbrains.kotlinx','kotlinx-serialization-core-jvm','1.9.0'),
    jar('junit','junit','4.13.2'),jar('org.hamcrest','hamcrest-core','1.3')]
(a.output/'IdentityBoundary.kt').write_text('''package com.soundq.android.data.timeline
@JvmInline value class TrackId(val value:Long)
data class TimelineClip(val occurrence:String,val track:Long,val sourceDurationMs:Long)
data class PhaseGrid(val revision:String,val provenance:String,val periodMs:Long,val anchorMs:Long,val law:Int,val sourceKey:String)
data class TrackWaveform(val track:TrackId,val sourceKey:String,val durationMs:Long,val phaseTiming:PhaseGrid?)
''')
sources=[r/'app/src/main/kotlin/com/soundq/android/data/timeline/TempoTransition.kt',r/'app/src/main/kotlin/com/soundq/android/product/timeline/TempoTransitionControls.kt',r/'app/src/test/kotlin/com/soundq/android/product/timeline/TempoTransitionControlsTest.kt',a.output/'IdentityBoundary.kt']
cmd=['kotlinc','-jvm-target','17','-J-XX:ActiveProcessorCount=1','-Xplugin='+kotlin_plugin('compose-compiler-plugin.jar'),*map(str,sources),'-cp',os.pathsep.join(map(str,cp)),'-d',str(a.output/'controls.jar')]
result=subprocess.run(cmd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=dict(os.environ,TMPDIR=str(a.output.resolve())))
(a.output/'compile.log').write_text(result.stdout)
print(result.stdout,end='')
if result.returncode:raise SystemExit(result.returncode)
print('Compiled exact TempoTransitionControls.kt + TempoTransition.kt against real Compose and existing design system. Mounted UI and audio not exercised.')
subprocess.run(['kotlin','-cp',str(a.output/'controls.jar')+os.pathsep+os.pathsep.join(map(str,cp)),'org.junit.runner.JUnitCore','com.soundq.android.product.timeline.TempoTransitionControlsTest'],check=True)
