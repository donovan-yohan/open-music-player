#!/usr/bin/env python3
"""Exact controller/resolver/source with real scoped TLS/filesystem downloads.
Android/Media3 boundary facades only. Mounted acceptance remains separate.
"""
from pathlib import Path
import argparse, ast, os
p=argparse.ArgumentParser();p.add_argument('--generate',type=Path,required=True);p.add_argument('--source',type=Path);a=p.parse_args()
r=a.source or Path(os.environ.get('SOUNDQ_DOWNLOAD_QUEUE_SOURCE',Path(__file__).resolve().parents[1]))
b=r/'app/src/main/kotlin/com/soundq/android'
def block(file,marker):
 t=(b/file).read_text();s=t.index(marker);e=t.index('{',s)+1;depth=1
 while depth:
  if t[e]=='{':depth+=1
  elif t[e]=='}':depth-=1
  e+=1
 return t[s:e]
tree=ast.parse((r/'scripts/test-device-play.py').read_text())
pre=next(ast.literal_eval(n.value) for n in tree.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='prelude' for t in n.targets))
# Preserve existing Android/Media3 boundary declarations, use real domain/store/TLS owners.
pre=pre[pre.index('class Bundle'):pre.index('interface TransferListener')]+ 'interface TransferListener\n'
pre=pre.replace('fun getLong(k:String)', 'fun getString(k:String)=fields[k] as? String;fun getLong(k:String)')
source=block('playback/SignedAudioDataSource.kt','    override fun open(').replace('override fun open','fun open')
resolve=block('playback/SoundQLibraryService.kt','    private fun resolve(').replace('private fun resolve','fun resolve')
enqueue=block('playback/ControllerProjection.kt','    fun enqueue(')
service_text=(b/'playback/SoundQLibraryService.kt').read_text()
undo_grants=service_text[service_text.index('            saved.forEach {item -> item.localConfiguration?.uri?.let {uri -> grants[uri.toString()]=MediaGrant(scope,TrackId(item.mediaMetadata.extras!!.getLong("trackId")),item.mediaMetadata.extras!!.getBoolean("localOnly"))}}'):].split('\n',1)[0]
vm=(b/'product/ProductViewModel.kt').read_text()
action=block('product/ProductViewModel.kt','    fun enqueueDownload(') if '    fun enqueueDownload(' in vm else ''
quick=vm[vm.index('    fun quickQueueDownload('):vm.index('    val queueSettings=',vm.index('    fun quickQueueDownload('))] if '    fun quickQueueDownload(' in vm else ''
code=r'''package com.soundq.android.downloadqueuefixture
import com.soundq.android.data.*
import com.soundq.android.data.offline.*
import com.soundq.android.data.preferences.*
import com.soundq.android.playback.QueuePolicy
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.nio.file.Files
object C {const val LENGTH_UNSET=-1}
'''+pre+r'''
class CacheWrite
class TemporaryCache {var calls=0;fun acquire(s:AccountScope,t:TrackId):LocalAudioLease?{calls++;error("Temporary cache forbidden")};fun begin(s:AccountScope,t:TrackId,n:Long):CacheWrite?=error("cache write out of scope")}
class StoragePreferences {class State {val temporaryAudioEnabled=true};class Value {val value=State()};val state=Value()}
class OkHttpDataSource(private val client:okhttp3.OkHttpClient):DataSource {
 class Factory(val c:okhttp3.OkHttpClient){fun createDataSource()=OkHttpDataSource(c)}
 fun addTransferListener(l:TransferListener){}
 override fun open(s:DataSpec):Long=client.newCall(okhttp3.Request.Builder().url(s.uri.toString()).build()).execute().use {check(it.code==200);it.body.bytes().size.toLong()}
 override fun close(){}
}
object HttpDataSource {class InvalidResponseCodeException(val responseCode:Int):Exception()}
class Graph(val session:AccountSession,val downloads:DeviceDownloads,val api:SoundQApi,val mediaClient:okhttp3.OkHttpClient,val swipeQueuePreferences:SwipeQueuePreferences){
 val temporaryAudio=TemporaryCache();val storagePreferences=StoragePreferences();val known=mutableMapOf<TrackId,Track>()
 fun rememberTracks(t:List<Track>){t.forEach{known[it.id]=it}};fun track(id:TrackId)=known[id]
}
class MediaGrant(val scope:AccountScope,val track:TrackId,val localOnly:Boolean=false)
class Source(val graph:Graph,val grants:ConcurrentHashMap<String,MediaGrant>){var grant:MediaGrant?=null;var internalUri:Uri?=null;var upstream:DataSource?=null;var local:LocalAudioLease?=null;var remaining=0L;var writing:CacheWrite?=null;var expectedCacheBytes=0L;var readCacheBytes=0L;val listeners=mutableListOf<TransferListener>()
SOURCE
}
class Service(val graph:Graph){fun validateSelection(items:List<MediaItem>,index:Int,position:Long){};fun supportsSourceActions()=true;val grants=ConcurrentHashMap<String,MediaGrant>()
RESOLVE
}
class Facade(val service:Service){
 val items=mutableListOf<MediaItem>();val mediaItemCount get()=items.size;var currentMediaItemIndex=0;var position=2300L;var playing=false
 val prepareCalls=0;val playCalls=0;var addThread=""
 fun getMediaItemAt(i:Int)=items[i]
 fun addMediaItem(i:Int,m:MediaItem){addThread=Thread.currentThread().name;items.addAll(i,service.resolve(listOf(m)))}
}
class Controller(val controller:Facade?){
 var contextIntent=0L
ENQUEUE
 // Same consuming fixture accepts the predecessor's existing two-argument ABI.
 fun device(track:Track,next:Boolean){val m=javaClass.declaredMethods.single{it.name=="enqueue"};if(m.parameterCount==3)m.invoke(this,track,next,true) else m.invoke(this,track,next)}
}
class Model(val graph:Graph,val controller:Controller):AutoCloseable {
 val dispatcher=Executors.newSingleThreadExecutor{r->Thread(r,"download-queue-main")}.asCoroutineDispatcher()
 val viewModelScope=CoroutineScope(SupervisorJob()+dispatcher)
ACTION
QUICK
 suspend fun drain(){withContext(dispatcher){};viewModelScope.coroutineContext[Job]!!.children.toList().forEach{it.join()}}
 fun request(scope:AccountScope,row:DeviceDownload,valid:()->Boolean,next:Boolean=false,quick:Boolean=false){val name=if(quick)"quickQueueDownload" else "enqueueDownload";javaClass.declaredMethods.singleOrNull{it.name==name}?.let {m->if(quick)m.invoke(this,scope,row,valid) else m.invoke(this,scope,row,valid,next)}}
 override fun close(){viewModelScope.cancel();dispatcher.close()}
}
internal class Fixture:AutoCloseable {
 val tls=HttpsFixture();val dir=Files.createTempDirectory("download-queue").toFile()
 val session=AccountSession(tls.endpoint,MemoryStore()).also{it.accept(it.beginIntent(),SecretTokens("a","r","fixture"))};var scope=session.capture()!!
 val api=SoundQApi(session,tls.client);val downloads=DeviceDownloads(dir.resolve("downloads"),session,api,tls.client).also{it.load(scope)}
 val pref=SwipeQueuePreferences(dir.resolve("swipe")).also{it.load()};val graph=Graph(session,downloads,api,tls.client,pref);val service=Service(graph);val facade=Facade(service);val controller=Controller(facade);val model=Model(graph,controller)
 val track=Track(TrackId(7),"Device","Fixture",durationMs=1000,artwork=tls.server.url("/must-not-artwork").toString())
 val bytes=java.nio.ByteBuffer.allocate(32044).order(java.nio.ByteOrder.LITTLE_ENDIAN).apply {put("RIFF".toByteArray());putInt(32036);put("WAVEfmt ".toByteArray());putInt(16);putShort(1);putShort(1);putInt(16000);putInt(32000);putShort(2);putShort(16);put("data".toByteArray());putInt(32000);repeat(16000){putShort((it%200).toShort())}}.array()
 fun complete(){tls.reply("""{"urls":[{"trackId":7,"url":"${tls.server.url("/media/copy.wav")}","expiresAt":"2030-01-01T00:00:00Z","contentType":"audio/wav","sizeBytes":${bytes.size}}]}""");tls.server.enqueue(mockwebserver3.MockResponse.Builder().body(okio.Buffer().write(bytes)).build());downloads.transfer(downloads.claim(scope,track){true}!!);assertEquals(DownloadStatus.Complete,row().status);graph.rememberTracks(listOf(track));assertEquals(2,tls.server.requestCount)}
 fun row()=downloads.state.value.rows.single()
 fun file()=dir.walkTopDown().single{it.extension=="audio"}
 fun index()=dir.walkTopDown().single{it.name=="index.v1.json"}
 fun seed(){for((id,manual) in listOf(1L to false,2L to true,3L to false)){val t=Track(TrackId(id),"old-$id");graph.rememberTracks(listOf(t));facade.items+=service.resolve(listOf(MediaItem.Builder().setMediaId("$id").setRequestMetadata(MediaItem.RequestMetadata.Builder().setExtras(Bundle().apply{putBoolean("manual",manual)}).build()).build()))}}
 fun ids()=facade.items.map{it.mediaMetadata.extras!!.getLong("trackId")}
 override fun close(){model.close();tls.close();dir.deleteRecursively()}
}
class DownloadQueueExtractedTest {
 @Test fun actualViewModelActionAdmitsOwnedCopyAndRevalidatesOriginalLifetime()=runBlocking {Fixture().use {f->
  f.complete();f.seed();val row=f.row()
  f.model.request(f.scope,row,{true});f.model.drain()
  assertEquals("Completed Downloads callback must enqueue through MediaController",listOf(1L,2L,7L,3L),f.ids())
  assertTrue(f.facade.items[2].mediaMetadata.extras!!.getBoolean("localOnly"));assertFalse(f.facade.playing)
  assertTrue(f.pref.setMode(f.pref.capture()!!,SwipeQueue.PlayNext){true})
  f.model.request(f.scope,row,{true},quick=true);f.model.drain();assertEquals(listOf(1L,7L,2L,7L,3L),f.ids())
  f.model.request(f.scope,row.copy(),{true});f.model.request(f.scope,row,{false});f.model.drain();assertEquals(5,f.facade.mediaItemCount)
  // Final dispatch must recheck the original lifetime after the off-main custody read.
  var checks=0;f.model.request(f.scope,row,{checks++;checks<3});f.model.drain();assertEquals(5,f.facade.mediaItemCount)
  assertEquals(2,f.tls.server.requestCount)
 }}
 @Test fun actualControllerServiceSourceRetainsLocalOnlyWithoutAutoplayOrFallback()=Fixture().use {f->
  f.complete();f.seed();val old=f.facade.items.toList();f.facade.playing=true
  f.controller.device(f.track,false)
  assertEquals(listOf(1L,2L,7L,3L),f.ids());val added=f.facade.items[2]
  assertTrue("Downloads enqueue lost localOnly before service resolution",added.mediaMetadata.extras!!.getBoolean("localOnly"));assertNull(added.mediaMetadata.artwork)
  assertTrue(added.mediaMetadata.extras!!.getBoolean("manual"));assertEquals("Manual",added.mediaMetadata.extras!!.getString("origin"));assertTrue(f.service.grants[added.localConfiguration!!.uri.toString()]!!.localOnly)
  assertEquals(old,listOf(f.facade.items[0],f.facade.items[1],f.facade.items[3]));assertTrue(f.facade.playing);assertEquals(2300L,f.facade.position);assertEquals(0,f.facade.currentMediaItemIndex);assertEquals(0,f.facade.prepareCalls);assertEquals(0,f.facade.playCalls)
  val s=Source(f.graph,f.service.grants);assertEquals(f.bytes.size.toLong(),s.open(DataSpec(added.localConfiguration!!.uri)));s.local!!.use {val actual=ByteArray(f.bytes.size);assertEquals(actual.size,it.read(actual,0,actual.size));assertArrayEquals(f.bytes,actual)}
  f.facade.playing=false;f.controller.device(f.track,true);assertEquals(listOf(1L,7L,2L,7L,3L),f.ids());assertNotEquals(added.mediaId,f.facade.items[1].mediaId);assertFalse(f.facade.playing)
  f.file().delete();assertTrue(runCatching{Source(f.graph,f.service.grants).open(DataSpec(added.localConfiguration!!.uri))}.exceptionOrNull() is SafeFailure)
  val saved=listOf(added);val scope=f.scope;val grants=f.service.grants;grants.clear()
UNDO_GRANTS
  assertTrue(grants[added.localConfiguration!!.uri.toString()]!!.localOnly)
  assertTrue(runCatching{Source(f.graph,grants).open(DataSpec(added.localConfiguration!!.uri))}.exceptionOrNull() is SafeFailure)
  assertEquals(0,f.graph.temporaryAudio.calls);assertEquals(2,f.tls.server.requestCount)
 }
 @Test fun invalidCustodyAndRejectedIndexesCannotEnqueueOrRewriteBytes()=runBlocking {
  for(kind in listOf("missing","corrupt","foreign","external","future","rejected"))Fixture().use {f->
   f.complete();val row=f.row();val index=f.index();val file=f.file();val audio=file.readBytes()
   when(kind){
    "missing"->file.delete()
    "corrupt"->file.writeBytes(ByteArray(audio.size){42})
    "foreign"->{val foreign=file.parentFile.resolve("00000000-0000-0000-0000-000000000001.audio");foreign.writeBytes(audio);index.writeText(index.readText().replace(file.name,foreign.name))}
    "external"->index.appendText(" ")
    "future"->index.writeText(index.readText().replace("\"version\":1","\"version\":99"))
    else->{index.writeText("{");f.downloads.load(f.scope)}
   }
   val before=index.readBytes();f.model.request(f.scope,row,{true});f.model.drain()
   assertEquals(kind,0,f.facade.mediaItemCount);assertArrayEquals(before,index.readBytes());assertEquals(2,f.tls.server.requestCount)
   if(kind=="foreign")assertTrue(file.parentFile.resolve("00000000-0000-0000-0000-000000000001.audio").exists())
  }
 }
 @Test fun deviceOnlyIdentityIsAdmittedButRetiredAccountAndRowAbaAreNot()=runBlocking {Fixture().use {f->
  f.complete();val old=f.row();val oldScope=f.scope
  f.session.failure(f.session.beginIntent(),SafeFailure.Reason.Network);assertTrue(f.session.useDeviceDownloads());f.scope=f.session.capture()!!;f.downloads.load(f.scope)
  assertFalse(f.session.remoteCurrent(f.scope));assertEquals(DownloadStatus.Complete,f.row().status)
  f.model.request(oldScope,old,{true});f.model.request(f.scope,old,{true});f.model.drain();assertEquals(0,f.facade.mediaItemCount)
  f.model.request(f.scope,f.row(),{true});f.model.drain();assertEquals(1,f.facade.mediaItemCount);assertTrue(f.facade.items.single().mediaMetadata.extras!!.getBoolean("localOnly"))
  val current=f.row();var checks=0
  f.model.request(f.scope,current,{checks++;if(checks==3)f.downloads.retire();true});f.model.drain();assertEquals(1,f.facade.mediaItemCount)
  assertEquals(2,f.tls.server.requestCount)
 }}
 @Test fun validationRunsOffCallerAndFinalDispatchRunsOnOwnerDispatcher()=runBlocking {Fixture().use {f->
  f.complete();val threads=java.util.concurrent.CopyOnWriteArrayList<String>()
  f.model.request(f.scope,f.row(),{threads.add(Thread.currentThread().name);true});f.model.drain()
  assertEquals(1,f.facade.mediaItemCount);assertTrue(threads.any{it.contains("DefaultDispatcher")});assertEquals("download-queue-main",f.facade.addThread.substringBefore(" @coroutine"))
 }}
 @Test fun bothDestinationsKeepQueueCapAndEmptyQueueDoesNotStart()=Fixture().use {f->
  f.complete();f.controller.device(f.track,false);assertEquals(1,f.facade.mediaItemCount);assertFalse(f.facade.playing)
  while(f.facade.mediaItemCount<QueuePolicy.MAX_CONTEXT_TRACKS)f.controller.enqueue(f.track,false)
  val before=f.facade.items.toList();f.controller.device(f.track,false);f.controller.device(f.track,true)
  assertEquals(before,f.facade.items);assertEquals(0,f.facade.prepareCalls);assertEquals(0,f.facade.playCalls);assertEquals(2,f.tls.server.requestCount)
 }
 @Test fun ordinaryLibraryEnqueueKeepsLocalFirstAndRemoteFallback()=Fixture().use {f->
  f.complete();f.controller.enqueue(f.track,false);val m=f.facade.items.single();assertFalse(m.mediaMetadata.extras!!.getBoolean("localOnly"));assertNotNull(m.mediaMetadata.artwork)
  val s=Source(f.graph,f.service.grants);assertEquals(f.bytes.size.toLong(),s.open(DataSpec(m.localConfiguration!!.uri)));s.local!!.close();assertEquals(2,f.tls.server.requestCount)
  f.file().delete()
  // Generic remote fallback remains permitted; temporary cache is intentionally disabled in this control.
  f.tls.reply("""{"urls":[{"trackId":7,"url":"${f.tls.server.url("/media/fallback.wav")}","expiresAt":"2030-01-01T00:00:00Z","contentType":"audio/wav","sizeBytes":${f.bytes.size}}]}""");f.tls.server.enqueue(mockwebserver3.MockResponse.Builder().body(okio.Buffer().write(f.bytes)).build())
  val remote=Source(f.graph,f.service.grants);assertEquals(f.bytes.size.toLong(),remote.open(DataSpec(m.localConfiguration!!.uri)));assertNotNull(remote.upstream);assertEquals(4,f.tls.server.requestCount)
 }
}
'''
# Remote control disables temporary cache, while the local-only path still proves no calls.
code=code.replace('val temporaryAudioEnabled=true','var temporaryAudioEnabled=true').replace('f.file().delete()\n  // Generic','f.file().delete();f.graph.storagePreferences.state.value.temporaryAudioEnabled=false\n  // Generic')
for key,value in [('SOURCE',source),('RESOLVE',resolve),('ENQUEUE',enqueue),('ACTION',action),('QUICK',quick),('UNDO_GRANTS',undo_grants)]:code=code.replace(key,value)
a.generate.mkdir(parents=True,exist_ok=True);(a.generate/'DownloadQueueExtractedTest.kt').write_text(code)
ui=(b/'product/offline/DownloadsScreen.kt').read_text()
if '            val lifetime=' in ui:
 start=ui.index('            val lifetime=');end=ui.index('            var menu',start) if '            var menu' in ui[start:] else ui.index('            Column(',start)
 binding=ui[start:end]
 header=ui[ui.index('SoundQSwipeQueue(',end):].split(' {front,',1)[0]
 # Selection paint is outside this ownership extraction; native tests cover it.
 binding+='\nval current=false\n'+header+' {_,_->}\n'
