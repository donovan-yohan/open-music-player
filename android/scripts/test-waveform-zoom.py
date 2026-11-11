#!/usr/bin/env python3
"""Exact production waveform/cache/paint regression; no Gradle, device or network.

Uses retained six-minute Go producer bytes, actual Kotlin data/parser/rate code,
real Compose Color jar and generated spectral tokens. Counts accesses to the
accepted rate list, not wall-clock thresholds. --paint can replay a pinned
predecessor against identical tests. One CPU/compiler backend thread.
"""
from pathlib import Path
import argparse
import hashlib
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--paint', type=Path)
p.add_argument('--waveform', type=Path)
p.add_argument('--mode', choices=['all', 'compatibility', 'performance'], default='all')
a = p.parse_args()
r = Path(__file__).resolve().parents[1]
o = a.output.resolve()
o.mkdir(parents=True, exist_ok=True)
cache = Path.home()/'.gradle/caches/modules-2/files-2.1'
def jar(group, name, version):
    return next((cache/group/name/version).glob('*/*.jar'))
# Extract real Android Compose classes, without invoking Gradle or Android APIs.
import zipfile
compose = []
for name in ['ui-graphics', 'ui-util']:
    aar = next((cache/'androidx.compose.ui'/f'{name}-android'/'1.12.1').glob('*/*.aar'))
    target = o/f'{name}.jar'
    with zipfile.ZipFile(aar) as z:
        target.write_bytes(z.read('classes.jar'))
    compose.append(target)
cp = ':'.join(map(str, [jar('org.jetbrains.kotlinx','kotlinx-serialization-json-jvm','1.7.3'), jar('org.jetbrains.kotlinx','kotlinx-serialization-core-jvm','1.7.3'), jar('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.8.1'), jar('junit','junit','4.13.2'),jar('org.hamcrest','hamcrest-core','1.3'), *compose]))
(o/'IdentityFacade.kt').write_text('package com.soundq.android.data\n@JvmInline value class TrackId(val value:Long)\n')
(o/'ExchangeFacade.kt').write_text('package com.soundq.android.data.mix\nclass ExchangeRefusal {enum class Code { conflict }}\n')
# Only unrelated Dp tokens need a host unit declaration; production Color is real.
(o/'Units.kt').write_text('package androidx.compose.ui.unit\n@JvmInline value class Dp(val value:Float)\nval Int.dp:Dp get()=Dp(toFloat())\nval Float.dp:Dp get()=Dp(this)\nval Double.dp:Dp get()=Dp(toFloat())\n')
data = r/'app/src/main/kotlin/com/soundq/android/data/timeline'
paint = a.paint or r/'app/src/main/kotlin/com/soundq/android/product/timeline/SpectralWaveformPaint.kt'
wave = a.waveform or data/'Waveform.kt'
files = [data/n for n in ['Timeline.kt','TimelineOwner.kt','LinkedPhase.kt','TimelineGeometry.kt','TempoTransition.kt']]+[wave, paint]
helper = paint.parent/'SpectralRateProjection.kt'
if helper.exists():
    files.append(helper)
files += [r/'designsystem/src/generated/kotlin/soundq/design/generated/SoundQSpectralTokens.kt', r/'app/src/test/kotlin/com/soundq/android/product/timeline/WaveformZoomRegression.kt', o/'IdentityFacade.kt', o/'ExchangeFacade.kt', o/'Units.kt']
files += [r/'app/src/test/kotlin/com/soundq/android/data/timeline/WaveformTest.kt', r/'app/src/test/kotlin/com/soundq/android/product/timeline/SpectralWaveformPaintTest.kt']
print('SOURCE_PINS', {str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in files}, flush=True)
for cmd in [
    ['kotlinc','-J-Xmx512m','-J-XX:ActiveProcessorCount=1','-Xbackend-threads=1',*map(str,files),'-cp',cp,'-include-runtime','-d',str(o/'zoom.jar')],
    ['java','-XX:ActiveProcessorCount=1','-Xmx512m','-cp',str(o/'zoom.jar')+':'+cp+':'+str(r/'app/src/test/resources'),'org.junit.runner.JUnitCore','com.soundq.android.data.timeline.WaveformTest','com.soundq.android.product.timeline.SpectralWaveformPaintTest'],
    ['java','-XX:ActiveProcessorCount=1','-Xmx512m','-cp',str(o/'zoom.jar')+':'+cp,'com.soundq.android.product.timeline.WaveformZoomRegressionKt',str(r/'app/src/test/resources/waveform/producer-six-minute.json.gz'),a.mode]
]:
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    print(result.stdout+result.stderr, flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)
