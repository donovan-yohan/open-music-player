#!/usr/bin/env python3
"""Execute exact extracted MP3 resource scope plus direct runner/cleanup controls.

Only declared failure collaborators are substituted. This does not open a codec,
JNI or Android service. No Gradle/SDK/device operations.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', required=True, type=Path)
p.add_argument('--java-home', required=True, type=Path)
p.add_argument('--test-source', type=Path)
a = p.parse_args()
probes = Path(__file__).resolve().parent
repo = probes.parents[2]
tests = repo / 'android/app/src/androidTest/kotlin/com/soundq/android'
source = a.test_source or tests / 'playback/nativeengine/PhonePlatformWindowTest.kt'
text = source.read_text()
start = text.index('fun mp3AboveOldCapPrimesDeepTargetThroughSoleNativeCallbackEngine()')
end = text.index('    @Test fun explicitDescriptorSlice', start)
method = text[start:end]
helper_start = text.find('internal fun finishDirectCodecFixture(')
helper = text[helper_start:] if helper_start >= 0 else ''
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=False)
wrapper = out / 'ExtractedMp3Fixture.kt'
wrapper.write_text('''package com.soundq.android.playback.nativeengine
import java.io.File
import kotlin.math.abs
class ExtractedMp3Fixture(root:File,frame:File) {
    val context=ContextFacade(root)
    val assets=AssetsFacade(frame)
    var source:OriginalAudioReadLease?=null
    fun lease(file:File)=OriginalAudioReadLease().also {source=it}
''' + method + '\n}\n' + helper)
metadata = dict(source=str(source), source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(), method_sha256=hashlib.sha256(method.encode()).hexdigest(), helper_sha256=hashlib.sha256(helper.encode()).hexdigest(), extraction='Verbatim method and helper; imports and only collaborator types supplied by explicit failure facades')
(out / 'extraction.json').write_text(json.dumps(metadata, indent=2)+'\n')
env = dict(os.environ, JAVA_HOME=str(a.java_home), JAVA_OPTS='-Xmx512m -XX:ActiveProcessorCount=1')
results = []
def run(name, command):
    command = list(map(str, command))
    r = subprocess.run(command, cwd=repo, env=env, text=True, capture_output=True)
    (out / (name+'.log')).write_text(r.stdout+r.stderr)
    results.append(dict(name=name, command=command, exit=r.returncode))
    (out / 'results.json').write_text(json.dumps(results, indent=2)+'\n')
    print(name, r.returncode, r.stdout+r.stderr, flush=True)
    return r.returncode

failed = run('mp3-compile', ['kotlinc', wrapper, probes / 'DirectCodecCleanupProbe.kt', '-nowarn', '-include-runtime', '-d', out / 'mp3.jar']) != 0
java = [a.java_home / 'bin/java', '-Xmx512m', '-XX:ActiveProcessorCount=1', '-Djava.io.tmpdir='+os.environ['TMPDIR']]
if not failed:
    for mode in ('open-zero', 'open-throws', 'cleanup-fails'):
        failed |= run(mode, [*java, '-jar', out / 'mp3.jar', mode, out / mode, tests.parents[3] / 'assets/streaming-codecs/repeatable-mp3-frame.bin']) != 0
# Compile the actual direct runner against a class-creating framework boundary.
runner = tests / 'DirectCodecFixtureRunner.kt'
frameworks = {
    'Application.kt': 'package android.app\nopen class Application\n',
    'Context.kt': 'package android.content\nclass Context\n',
    'AndroidJUnitRunner.kt': '''package androidx.test.runner
open class AndroidJUnitRunner {
    open fun newApplication(cl:ClassLoader,className:String,context:android.content.Context):android.app.Application =
        cl.loadClass(className).getDeclaredConstructor().newInstance() as android.app.Application
}
''',
    'RunnerProbe.kt': '''package com.soundq.android
class ProductApplication:android.app.Application() {init {error("Product graph must not start")}}
fun main() {
    val runner=DirectCodecFixtureRunner()
    val app=runner.newApplication(runner.javaClass.classLoader,ProductApplication::class.java.name,android.content.Context())
    check(app.javaClass==android.app.Application::class.java)
    println("PASS actual direct runner selects plain Application, never product graph/service")
}
''',
}
for name, content in frameworks.items():
    (out / name).write_text(content)
if run('runner-compile', ['kotlinc', runner, *[out / n for n in frameworks], '-nowarn', '-include-runtime', '-d', out / 'runner.jar']):
    failed = True
else:
    failed |= run('runner', [*java, '-jar', out / 'runner.jar']) != 0
if helper:
    controls = out / 'SuppressionProbe.kt'
    controls.write_text('''package com.soundq.android.playback.nativeengine
''' + helper + '''
fun main() {
    finishDirectCodecFixture(null,{})
    val primary=IllegalArgumentException("body")
    finishDirectCodecFixture(primary,{})
    check(primary.suppressed.isEmpty())
    val a=IllegalStateException("cleanup A");val b=IllegalStateException("cleanup B")
    var attempts=0
    val thrown=runCatching {finishDirectCodecFixture(null,{attempts++;throw a},{attempts++;throw b},{attempts++})}.exceptionOrNull()
    check(thrown===a && a.suppressed.single()===b && attempts==3)
    attempts=0
    finishDirectCodecFixture(primary,{attempts++;throw a},{attempts++;throw b},{attempts++})
    check(primary.suppressed.toList()==listOf(a,b) && attempts==3)
    println("PASS cleanup success, body-only, cleanup-only and combined primary/suppression/all-attempt controls")
}
''')
    if run('suppression-compile', ['kotlinc', controls, '-nowarn', '-include-runtime', '-d', out / 'suppression.jar']):
        failed = True
    else:
        failed |= run('suppression', [*java, '-jar', out / 'suppression.jar']) != 0
raise SystemExit(int(failed))
