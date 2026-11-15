#!/usr/bin/env python3
"""Runnable real-body radar/import readback regression; no Gradle/SDK/network.

Usage: python3 android/scripts/test-radar-readback.py --dependencies OWNED_JARS
       --out OWNED_OUTPUT [--source REPOSITORY] [--case readback-control]

Supply copied, hash-verified jars; this runner never installs or reads build caches.
Compile against pinned Android OkHttp 5.5.1 signatures, execute JVM OkHttp 4.12
synthetic interception invoking the real WireGuard. This is not Android TLS,
Compose, full AppGraph initialization, Library navigation or device acceptance.
AppGraph's actual API/discovery declarations and revision-observer initializer
are extracted unchanged; only unrelated graph collaborators are closed facades.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

PINS = {
    'kotlinx-serialization-json-jvm-1.12.0.jar': '879eb73e46cb63253ab0fa7cca4448f5c96bca1a16ff377abcb71ebab60e0631',
    'kotlinx-serialization-core-jvm-1.12.0.jar': 'bcfddcac76159058ba0953af05938c17111d238cd41be7191874656454d62f1a',
    'kotlinx-coroutines-core-jvm-1.10.2.jar': '5ca175b38df331fd64155b35cd8cae1251fa9ee369709b36d42e0a288ccce3fd',
    'okhttp-5.5.1.jar': '1dc59d283780d37a351698cc7b6f790fe8dab522c2a048541e625296bdf6e837',
    'okio-jvm-3.18.1.jar': 'b97b640557a650d15411f2be29aef558c4e422a83653cb18ba494311dbed18be',
    'okhttp-4.12.0.jar': 'b1050081b14bb7a3a7e55a4d3ef01b5dcfabc453b4573a4fc019767191d5f4e0',
}

def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def between(text, start, end):
    return text[text.index(start):text.index(end)]

def generate(repo, out):
    base = repo / 'android/app/src/main/kotlin/com/soundq/android'
    api = (base / 'data/SoundQApi.kt').read_text()
    selected = (api[:api.index('    fun authenticate')]
        + between(api, '    private fun refresh', '    /** Feature-local transport')
        + between(api, '    fun trackDetailsSnapshot', '    fun trackDetailsAnalysis')
        + between(api, '    fun playlists(', '    fun browsePlaylists')
        + between(api, '    fun playlistDetail(', '    fun serverImports')
        + between(api, '    companion object {', '\n}\nclass AudioDescriptor') + '\n}\n')
    (out / 'SoundQApi.kt').write_text(selected)
    app = (base / 'SoundQApplication.kt').read_text()
    api_declaration = between(app, '    val api', '    val timeline=')
    discovery = between(app, '    val discovery=', '    val io=')
    observer = between(app, '    init {localUnlock.loadBeforeRestore();', '    fun start()')
    graph = '''package com.soundq.android.data
import kotlinx.coroutines.*
import java.io.File
import okhttp3.OkHttpClient
class ReadbackGraph(val session:AccountSession, apiClient:OkHttpClient, val directory:File,
    radarFixtureAdmission:Boolean=true, dispatcher:CoroutineDispatcher=Dispatchers.Unconfined):AutoCloseable {
    val library=LibraryRepository()
    val localUnlock=LocalUnlockFacade()
    val io=CoroutineScope(SupervisorJob()+dispatcher)
''' + api_declaration + discovery + observer + '''
    override fun close(){io.cancel();discovery.retire()}
}
class LocalUnlockFacade { fun loadBeforeRestore(){} }
'''
    (out / 'ReadbackGraph.kt').write_text(graph)
    facades = {
        'Unrelated.kt': '''package com.soundq.android.data
import kotlinx.coroutines.flow.MutableStateFlow
class LibraryCollection
class PlaylistMissing:Exception()
data class LibraryState(val pageRevision:Long=0)
class LibraryRepository {
 val state=MutableStateFlow(LibraryState())
 var acceptedScope:AccountScope?=null
 fun projectionScope(expected:LibraryState)=acceptedScope?.takeIf {state.value===expected&&it.owner.current(it)}
 fun publish(scope:AccountScope){acceptedScope=scope;state.value=LibraryState(state.value.pageRevision+1)}
 fun revealImported(track:TrackId,valid:()->Boolean):Boolean=error("unexercised Library navigation")
}
''',
        'Feature.kt': 'package com.soundq.android.data.connect\nclass FeatureFailure(val status:Int):Exception()\n',
        'LibraryCapture.kt': 'package com.soundq.android.data.playlists\nclass LibraryTrackCapture\n',
        'CatalogErrors.kt': '''package com.soundq.android.data.catalog
import kotlinx.serialization.json.JsonObject
class CatalogMembershipRefusal(val code:Code):Exception(){enum class Code{UNAVAILABLE}}
object CatalogMembershipJson {fun refusal(status:Int,body:JsonObject):CatalogMembershipRefusal.Code?=error("unrelated catalog POST")}
''',
        'MixErrors.kt': '''package com.soundq.android.data.mix
class ExchangeRefusal(val code:Code):Exception(){enum class Code{UNAVAILABLE}}
class ExchangeAdmissionRefused:Exception()
''',
    }
    for name, content in facades.items():
        (out / name).write_text(content)
    # Home's composed API error mapper names this collaborator. No Home read is exercised here.
    (out / 'HomeErrors.kt').write_text('package com.soundq.android.data.home\nclass RecentChanged:Exception()\n')
    details = (base / 'data/trackdetails/TrackDetails.kt').read_text()
    (out / 'TrackDetails.kt').write_text(details[:details.index('sealed interface DetailsAction')])
    paths = ['AccountSession.kt', 'Contracts.kt', 'catalog/Catalog.kt',
        'imports/Imports.kt', 'imports/ImportJson.kt', 'imports/ImportRepository.kt',
        'acquisition/IntakeReceipts.kt', 'playlists/PlaylistContracts.kt',
        'playlists/PlaylistJson.kt', 'trackdetails/TrackDetailsJson.kt', 'trackdetails/Verification.kt',
        *['discovery/' + n for n in ['Discovery.kt', 'DiscoveryJson.kt', 'DiscoveryHistory.kt',
            'DiscoveryRepository.kt', 'ReleaseRadar.kt']]]
    sources = [base / 'data' / p for p in paths]
    sources += [out / n for n in [*facades, 'HomeErrors.kt', 'TrackDetails.kt', 'SoundQApi.kt', 'ReadbackGraph.kt']]
    fixture = Path(__file__).parent / 'fixtures/radar-readback/Journey.kt'
    (out / 'Journey.kt').write_bytes(fixture.read_bytes())
    sources.append(out / 'Journey.kt')
    return sources, {'selected_api_sha256': hashlib.sha256(selected.encode()).hexdigest(),
        'composition_api_sha256': hashlib.sha256(api_declaration.encode()).hexdigest(),
        'composition_discovery_sha256': hashlib.sha256(discovery.encode()).hexdigest(),
        'composition_observer_sha256': hashlib.sha256(observer.encode()).hexdigest(),
        'production_inputs': {str(base / p): digest(base / p) for p in ['data/SoundQApi.kt', 'SoundQApplication.kt']}}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--dependencies', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--case', default='readback-control')
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    tmp = out / 'tmp'
    tmp.mkdir(exist_ok=True)
    for name, expected in PINS.items():
        assert digest(args.dependencies / name) == expected, name
    sources, receipt = generate(args.source.resolve(), out)
    compile_cp = os.pathsep.join(str(args.dependencies / n) for n in PINS if n != 'okhttp-4.12.0.jar')
    runtime_cp = os.pathsep.join(str(args.dependencies / n) for n in PINS if n != 'okhttp-5.5.1.jar')
    env = dict(os.environ, TMPDIR=str(tmp), JAVA_OPTS='-Djava.io.tmpdir=' + str(tmp))
    cmd = ['kotlinc', *map(str, sources), '-cp', compile_cp, '-include-runtime', '-d', str(out / 'regression.jar')]
    compiled = subprocess.run(cmd, env=env, text=True, capture_output=True)
    (out / 'compile.log').write_text(compiled.stdout + compiled.stderr)
    receipt.update(sources={str(p): digest(p) for p in sources}, dependencies=PINS, compile_exit=compiled.returncode)
    if compiled.returncode:
        receipt['classification'] = 'setup/signature/facade failure; NOT behavioral RED'
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2))
        print(compiled.stdout + compiled.stderr)
        return compiled.returncode
    cmd = ['java', '-Djava.io.tmpdir=' + str(tmp), '-cp', str(out / 'regression.jar') + os.pathsep + runtime_cp,
        'com.soundq.android.data.JourneyKt', str(args.source / 'android/app/src/androidTest/assets/release-radar-wire.json'), args.case]
    result = subprocess.run(cmd, env=env, text=True, capture_output=True)
    (out / 'run.log').write_text(result.stdout + result.stderr)
    receipt.update(command=cmd, exit=result.returncode, stdout=result.stdout, stderr=result.stderr,
        fixture_sha256=digest(out / 'Journey.kt'), jar_sha256=digest(out / 'regression.jar'))
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2))
    print(result.stdout + result.stderr)
    return result.returncode

if __name__ == '__main__':
    raise SystemExit(main())
