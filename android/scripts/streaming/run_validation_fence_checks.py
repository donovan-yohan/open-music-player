#!/usr/bin/env python3
"""SDK-free production-reader validation-fence regression; not codec/device proof.

Full original route/stat validation is bounded by operation/positioned IO and
pre-publication, not decoder output chunk count. Cached speculative decoding must
still refuse a changed or revoked original before returning any native page.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--java-home', type=Path, required=True)
p.add_argument('--kotlinc', default='kotlinc')
p.add_argument('--reader-source', type=Path)
a = p.parse_args()
probes = Path(__file__).resolve().parent
repo = probes.parents[2]
native = repo / 'android/app/src/main/kotlin/com/soundq/android/playback/nativeengine'
out = a.output.resolve()
if out.is_relative_to(repo):
    p.error('Keep mutable host output outside source')
out.mkdir(parents=True, exist_ok=False)
inputs = [a.reader_source or native / 'AndroidPlatformWindowReader.kt',
          native / 'Mp3OriginalFrames.kt', probes / 'KeepFacade.kt']
inputs += [probes / 'validation-fence' / n for n in ('MediaFacade.kt', 'LeaseFacade.kt', 'ValidationFenceProbe.kt')]
sha = lambda f: hashlib.sha256(f.read_bytes()).hexdigest()
before = {str(f): sha(f) for f in inputs}
(out / 'inputs.json').write_text(json.dumps(before, indent=2) + '\n')
env = dict(os.environ, JAVA_HOME=str(a.java_home))
commands = [[a.kotlinc, '-J-Xmx512m', '-J-XX:ActiveProcessorCount=1',
             *map(str, inputs), '-nowarn', '-include-runtime', '-d', str(out / 'fence.jar')],
            [str(a.java_home / 'bin/java'), '-Xmx512m', '-jar', str(out / 'fence.jar')]]
runs = []
for i, command in enumerate(commands):
    with (out / f'run-{i}.log').open('w') as f:
        result = subprocess.run(command, env=env, stdout=f, stderr=subprocess.STDOUT)
    runs.append(dict(command=command, exit=result.returncode))
    (out / 'results.json').write_text(json.dumps(runs, indent=2) + '\n')
    print(i, result.returncode, flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)
assert before == {str(f): sha(f) for f in inputs}, 'Inputs changed during probe'
print('PASS exact production reader: bounded validation, samples, version/revocation/publication and close fences')
