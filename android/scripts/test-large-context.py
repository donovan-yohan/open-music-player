#!/usr/bin/env python3
"""Pinned cached JVM qualification for large canonical contexts.

Requires an exact private :app:compileDebugKotlin build first. Compiles the owned
production files again, executes real service/Media3/player with Robolectric and
controlled encoded/hardware boundaries. No device, JNI/audio or live API claim.
"""
import argparse
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--build', type=Path, required=True)
p.add_argument('--pure-only', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
a.build.mkdir(parents=True, exist_ok=True)
# Freeze unchanged compiled collaborators instead of retaining a live classes
# directory on the executing runtime classpath. Owned sources are recompiled below.
classes = root/'app/build/intermediates/built_in_kotlinc/debug/compileDebugKotlin/classes'
collaborators = a.build/'collaborators'
shutil.copytree(classes, collaborators, dirs_exist_ok=True)
(a.build/'collaborators.json').write_text(json.dumps({str(x.relative_to(collaborators)):hashlib.sha256(x.read_bytes()).hexdigest() for x in sorted(collaborators.rglob('*')) if x.is_file()}, indent=2)+'\n')
# Reuse the repository's pinned classpath/compiler discovery. The generated
# runner is private, and no shared source or compiled output is rewritten.
runner = (root/'scripts/test-overlap-compile.py').read_text()
runner = runner.replace('r=Path(__file__).resolve().parents[2]', 'r=Path('+repr(str(root.parent))+')')
runner = runner.replace("cache=Path.home()/'.gradle/caches/modules-2/files-2.1'", "cache=Path(os.environ['GRADLE_USER_HOME'])/'caches/modules-2/files-2.1'")
runner = runner.replace("r/'android/app/build/intermediates/built_in_kotlinc/debug/compileDebugKotlin/classes'", 'Path('+repr(str(collaborators))+')')
owned = ['data/timeline/TimelineOwner.kt', 'playback/QueuePolicy.kt', 'playback/QueueOrigin.kt', 'playback/QueueSnapshot.kt', 'playback/QueueSnapshotStore.kt', 'playback/ContextStartAdmission.kt', 'data/LibraryRepository.kt', 'SoundQApplication.kt', 'product/ProductViewModel.kt']
added = ['app/src/test/kotlin/com/soundq/android/data/timeline/TimelineOwnerTest.kt', 'app/src/test/kotlin/com/soundq/android/data/TimelineRepositoryTest.kt', 'app/src/test/kotlin/com/soundq/android/playback/LargeContextTest.kt', 'app/src/test/kotlin/com/soundq/android/data/LargeLibraryPlaybackTest.kt']
added += ['app/src/test/kotlin/com/soundq/android/'+x for x in ['playback/ContextAdmissionTest.kt','data/PlaylistCapacityTest.kt','data/PlaylistCandidateTest.kt','data/ScopeRaceTest.kt','data/AccountSessionTest.kt']]
if not a.pure_only:
    added += ['scripts/LargeContextPlayerTest.kt', 'scripts/OrdinaryCrossfadePlayerTest.kt']
insert = '\nsources += '+repr([str(root/'app/src/main/kotlin/com/soundq/android'/x) for x in owned])+'\nsources += '+repr([str(root/x) for x in added])+'\nsources=[Path(x) for x in sources]\n'
if not a.pure_only:
    # Read-only method-entry witnesses in the private compiled copy. No production
    # statement is changed or omitted. Reverse the two insertions byte-for-byte.
    native = root/'app/src/main/kotlin/com/soundq/android/playback/nativeengine/NativeCallbackPlayer.kt'
    original = native.read_text()
    observed = original
    probes = {
        '    override fun handlePrepare(): ListenableFuture<*> {': '\n        LargeContextCallProbe.prepares.incrementAndGet()',
        '    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {': '\n        if (playWhenReady) LargeContextCallProbe.plays.incrementAndGet()',
    }
    for signature, entry in probes.items():
        assert observed.count(signature) == 1
        observed = observed.replace(signature, signature+entry)
    reverse = observed
    for signature, entry in probes.items():
        reverse = reverse.replace(signature+entry, signature)
    assert reverse == original
    witness = a.build/'NativeCallbackPlayer.kt'
    witness.write_text(observed)
    (a.build/'entry-witness.json').write_text(json.dumps({'original_sha256': hashlib.sha256(original.encode()).hexdigest(), 'observed_sha256': hashlib.sha256(observed.encode()).hexdigest(), 'original_body_reconstruction_exact': True, 'insertions': probes}, indent=2)+'\n')
    insert += '\nsources=[Path('+repr(str(witness))+') if str(x)=='+repr(str(native))+' else x for x in sources]\n'
runner = runner.replace("java=Path('/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java')", insert+"java=Path(os.environ['JAVA_HOME'])/'bin/java'")
tests = ['com.soundq.android.data.timeline.TimelineOwnerTest', 'com.soundq.android.data.TimelineRepositoryTest', 'com.soundq.android.playback.LargeContextTest', 'com.soundq.android.data.LargeLibraryPlaybackTest', 'com.soundq.android.playback.ContextAdmissionTest', 'com.soundq.android.data.PlaylistCapacityTest']
if not a.pure_only:
    tests += ['com.soundq.android.playback.nativeengine.LargeContextPlayerTest', 'com.soundq.android.playback.nativeengine.OrdinaryCrossfadePlayerTest']
runner = runner.replace("'org.junit.runner.JUnitCore','com.soundq.android.playback.nativeengine.NativeArrangementPlayerTest'", "'org.junit.runner.JUnitCore',"+','.join(repr(x) for x in tests))
runner = runner.replace("print('PASS pinned Kotlin 2.4.21 owned playback and service compile against cached Media3 1.11.1 and existing app dependencies')", "print('PASS large-context production/persistence/Library tests with pinned Kotlin 2.4.21 and Media3 1.11.1')")
# AGP emits BuildConfig.java before Kotlin compilation. Compile that exact
# generated fixture configuration privately; do not synthesize build values.
config = root/'app/build/generated/source/buildConfig/debug/com/soundq/android/BuildConfig.java'
support = a.build/'support'
support.mkdir(exist_ok=True)
subprocess.run([str(Path(os.environ['JAVA_HOME'])/'bin/javac'), '-d', str(support), str(config)], check=True)
resources = root/'app/build/intermediates/compile_and_runtime_r_class_jar/debug/processDebugResources/R.jar'
if not resources.exists():
    raise SystemExit('Run :app:processDebugResources before host qualification. Real Media3 command icons require its generated R classes.')
runner = runner.replace("base=r/'android/app/src/main/kotlin/com/soundq/android/playback'", "cp.extend([Path("+repr(str(support))+"),Path("+repr(str(resources))+")])\nbase=r/'android/app/src/main/kotlin/com/soundq/android/playback'")
(a.build/'resource-input.json').write_text(json.dumps({'path':str(resources),'sha256':hashlib.sha256(resources.read_bytes()).hexdigest()},indent=2)+'\n')
script = a.build/'run.py'
script.write_text(runner)
source_paths = [root/'app/src/main/kotlin/com/soundq/android'/x for x in owned] + [root/x for x in added]
source_paths += [root/'app/src/main/kotlin/com/soundq/android'/x for x in ['playback/ControllerProjection.kt','playback/SoundQLibraryService.kt','playback/nativeengine/NativeCallbackPlayer.kt']]
(a.build/'inputs.json').write_text(json.dumps({str(x.relative_to(root)):hashlib.sha256(x.read_bytes()).hexdigest() for x in source_paths}, indent=2)+'\n')
subprocess.run(['python3',str(script),'--build',str(a.build/'compiled'),'--player-tests'], check=True)
