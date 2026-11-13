#!/usr/bin/env python3
"""Actual original lease, repository acquisition and proof bodies with syscall/resolver facades.
API26 linkage is a separate Java runtime shape. No Android/provider/codec execution.
"""
from pathlib import Path
import argparse, subprocess, os, json
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--root',type=Path);a=p.parse_args()
root=a.root or Path(__file__).resolve().parents[1];out=a.output;out.mkdir(parents=True,exist_ok=True);src=root/'app/src/main/kotlin/com/soundq/android'
def method(file,marker):
 s=(src/file).read_text();start=s.index(marker);end=s.index('{',start)+1;depth=1
 while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
 return s[start:end]
commands=[]
def run(name,cmd):
 r=subprocess.run(list(map(str,cmd)),capture_output=True,text=True);(out/(name+'.log')).write_text(r.stdout+r.stderr);commands.append(dict(name=name,command=list(map(str,cmd)),exit=r.returncode));print(name,r.returncode,flush=True);return r.returncode
for api in (26,27):
 d=out/str(api);(d/'android/system').mkdir(parents=True,exist_ok=True);(d/'android/os').mkdir(parents=True,exist_ok=True)
 (d/'android/os/Build.java').write_text('package android.os; public class Build {public static class VERSION {public static int SDK_INT='+str(api)+';}}')
 extra='public StructTimespec st_mtim=new StructTimespec(10,123),st_ctim=new StructTimespec(11,456);' if api==27 else ''
 (d/'android/system/StructStat.java').write_text('package android.system;public class StructStat {public long st_dev=1,st_ino=2,st_size=8,st_mtime=10,st_ctime=11;public int st_mode=1;'+extra+'}')
 if api==27:(d/'android/system/StructTimespec.java').write_text('package android.system;public class StructTimespec {public long tv_sec,tv_nsec;public StructTimespec(long s,long n){tv_sec=s;tv_nsec=n;}}')
 assert run('javac-'+str(api),['javac','-d',d/'classes',*d.glob('android/**/*.java')])==0
