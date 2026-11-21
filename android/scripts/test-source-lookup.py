#!/usr/bin/env python3
"""Full ordinary current -> granted acquisition -> repository -> original lease.
Only Android/provider/output seams are facades. No SDK, Gradle or device use.
Generated domain source is instrumented for collection/identity work, not semantics.
"""
from pathlib import Path
import argparse, ast, hashlib, json, os, subprocess
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--root',type=Path);p.add_argument('--output',type=Path,required=True)
a=p.parse_args();root=(a.root or Path(__file__).resolve().parents[1]).resolve();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
b=root/'app/src/main/kotlin/com/soundq/android';records=[];sources={};spans={}
env=dict(os.environ,JAVA_OPTS='-Xmx512m -XX:ActiveProcessorCount=1',TMPDIR=str(out))
def run(name,cmd):
 r=subprocess.run(list(map(str,cmd)),env=env,capture_output=True,text=True,timeout=300)
 (out/(name+'.log')).write_text(r.stdout+r.stderr);records.append(dict(name=name,command=list(map(str,cmd)),exit=r.returncode));(out/'commands.json').write_text(json.dumps(records,indent=2)+'\n');print(name,r.returncode,flush=True)
 return r.returncode
def read(f):
 s=(b/f).read_text();sources[f]=hashlib.sha256(s.encode()).hexdigest();return s
def block(f,marker):
 s=read(f);start=s.index(marker);i=s.index('{',start)+1;depth=1
 while depth:depth+=(s[i]=='{')-(s[i]=='}');i+=1
 result=s[start:i];spans[f+':'+marker.strip()]=hashlib.sha256(result.encode()).hexdigest();return result
def put(n,s):(out/n).write_text(s)
def jar(group,artifact,version):
 f=next((Path.home()/'.gradle/caches/modules-2/files-2.1'/group/artifact/version).glob('*/*.jar'))
 dependencies[str(f)]=hashlib.sha256(f.read_bytes()).hexdigest();return f
# Reuse declaration-only OS facades, never that helper's Phone/Grant collaborators.
tree=ast.parse((root/'scripts/test-original-read-boundaries.py').read_text())
facades=ast.literal_eval(next(n.value for n in tree.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='files' for t in n.targets)))
for n in ['Annotations.kt','Uri.kt','Media.kt','Store.kt','Os.kt','Pfd.kt','Resolver.kt']:put(n,facades[n])
java=out/'java/android';(java/'os').mkdir(parents=True);(java/'system').mkdir()
(java/'os/Build.java').write_text('package android.os;public class Build {public static class VERSION {public static int SDK_INT=27;}}')
(java/'system/StructTimespec.java').write_text('package android.system;public class StructTimespec {public long tv_sec,tv_nsec;public StructTimespec(long s,long n){tv_sec=s;tv_nsec=n;}}')
(java/'system/StructStat.java').write_text('package android.system;public class StructStat {public long st_dev=1,st_ino=2,st_size=8,st_mtime=10,st_ctime=11;public int st_mode=1;public StructTimespec st_mtim=new StructTimespec(10,123),st_ctim=new StructTimespec(11,456);}')
assert run('javac',['javac','-d',out/'classes',*java.glob('**/*.java')])==0
stamp=read('data/device/PhoneFileActions.kt');put('Stamp.kt','package com.soundq.android.data.device\nimport android.os.Build\nimport android.system.StructStat\n'+stamp[stamp.index('internal data class OriginalFileStamp'):stamp.index('internal data class PhoneFileTarget')])
# Entire identity/resolver/domain, real session and PlaybackRef (including serialization plugin).
production=[]
for f in ['data/deviceaudio/'+p.name for p in (b/'data/deviceaudio').glob('*.kt')]+['data/AccountSession.kt','playback/PlaybackRef.kt','playback/nativeengine/OriginalAudioReadLease.kt','playback/nativeengine/OriginalMetadataReader.kt','playback/nativeengine/OriginalDescriptorCustody.kt','playback/nativeengine/NativePlaybackSource.kt','playback/nativeengine/LiveOriginalVersions.kt']:
 s=read(f)
 if f.endswith(('DeviceAudioTypes.kt','PublishedDeviceListeningView.kt','PlaybackRef.kt')):
  # These imports count receiver-owned collection predicate visits, not builder accesses.
  s=s.replace('\n\n','\nimport com.soundq.android.lookupprobe.countedSingleOrNull\nimport com.soundq.android.lookupprobe.countedAny\nimport com.soundq.android.lookupprobe.Work\n\n',1)
  s=s.replace('.singleOrNull {','.countedSingleOrNull {').replace('.any {','.countedAny {')
  s=s.replace('UUID.fromString(', 'Work.uuid(').replace('Regex(', 'Work.regex(')
  if f.endswith('DeviceAudioTypes.kt'):
   s=s.replace('init { require(sha256.', 'init { Work.revisions++; require(sha256.')
   s=s.replace('init { require(incarnation > 0)', 'init { Work.owners++; require(incarnation > 0)')
  if f.endswith('PublishedDeviceListeningView.kt'):
   assert 'override fun get(index: Int): T = values[index]' in s
  if f.endswith('PlaybackRef.kt'):
   assert 'UUID.fromString(' not in s
 if f.endswith('PublishedDeviceListeningView.kt'):
  s=s.replace('override fun get(index: Int): T = values[index]', 'override fun get(index: Int): T { Work.visits++; return values[index] }')
 if f.endswith('AccountSession.kt'):
  s=s.replace('import kotlinx.coroutines.flow.MutableStateFlow','import com.soundq.android.lookupprobe.Work\nimport kotlinx.coroutines.flow.MutableStateFlow')
  s=s.replace('fun owns(intent: Long) = intent == epoch','fun owns(intent: Long):Boolean { Work.sessionChecks++; return intent == epoch }')
 dest=out/Path(f).name;put(dest.name,s);production.append(dest)
