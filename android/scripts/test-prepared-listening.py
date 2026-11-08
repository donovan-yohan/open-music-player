#!/usr/bin/env python3
"""Compile real preparation/cursor/JNI against codec/platform IO facades. Not Android decode."""
from pathlib import Path
from host_probe import directory, gradle_cache, kotlin_plugin, android_jar
import argparse,json,os,subprocess,sys
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--classpath',required=True);p.add_argument('--library',required=True);p.add_argument('--fixtures',required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[1];a.out.mkdir(parents=True)
main=root/'app/src/main/kotlin/com/soundq/android/playback'
files=list((root/'scripts/prepared-listening-tests').glob('*.kt'))+[main/'listening'/f for f in ['PreparedListening.kt','SequentialPcmCursor.kt','ListeningMemoryOutput.kt','ListeningSchedule.kt','RollingListeningPcm.kt']]+[main/'mix'/f for f in ['NativeMix.kt','NativeMixStream.kt']]
private=main/'listening/PrivateListeningPcm.kt'
if private.exists():files.append(private)
env=dict(os.environ,JAVA_HOME=str(directory('JAVA_HOME')),JAVA_TOOL_OPTIONS='-XX:ActiveProcessorCount=1')
def run(label,cmd):
 r=subprocess.run(cmd,capture_output=True,text=True,env=env,timeout=180)
 (a.out/(label+'.json')).write_text(json.dumps(dict(argv=cmd,exit=r.returncode,stdout=r.stdout,stderr=r.stderr),indent=2));print(r.stdout,r.stderr);return r.returncode
cmd=['kotlinc','-J-Xmx1536m','-J-XX:MaxMetaspaceSize=512m','-J-XX:ActiveProcessorCount=1','-jvm-target','17','-cp',a.classpath,*map(str,files),'-include-runtime','-d',str(a.out/'tests.jar')]
if run('compile',cmd):sys.exit(1)
sys.exit(run('junit',[env['JAVA_HOME']+'/bin/java','-Xcheck:jni','-Xmx512m','-XX:ActiveProcessorCount=1','-Dsoundq.mix.library='+a.library,'-Dsoundq.prepared.fixture='+a.fixtures,'-cp',str(a.out/'tests.jar')+':'+a.classpath,'com.soundq.android.playback.listening.NamedTestRunner']))
