#!/usr/bin/env python3
"""Serial one-lane source/build validation. Never installs or starts Android."""
import hashlib,json,os,pathlib,shutil,subprocess,sys,time,xml.etree.ElementTree as ET
from host_probe import directory, scratch_root
ROOT=pathlib.Path(__file__).resolve().parents[1]
OUT=pathlib.Path(sys.argv[1]);OUT.mkdir(parents=True,exist_ok=True)
PY=sys.executable
ENV=os.environ.copy()
for name in ('JAVA_HOME','ANDROID_HOME','GRADLE_USER_HOME'):
    ENV[name]=str(directory(name))
ENV['TMPDIR']=str(scratch_root())
for name in ('OMP_API_BASE_URL','OMP_SOURCE_REF','OMP_BUILD_ID'):
    if not ENV.get(name):raise SystemExit('Set '+name+' explicitly')
ENV.update(SOUNDQ_PYTHON=PY,CMAKE_BUILD_PARALLEL_LEVEL='1')
suffix='dylib' if sys.platform=='darwin' else 'so'
ENV['SOUNDQ_MIX_HOST_LIBRARY']=str(ROOT/('build/native-mix-host/libsoundq_mix_android.'+suffix))
ENV['SOUNDQ_MIX_FIXTURE']=str(pathlib.Path(os.environ['TMPDIR'])/'native-mix-oracle')
steps=[]
def run(name,argv,cwd=ROOT,env=ENV):
    start=time.monotonic();log=OUT/(name+'.log')
    with log.open('w') as f:
        result=subprocess.run(argv,cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT)
    step=dict(name=name,argv=argv,cwd=str(cwd),exit=result.returncode,seconds=time.monotonic()-start,log=log.name)
    steps.append(step);(OUT/'commands.json').write_text(json.dumps(steps,indent=2))
    print(json.dumps(step),flush=True)
    if result.returncode:raise SystemExit(result.returncode)
host=ENV.copy();host['JAVA_HOME']=ENV.get('SOUNDQ_HOST_JAVA_HOME',ENV['JAVA_HOME'])
if not (pathlib.Path(host['JAVA_HOME'])/'include/jni.h').is_file():raise SystemExit('Set SOUNDQ_HOST_JAVA_HOME to a full JDK with JNI headers')
run('host-configure',['cmake','-S','app/src/main/cpp','-B','build/native-mix-host','-DCMAKE_BUILD_TYPE=Debug'],env=host)
run('host-build',['cmake','--build','build/native-mix-host','--parallel','1'])
run('every-sample-oracle',[PY,'scripts/test-native-mix.py','build/native-mix-host',ENV['SOUNDQ_MIX_FIXTURE']])
run('kotlin-ndk-apks-lint',['./gradlew',':app:testDebugUnitTest','--tests','com.soundq.android.data.MixBoundaryTest','--tests','com.soundq.android.playback.mix.*','--tests','com.soundq.android.data.ApiTest','--tests','com.soundq.android.playback.QueuePolicyTest','--tests','com.soundq.android.playback.QueueSnapshotTest','--tests','com.soundq.android.extracted.DevicePlayExtractedTest',':app:assembleDebug',':app:assembleDebugAndroidTest',':app:lintDebug','--no-daemon','--max-workers=1','-Dorg.gradle.jvmargs=-Xmx1536m -XX:MaxMetaspaceSize=512m -XX:ActiveProcessorCount=1 -Dfile.encoding=UTF-8','-Pkotlin.compiler.execution.strategy=in-process','-POMP_API_BASE_URL='+ENV['OMP_API_BASE_URL']])
run('go-mix-handlers',['go','test','-p','1','./internal/api','-run','Test(CreateMixPlan|UpdateMixPlan|GetMixPlan|SaveMixPlan|BuildMixPlanPayload)','-count=1'],cwd=ROOT.parent/'backend',env={**ENV,'GOMAXPROCS':'1'})
run('design-drift',[PY,'-B','scripts/check-design.py'])
run('delivery',['scripts/lint','delivery'],cwd=ROOT.parent)
run('diff-check',['git','diff','--check'])
xmls=list((ROOT/'app/build/test-results/testDebugUnitTest').glob('TEST-*.xml'))
counts={k:sum(int(ET.parse(p).getroot().attrib[k]) for p in xmls) for k in ['tests','failures','errors','skipped']}
assert counts['failures']==counts['errors']==counts['skipped']==0
shutil.copytree(ROOT/'app/build/test-results/testDebugUnitTest',OUT/'xml',dirs_exist_ok=True)
for file in ['lint-results-debug.xml','lint-results-debug.html','lint-results-debug.sarif']:
    shutil.copy2(ROOT/'app/build/reports'/file,OUT/file)
for src in [ROOT/'app/build/outputs/apk/debug/app-debug.apk',ROOT/'app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk']:
    target=OUT/src.name;shutil.copy2(src,target)
(OUT/'test-counts.json').write_text(json.dumps(counts,indent=2))
print(json.dumps({'status':'PASS','tests':counts,'noRuntime':True}),flush=True)