files={
'Annotations.kt':'package androidx.annotation\nannotation class RequiresApi(val value:Int)\nannotation class Keep\n',
'Uri.kt':'package android.net\nclass Uri(val value:String){val scheme get()=value.substringBefore(":");val authority get()=value.substringAfter("://").substringBefore("/");override fun toString()=value;companion object {fun parse(s:String)=Uri(s)}}\n',
'Media.kt':'package android.media\nabstract class MediaDataSource:java.io.Closeable {abstract fun readAt(position:Long,buffer:ByteArray,bufferOffset:Int,size:Int):Int;abstract fun getSize():Long}\n',
'Store.kt':'package android.provider\nobject MediaStore {const val AUTHORITY="media";object MediaColumns {const val DATA="_data";const val SIZE="_size";const val DATE_MODIFIED="date_modified";const val GENERATION_ADDED="generation_added";const val GENERATION_MODIFIED="generation_modified"}}\n',
'Os.kt':'''package android.system
import java.io.FileDescriptor
object OsConstants {fun S_ISREG(mode:Int)=mode==1}
object Os {
 data class Entry(val bytes:ByteArray,val stat:StructStat=StructStat())
 val entries=java.util.IdentityHashMap<FileDescriptor,Entry>();val paths=mutableMapOf<String,Entry>()
 fun fstat(fd:FileDescriptor)=entries.getValue(fd).stat
 fun stat(path:String)=paths.getValue(path).stat
 fun pread(fd:FileDescriptor,b:ByteArray,offset:Int,count:Int,position:Long):Int {if(android.os.ParcelFileDescriptor.readFault)throw java.io.IOException("injected read fault");val bytes=entries.getValue(fd).bytes;val n=minOf(count,bytes.size-position.toInt());if(n<=0)return 0;bytes.copyInto(b,offset,position.toInt(),position.toInt()+n);return n}
}
''',
'Pfd.kt':'''package android.os
import android.system.Os
import java.io.FileDescriptor
class ParcelFileDescriptor(val fileDescriptor:FileDescriptor,val duplicate:Boolean=false):java.io.Closeable {
 override fun close(){if(duplicate&&failDuplicateClose)throw java.io.IOException("injected close failure");open.remove(this)}
 companion object {
  const val MODE_READ_ONLY=1
  fun open(file:java.io.File,mode:Int):ParcelFileDescriptor {val fd=FileDescriptor();Os.entries[fd]=Os.paths.getValue(file.path);return ParcelFileDescriptor(fd).also {open.add(it)}}
  var readFault=false
  var failDuplicateClose=false
  val open=java.util.Collections.newSetFromMap(java.util.IdentityHashMap<ParcelFileDescriptor,Boolean>())
  fun dup(fd:FileDescriptor):ParcelFileDescriptor {val copy=FileDescriptor();Os.entries[copy]=Os.entries.getValue(fd);return ParcelFileDescriptor(copy,true).also {open.add(it)}}
 }
}
''',
'Resolver.kt':'''package android.content
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.system.Os
class Cursor(val values:List<String>):java.io.Closeable {val count=1;fun moveToFirst()=true;fun getString(i:Int)=values[i];override fun close(){}}
class Asset(val fileDescriptor:java.io.FileDescriptor,val startOffset:Long,val declaredLength:Long):java.io.Closeable {
 fun createInputStream():java.io.InputStream=java.io.ByteArrayInputStream(Os.entries.getValue(fileDescriptor).bytes,startOffset.toInt(),declaredLength.toInt())
 override fun close(){}
}
open class ContentResolver {
 var opens=0;var slice=false;var invalid=false;var generation=1;var mismatch=false
 val direct=Os.Entry(byteArrayOf(1,2,3,4,5,6,7,8))
 var gate:java.util.concurrent.CountDownLatch?=null;val entered=java.util.concurrent.CountDownLatch(1)
 val path="/synthetic/original";val a=Os.Entry(byteArrayOf(1,2,3,4,5,6,7,8));val b=Os.Entry(byteArrayOf(8,7,6,5,4,3,2,1))
 init {Os.paths[path]=a}
 fun query(uri:Uri,c:Array<String>,s:String?,v:Array<String>?,o:String?)=Cursor(c.map {when(it){"_data"->path;"_size"->"8";"date_modified"->(generation+9).toString();else->generation.toString()}})
 fun splitViews(){
  mismatch=true;a.stat.st_dev=65063;direct.stat.st_dev=84
  for(stat in listOf(a.stat,direct.stat)) {stat.st_ino=106675;stat.st_mtime=1794516375;stat.st_ctime=1794516375
   if(android.os.Build.VERSION.SDK_INT>=27){stat.st_mtim.tv_sec=1794516375;stat.st_ctim.tv_sec=1794516375;stat.st_mtim.tv_nsec=612004829;stat.st_ctim.tv_nsec=612004829}}
  if(android.os.Build.VERSION.SDK_INT>=27)a.stat.st_ctim.tv_nsec=644004829
  Os.paths[path]=direct
 }
 fun openAssetFileDescriptor(uri:Uri,mode:String):Asset {entered.countDown();gate?.await();opens++;val entry=if(opens==1||slice)a else b;entry.stat.st_size=entry.bytes.size.toLong();if(invalid)entry.stat.st_mode=0;val fd=java.io.FileDescriptor();Os.entries[fd]=entry;return Asset(fd,if(slice&&opens>1)4 else 0,if(slice)4 else 8)}
}
''',
'Platform.kt':'''package com.soundq.android.readprobe
import android.content.ContentResolver
import android.net.Uri
import com.soundq.android.playback.nativeengine.*
import java.security.MessageDigest
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.CancellationException
internal data class AudioContentProof(val bytes:Long,val sha256:String)
internal class Platform(val resolver:ContentResolver) {
 var allowed=true;fun storageAllowed()=allowed
 val MAX_SOURCE_BYTES=8L*1024*1024*1024;val DISK_RESERVE_BYTES=0L
 fun openOriginal(locator:String,current:()->Boolean,changed:()->Unit,sourceKey:String=locator)=OriginalAudioReadLease.open(resolver,locator,current,changed)
PROOF
COPY
}
''',
'Repository.kt':'''package com.soundq.android.readprobe
import com.soundq.android.playback.nativeengine.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
internal data class Id(val value:String="target")
internal data class Locator(val value:String="content://test/original")
internal enum class AccessState {AVAILABLE}
internal data class Alias(val locator:Locator=Locator(),val state:AccessState=AccessState.AVAILABLE)
internal data class Row(val aliases:List<Alias> = listOf(Alias()),val owner:String="owner",val id:Id=Id(),val durationMs:Long?=null)
internal data class PhoneSourceAdmission(val row:Row=Row(),val source:String="source",val sessionVersion:Long=1,val resumeMs:Long=0)
internal enum class Mutation {REFUSED,APPLIED}
internal class Store {fun retireChangedOriginal(s:String)=Mutation.APPLIED}
internal class Graph(val directory:File)
internal class Repository(val platform:Platform,val graph:Graph) {
 val serial=Mutex();val store:Store?=Store();val access:Any?=Any();var liveVersions:LiveOriginalVersions?=null
 val jobs=CoroutineScope(SupervisorJob()+Dispatchers.Unconfined)
 fun current(v:Long)=true
 fun advanceAuthority(id:Id=Id())=0L
 fun publish(message:String){}
ACQUIRE
}
''',
'Window.kt':'''package com.soundq.android.playback.nativeengine
import java.io.File
import java.nio.ByteBuffer
internal class AndroidPlatformWindowReader(val lease:OriginalAudioReadLease):NativePcmReader {
 override fun open()=48000;override fun read(first:Long,count:Int,destination:ByteBuffer)=0;override fun endFrames()=0L;override fun revoke()=lease.revoke()
 override fun closeReader()=try {lease.close();true}catch(_:Throwable){false}
}
internal class LiveOriginalVersions(file:File) {
 enum class Observation {Changed,Same}
 fun observe(k:String,v:String,reset:()->Unit):Observation {throw java.io.IOException("injected version persistence failure")}
}
''',
'Drain.kt':'''package com.soundq.android.readprobe
import kotlinx.coroutines.*
private data class RetainedSource(val physicalFileId:String?)
internal class Drain {
 val dispatcher=Dispatchers.Unconfined
 private val borrowed=mutableSetOf<String>();private val ordinaryFiles=mutableMapOf<Int,String>()
 private val borrowedOriginals=mutableSetOf<RetainedSource>();private val ordinaryOriginals=mutableMapOf<Int,RetainedSource>()
 fun descriptorsDrained(id:String?):Boolean=DESCRIPTOR_DRAIN
DRAIN
}
''',
'Main.kt':'''package com.soundq.android.readprobe
import android.content.ContentResolver
import android.os.Build
import android.os.ParcelFileDescriptor
import com.soundq.android.playback.nativeengine.*
import kotlinx.coroutines.*
import java.io.File
import java.security.MessageDigest
fun hash(b:ByteArray)=MessageDigest.getInstance("SHA-256").digest(b).joinToString(""){"%02x".format(it)}
fun main(args:Array<String>)=runBlocking {
 when(args.single()) {
 "media-revoke"->{val r=ContentResolver();r.splitViews();val p=Platform(r);val lease=p.openOriginal("content://media/external/audio/media/1",{true},{});try {p.allowed=false;check(runCatching {lease.checkCurrent()}.isFailure)}finally {lease.close()};println("PASS platform all-files revocation refuses retained direct original")}
 "media-truncate","media-read-fault"->{val r=ContentResolver();r.splitViews();val lease=Platform(r).openOriginal("content://media/external/audio/media/1",{true},{});try {lease.beginOperation();if(args.single()=="media-truncate")r.direct.stat.st_size-- else ParcelFileDescriptor.readFault=true;check(runCatching {lease.readAt(0,ByteArray(8),0,8)}.isFailure)}finally {lease.close()};check(ParcelFileDescriptor.open.isEmpty());println("PASS "+args.single()+" refuses and closes")}
 "media-close-failure"->{val r=ContentResolver();r.splitViews();r.direct.stat.st_mode=0;ParcelFileDescriptor.failDuplicateClose=true;check(runCatching {Platform(r).openOriginal("content://media/external/audio/media/1",{true},{},"target")}.isFailure);check(!Drain().sourcesDrained("target")&&Drain().sourcesDrained("unrelated"));check(ParcelFileDescriptor.open.size==1);println("PASS failed direct acquisition close retains target custody without blocking unrelated original")}
 "media-view"->{val r=ContentResolver();r.splitViews();val proof=Platform(r).proof("content://media/external/audio/media/1"){true};check(proof.sha256==hash(r.direct.bytes));check(r.opens==0);println("PASS MediaStore proof reads direct named original without cross-view stamp equality")}
 "media-route"->{val r=ContentResolver();r.splitViews();val lease=Platform(r).openOriginal("content://media/external/audio/media/1",{true},{});try {r.generation++;check(runCatching {lease.checkCurrent()}.isFailure)}finally {lease.close()};println("PASS MediaStore route generation change revokes direct lease")}
 "media-replace"->{val r=ContentResolver();r.splitViews();val lease=Platform(r).openOriginal("content://media/external/audio/media/1",{true},{});try {r.direct.stat.st_dev++;check(runCatching {lease.checkCurrent()}.isFailure)}finally {lease.close()};println("PASS full direct device identity remains guarded")}
 "provider-view"->{val r=ContentResolver();r.splitViews();check(runCatching {Platform(r).proof("content://test/original"){true}}.isFailure);check(ParcelFileDescriptor.open.isEmpty());println("PASS generic provider cross-view mismatch still refuses and closes")}
 "api"->{val r=ContentResolver();val p=Platform(r);val proof=p.proof("content://test/original"){true};check(proof.sha256==hash(r.a.bytes));println("PASS actual lease/proof API"+Build.VERSION.SDK_INT)}
 "route"->{val r=ContentResolver();val proof=Platform(r).proof("content://test/original"){true};check(proof.sha256==hash(r.a.bytes)){"Proof hashed a substituted descriptor"};check(r.opens==1){"Proof reopened mutable URI"};println("PASS captured A descriptor, no A-B-A hash reopen")}
 "slice"->{val r=ContentResolver();r.slice=true;val proof=Platform(r).proof("content://test/original"){true};check(proof.bytes==4L&&proof.sha256==hash(r.a.bytes.copyOfRange(0,4))){"Proof hashed a different valid slice of the same inode"};check(r.opens==1);println("PASS captured same-file range")}
 "held-open"->{
  val r=ContentResolver();val hold=java.util.concurrent.CountDownLatch(1);r.gate=hold
  val dir=File(System.getProperty("java.io.tmpdir"),"held-open-"+System.nanoTime()).apply {mkdirs()};val repo=Repository(Platform(r),Graph(dir))
  val acquire=async(Dispatchers.IO) {runCatching {repo.openOriginal(PhoneSourceAdmission()){true}}}
  try {
   check(r.entered.await(5,java.util.concurrent.TimeUnit.SECONDS))
   check(!Drain().sourcesDrained("target")){"Provider acquisition before return escaped destructive drain"}
   check(Drain().sourcesDrained("unrelated"))
  } finally {hold.countDown();acquire.await();repo.jobs.cancel();dir.deleteRecursively()}
  check(Drain().sourcesDrained("target"));println("PASS held provider open reserves target drain before descriptor return")
 }
 "validation-failed-close","validation-closed","admission-failed-close","admission-closed"->{
  val failed=args.single().endsWith("failed-close");val validation=args.single().startsWith("validation")
  val r=ContentResolver();r.invalid=validation;ParcelFileDescriptor.failDuplicateClose=failed
  val p=Platform(r);val dir=File(System.getProperty("java.io.tmpdir"),"read-boundary-"+System.nanoTime()).apply {mkdirs()};val repo=Repository(p,Graph(dir))
  try {
   val error=runCatching {repo.openOriginal(PhoneSourceAdmission()){true}}.exceptionOrNull();check(error!=null)
   check(ParcelFileDescriptor.open.size==(if(failed)1 else 0)){"Expected concrete unclosed duplicate witness"}
   check(Drain().sourcesDrained("target")==!failed){"Acquisition-internal close escaped source drain ledger"}
   check(Drain().sourcesDrained("unrelated")){"Healthy unrelated source must not block"}
   println("PASS "+args.single()+" native identity absent, target drain="+!failed)
  } finally {repo.jobs.cancel();dir.deleteRecursively()}
 }
 }
}
'''}
# Execute the exact production capture/matches bodies with declaration-only graph facades.
files['Actions.kt'] = '''package com.soundq.android.actionprobe
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.MediaStore
import android.provider.DocumentsContract
import android.system.Os
import com.soundq.android.data.device.OriginalFileStamp
import com.soundq.android.playback.nativeengine.OriginalAudioReadLease
import kotlinx.coroutines.*
import java.io.File
internal object PlaybackRef {data class Device(val bytes:Long=8)}
internal data class PhoneSourceAdmission(val sessionVersion:Long=1)
internal data class PhoneFileTarget(val ref:PlaybackRef.Device,val version:Long,val admission:PhoneSourceAdmission,val uri:Uri,val path:String,val stamp:OriginalFileStamp,val providerValues:List<Pair<String,String>>,val folder:Uri?)
internal class Row {val aliases=listOf(Alias())}
internal class Alias {val state=com.soundq.android.data.deviceaudio.AccessState.AVAILABLE;val locator=Locator()}
internal class Locator {val value="content://media/external/audio/media/1"}
internal class Platform {fun storageAllowed()=true}
internal class Phone {val platform=Platform();fun observed(ref:PlaybackRef.Device):Row?=Row();fun admit(row:Row):PhoneSourceAdmission?=PhoneSourceAdmission();fun current(version:Long)=true}
internal class Session {fun owns(version:Long)=true}
internal class Context(val contentResolver:android.content.ContentResolver) {fun getSystemService(c:Class<StorageManager>)=StorageManager()}
internal class Graph(r:android.content.ContentResolver) {val phoneAudio=Phone();val session=Session();val applicationContext=Context(r)}
internal class Actions(private val graph:Graph) {
 private val resolver=graph.applicationContext.contentResolver
 private fun current(target:PhoneFileTarget)=graph.phoneAudio.current(target.version)&&graph.session.owns(target.version)
 CAPTURE
 MATCHES
 fun check(target:PhoneFileTarget)=matches(target)
}
fun main()=runBlocking {
 val resolver=android.content.ContentResolver();resolver.splitViews()
 val actions=Actions(Graph(resolver))
 val target=checkNotNull(actions.capture(PlaybackRef.Device()){true}) {"Cross-view mismatch wrongly refused captured named original"}
 check(target.path==resolver.path&&target.stamp.device==84L)
 check(actions.check(target)) {"Captured original failed same-view matching"}
 resolver.direct.stat.st_dev++
 check(!actions.check(target)) {"Complete device identity was weakened"}
 check(android.os.ParcelFileDescriptor.open.isEmpty())
 println("PASS exact PhoneFileActions capture/matches bodies use coherent named-original view and refuse changed identity")
}
'''.replace('CAPTURE',method('data/device/PhoneFileActions.kt','    suspend fun capture(')).replace('MATCHES','    private fun matches('+(src/'data/device/PhoneFileActions.kt').read_text().split('    private fun matches(',1)[1].split('    /** Confirmation',1)[0])
files['Storage.kt']='package android.os.storage\nclass Volume {val directory:java.io.File?=null;val isPrimary=true;val uuid:String?=null}\nclass StorageManager {val storageVolumes=emptyList<Volume>()}\n'
files['Environment.kt']='package android.os\nobject Environment {fun getExternalStorageDirectory()=java.io.File("/synthetic")}\n'
files['Documents.kt']='package android.provider\nobject DocumentsContract {fun buildDocumentUri(authority:String,id:String)=android.net.Uri.parse("content://"+authority+"/"+id)}\n'
files['Access.kt']='package com.soundq.android.data.deviceaudio\nenum class AccessState {AVAILABLE}\n'
proof=method('data/device/AndroidAudioAccess.kt','    fun proof(')
copy=method('data/device/AndroidAudioAccess.kt','    private fun copyOrHash(')
acquire=method('data/device/PhoneAudioRepository.kt','    suspend fun openOriginal(')
owner=(src/'playback/nativeengine/NativeCallbackOwner.kt').read_text();drain=owner[owner.index('    suspend fun sourcesDrained('):owner.index('    suspend fun retainedBytes(')]
ledger=src/'playback/nativeengine/OriginalDescriptorCustody.kt'
if ledger.exists():
 files['Platform.kt']=files['Platform.kt'].replace('OriginalAudioReadLease.open(resolver,locator,current,changed)','OriginalAudioReadLease.open(resolver,locator,current,changed,sourceKey)')
 descriptor_drain='OriginalDescriptorCustody.drained(id?.let {setOf(it)})'
