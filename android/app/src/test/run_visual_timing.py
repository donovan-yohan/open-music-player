#!/usr/bin/env python3
"""Actual timing mapping tests plus no-raw-entry source contract; no mounted UI claim."""
import os
import argparse
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "scripts"))
from host_probe import scratch_root, gradle_cache, kotlin_plugin, android_jar
import subprocess
import tempfile
root=Path(__file__).resolve().parents[3]
main=root/'app/src/main/kotlin/com/soundq/android'
ui=main/'product/timeline'
parser=argparse.ArgumentParser();parser.add_argument('--contract-source',type=Path);parser.add_argument('--mapping-source',type=Path);parser.add_argument('--contract-only',action='store_true');args=parser.parse_args()
for name in ['LinkedPhaseControls.kt','LiveSyncControls.kt','TimelineFadeControls.kt','StackedTimeline.kt']:
    source=((args.contract_source/(name+'.before')) if args.contract_source else ui/name).read_text()
    for line in source.splitlines():
        if ('SoundQTextField(' in line or 'OutlinedTextField(' in line) and any(x in line.lower() for x in ['anchor','origin','proposed','pairstart','duration','milliseconds']):
            raise AssertionError(f'{name}: raw timing entry remains: {line.strip()}')
print('PASS no raw timing entry source contract')
if args.contract_only:raise SystemExit(0)
cache=gradle_cache() / 'modules-2/files-2.1'
def jar(group,name,version):return str(next((cache/group/name/version).glob('**/*.jar')))
cp=os.pathsep.join([jar('junit','junit','4.13.2'),jar('org.hamcrest','hamcrest-core','1.3'),jar('org.jetbrains.kotlinx','kotlinx-serialization-core-jvm','1.9.0'),jar('org.jetbrains.kotlinx','kotlinx-serialization-json-jvm','1.9.0'),jar('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.10.2')])
scratch=scratch_root()
with tempfile.TemporaryDirectory(prefix='visual-timing-',dir=scratch) as directory:
    out=Path(directory)
    track=out/'TrackId.kt';track.write_text('package com.soundq.android.data\n@JvmInline value class TrackId(val value:Long)')
    sources=[main/'data/timeline'/x for x in ['Timeline.kt','TimelineOwner.kt','TimelineGeometry.kt','LinkedPhase.kt','TempoTransition.kt','Waveform.kt']]
    sources += [args.mapping_source or ui/'VisualTimingMapping.kt',track,root/'app/src/test/kotlin/com/soundq/android/product/timeline/VisualTimingControlsTest.kt']
    env=dict(os.environ,TMPDIR=str(out))
    subprocess.run(['kotlinc','-J-XX:ActiveProcessorCount=1','-Xplugin='+kotlin_plugin('kotlinx-serialization-compiler-plugin.jar'),*map(str,sources),'-cp',cp,'-d',str(out/'tests.jar')],check=True,env=env)
    subprocess.run(['kotlin','-J-XX:ActiveProcessorCount=1','-cp',str(out/'tests.jar')+os.pathsep+cp,'org.junit.runner.JUnitCore','com.soundq.android.product.timeline.VisualTimingControlsTest'],check=True,env=env)
