#!/usr/bin/env python3
"""Link the production original stamp against API26-shaped and API27-shaped stat classes.
The API26 runtime intentionally has NO StructTimespec class or nanosecond fields.
This is a JVM linkage control, not an Android OS/provider/file-manager test.
"""
from pathlib import Path
import argparse, subprocess, os, json
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--root',type=Path);a=p.parse_args()
root=a.root or Path(__file__).resolve().parents[1];out=a.output;out.mkdir(parents=True,exist_ok=True)
s=(root/'app/src/main/kotlin/com/soundq/android/data/device/PhoneFileActions.kt').read_text()
stamp=s[s.index('internal data class OriginalFileStamp'):s.index('internal data class PhoneFileTarget')]
start=s.index('    suspend fun delete(');end=s.index('{',start)+1;depth=1
while depth:
 depth+=(s[end]=='{')-(s[end]=='}');end+=1
delete=s[start:end]
reason=next((line for line in s.splitlines() if 'val deleteUnavailableReason:' in line),'val deleteUnavailableReason:String? get()=null')
coroutines=next((Path.home()/'.gradle/caches/modules-2/files-2.1/org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.10.2').glob('*/*.jar'))
commands=[]
def run(label,cmd):
 commands.append(cmd);r=subprocess.run(cmd,capture_output=True,text=True);(out/(label+'.log')).write_text(r.stdout+r.stderr);print(label,r.returncode,r.stdout,r.stderr);return r.returncode
for api in (26,27):
 d=out/str(api);(d/'android/system').mkdir(parents=True,exist_ok=True);(d/'android/os').mkdir(parents=True,exist_ok=True)
 (d/'android/os/Build.java').write_text('package android.os;public class Build {public static class VERSION {public static int SDK_INT='+str(api)+';}}')
 extra='public StructTimespec st_mtim=new StructTimespec(10,123);public StructTimespec st_ctim=new StructTimespec(11,456);' if api>=27 else ''
 (d/'android/system/StructStat.java').write_text('package android.system;public class StructStat {public long st_dev=1,st_ino=2,st_size=3,st_mtime=10,st_ctime=11;'+extra+'}')
 if api>=27:(d/'android/system/StructTimespec.java').write_text('package android.system;public class StructTimespec {public long tv_sec,tv_nsec;public StructTimespec(long s,long n){tv_sec=s;tv_nsec=n;}}')
 rc=run('javac-'+str(api),['javac','-d',str(d/'classes'),*map(str,d.glob('android/**/*.java'))]);assert rc==0
(out/'RequiresApi.kt').write_text('package androidx.annotation\nannotation class RequiresApi(val value:Int)\n')
(out/'Stamp.kt').write_text('package com.soundq.android.stampprobe\nimport android.system.StructStat\nimport android.os.Build\n'+stamp)
(out/'Delete.kt').write_text('''package com.soundq.android.stampprobe
import android.os.Build
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
private data class Ref(val bytes:Long=3,val sha256:String="synthetic")
private data class PhoneFileTarget(val path:String,val stamp:OriginalFileStamp,val uri:String=path,val ref:Ref=Ref(),val providerValues:List<Pair<String,String>> = listOf("path" to path),val admission:Unit=Unit)
private enum class FileDeleteOutcome {Deleted,Changed,Missing,Refused,Unconfirmed}
private data class AudioContentProof(val bytes:Long,val sha256:String)
private object MediaStore {object MediaColumns {const val _ID="_id"}}
private class Platform {fun storageAllowed()=true;fun proof(uri:String,valid:()->Boolean):AudioContentProof {check(valid());return AudioContentProof(3,"synthetic")}}
private class Phone {val platform=Platform();var fenced=0;fun beginFileMutation(ref:Ref)=UUID.randomUUID().also {fenced++};fun endFileMutation(token:UUID){fenced--};suspend fun markFileMissing(admission:Unit,uri:String)=true}
private class Graph {val phoneAudio=Phone()}
private class Cursor:java.io.Closeable {fun moveToFirst()=false;override fun close(){}}
private class Resolver {var deletes=0;fun delete(uri:String,where:String,values:Array<String>):Int {deletes++;return if(File(uri).delete())1 else 0};fun query(uri:String,columns:Array<String>,a:Any?,b:Any?,c:Any?)=Cursor()}
private class Actions {
 val graph=Graph();val resolver=Resolver();val mutation=Mutex()
 fun current(target:PhoneFileTarget)=true
 fun matches(target:PhoneFileTarget)=File(target.path).isFile
REASON
DELETE
}
internal fun deletePolicyProbe(stamp:OriginalFileStamp) = runBlocking {
 val original=File.createTempFile("original-delete-policy-",".bin").apply {writeBytes(byteArrayOf(1,2,3))}
 try {
  val actions=Actions();var retirements=0
  val outcome=actions.delete(PhoneFileTarget(original.path,stamp),{true}) {retirements++;true}
  if(Build.VERSION.SDK_INT==26) {
   check(outcome==FileDeleteOutcome.Refused&&retirements==0&&actions.resolver.deletes==0&&original.isFile)
   check(actions.graph.phoneAudio.fenced==0)
   println("PASS API26: actual delete body refuses before retirement, mutation fence or provider delete")
  } else {
   check(outcome==FileDeleteOutcome.Deleted&&retirements==1&&actions.resolver.deletes==1&&!original.exists())
   println("PASS API27: actual delete body reaches confirmed synthetic original deletion")
  }
 } finally {original.delete()}
}
'''.replace('REASON',reason).replace('DELETE',delete))
# Reflection makes one identical compiled test legal against both API surfaces.
(out/'Main.kt').write_text('''package com.soundq.android.stampprobe
import android.system.StructStat
import android.os.Build
fun main(){
 val s=StructStat();val first=OriginalFileStamp.of(s)
 deletePolicyProbe(first)
 check(first.device==1L&&first.inode==2L&&first.bytes==3L&&first.modified==10L&&first.changed==11L)
 if(Build.VERSION.SDK_INT==26){check(StructStat::class.java.fields.none {it.name=="st_mtim"});println("PASS API26: capture stamp links without unavailable nanosecond fields")}
 else {
  check(first.modifiedNs==123L&&first.changedNs==456L)
  val timespec=StructStat::class.java.getField("st_mtim").get(s)
  timespec.javaClass.getField("tv_nsec").setLong(timespec,124)
  check(first!=OriginalFileStamp.of(s));println("PASS API27: subsecond replacement observation remains unequal")
 }
}
''')
rc=run('compile',['kotlinc','-J-Xmx512m','-J-XX:ActiveProcessorCount=1',str(out/'Stamp.kt'),str(out/'Main.kt'),str(out/'Delete.kt'),str(out/'RequiresApi.kt'),'-cp',str(out/'27/classes')+os.pathsep+str(coroutines),'-include-runtime','-d',str(out/'stamp.jar')]);assert rc==0
failed=False
for api in (26,27):failed=bool(run('api-'+str(api),['java','-XX:ActiveProcessorCount=1','-Djava.io.tmpdir='+str(out),'-cp',os.pathsep.join(map(str,[out/str(api)/'classes',out/'stamp.jar',coroutines])),'com.soundq.android.stampprobe.MainKt'])) or failed
(out/'commands.json').write_text(json.dumps(commands,indent=2))
raise SystemExit(int(failed))
