#!/usr/bin/env python3
"""Compile exact lane and instrumentation with cached real Kotlin/Compose. No device.

Only TrackId and generated resource IDs are declarations. The lane, More sheet,
BPM control, design system, timeline owner and pointer tests are real source.
Panel/IO and the unrelated BPM editor are not part of this component gate.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import subprocess
import zipfile
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--unit-tests',action='store_true',help='Execute pure timeline/owner/geometry/gesture/stroke JUnit controls')
a=p.parse_args()
a.output=a.output.resolve();a.output.mkdir(parents=True,exist_ok=True)
root=Path(__file__).resolve().parents[1]
main=root/'app/src/main/kotlin/com/soundq/android'
timeline=main/'product/timeline'
cache=Path.home()/'.gradle/caches/modules-2/files-2.1'
def jar(group,artifact,version):return next((cache/group/artifact/version).glob('*/*.jar'))
compiler=[jar('org.jetbrains.kotlin',x,'2.4.21') for x in ('kotlin-compiler-embeddable','kotlin-build-tools-api','kotlin-stdlib','kotlin-script-runtime','kotlin-daemon-embeddable')]
compiler += [jar('org.jetbrains.kotlin','kotlin-reflect','1.6.10'),jar('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.8.0')]
compiler += list((cache/'org.jetbrains'/'annotations').glob('*/*/*.jar'))
cp=[Path.home()/'Library/Android/sdk/platforms/android-37.0/android.jar',jar('org.jetbrains.kotlin','kotlin-stdlib','2.4.21')]
for group in ('androidx.compose.ui','androidx.compose.runtime','androidx.compose.foundation','androidx.compose.material3','androidx.compose.animation','androidx.activity','androidx.lifecycle','androidx.savedstate','androidx.annotation','androidx.core','androidx.collection','androidx.test','androidx.test.ext','androidx.tracing','androidx.arch.core','androidx.concurrent','androidx.window','androidx.profileinstaller','org.jetbrains.kotlinx','org.jetbrains','junit','org.hamcrest'):
    for artifact in (cache/group).glob('*'):
        for version in artifact.iterdir():
            if group.startswith('androidx.compose') and version.name not in ('1.12.1','1.4.0'):continue
            if group=='androidx.lifecycle' and version.name!='2.11.0':continue
            if group=='org.jetbrains.kotlinx' and artifact.name.startswith('kotlinx-serialization') and version.name!='1.12.0':continue
            if group=='org.jetbrains.kotlinx' and artifact.name.startswith('kotlinx-coroutines') and version.name!='1.10.2':continue
            if group=='junit' and version.name!='4.13.2':continue
            for file in version.glob('*/*'):
                if file.suffix=='.jar':cp.append(file)
                elif file.suffix=='.aar':
                    with zipfile.ZipFile(file) as z:
                        if 'classes.jar' in z.namelist():
                            target=a.output/(group+'-'+artifact.name+'-'+version.name+'.jar')
                            target.write_bytes(z.read('classes.jar'));cp.append(target)
s=(timeline/'StackedTimeline.kt').read_text()
imports='\n'.join(line for line in s.splitlines() if line.startswith('import ') and not any(x in line for x in ('ProductViewModel','playback.','kotlinx.coroutines.')))
lane_file=a.output/'StackedTimelineLane.kt'
lane_file.write_text('package com.soundq.android.product.timeline\n'+imports+'\n'+s[s.index('private fun timelineTime'):])
bpm=(timeline/'WaveformBpmControls.kt').read_text()
bpm_file=a.output/'WaveformBpmButton.kt'
bpm_file.write_text(bpm[:bpm.index('/** The whole setting')].replace('import com.soundq.android.data.AccountScope\n','').replace('import com.soundq.android.playback.*\n',''))
helper=(timeline/'TempoTransitionControls.kt').read_text()
helper_file=a.output/'QualifiedTempoSource.kt'
helper_file.write_text('package com.soundq.android.product.timeline\nimport com.soundq.android.data.timeline.*\n'+helper[helper.index('fun qualifiedTempoSource'):])
load=(timeline/'WaveformLoad.kt').read_text()
load_file=a.output/'WaveformLoad.kt'
load_file.write_text('package com.soundq.android.product.timeline\nimport com.soundq.android.data.timeline.*\n'+load[load.index('internal sealed interface'):load.index('internal suspend fun')])
track_file=a.output/'TrackId.kt'
track_file.write_text('package com.soundq.android.data\n@JvmInline value class TrackId(val value:Long) {init {require(value>0)}}\n')
theme=(root/'designsystem/src/main/kotlin/com/soundq/designsystem/Theme.kt').read_text()
fonts=sorted(set(re.findall(r'R\.font\.(\w+)',theme)))
resource=a.output/'ResourceIds.kt'
resource.write_text('package com.soundq.designsystem\nobject R {object font {'+';'.join('const val '+n+'='+str(i+1) for i,n in enumerate(fonts))+'}}\n')
sources=[lane_file,bpm_file,helper_file,load_file,track_file,resource]
sources += [main/'data/timeline'/name for name in ('Timeline.kt','TimelineOwner.kt','TimelineGeometry.kt','TimelineGesture.kt','Waveform.kt','LinkedPhase.kt','TempoTransition.kt')]
sources += [timeline/name for name in ('VinylStroke.kt','WaveformScratch.kt','VisualTimingMapping.kt','SourceMarkerPicker.kt','TimelinePlacementPicker.kt','SpectralWaveformPaint.kt','SpectralRateProjection.kt')]
sources += list((root/'designsystem/src/main').rglob('*.kt'))+list((root/'designsystem/src/generated').rglob('*.kt'))
tests=root/'app/src/androidTest/kotlin/com/soundq/android'
sources += [tests/name for name in ('TimelineIdentityTouchJourneyTest.kt','TimelineGestureJourneyTest.kt','CompactWaveformStackJourneyTest.kt','VinylGestureJourneyTest.kt')]
unit_names=('TimelineTest','TimelineOwnerTest','TimelineGeometryTest','TimelineGestureTest')
if a.unit_tests:
    sources += [root/'app/src/test/kotlin/com/soundq/android/data/timeline'/(name+'.kt') for name in unit_names]
    sources.append(root/'app/src/test/kotlin/com/soundq/android/product/timeline/VinylStrokeTest.kt')
command=['/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java','-Xmx1536m','-XX:ActiveProcessorCount=1','-cp',os.pathsep.join(map(str,compiler)),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect',f'-Xplugin={jar("org.jetbrains.kotlin","kotlin-compose-compiler-plugin-embeddable","2.4.21")}',f'-Xplugin={jar("org.jetbrains.kotlin","kotlin-serialization-compiler-plugin-embeddable","2.4.21")}','-jvm-target','17','-cp',os.pathsep.join(map(str,cp)),'-d',str(a.output/'classes'),*map(str,sources)]
(a.output/'provenance.json').write_text(json.dumps({'command':command,'sources':{str(x):hashlib.sha256(x.read_bytes()).hexdigest() for x in sources},'boundary':'compile only, no mounted execution'},indent=2)+'\n')
subprocess.run(command,check=True)
if a.unit_tests:
    subprocess.run([command[0],'-XX:ActiveProcessorCount=1','-cp',os.pathsep.join(map(str,[a.output/'classes',*cp])),'org.junit.runner.JUnitCore',*['com.soundq.android.data.timeline.'+name for name in unit_names],'com.soundq.android.product.timeline.VinylStrokeTest'],check=True)
print('PASS exact TimelineLane, real More/BPM/timing controls and 4 instrumentation classes compile against cached Kotlin 2.4.21 / Compose 1.12.1. Not device execution.')
