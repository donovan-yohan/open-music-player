#!/usr/bin/env python3
"""Compile only owned Kotlin playback/service sources with pinned cached dependencies.
No Gradle, network, backend, device or account access. Existing app classes supply
unmodified module dependencies, not replacements for the changed source bodies.
"""
from pathlib import Path
import argparse, os, subprocess, zipfile
p=argparse.ArgumentParser();p.add_argument('--build',type=Path,required=True);p.add_argument('--player-tests',action='store_true');p.add_argument('--legacy-extracted',type=Path);p.add_argument('--player-source',type=Path);a=p.parse_args()
r=Path(__file__).resolve().parents[2];a.build.mkdir(parents=True,exist_ok=True)
cache=Path(os.environ['GRADLE_USER_HOME'])/'caches/modules-2/files-2.1'
def jar(group,artifact,version):return next((cache/group/artifact/version).glob('*/*.jar'))
compiler=[jar('org.jetbrains.kotlin',x,'2.4.21') for x in ('kotlin-compiler-embeddable','kotlin-build-tools-api','kotlin-stdlib','kotlin-script-runtime','kotlin-daemon-embeddable')]
compiler += [jar('org.jetbrains.kotlin','kotlin-reflect','1.6.10'),jar('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.8.0')]
compiler += list((cache/'org.jetbrains'/'annotations').glob('*/*/*.jar'))
cp=[r/'android/app/build/intermediates/built_in_kotlinc/debug/compileDebugKotlin/classes',Path.home()/'Library/Android/sdk/platforms/android-37.0/android.jar']
for group in ('androidx.media3','androidx.annotation','androidx.core','androidx.lifecycle','androidx.collection','com.google.guava','org.jetbrains.kotlinx','org.jetbrains.kotlin','androidx.concurrent','com.squareup.okhttp3','com.squareup.okio'):
    for artifact in (cache/group).glob('*'):
        for version in artifact.iterdir():
            # Exact runtime versions for Media3 and Kotlin. Other cached modules
            # only supply annotation/utility ABI and have no product execution here.
            if group=='androidx.media3' and version.name!='1.11.1':continue
            if group=='org.jetbrains.kotlin' and (version.name!='2.4.21' or artifact.name!='kotlin-stdlib'):continue
            if group=='org.jetbrains.kotlinx' and artifact.name.startswith('kotlinx-serialization') and version.name!='1.12.0':continue
            if group=='org.jetbrains.kotlinx' and artifact.name.startswith('kotlinx-coroutines') and version.name!='1.10.2':continue
            if group=='com.google.guava' and artifact.name=='guava' and version.name!='33.4.8-jre':continue
            if group=='androidx.lifecycle' and version.name!='2.11.0':continue
            if group=='androidx.core' and artifact.name in ('core','core-ktx') and version.name!='1.18.0':continue
            if group=='com.squareup.okhttp3' and version.name!='5.5.1':continue
            if group=='com.squareup.okio' and version.name!='3.18.1':continue
            for file in version.glob('*/*'):
                if file.suffix=='.jar':cp.append(file)
                elif file.suffix=='.aar':
                    with zipfile.ZipFile(file) as z:
                        if 'classes.jar' in z.namelist():
                            target=a.build/(artifact.name+'-'+version.name+'.jar');target.write_bytes(z.read('classes.jar'));cp.append(target)
base=r/'android/app/src/main/kotlin/com/soundq/android/playback'
sources=list((base/'nativeengine').glob('*.kt'))+[base/'Arrangement.kt',base/'SoundQLibraryService.kt',base/'ControllerProjection.kt']
if (base/'TransientPerformance.kt').exists():sources.append(base/'TransientPerformance.kt')
if a.player_source:sources=[a.player_source if x.name=='NativeCallbackPlayer.kt' else x for x in sources]
sources.append(base.parent/'data/timeline/TimelineRepository.kt')
if a.player_tests:
    for group in ('org.robolectric','org.ow2.asm','org.junit','junit','org.hamcrest','javax.inject','jakarta.inject','javax.annotation','com.google.errorprone','com.google.j2objc','com.google.auto.service','com.google.auto','com.almworks.sqlite4java','org.bouncycastle','org.conscrypt','org.jetbrains','androidx.test','androidx.test.ext','androidx.tracing','androidx.arch.core','androidx.versionedparcelable','androidx.media','androidx.customview','androidx.activity','androidx.savedstate'):
        for file in (cache/group).glob('*/*/*/*'):
            if file.suffix=='.jar':cp.append(file)
            elif file.suffix=='.aar':
                with zipfile.ZipFile(file) as z:
                    if 'classes.jar' in z.namelist():
                        target=a.build/(file.stem+'.jar');target.write_bytes(z.read('classes.jar'));cp.append(target)
    sources.extend([r/'android/scripts/OrdinaryCrossfadePlayerTest.kt',base.parent/'data/preferences/CrossfadePreferences.kt',r/'android/app/src/test/kotlin/com/soundq/android/data/preferences/CrossfadePreferencesTest.kt'])
    if a.legacy_extracted:
        sources.append(a.legacy_extracted/'ArrangementServiceExtractedTest.kt')
        cp.append(r/'android/app/build/intermediates/built_in_kotlinc/debugUnitTest/compileDebugUnitTestKotlin/classes')
java=Path('/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java')
subprocess.run([str(java),'-Xmx1536m','-XX:ActiveProcessorCount=1','-cp',os.pathsep.join(map(str,compiler)),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect',f'-Xplugin={jar("org.jetbrains.kotlin","kotlin-serialization-compiler-plugin-embeddable","2.4.21")}',f'-Xfriend-paths={cp[0]},{r}/android/app/build/intermediates/built_in_kotlinc/debugUnitTest/compileDebugUnitTestKotlin/classes','-jvm-target','17','-cp',os.pathsep.join(map(str,cp)),'-d',str(a.build/'classes')]+list(map(str,sources)),check=True)
if a.player_tests:
    latest_asm={artifact.name:sorted(artifact.iterdir(),key=lambda x:tuple(int(n) for n in x.name.split('.') if n.isdigit()))[-1].name for artifact in (cache/'org.ow2.asm').iterdir()}
    cp=[x for x in cp if not ('/junit/junit/' in str(x) and '/4.13.2/' not in str(x)) and not ('/org.ow2.asm/' in str(x) and x.parent.parent.name!=latest_asm.get(x.parent.parent.parent.name))]
    runtime=[a.build/'classes']+cp
    result=subprocess.run([str(java),'-Xmx1536m','-XX:ActiveProcessorCount=1','-Drobolectric.offline=true','-Drobolectric.dependency.dir='+str(Path.home()/'.m2/repository/org/robolectric/android-all-instrumented/9-robolectric-4913185-2-i7'),'-cp',os.pathsep.join(map(str,runtime)),'org.junit.runner.JUnitCore','com.soundq.android.playback.nativeengine.OrdinaryCrossfadePlayerTest','com.soundq.android.data.preferences.CrossfadePreferencesTest'])
    if result.returncode: raise SystemExit(result.returncode)
print('PASS ordinary crossfade production Player/Owner with Media3 and controlled hardware/source boundaries')
