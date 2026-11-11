#!/usr/bin/env python3
"""Compile exact playlist parser/repository and extracted API body; no Gradle/device/network."""
from pathlib import Path
from host_probe import directory, gradle_cache, kotlin_plugin, android_jar
import argparse, subprocess, os
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);a=p.parse_args()
r=Path(__file__).resolve().parents[1]; b=r/'app/src/main/kotlin/com/soundq/android';o=a.out;o.mkdir(parents=True,exist_ok=True)
def put(n,s): (o/n).write_text(s)
api=(b/'data/SoundQApi.kt').read_text(); method=api[api.index('    fun createPlaylistImport('):api.index('    fun research(',api.index('    fun createPlaylistImport('))]
has='description:String' in method
put('Data.kt','''package com.soundq.android.data
import com.soundq.android.data.imports.*
import com.soundq.android.data.acquisition.*
import kotlinx.serialization.json.*
class AccountScope(val accountId:String="A")
class AccountSession {var scope:AccountScope?=AccountScope();val endpoint=Endpoint();fun capture()=scope;fun current(s:AccountScope)=scope===s;fun remoteCurrent(s:AccountScope)=current(s);fun replace(){scope=AccountScope()}}
class Endpoint {val identity="fixture"}
class TrackId(val value:Long){init{require(value>0)}}
class SafeFailure(val reason:Reason):RuntimeException(){enum class Reason {InvalidResponse,Retired,StoreRejected,Uncertain,Refused,Capacity}}
class SoundQApi(val session:AccountSession,val intakeReceipts:IntakeReceipts=IntakeReceipts()){var posts=0;var gets=0;var body:JsonObject?=null;var response=Json.parseToJsonElement(BODY).jsonObject;var beforeReturn:()->Unit={}
fun authorized(s:AccountScope,path:String,method:String,body:JsonObject,readOnly:Boolean,valid:()->Boolean,expectedStatus:Int,dispatchValid:()->Boolean):JsonObject {check(valid()&&dispatchValid());posts++;this.body=body;beforeReturn();return response}
'''+method+'''
fun playlistImport(s:AccountScope,id:ImportJobId,v:()->Boolean):PlaylistImportProgress {check(v());gets++;beforeReturn();return AcquisitionJson.playlist(response,id)}
fun serverImports(s:AccountScope,v:()->Boolean):ServerImportQueue=error("out of scope")
fun manageServerImport(s:AccountScope,op:String,id:String?,pos:Int?,v:()->Boolean,a:()->Boolean):ServerImportQueue=error("out of scope")
fun research(s:AccountScope,id:ImportJobId,v:()->Boolean):ResearchProgress=error("out of scope")
fun startResearch(s:AccountScope,q:String,k:String,v:()->Boolean,a:()->Boolean):ResearchProgress=error("out of scope")
fun mutateResearch(s:AccountScope,id:ImportJobId,op:String,v:()->Boolean,a:()->Boolean):ResearchProgress=error("out of scope")
fun researchEvents(s:AccountScope,id:ImportJobId,after:Long,v:()->Boolean)=Events(emptyList())
fun queueResearchReview(s:AccountScope,d:String,v:()->Boolean,a:()->Boolean):ImportAcknowledgement=error("out of scope")
fun reviewResearch(s:AccountScope,id:ImportJobId,c:com.soundq.android.data.discovery.SourceCandidate,op:String,k:String,reason:String,v:()->Boolean,a:()->Boolean):ResearchReview=error("out of scope")
}
const val BODY="""{"id":"123e4567-e89b-12d3-a456-426614174001","playlistId":17,"sourceTitle":"Real source title","status":"partial_failure","totalItems":2,"importedItems":1,"queuedItems":0,"failedItems":1,"skippedItems":0,"items":[{"id":1,"title":"Ready","status":"imported","trackId":71},{"id":2,"status":"failed","error":"private video"}]}"""
''')
put('Imports.kt','''package com.soundq.android.data.imports
data class ImportJobId(val value:String){init{require(java.util.UUID.fromString(value).toString()==value)}}
class ImportSource(val url:String,val provider:String){companion object {fun parse(s:String)=if(s.startsWith("https://youtube.com/"))ImportSource(s,"youtube")else null}}
class ImportAcknowledgement(val id:ImportJobId)
''')
put('Discovery.kt','''package com.soundq.android.data.discovery
class SourceCandidate(val id:String,val source:com.soundq.android.data.imports.ImportSource)
object DiscoveryJson {fun candidate(o:kotlinx.serialization.json.JsonObject):SourceCandidate=error("out of scope")}
''')
put('Events.kt','''package com.soundq.android.data.acquisition
class ResearchEvent(val sequence:Long)
class Events(val rows:List<ResearchEvent>)
''')
root=(b/'product/ProductApp.kt').read_text()
close=root[root.index('    fun closePlaylistDestination()'):root.index('    if(destination=="Playlists" && importView==null) androidx.activity.compose.BackHandler')]
put('RootReturn.kt','''package com.soundq.android.data
class RouteActions {var closed=0;fun close(){closed++}}
class RouteModel {var closed=0;fun closePlaylistDetail(){closed++}}
class RouteDetail(var id:Long?)
fun rootReturnChecks() {
 val orderActions:RouteActions?=RouteActions();val playlistActions:RouteActions?=RouteActions();val model=RouteModel();val playlistDetail=RouteDetail(null)
 var acquisitionPlaylistJob:String?="123e4567-e89b-12d3-a456-426614174001";var destination="Playlists"
'''+close+'''
 closePlaylistDestination();check(destination=="Acquisition"&&acquisitionPlaylistJob!=null)
 destination="Playlists";playlistDetail.id=17;closePlaylistDestination();check(destination=="Acquisition")
 acquisitionPlaylistJob=null;destination="Playlists";closePlaylistDestination();check(destination=="Playlists")
 playlistDetail.id=null;closePlaylistDestination();check(destination=="Library")
 println("PASS exact root Back handler returns to import with loaded or absent playlist projection")
}
''')
call='api.createPlaylistImport(s.scope!!,source,"Name",500,{true},{true}'+(',description="A description"' if has else '')+')'
put('Check.kt','''package com.soundq.android.data
import com.soundq.android.data.acquisition.*
import com.soundq.android.data.imports.*
import kotlinx.serialization.json.*
fun main(){
 val s=AccountSession();val api=SoundQApi(s);val source=ImportSource.parse("https://youtube.com/playlist?list=PLfixture")!!
 CALL
 check(api.body!!["description"]?.jsonPrimitive?.content=="A description"){"actual create request dropped optional description"}
 println("PASS exact API description payload")
 val progress=AcquisitionJson.playlist(api.response)
 check(progress.javaClass.methods.firstOrNull{it.name=="getSourceTitle"}?.invoke(progress)=="Real source title"){"acknowledged source title is unavailable"}
 check(progress.items.last().javaClass.methods.firstOrNull{it.name=="getError"}?.invoke(progress.items.last())=="Private video") {"entry failure has no safe meaningful fact"}
 println("PASS producer title and meaningful entry error")
 val repo=AcquisitionRepository(s,api);val view=repo.open()!!
 repo.startPlaylist(view,source.url,"Name",500,"A description")!!()
 val accepted=repo.state.value.playlist!!
 var opened=0L
 fun open(v:AcquisitionView,p:PlaylistImportProgress):Boolean {
  val fn=repo.javaClass.methods.firstOrNull{it.name=="openPlaylist"} ?: return false
  return fn.invoke(repo,v,p,{id:Long->opened=id}) as Boolean
 }
 check(open(view,accepted)&&opened==17L){"acknowledged partial import has no usable playlist continuation"}
 repo.close(view);check(!open(view,accepted))
 val next=repo.open()!!;check(open(next,accepted))
 repo.loadPlaylist(next,accepted.id)!!();check(!open(next,accepted));check(open(next,repo.state.value.playlist!!))
 s.replace();check(!open(next,repo.state.value.playlist!!));repo.open();check(repo.state.value.playlist==null)
 check(api.posts==2);check(api.gets==1)
 println("PASS acknowledged partial Open, return, stale observation and replacement refusal")
 val journal=java.io.File(java.nio.file.Files.createTempDirectory("playlist-host").toFile(),"receipts.json")
 val ss=AccountSession();val aa=SoundQApi(ss,IntakeReceipts(journal));val rr=AcquisitionRepository(ss,aa);val vv=rr.open()!!
 check(rr.startPlaylist(vv,source.url,"",500,"x".repeat(5001))==null)
 val work=rr.startPlaylist(vv,source.url,"",500,"Exact description")!!
 check(rr.startPlaylist(vv,source.url,"",500)==null);work();work();check(aa.posts==1)
 val receipt=aa.intakeReceipts.entries(ss.endpoint.identity,"A").single();check(receipt.phase=="accepted")
 val restoredApi=SoundQApi(ss,IntakeReceipts(journal));val restored=AcquisitionRepository(ss,restoredApi);val restoredView=restored.open()!!
 check(restored.state.value.playlist==null);restored.loadPlaylist(restoredView,ImportJobId(receipt.job!!))!!()
 var restoredId=0L;check(restored.openPlaylist(restoredView,restored.state.value.playlist!!){restoredId=it});check(restoredId==17L);check(aa.posts==1)
 val dropped=rr.startPlaylist(vv,source.url,"",500)!!;rr.close(vv);dropped();check(aa.posts==1)
 val fresh=rr.open()!!;aa.beforeReturn={throw SafeFailure(SafeFailure.Reason.Uncertain)}
 rr.startPlaylist(fresh,source.url,"",500)!!();check(rr.state.value.uncertain);check(rr.startPlaylist(fresh,source.url,"",500)==null)
 val original=Json.parseToJsonElement(BODY).jsonObject
 for(key in listOf("sourceTitle","error")) for(value in listOf(JsonNull,JsonPrimitive(7),JsonPrimitive(true),buildJsonObject{})) {
   check(runCatching {AcquisitionJson.playlist(JsonObject(original+(key to value)))}.exceptionOrNull() is SafeFailure)
 }
 for(value in listOf(JsonNull,JsonPrimitive(7),JsonPrimitive(true),buildJsonObject{})) {
   val rows=original.getValue("items").jsonArray
   val row=JsonObject(rows.last().jsonObject+("error" to value))
   check(runCatching {AcquisitionJson.playlist(JsonObject(original+("items" to JsonArray(listOf(rows.first(),row)))))}.exceptionOrNull() is SafeFailure)
 }
 val sensitive=BODY.replace("private video","download failed https://secret.test/token=abc")
 check(AcquisitionJson.playlist(Json.parseToJsonElement(sensitive).jsonObject).items.last().error=="The server could not import this source.")
 ss.scope=null;check(!restored.openPlaylist(restoredView,restored.state.value.playlist!!){error("logout admitted playlist navigation")})
 println("PASS bounded description, one-shot claim, receipt restoration, dropped work, uncertainty no-replay, malformed scalar, logout and secret-safe failures")
 rootReturnChecks()
 journal.parentFile.deleteRecursively()
}
'''.replace('CALL',call))
cache=gradle_cache()/'modules-2/files-2.1'
cp=os.pathsep.join(str(next(cache.glob(group+'/'+art+'/'+ver+'/*/*.jar'))) for group,art,ver in [('org.jetbrains.kotlinx','kotlinx-serialization-json-jvm','1.9.0'),('org.jetbrains.kotlinx','kotlinx-serialization-core-jvm','1.9.0'),('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.10.2'),('com.squareup.okhttp3','okhttp','4.12.0'),('com.squareup.okio','okio-jvm','3.6.0')])
src=[b/'data/acquisition'/f for f in ['AcquisitionContracts.kt','AcquisitionRepository.kt','IntakeReceipts.kt']]+list(o.glob('*.kt'))
c=subprocess.run(['kotlinc','-J-Xmx512m','-J-XX:ActiveProcessorCount=1',*map(str,src),'-cp',cp,'-include-runtime','-d',str(o/'check.jar')],capture_output=True,text=True);(o/'compile.log').write_text(c.stdout+c.stderr);print(c.stdout,c.stderr);assert c.returncode==0
p=subprocess.run(['java','-XX:ActiveProcessorCount=1','-Djava.io.tmpdir='+str(o),'-cp',str(o/'check.jar')+os.pathsep+cp,'com.soundq.android.data.CheckKt'],capture_output=True,text=True);(o/'runtime.log').write_text(p.stdout+p.stderr);print(p.stdout,p.stderr);raise SystemExit(p.returncode)
