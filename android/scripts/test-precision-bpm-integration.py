#!/usr/bin/env python3
"""Pinned cached Kotlin/Compose checks. No Gradle, ADB, network or device claims.

Compile all real non-UI app collaborators, run existing service/controller tests plus
live-tempo cases, compile the actual BPM sheet and frozen design-system sources.
AGP resource IDs/MainActivity/BuildConfig are declaration-only host boundaries.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--build', type=Path, required=True)
a = p.parse_args()
root = Path(__file__).resolve().parents[2]
a.build = a.build.resolve()
a.build.mkdir(parents=True, exist_ok=True)
editor = (root/'android/app/src/main/kotlin/com/soundq/android/product/timeline/TempoTransitionEditor.kt').read_text()
editor_pure = editor[editor.index('data class TempoEditorOverlap'):editor.index('/** One disposable draft') if '/** One disposable draft' in editor else editor.index('@Composable')]
# Fit's actual pure prefix includes a native observation type declaration used by UI only.
editor_pure = re.sub(r'data class TempoEditorNativeObservation[^\n]*\n', '', editor_pure)
fit_file = a.build/'TempoEditorFit.kt'
fit_file.write_text('package com.soundq.android.product.timeline\nimport com.soundq.android.data.timeline.*\nimport kotlin.math.*\n'+editor_pure)
host_runner = (root/'android/scripts/test-queue-waveform-integration.py').read_text()
host_runner = host_runner.replace("root=Path(__file__).resolve().parents[1]", "root=Path("+repr(str(root/'android'))+")")
host_runner = host_runner.replace("r/'android/scripts/NativeQueueWaveformResumeTest.kt',Path(", "r/'android/scripts/NativeQueueWaveformResumeTest.kt',r/'android/app/src/test/kotlin/com/soundq/android/data/timeline/TempoRepositoryIntegrationTest.kt',Path(")
host_runner = host_runner.replace("'com.soundq.android.playback.nativeengine.NativeQueueWaveformResumeTest',", "'com.soundq.android.data.timeline.TempoRepositoryIntegrationTest','com.soundq.android.playback.nativeengine.NativeQueueWaveformResumeTest',")
host_runner = host_runner.replace("r/'android/app/src/test/kotlin/com/soundq/android/data/timeline/TempoRepositoryIntegrationTest.kt',Path(", "r/'android/app/src/test/kotlin/com/soundq/android/data/timeline/TempoRepositoryIntegrationTest.kt',Path("+repr(str(fit_file))+"),Path(")
host_file = a.build/'host-check.py' 
host_file.write_text(host_runner)
subprocess.run(['python3', str(host_file), '--build', str(a.build/'host')], check=True)

# Reuse pinned dependency discovery. Compile UI with the host classes just built,
# never a stale app classpath. No changed production implementation is substituted.
runner = (root/'android/scripts/test-overlap-compile.py').read_text()
start = runner.index('java=Path(')
end = runner.index('if a.player_tests:', start)
helper = (root/'android/app/src/main/kotlin/com/soundq/android/product/timeline/TempoTransitionEditor.kt').read_text()
helper = helper[helper.index('data class TempoEditorOverlap'):helper.index('/** Disclosure')]
helper_file = a.build/'TempoEditorOverlap.kt'
helper_file.write_text('package com.soundq.android.product.timeline\nimport com.soundq.android.data.timeline.*\n'+helper)
theme = (root/'android/designsystem/src/main/kotlin/com/soundq/designsystem/Theme.kt').read_text()
fonts = sorted(set(re.findall(r'R\.font\.(\w+)', theme)))
resource_file = a.build/'DesignResourceIds.kt'
resource_file.write_text('package com.soundq.designsystem\nobject R {object font {'+';'.join('const val '+name+'='+str(n+1) for n,name in enumerate(fonts))+'}}\n')
setup = '''base=r/'android/app/src/main/kotlin/com/soundq/android'
cp.insert(0,Path(HOST_CLASSES))
for group in ('androidx.compose.ui','androidx.compose.runtime','androidx.compose.foundation','androidx.compose.material3','androidx.compose.animation','androidx.activity','androidx.savedstate','androidx.lifecycle'):
    for artifact in (cache/group).glob('*'):
        for version in artifact.iterdir():
            if group.startswith('androidx.compose') and version.name not in ('1.12.1','1.4.0'): continue
            if group=='androidx.lifecycle' and version.name!='2.11.0': continue
            for file in version.glob('*/*'):
                if file.suffix=='.jar':cp.append(file)
                elif file.suffix=='.aar':
                    with zipfile.ZipFile(file) as z:
                        if 'classes.jar' in z.namelist():
                            target=a.build/(artifact.name+'-'+version.name+'.jar');target.write_bytes(z.read('classes.jar'));cp.append(target)
sources=list((r/'android/designsystem/src/main').rglob('*.kt'))+list((r/'android/designsystem/src/generated').rglob('*.kt'))+[base/'product/timeline/WaveformBpmControls.kt',Path(HELPER),Path(RESOURCE)]
'''.replace('HOST_CLASSES', repr(str(a.build/'host/compiled/classes'))).replace('HELPER', repr(str(helper_file))).replace('RESOURCE', repr(str(resource_file)))
compiled = runner[:runner.index('base=r/')]+setup+runner[start:end]
compiled = compiled.replace('r=Path(__file__).resolve().parents[2]', 'r=Path('+repr(str(root))+')')
compiled = compiled.replace("f'-Xplugin={jar(\"org.jetbrains.kotlin\",\"kotlin-serialization-compiler-plugin-embeddable\",\"2.4.21\")}'", "f'-Xplugin={jar(\"org.jetbrains.kotlin\",\"kotlin-serialization-compiler-plugin-embeddable\",\"2.4.21\")}', f'-Xplugin={jar(\"org.jetbrains.kotlin\",\"kotlin-compose-compiler-plugin-embeddable\",\"2.4.21\")}'")
compiled = compiled.replace("f'-Xfriend-paths={cp[0]},{r}/android/app/build/intermediates/built_in_kotlinc/debugUnitTest/compileDebugUnitTestKotlin/classes'", "f'-Xfriend-paths={cp[0]}'")
ui_runner = a.build/'compile-ui.py'
ui_runner.write_text(compiled)
subprocess.run(['python3', str(ui_runner), '--build', str(a.build/'ui')], check=True)
subprocess.run(['python3', str(root/'android/scripts/test-output-recovery.py'), '--build', str(a.build/'recovery')], check=True)
print('PASS precision BPM real service/controller transaction checks, exact Compose sheet compile, ordinary recovery checks. Device/JNI audio journey remains a separate gate.')
