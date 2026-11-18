#!/usr/bin/env python3
"""Direct TLS API/model + listening-owner tests; no Gradle, SDK, device or provider.
Uses exact authored methods and real auth/JSON/repository/journal consumers.
Only unrelated feature types and Android callback-deck data are isolated.
"""
from pathlib import Path
import argparse,os,subprocess,zipfile,json,hashlib,re
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--cache',type=Path,required=True);p.add_argument('--source-root',type=Path);p.add_argument('--tests-root',type=Path);a=p.parse_args()
r=a.source_root or Path(__file__).resolve().parents[1];testroot=a.tests_root or r;b=r/'app/src/main/kotlin/com/soundq/android';o=a.out;o.mkdir(parents=True,exist_ok=True);cache=a.cache/'modules-2/files-2.1'
def put(n,s):(o/n).write_text(s)
def method(src,name):
 start=src.index('    fun '+name+'(');match=re.search(r'^    (?:internal |private )?fun ',src[start+5:],re.M);return src[start:start+5+match.start()] if match else src[start:src.rfind('}')]
api=(b/'data/SoundQApi.kt').read_text();prefix=api[:api.index('    /** Feature-local transport')]
heads=list(re.finditer(r'^    (?:internal |private )?fun (\w+)\(',api,re.M))
selected={'playlistSourceSync','startPlaylistSourceSync','playlistDetail','playlistManagementSnapshot','library','ownedLibraryPage','renamePlaylist','deletePrivatePlaylist','removePlaylistMembers','removePlaylistMember','restorePlaylistPosition','addQueuePlaylistTracks','addPlaylistTrack'}
methods=''.join(api[m.start():heads[i+1].start()] for i,m in enumerate(heads[:-1]) if m[1] in selected)
companion=api[api.index('    companion object {'):api.rindex('\n}')]
put('SoundQApi.kt',prefix+methods+companion+'\n}\n')
# Cached product dependency is Android variant. Replace ONLY its platform
# registry with the real base JVM/JDK Platform for this host TLS run; no HTTP,
# auth, JSON, source-sync or journal method is replaced. Android SDK gate remains separate.
put('HostPlatform.kt','''package okhttp3.internal.platform
@OptIn(okhttp3.internal.OkHttpInternalApi::class)
object PlatformRegistry {fun findPlatform():Platform=Platform();fun isAndroid()=false}
''')
put('Imports.kt','''package com.soundq.android.data.imports
class ImportJobId(val value:String){init{require(java.util.UUID.fromString(value).toString()==value)}}
''')
put('Catalog.kt','''package com.soundq.android.data.catalog
import kotlinx.serialization.json.JsonObject
class CatalogMembershipRefusal(val code:Code):RuntimeException(){enum class Code{UNAVAILABLE}}
object CatalogMembershipJson{fun refusal(code:Int,o:JsonObject):CatalogMembershipRefusal.Code?=error("catalog outside sync probe")}
''')
put('Mix.kt','''package com.soundq.android.data.mix
class ExchangeRefusal(val code:Code):RuntimeException(){enum class Code{UNAVAILABLE}}
class ExchangeAdmissionRefused:RuntimeException()
''')
put('Connect.kt','package com.soundq.android.data.connect\nclass FeatureFailure(val code:Int):RuntimeException()\n')
put('Home.kt','package com.soundq.android.data.home\nclass RecentChanged:RuntimeException()\n')
put('PlaylistMissing.kt','package com.soundq.android.data\nclass PlaylistMissing:RuntimeException()\n')
# Actual ordinary assignment snapshot data, without JNI/HandlerThread adapter.
native=(b/'playback/nativeengine/NativeCallbackOwner.kt').read_text();put('Deck.kt','package com.soundq.android.playback.nativeengine\n'+native[native.index('internal data class NativeNaturalEndReceipt'):native.index('internal data class NativeCallbackSnapshot')])
membership=(b/'data/playlists/PlaylistMembershipRepository.kt').read_text()
put('LibraryTrackCapture.kt','package com.soundq.android.data.playlists\nimport com.soundq.android.data.*\n'+next(line for line in membership.splitlines() if line.startswith('class LibraryTrackCapture '))+'\n')
import runpy
runpy.run_path(str(Path(__file__).resolve().parent/'host-tests/generate_playlist_sync_probes.py'))['generate'](b,o)
tests=testroot/'app/src/test/kotlin/com/soundq/android/data'
fixture=(tests/'ScopeRaceTest.kt').read_text();put('Fixture.kt',fixture[:fixture.index('class ScopeRaceTest')])
memory=(tests/'AccountSessionTest.kt').read_text();put('Memory.kt',memory[:memory.index('class AccountSessionTest')])
def jar(g,art,v):
 values=list((cache/g/art/v).glob('*/*.jar'));assert len(values)==1,(g,art,v,values);return str(values[0])