else:descriptor_drain='true'
platform_source=(src/'data/device/AndroidAudioAccess.kt').read_text()
open_wrapper=platform_source[platform_source.index('    fun openOriginal('):platform_source.index('    /** Exact-byte proof')]
files['Platform.kt']=files['Platform.kt'].replace(next(line for line in files['Platform.kt'].splitlines() if 'fun openOriginal(' in line),open_wrapper)
files['Platform.kt']=files['Platform.kt'].replace('PROOF',proof).replace('COPY',copy)
files['Repository.kt']=files['Repository.kt'].replace('ACQUIRE',acquire)
files['Drain.kt']=files['Drain.kt'].replace('import kotlinx.coroutines.*','import kotlinx.coroutines.*\nimport com.soundq.android.playback.nativeengine.*').replace('DESCRIPTOR_DRAIN',descriptor_drain).replace('DRAIN',drain)
stamp=(src/'data/device/PhoneFileActions.kt').read_text();stamp=stamp[stamp.index('internal data class OriginalFileStamp'):stamp.index('internal data class PhoneFileTarget')]
files['Stamp.kt']='package com.soundq.android.data.device\nimport android.os.Build\nimport android.system.StructStat\n'+stamp
for n,s in files.items():(out/n).write_text(s)
coroutines=next((Path.home()/'.gradle/caches/modules-2/files-2.1/org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.10.2').glob('*/*.jar'))
production=[src/'playback/nativeengine/OriginalAudioReadLease.kt',src/'playback/nativeengine/NativePlaybackSource.kt']+([ledger] if ledger.exists() else [])
assert run('compile',['kotlinc','-J-Xmx512m','-J-XX:ActiveProcessorCount=1',*production,*[out/n for n in files],'-cp',str(out/'27/classes')+os.pathsep+str(coroutines),'-include-runtime','-d',out/'probe.jar'])==0
failed=False
for api,case in [(26,'api'),(27,'api'),(27,'route'),(27,'slice'),(27,'held-open'),(27,'validation-failed-close'),(27,'validation-closed'),(27,'admission-failed-close'),(27,'admission-closed'),(27,'media-view'),(27,'media-route'),(27,'media-replace'),(27,'provider-view'),(27,'media-revoke'),(27,'media-truncate'),(27,'media-read-fault'),(27,'media-close-failure')]:
 rc=run(str(api)+'-'+case,['java','-XX:ActiveProcessorCount=1','-Djava.io.tmpdir='+str(out),'-cp',os.pathsep.join(map(str,[out/str(api)/'classes',out/'probe.jar',coroutines])),'com.soundq.android.readprobe.MainKt',case]);failed=failed or bool(rc)
rc=run('27-file-actions',['java','-XX:ActiveProcessorCount=1','-Djava.io.tmpdir='+str(out),'-cp',os.pathsep.join(map(str,[out/'27/classes',out/'probe.jar',coroutines])),'com.soundq.android.actionprobe.ActionsKt']);failed=failed or bool(rc)
(out/'commands.json').write_text(json.dumps(commands,indent=2));raise SystemExit(int(failed))
