#!/usr/bin/env python3
"""Actual source lease/parser host controls. Syscall/route facades only; no SDK/media."""
from pathlib import Path
import argparse, hashlib, json, os, subprocess
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);p.add_argument('--java-home',type=Path,required=True);a=p.parse_args()
repo=Path(__file__).resolve().parents[3];out=a.output.resolve()
assert not out.is_relative_to(repo)
out.mkdir(parents=True,exist_ok=False)
java=a.java_home.resolve()
assert (java/'bin/java').is_file() and (java/'bin/javac').is_file(), 'Explicit full JDK required'
env=dict(os.environ,JAVA_HOME=str(java),PATH=str(java/'bin')+os.pathsep+os.environ['PATH'],TMPDIR=str(out),JAVA_OPTS='-Xmx512m -XX:ActiveProcessorCount=1')
results=[]
def run(name,cmd):
 cmd=list(map(str,cmd));r=subprocess.run(cmd,env=env,cwd=repo,capture_output=True,text=True,timeout=300)
 (out/(name+'.log')).write_text(r.stdout+r.stderr);results.append(dict(name=name,command=cmd,exit=r.returncode));(out/'commands.json').write_text(json.dumps(results,indent=2)+'\n');print(name,r.returncode,r.stdout+r.stderr,flush=True)
 if r.returncode:raise SystemExit(r.returncode)
run('lease-boundaries',['python3',repo/'android/scripts/test-original-read-boundaries.py','--output',out/'boundaries'])
native=repo/'android/app/src/main/kotlin/com/soundq/android/playback/nativeengine'
probe=Path(__file__).with_name('MetadataLeaseProbe.kt');jar=out/'boundaries/probe.jar'
inputs=[native/n for n in ('OriginalMetadataReader.kt','OriginalAudioReadLease.kt','Mp3OriginalFrames.kt','OriginalDescriptorCustody.kt')]+[probe,repo/'android/scripts/test-original-read-boundaries.py']
(out/'inputs.json').write_text(json.dumps({str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in inputs},indent=2)+'\n')
cp=os.pathsep.join(map(str,[jar,out/'boundaries/27/classes']))
run('compile',['kotlinc','-J-Xmx512m','-J-XX:ActiveProcessorCount=1',probe,native/'Mp3OriginalFrames.kt','-cp',cp,'-Xfriend-paths='+str(jar),'-nowarn','-include-runtime','-d',out/'metadata.jar'])
run('metadata-controls',[java/'bin/java','-Xmx512m','-XX:ActiveProcessorCount=1','-Djava.io.tmpdir='+str(out),'-cp',str(out/'metadata.jar')+os.pathsep+cp,'com.soundq.android.playback.nativeengine.MetadataLeaseProbeKt'])
