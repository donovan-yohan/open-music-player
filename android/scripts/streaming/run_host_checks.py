#!/usr/bin/env python3
"""Private host checks. No Gradle, Android SDK build, device or personal file IO.

--serialization-json/core and --junit/hamcrest are explicit existing read-only jars.
Native tests substitute only OS output / encoded decoder boundaries as named.
AndroidPlatformWindowReader compiles unchanged against declared Android facades;
actual codecs remain PhonePlatformWindowTest instrumentation, NOT a host pass.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build', type=Path, required=True)
parser.add_argument('--java-home', type=Path, default=os.environ.get('JAVA_HOME'))
parser.add_argument('--serialization-json', type=Path)
parser.add_argument('--serialization-core', type=Path)
parser.add_argument('--junit', type=Path)
parser.add_argument('--hamcrest', type=Path)
parser.add_argument('--skip-native', action='store_true')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
build = args.build.resolve()
build.mkdir(parents=True, exist_ok=True)
tmp = Path(os.environ['TMPDIR'])
assert tmp.is_absolute() and tmp.is_dir() and str(tmp.resolve()) == str(tmp)
env = dict(os.environ, TMPDIR=str(tmp))
assert args.java_home and (args.java_home / 'include/jni.h').is_file(), 'Explicit full JDK required'
env['JAVA_HOME'] = str(args.java_home.resolve())
java = args.java_home / 'bin/java'
native = repo / 'android/app/src/main/cpp/nativeengine'
kotlin = repo / 'android/app/src/main/kotlin/com/soundq/android'
probes = Path(__file__).resolve().parent
results = []


def run(name, command):
    command = list(map(str, command))
    result = subprocess.run(command, cwd=repo, env=env, text=True, capture_output=True)
    text = result.stdout + result.stderr
    (build / (name + '.log')).write_text(text)
    results.append(dict(name=name, command=command, exit=result.returncode))
    (build / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(text, end='', flush=True)
    assert result.returncode == 0, f'{name} failed, see {build / (name + ".log")}'


if not args.skip_native:
    run('native-configure', ['cmake', '-S', native, '-B', build / 'native', '-DSOUNDQ_CALLBACK_TESTS=ON', '-DSOUNDQ_CALLBACK_SANITIZE=ON', '-DCMAKE_BUILD_TYPE=Debug'])
    run('native-build', ['cmake', '--build', build / 'native', '-j1'])
    run('native-tests', ['ctest', '--test-dir', build / 'native', '--output-on-failure'])
run('jni-configure', ['cmake', '-S', native, '-B', build / 'jni', '-DSOUNDQ_CALLBACK_TESTS=ON', '-DSOUNDQ_CALLBACK_JNI_TESTS=ON', '-DCMAKE_BUILD_TYPE=Debug'])
run('jni-build', ['cmake', '--build', build / 'jni', '--target', 'soundq_streaming_jni', '-j1'])
common = [probes / 'KeepFacade.kt', kotlin / 'playback/nativeengine/NativePlaybackSource.kt']
run('jni-kotlin', ['kotlinc', probes / 'StreamingJniProbe.kt', *common, kotlin / 'playback/nativeengine/NativeCallbackBridge.kt', '-include-runtime', '-d', build / 'jni.jar'])
for mode in ('normal', 'close-failure'):
    run('jni-' + mode, [java, '--enable-native-access=ALL-UNNAMED', f'-Djava.io.tmpdir={tmp}', f'-Djava.library.path={build / "jni"}', '-jar', build / 'jni.jar', *([] if mode == 'normal' else ['--close-failure'])])
run('platform-facade-compile', ['kotlinc', probes / 'MediaFacade.kt', probes / 'LeaseFacade.kt', probes / 'PlatformWindowProbe.kt', *common, kotlin / 'playback/nativeengine/AndroidPlatformWindowReader.kt', kotlin / 'playback/nativeengine/Mp3OriginalFrames.kt', '-nowarn', '-include-runtime', '-d', build / 'platform.jar'])
run('platform-facade', [java, f'-Djava.io.tmpdir={tmp}', '-jar', build / 'platform.jar'])
run('custody-compile', ['kotlinc', probes / 'CustodyProbe.kt', *common, kotlin / 'playback/nativeengine/LiveOriginalVersions.kt', '-include-runtime', '-d', build / 'custody.jar'])
import tempfile
custody = Path(tempfile.mkdtemp(prefix='custody-', dir=build))
run('custody', [java, f'-Djava.io.tmpdir={tmp}', '-jar', build / 'custody.jar', custody])
if args.serialization_json and args.serialization_core:
    jars = [args.serialization_json, args.serialization_core]
    cp = os.pathsep.join(map(str, jars))
    domain = list((kotlin / 'data/deviceaudio').glob('*.kt'))
    run('journal-compile', ['kotlinc', *domain, probes / 'StreamingJournalProbe.kt', '-cp', cp, '-nowarn', '-include-runtime', '-d', build / 'journal.jar'])
    state = Path(tempfile.mkdtemp(prefix='journal-', dir=build))
    run('journal', [java, f'-Djava.io.tmpdir={tmp}', '-cp', str(build / 'journal.jar') + os.pathsep + cp, 'com.soundq.android.data.deviceaudio.StreamingJournalProbeKt', state])
    if args.junit and args.hamcrest:
        owner = (kotlin / 'playback/nativeengine/NativeCallbackOwner.kt').read_text()
        start = owner.index('internal data class NativeNaturalEndReceipt(')
        end = owner.index('internal data class NativeCallbackSnapshot(')
        models = owner[start:end]
        facade = build / 'NativeDeckModels.kt'
        facade.write_text('package com.soundq.android.playback.nativeengine\n' + models)
        (build / 'model-extraction.json').write_text(json.dumps(dict(source='NativeCallbackOwner.kt', models_sha256=hashlib.sha256(models.encode()).hexdigest(), scope='verbatim data models only, no Android Handler/Owner or JSON parser'), indent=2))
        cp += os.pathsep + os.pathsep.join(map(str, (args.junit, args.hamcrest)))
        test_root = repo / 'android/app/src/test/kotlin/com/soundq/android'
        tests = [test_root / 'data/deviceaudio/DeviceListeningStoreTest.kt', test_root / 'playback/nativeengine/NativeListeningJournalTest.kt', test_root / 'playback/nativeengine/NativeSameSourceListeningTest.kt', test_root / 'playback/nativeengine/NativeStreamingListeningTest.kt']
        run('regression-compile', ['kotlinc', *domain, facade, kotlin / 'playback/nativeengine/NativeListeningBinding.kt', *tests, '-cp', cp, '-nowarn', '-include-runtime', '-d', build / 'regression.jar'])
        run('regression-tests', [java, '-Xmx2g', f'-Djava.io.tmpdir={tmp}', '-cp', str(build / 'regression.jar') + os.pathsep + cp, 'org.junit.runner.JUnitCore', 'com.soundq.android.data.deviceaudio.DeviceListeningStoreTest', 'com.soundq.android.playback.nativeengine.NativeListeningJournalTest', 'com.soundq.android.playback.nativeengine.NativeSameSourceListeningTest', 'com.soundq.android.playback.nativeengine.NativeStreamingListeningTest'])
print('PASS host checks. Actual Android codecs, app composition/build and mounted playback remain separate gates.')
