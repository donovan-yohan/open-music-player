#!/usr/bin/env python3
"""Host-only real timeline model/owner behavior. No shared Gradle or device."""
import os
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "scripts"))
from host_probe import scratch_root, gradle_cache, kotlin_plugin, android_jar
import subprocess
import tempfile
root = Path(__file__).resolve().parents[3]
cache = gradle_cache() / 'modules-2/files-2.1'
scratch = scratch_root()
def jar(group, name, version):
    return str(next((cache/group/name/version).glob('*/*.jar')))
cp = os.pathsep.join([jar('junit','junit','4.13.2'),jar('org.hamcrest','hamcrest-core','1.3'),jar('org.jetbrains.kotlinx','kotlinx-serialization-core-jvm','1.9.0'),jar('org.jetbrains.kotlinx','kotlinx-serialization-json-jvm','1.9.0'),jar('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.10.2')])
src = root/'app/src/main/kotlin/com/soundq/android/data/timeline'
tests = root/'app/src/test/kotlin/com/soundq/android/data/timeline'
with tempfile.TemporaryDirectory(prefix='tempo-integration-', dir=scratch) as directory:
    out = Path(directory)
    (out/'TrackId.kt').write_text('package com.soundq.android.data\n@JvmInline value class TrackId(val value:Long)')
    sources = [src/x for x in ['Timeline.kt','TimelineOwner.kt','TimelineGeometry.kt','LinkedPhase.kt','TempoTransition.kt','Waveform.kt']]
    test_sources = [tests/x for x in ['TempoPlaybackWorkflowTest.kt','TempoIntegrationTest.kt','TimelineOwnerTest.kt','TimelineFadeEditTest.kt','TimelineGeometryTest.kt','TempoTransitionTest.kt']]
    env = dict(os.environ,TMPDIR=str(out))
    subprocess.run(['kotlinc','-J-XX:ActiveProcessorCount=1',*map(str,sources+test_sources),str(out/'TrackId.kt'),'-cp',cp,'-Xplugin='+kotlin_plugin('kotlinx-serialization-compiler-plugin.jar'),'-d',str(out/'tests.jar')],check=True,env=env)
    result = subprocess.run(['kotlin','-J-XX:ActiveProcessorCount=1','-cp',str(out/'tests.jar')+os.pathsep+cp,'org.junit.runner.JUnitCore',*[f'com.soundq.android.data.timeline.{p.stem}' for p in test_sources]],env=env)
    raise SystemExit(result.returncode)
