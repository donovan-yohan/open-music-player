#!/usr/bin/env python3
"""Device-free round1 regression gate. Never launches apps or default endpoints.
Example: python3 native/tests/repair_round1.py --evidence /private/output \
  --rust-bin /explicit/rust/toolchain/bin --include-kotlin
Kotlin seams use the documented local JDK17/Android36 SDK metadata and Gson;
without that opt-in only Rust/ABI/planner controls execute.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import hashlib

ROOT=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--evidence',type=Path,required=True)
parser.add_argument('--rust-bin',type=Path,required=True)
parser.add_argument('--include-kotlin',action='store_true')
args=parser.parse_args()
out=args.evidence.resolve()
for d in [out,out/'home',out/'tmp',out/'cargo-home',out/'logs']:
    d.mkdir(parents=True,exist_ok=True)
# Reuse public Cargo registry only, never user config/auth/settings.
registry=out/'cargo-home/registry'
if not registry.exists():
    source_registry=Path(os.environ.get('CARGO_HOME',str(Path.home()/'.cargo')))/'registry'
    if not source_registry.is_dir():
        raise SystemExit('Offline Cargo registry unavailable; set CARGO_HOME to the installed registry cache')
    registry.symlink_to(source_registry.resolve(),target_is_directory=True)
env={'PATH':str(args.rust_bin)+':/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(out/'home'),
     'TMPDIR':str(out/'tmp'),'CARGO_HOME':str(out/'cargo-home'),'CARGO_TARGET_DIR':str(out/'target'),
     'CARGO_BUILD_JOBS':'2','CARGO_NET_OFFLINE':'true','PYTHONDONTWRITEBYTECODE':'1',
     'SOUNDQ_REPAIR_PROBES':str(ROOT/'native/tests'),'SOUNDQ_REPAIR_EVIDENCE':str(out),
     'SOUNDQ_REPAIR_OUTPUT':str(out/'logs'),
     'SOUNDQ_CORE_LIBRARY':str(out/'target/debug'/('libsoundq_core.dylib' if sys.platform=='darwin' else 'libsoundq_core.so'))}
commands=[[str(args.rust_bin/'cargo'),'fmt','--manifest-path',str(ROOT/'native/core/Cargo.toml'),'--check'],
          [str(args.rust_bin/'cargo'),'test','--locked','--offline','--manifest-path',str(ROOT/'native/core/Cargo.toml'),'--','--test-threads=1'],
          [str(args.rust_bin/'cargo'),'build','--locked','--offline','--manifest-path',str(ROOT/'native/core/Cargo.toml')]]
names=['credential_delivery','cache_collision','cache_stage_ownership','account_scope','refresh_response','envelope_invariants','planner_invariants']
names.insert(3,'cache_publication')
if args.include_kotlin:
    for name in ['SOUNDQ_JAVA_HOME','JAVA_HOME','ANDROID_HOME','ANDROID_SDK_ROOT','SOUNDQ_ANDROID_JAR','SOUNDQ_GSON_JAR','SOUNDQ_KOTLINC']:
        if name in os.environ:
            env[name]=os.environ[name]
    env['PATH']+=os.pathsep+os.environ.get('PATH',os.defpath)
    names+=['android_adapter_invariants','composed_credentials']
commands += [[sys.executable,str(ROOT/'native/tests'/f'{name}.py')] for name in names]
results=[]
for index,argv in enumerate(commands):
    p=subprocess.run(argv,cwd=ROOT,env=env,capture_output=True,text=True,timeout=240)
    log=out/'logs'/f'{index}.log'
    log.write_text(p.stdout+p.stderr)
    results.append({'argv':argv,'exitCode':p.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
    (out/'gate.json').write_text(json.dumps({'results':results,'complete':False},indent=2)+'\n')
    print(index,p.returncode)
    if p.returncode:
        sys.exit(p.returncode)
(out/'gate.json').write_text(json.dumps({'results':results,'complete':True,'status':'passed'},indent=2)+'\n')
print('ROUND1_DEVICE_FREE_GATE_PASS')