else:binding=''
(a.generate/'DownloadsQueueBindingExtractedTest.kt').write_text('''package com.soundq.android.downloadqueuefixture
import com.soundq.android.data.offline.*
import com.soundq.android.product.LibraryRowLifetime
import com.soundq.designsystem.*
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
private class Driver {var quick:()->Unit={};var explicit:()->Unit={}}
private lateinit var driver:Driver
private fun <T> remember(vararg keys:Any?,block:()->T):T=block()
private fun SoundQSwipeQueue(title:String,state:RowRevealState,enabled:Boolean,onQueue:()->Unit,explicitQueue:()->Unit,current:Boolean=false,content:(Unit,()->Boolean)->Unit){driver.quick={if(enabled)onQueue()};driver.explicit={if(enabled)explicitQueue()}}
class DownloadsQueueBindingExtractedTest {
 @Test fun actualCompletedRowBindingQueuesAndRetainedCallbacksRetire()=runBlocking {Fixture().use {f->
  f.complete();val model=f.model;val scope=f.scope;val row=f.row();val state=f.downloads.state.value;val valid={true};val revealOwner=RowRevealOwner();driver=Driver()
BINDING
  driver.quick();model.drain();assertEquals("Full-left callback must reach the existing controller",listOf(7L),f.ids())
  driver.explicit();model.drain();assertEquals(listOf(7L,7L),f.ids());assertFalse(f.facade.playing)
  lifetime.close();driver.quick();driver.explicit();model.drain();assertEquals(2,f.facade.mediaItemCount)
 }}
}
'''.replace('BINDING',binding.replace('com.soundq.android.product.rememberTrackRowLifetime(com.soundq.android.product.RowIdentity(row))','LibraryRowLifetime {true}') if binding else 'val lifetime=LibraryRowLifetime {true}'))