contracts=read('data/Contracts.kt');contracts=contracts[:contracts.index('enum class LibrarySort')]+contracts[contracts.index('class SafeFailure'):];put('Contracts.kt',contracts)
# Exact repo bodies/fields; test-only publication setup does not replace live validators.
s=read('data/device/PhoneAudioRepository.kt')
head=s[s.index('internal data class PhoneAudioState'):s.index('/** Android composition')]
fields=s[s.index('    private val authoritySequence'):s.index('    fun sourceFileId(')]
fields=fields[:fields.index('    private fun advanceAuthority(')]+block('data/device/PhoneAudioRepository.kt','    private fun advanceAuthority(')
repo='''package com.soundq.android.data.device
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.playback.nativeengine.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.*
import java.io.File
import java.util.UUID
'''+head+'''internal class PhoneAudioRepository(private val graph:AppGraph) {
 val platform=AndroidAudioAccess(graph.applicationContext)
 private val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO)
 private val serial=Mutex()
 private var store:DeviceListeningStore?=null
 private var access:AccessCapture?=null
 private var liveVersions:LiveOriginalVersions?=null
 @Volatile private var acceptedVersion=-1L
 private var lastScan:PhoneScanObservation?=null
 private val mutable=MutableStateFlow(PhoneAudioState())
 val state:StateFlow<PhoneAudioState> = mutable.asStateFlow()
 // This probe runs exact physical-mutation admission, but never schedules a refresh.
 private data class FileMutation(val token:UUID,val refresh:Long)
 private val fileMutations=java.util.concurrent.ConcurrentHashMap<String,FileMutation>()
 private data class RefreshScope(val version:Long,val storage:Boolean)
 private var refreshScope:RefreshScope?=null
 private var refreshRunning:(()->Unit)?=null
 private var pendingRefresh:(()->Unit)?=null
 private val refreshEpoch=java.util.concurrent.atomic.AtomicLong()
 private val refreshLock=java.util.concurrent.locks.ReentrantLock()
 private inline fun <T> refreshLocked(block:()->T):T {refreshLock.lock();try{return block()}finally{refreshLock.unlock()}}
'''+fields+'\n'
# Include expression-bodied methods verbatim as lines/ranges, block methods by brace parser.
for start,end in [('    fun current(version:','    // One sequence'),('    fun sourceAuthority(','    /** An observed access ABA'),('    fun observed(','    suspend fun <T> journal(')]:repo+=s[s.index(start):s.index(end)]
for marker in ['    fun sourceFileId(','    private fun publish(','    fun beginFileMutation(','    fun endFileMutation(','    fun sameFile(','    suspend fun <T> journal(','    suspend fun admit(','    suspend fun reportFailure(','    suspend fun openOriginal(']:repo+=block('data/device/PhoneAudioRepository.kt',marker)+'\n'
repo+=''' fun setup(owner:DeviceListeningStore,accepted:AccessCapture) {store=owner;access=accepted;acceptedVersion=graph.session.version();publish()}
 fun install(snapshot:DeviceListeningSnapshot?) {mutable.value=mutable.value.copy(snapshot=snapshot)}
 fun acceptVersion(v:Long) {acceptedVersion=v}
 fun authority(file:DeviceFileId?=null)=advanceAuthority(file)
 fun republish()=publish()
 fun stop(){jobs.cancel();store?.close()}
}
''';repo=repo.replace('import java.util.UUID','import java.util.UUID\nimport com.soundq.android.lookupprobe.Work').replace('UUID.fromString(', 'Work.uuid(')
# The independent watchdog is queued, not scheduled, in this deterministic caller probe.
# Its production body remains present; scheduling/OS work is not the work-count subject.
repo=repo.replace('private val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO)', 'private val jobs=CoroutineScope(SupervisorJob()+object:CoroutineDispatcher(){override fun dispatch(context:kotlin.coroutines.CoroutineContext,block:Runnable){}})')
repo=repo.replace('fun active()=live.get() && current(admission.sessionVersion) && valid()', 'fun active():Boolean {Work.callbackChecks++;return live.get() && current(admission.sessionVersion) && valid()}')
current_line=next(line for line in repo.splitlines() if line.strip().startswith('fun current(version: Long) = '))
repo=repo.replace(current_line,'    fun current(version:Long):Boolean {Work.repositoryChecks++;return '+current_line.split(' = ',1)[1]+'}')
put('Repository.kt',repo)
wrapper=s=read('data/device/AndroidAudioAccess.kt');wrapper=s[s.index('    fun openOriginal('):s.index('    /** Exact-byte proof')]
put('Platform.kt','''package com.soundq.android.data.device
import com.soundq.android.playback.nativeengine.*
internal class AndroidAudioAccess(val resolver:android.content.ContentResolver) {
 var allowed=true
 fun storageAllowed()=allowed
'''+wrapper+'\n}\n')
put('Window.kt','''package com.soundq.android.playback.nativeengine
internal class AndroidPlatformWindowReader(val lease:OriginalAudioReadLease):NativePcmReader {
 override fun open()=error("codec outside host test")
 override fun read(first:Long,count:Int,destination:java.nio.ByteBuffer):Int=error("codec outside host test")
 override fun endFrames()=0L
 override fun revoke()=lease.revoke()
 override fun closeReader()=try{lease.close();true}catch(_:Throwable){false}
}
''')
put('Graph.kt','''package com.soundq.android
import com.soundq.android.data.*
import com.soundq.android.data.device.*
internal class AppGraph(val directory:java.io.File) {
 val endpoint=ApiEndpoint.parse("https://fixture.invalid/api/v1")
 val session=AccountSession(endpoint,object:SessionStore {override fun load(endpoint:ApiEndpoint):SecretTokens?=null;override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){};override fun clear(){}}).apply {retire()}
 val applicationContext=android.content.ContentResolver()
 val phoneAudio=PhoneAudioRepository(this)
}
''')
grant=block('playback/SignedAudioDataSource.kt','internal class MediaGrant')
grant=grant.replace('fun current(graph:AppGraph):Boolean=', 'fun current(graph:AppGraph):Boolean {com.soundq.android.lookupprobe.Work.grantChecks++;return ')
grant=grant.replace('graph.phoneAudio.observed(device)!=null\n}', 'graph.phoneAudio.observed(device)!=null}\n}')
put('Grant.kt','package com.soundq.android.playback\nimport com.soundq.android.AppGraph\nimport com.soundq.android.data.*\n'+grant)
put('MediaItem.kt','''package androidx.media3.common
class MediaItem(val uri:android.net.Uri) {
 class Local(val uri:android.net.Uri);val localConfiguration=Local(uri)
 class Extras {fun getString(key:String):String?=null}
 class Metadata {val extras:Extras?=null};val mediaMetadata=Metadata()
}
''')
put('Source.kt','''package com.soundq.android.playback.nativeengine
import androidx.media3.common.MediaItem
import com.soundq.android.AppGraph
import com.soundq.android.playback.MediaGrant
import java.util.concurrent.ConcurrentHashMap
internal class GrantedNativeCallbackSource(val graph:AppGraph,val grants:ConcurrentHashMap<String,MediaGrant>) {
 fun prepareBounded(item:MediaItem,max:Long,current:()->Boolean):java.io.File=error("server out of scope")
 companion object {const val MAX_BYTES=128L*1024*1024}
'''+block('playback/nativeengine/NativeCallbackSource.kt','    override fun acquire(').replace('override fun','fun',1)+'\n}')
# Full ordinary player method, with output/journal declarations only.
put('Player.kt','''package com.soundq.android.lookupprobe
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import com.soundq.android.playback.*
import com.soundq.android.playback.nativeengine.*
import androidx.media3.common.MediaItem
import kotlinx.coroutines.*
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
private object Player {const val STATE_IDLE=1;const val STATE_BUFFERING=2}
private class ListenableFuture<T>
internal class Hardware {
 var onLoad:(NativePlaybackSource,()->Boolean)->Unit={_,_->}
 var source:NativePlaybackSource?=null
 suspend fun recoverOutput(current:()->Boolean)=current()
 suspend fun releaseUnborrowed(s:NativePlaybackSource)=s.release()
 suspend fun load(s:NativePlaybackSource,id:Long,generation:Long,p:Long,current:()->Boolean,speed:Double):Boolean {source=s;onLoad(s,current);return current()}
 suspend fun control(op:Int,v:Double,current:()->Boolean)=current()
}
private class Journal {fun initialResume(s:NativePlaybackSource.BorrowedOriginal,g:MediaGrant,d:Int)=s.resumeMs}
internal class CanonicalPrepare(val graph:AppGraph,val grants:ConcurrentHashMap<String,MediaGrant>,val items:List<MediaItem>,val lifetime:CoroutineScope) {
 // Ordinary phone preparation has no parked or preview selection.
 private var preview:Any?=null;private var restoredPark:Any?=null
 var intent=true;var released=false;var pending:Job?=null;var tail:Job?=null;var selectedLoaded=false;var arrangement:Any?=null;var activeGrant:MediaGrant?=null;var activeUri:String?=null;var queueScope:AccountScope?=null
 var epoch=1L;var sourceSequence=0L;var ordinaryDeck=0;var ordinaryIdentity=0L;var playback=Player.STATE_IDLE;var error:Any?=null;var eofCount=0L;var position=0L;val preparing=AtomicInteger();var explicitSeek=0L;var desiredSeek:Long?=null;var acknowledgedSeekPosition:Long?=null;var outputUnavailable=false;val volume=1f
 val source=GrantedNativeCallbackSource(graph,grants);val owner=Hardware();private val journal=Journal()
 fun loadSpeed(item:MediaItem)=1.0
 fun selected()=items.firstOrNull();fun validate(rows:List<MediaItem>){check(rows.all {grants[it.localConfiguration.uri.toString()]?.current(graph)==true})}
 fun dispatchIntent(generation:Long=epoch,recoverOutput:Boolean=false){}
 fun retireSelection(){epoch++;selectedLoaded=false};fun fail(m:String){error=m};fun currentScope()=graph.phoneAudio.current(graph.session.version());fun invalidateState(){};private fun done()=ListenableFuture<Any>()
 private suspend fun bindJournal(item:MediaItem,grant:MediaGrant,source:NativePlaybackSource,deck:Int,generation:Long,resume:Boolean,current:()->Boolean){check(current())}
'''+block('playback/nativeengine/NativeCallbackPlayer.kt','    override fun handlePrepare(').replace('override fun','private fun',1)+'''
 suspend fun prepare(){handlePrepare();tail?.join()}
}
''')
put('Work.kt','''package com.soundq.android.lookupprobe
object Work {
 var visits=0L;var uuids=0L;var regexes=0L;var revisions=0L;var owners=0L
 var callbackChecks=0L;var grantChecks=0L;var repositoryChecks=0L;var sessionChecks=0L
 fun uuid(s:String):java.util.UUID {uuids++;return java.util.UUID.fromString(s)}
 fun regex(s:String):Regex {regexes++;return Regex(s)}
 fun reset(){visits=0;uuids=0;regexes=0;revisions=0;owners=0;callbackChecks=0;grantChecks=0;repositoryChecks=0;sessionChecks=0}
 fun snapshot()=listOf(visits,uuids,regexes,revisions,owners)
}
inline fun <T> Iterable<T>.countedSingleOrNull(predicate:(T)->Boolean):T? {var found=false;var result:T?=null;for(v in this){Work.visits++;if(predicate(v)){if(found)return null;found=true;result=v}};return result}
inline fun <T> Iterable<T>.countedAny(predicate:(T)->Boolean):Boolean {for(v in this){Work.visits++;if(predicate(v))return true};return false}
''')
put('Probe.kt',(Path(__file__).with_name('source-lookup')/'Probe.kt').read_text())
# Optional published view exists only in successor; predecessor compiles identical fixture.
# Publication extension chooses the production sealing factory when available.
types=read('data/deviceaudio/DeviceAudioTypes.kt')
put('Publish.kt','package com.soundq.android.lookupprobe\nimport com.soundq.android.data.deviceaudio.*\ninternal fun DeviceListeningSnapshot.sealForTest():DeviceListeningSnapshot='+('published()' if 'fun published()' in types else 'this')+'\n')
dependencies={}
cp=os.pathsep.join(map(str,[out/'classes',jar('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.10.2'),jar('org.jetbrains.kotlinx','kotlinx-serialization-core-jvm','1.9.0'),jar('org.jetbrains.kotlinx','kotlinx-serialization-json-jvm','1.9.0'),jar('com.squareup.okhttp3','okhttp','4.12.0'),jar('com.squareup.okio','okio-jvm','3.6.0')]))
# Contracts only references LibraryCollection through an excluded unrelated section.
kotlin=Path(os.path.realpath(__import__('shutil').which('kotlinc'))).parents[1]
plugin=next((f for f in [kotlin/'lib/kotlinx-serialization-compiler-plugin.jar',kotlin/'libexec/lib/kotlinx-serialization-compiler-plugin.jar'] if f.is_file()),None)
assert plugin is not None, 'kotlinc serialization compiler plugin required'
dependencies[str(plugin)]=hashlib.sha256(plugin.read_bytes()).hexdigest()
helpers=[Path(__file__).resolve(),Path(__file__).with_name('source-lookup')/'Probe.kt',root/'scripts/test-original-read-boundaries.py']
helper_hashes={str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in helpers}
(out/'inputs.json').write_text(json.dumps(dict(source=sources,spans=spans,dependencies=dependencies,helpers=helper_hashes,generated={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in out.glob('*.kt')},instrumentation='predicate receiver iteration, sealed backing get, UUID/Regex/identity construction, full validator entry counters; no validator replacement'),indent=2)+'\n')
rc=run('compile',['kotlinc','-J-Xmx512m','-J-XX:ActiveProcessorCount=1',*out.glob('*.kt'),'-Xplugin='+str(plugin),'-cp',cp,'-nowarn','-include-runtime','-d',out/'probe.jar'])
if rc:raise SystemExit(rc)
rc=run('full-current',['java','-Xmx512m','-XX:ActiveProcessorCount=1','-Djava.io.tmpdir='+str(out),'-cp',str(out/'probe.jar')+os.pathsep+cp,'com.soundq.android.lookupprobe.ProbeKt'])
assert all(hashlib.sha256((b/f).read_bytes()).hexdigest()==h for f,h in sources.items()), 'Production input changed'
assert all(hashlib.sha256(Path(f).read_bytes()).hexdigest()==h for f,h in {**dependencies,**helper_hashes}.items()), 'Dependency/helper changed'
(out/'input-readback.json').write_text(json.dumps(dict(sourceUnchanged=True,dependencyAndHelperUnchanged=True,rawExit=rc),indent=2)+'\n')
raise SystemExit(rc)
