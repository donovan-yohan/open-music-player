#!/usr/bin/env python3
"""Compile actual tempo source and JUnit tests only; no Gradle, Android or audio."""
import argparse
import os
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "scripts"))
from host_probe import scratch_root, gradle_cache, kotlin_plugin, android_jar
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, help='Replay an exact preserved production source')
args = parser.parse_args()
android = Path(__file__).resolve().parents[3]
cache = gradle_cache() / 'modules-2/files-2.1'
scratch = scratch_root()
def jar(group, artifact, version):
    paths = list((cache/group/artifact/version).glob('*/*.jar'))
    if len(paths) != 1:
        raise SystemExit(f'Expected one {artifact}:{version}, got {paths}')
    return str(paths[0])
cp = os.pathsep.join([jar('junit','junit','4.13.2'),jar('org.hamcrest','hamcrest-core','1.3'),
    jar('org.jetbrains.kotlinx','kotlinx-serialization-core-jvm','1.9.0'),
    jar('org.jetbrains.kotlinx','kotlinx-serialization-json-jvm','1.9.0'),jar('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.10.2')])
compiler = kotlin_plugin('kotlinx-serialization-compiler-plugin.jar')
source = args.source or android/'app/src/main/kotlin/com/soundq/android/data/timeline/TempoTransition.kt'
tests = android/'app/src/test/kotlin/com/soundq/android/data/timeline/TempoTransitionTest.kt'
with tempfile.TemporaryDirectory(prefix='soundq-tempo-',dir=scratch) as directory:
    out = Path(directory)/'tests.jar'
    env = dict(os.environ, TMPDIR=str(scratch))
    src=android/'app/src/main/kotlin/com/soundq/android/data/timeline'
    track=Path(directory)/'TrackId.kt';track.write_text('package com.soundq.android.data\n@JvmInline value class TrackId(val value:Long)')
    dependencies=[src/x for x in ['Timeline.kt','TimelineOwner.kt','TimelineGeometry.kt','LinkedPhase.kt','Waveform.kt']]
    subprocess.run(['kotlinc','-J-XX:ActiveProcessorCount=1',str(source),str(tests),*map(str,dependencies),str(track),'-cp',cp,f'-Xplugin={compiler}','-d',str(out)],check=True,env=env)
    result = subprocess.run(['kotlin','-cp',str(out)+os.pathsep+cp,'org.junit.runner.JUnitCore',
        'com.soundq.android.data.timeline.TempoTransitionTest'],env=env)
    raise SystemExit(result.returncode)
