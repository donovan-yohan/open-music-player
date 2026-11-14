#!/usr/bin/env python3
"""Bounded, SDK/Gradle-free codec eligibility facades. Not Android runtime proof."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', required=True, type=Path)
p.add_argument('--java-home', required=True, type=Path)
p.add_argument('--reader-source', type=Path)
a = p.parse_args()
probes = Path(__file__).resolve().parent
repo = probes.parents[2]
native = repo / 'android/app/src/main/kotlin/com/soundq/android/playback/nativeengine'
reader = a.reader_source or native / 'AndroidPlatformWindowReader.kt'
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=False)
env = dict(os.environ, JAVA_HOME=str(a.java_home), JAVA_OPTS='-Xmx512m -XX:ActiveProcessorCount=1')
results = []
inputs = [probes / n for n in ('KeepFacade.kt', 'MediaFacade.kt', 'LeaseFacade.kt', 'PlatformWindowProbe.kt', 'EligibilityEosProbe.kt')]
inputs += [native / 'NativePlaybackSource.kt', native / 'Mp3OriginalFrames.kt', reader]
(out / 'inputs.json').write_text(json.dumps({str(f): hashlib.sha256(f.read_bytes()).hexdigest() for f in inputs}, indent=2)+'\n')

def run(name, command):
    command = list(map(str, command))
    r = subprocess.run(command, cwd=repo, env=env, text=True, capture_output=True)
    (out / (name+'.log')).write_text(r.stdout+r.stderr)
    results.append(dict(name=name, command=command, exit=r.returncode))
    (out / 'results.json').write_text(json.dumps(results, indent=2)+'\n')
    print(name, r.returncode, r.stdout+r.stderr, flush=True)
    return r.returncode

if run('compile', ['kotlinc', *inputs, '-nowarn', '-include-runtime', '-d', out / 'platform.jar']):
    raise SystemExit(1)
java = [a.java_home / 'bin/java', '-Xmx512m', '-XX:ActiveProcessorCount=1', '-Djava.io.tmpdir='+os.environ['TMPDIR'], '-cp', out / 'platform.jar']
failed = run('long-control', [*java, 'com.soundq.android.playback.nativeengine.PlatformWindowProbeKt']) != 0
for mode in ('short-empty-eos', 'short-unmapped-seek', 'failure-read', 'failure-cancel', 'failure-decoded-budget'):
    failed |= run(mode, [*java, 'com.soundq.android.playback.nativeengine.EligibilityEosProbeKt', mode]) != 0
raise SystemExit(int(failed))
