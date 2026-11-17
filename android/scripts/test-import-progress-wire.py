#!/usr/bin/env python3
"""Exact API/parser/journal/import-owner progress proof with synthetic interception.

No SDK/Gradle/network. Reuses the existing readback generator and its pinned jars.
Compiles Android OkHttp signatures and runs the established JVM transport adapter.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--dependencies', type=Path, required=True)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
repo = Path(__file__).resolve().parents[2]
out = a.out.resolve()
out.mkdir(parents=True, exist_ok=True)
runner = runpy.run_path(str(Path(__file__).with_name('test-radar-readback.py')))
pins = runner['PINS']
for name, expected in pins.items():
    assert hashlib.sha256((a.dependencies / name).read_bytes()).hexdigest() == expected, name
sources, receipt = runner['generate'](repo, out)
sources.remove(out / 'Journey.kt')
fixture = Path(__file__).parent / 'fixtures/import-progress/WireJourney.kt'
sources.append(fixture)
compile_cp = os.pathsep.join(str(a.dependencies / n) for n in pins if n != 'okhttp-4.12.0.jar')
runtime_cp = os.pathsep.join(str(a.dependencies / n) for n in pins if n != 'okhttp-5.5.1.jar')
env = dict(os.environ, TMPDIR=str(out), JAVA_OPTS='-Xmx512m -XX:ActiveProcessorCount=2 -Djava.io.tmpdir='+str(out))
c = subprocess.run(['kotlinc', '-J-Xmx512m', '-J-XX:ActiveProcessorCount=2', *map(str, sources), '-cp', compile_cp, '-include-runtime', '-d', str(out / 'checks.jar')], env=env, capture_output=True, text=True)
(out / 'compile.log').write_text(c.stdout+c.stderr)
receipt.update(compile_exit=c.returncode, dependencies=pins, sources={str(s):hashlib.sha256(s.read_bytes()).hexdigest() for s in sources})
if c.returncode:
    print(c.stdout+c.stderr)
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2))
    raise SystemExit(c.returncode)
r = subprocess.run(['java', '-Xmx512m', '-XX:ActiveProcessorCount=2', '-Djava.io.tmpdir='+str(out), '-cp', str(out / 'checks.jar')+os.pathsep+runtime_cp, 'com.soundq.android.data.WireJourneyKt'], env=env, capture_output=True, text=True)
(out / 'run.log').write_text(r.stdout+r.stderr)
receipt.update(exit=r.returncode, stdout=r.stdout, stderr=r.stderr)
(out / 'receipt.json').write_text(json.dumps(receipt, indent=2))
print(r.stdout+r.stderr)
raise SystemExit(r.returncode)