aars=list((cache/'com.squareup.okhttp3/okhttp-android/5.5.1').glob('*/*.aar'));assert len(aars)==1
with zipfile.ZipFile(aars[0]) as z:(o/'okhttp.jar').write_bytes(z.read('classes.jar'))
cp=os.pathsep.join([str(o/'okhttp.jar')]+[jar(*x) for x in [('org.jetbrains.kotlinx','kotlinx-serialization-json-jvm','1.12.0'),('org.jetbrains.kotlinx','kotlinx-serialization-core-jvm','1.12.0'),('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.9.0'),('com.squareup.okio','okio-jvm','3.18.1'),('com.squareup.okhttp3','mockwebserver3','5.5.1'),('com.squareup.okhttp3','okhttp-tls','5.5.1'),('junit','junit','4.13.2'),('org.hamcrest','hamcrest-core','1.3')]])
src=[b/'data'/f for f in ['Contracts.kt','AccountSession.kt','LibraryCollection.kt','LibraryRepository.kt','LibrarySortStore.kt','LibraryAnalysisFacts.kt','BoundedLibraryCorpus.kt']]+[b/'data/playlists'/f for f in ['PlaylistContracts.kt','PlaylistJson.kt','PlaylistDetailRepository.kt','PlaylistSourceSyncRepository.kt','PlaylistManagementRepository.kt','QueuePlaylistJson.kt']]+[b/'data/acquisition/IntakeReceipts.kt',b/'playback/QueuePolicy.kt',b/'playback/nativeengine/NativeListeningBinding.kt']+list((b/'data/deviceaudio').glob('*.kt'))+[tests/'PlaylistSourceSyncTest.kt']+list((Path(__file__).resolve().parent/'host-tests').glob('PlaylistSync*.kt'))+list(o.glob('*.kt'))
(o/'sources.json').write_text(json.dumps([{'path':str(f),'sha256':hashlib.sha256(f.read_bytes()).hexdigest()} for f in src],indent=2))
env=dict(os.environ);env['TMPDIR']=str(o)
cmd=['kotlinc','-J-Xmx512m','-J-XX:ActiveProcessorCount=1',*map(str,src),'-cp',cp,'-include-runtime','-d',str(o/'tests.jar')]
result=subprocess.run(cmd,capture_output=True,text=True,env=env);(o/'compile.log').write_text(result.stdout+result.stderr);print(result.stdout+result.stderr);assert result.returncode==0
cmd=['java','-XX:ActiveProcessorCount=1','-Djava.io.tmpdir='+str(o),'-Dsoundq.tests.events='+str(o/'events.jsonl'),'-cp',str(o/'tests.jar')+os.pathsep+cp+os.pathsep+str(testroot/'app/src/test/resources'),'com.soundq.android.data.PlaylistSyncNamedRunner','com.soundq.android.data.PlaylistSourceSyncTest','com.soundq.android.data.PlaylistSyncLifecycleTest']
result=subprocess.run(cmd,capture_output=True,text=True,env=env);(o/'runtime.log').write_text(result.stdout+result.stderr);print(result.stdout+result.stderr);raise SystemExit(result.returncode)
