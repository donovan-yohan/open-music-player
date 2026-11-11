#!/usr/bin/env python3
"""Generate byte-exact service callback and pinned Media3 task host regressions.

Only Android player/Bundle/session boundaries are facades. AccountSession,
SoundQApi, TLS, JSON, coroutine IO and Guava futures are real. The consuming
Media3 task and request-admission method are extracted from verified 1.11.1
sources; no selection-generation implementation is copied into the fixture.
"""
import argparse
import hashlib
import json
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1])
p.add_argument('--media3', type=Path, required=True)
p.add_argument('--generate', type=Path, required=True)
a = p.parse_args()
base = a.source / 'app/src/main/kotlin/com/soundq/android'
stub = a.media3 / 'media3-session/androidx/media3/session/MediaSessionStub.java'
assert hashlib.sha256(stub.read_bytes()).hexdigest() == 'e7f02f75d50ee59312f38f820b5a9bbc05cc75086f14b4411c83fdee124bcffc'

def block(text, marker):
    start = text.index(marker)
    opening = text.index('{', text.index('){',start)) if marker=='    fun playPlaylist(' else text.index('{', start)
    depth, i = 1, opening + 1
    while depth:
        depth += (text[i] == '{') - (text[i] == '}')
        i += 1
    return text[start:i]

service = (base / 'playback/SoundQLibraryService.kt').read_text()
projection = (base / 'playback/ControllerProjection.kt').read_text()
callbacks = '\n'.join(block(service, m).replace('override fun', 'fun', 1) for m in (
    '        override fun onPlayerCommandRequest(', '        override fun onCustomCommand('))
next_action = block(projection, '    fun next(')
undo_action = block(projection, '    fun undo(').replace('SoundQLibraryService.UNDO', 'UNDO')
seek_action = block(projection, '    fun seek(')
play_mix_action=block(projection,'    fun playMix(').replace('SoundQLibraryService.PLAY_MIX','PLAY_MIX')
playlist_action=block((base/'product/ProductViewModel.kt').read_text(),'    fun playPlaylist(')
blend_actions='\n'.join(block((base/'product/ProductViewModel.kt').read_text(),m) for m in ('    fun generatePlaylistBlend(', '    fun recoverPlaylistBlend('))
# Dispatchers.IO is the only scheduling boundary replaced by a held dispatcher.
blend_actions=blend_actions.replace('Dispatchers.IO','dispatcher')
text = stub.read_text()
markers = [
    '  private void queueSessionTaskWithPlayerCommand(',
    '  public void seekToNextMediaItem(', '  public void seekToPreviousMediaItem(',
    '  public void seekBack(', '  public void seekForward(',
    '  public void seekBackForControllerInfo(', '  public void seekForwardForControllerInfo(',
    '  public void seekToDefaultPosition(', '  public void seekTo(',
    '  public void seekToNextForControllerInfo(', '  public void seekToPreviousForControllerInfo(',
]
methods = '\n'.join(block(text, m).replace('@Nullable ', '').replace('@Player.Command ', '') for m in markers)
# These overloads are unchanged generic success continuations from the pin.
start = text.index('  private static <K extends MediaSessionImpl>\n      SessionTask<ListenableFuture<Void>, K> sendSessionResultSuccess(')
end = text.index('  private static <K extends MediaSessionImpl>\n      SessionTask<ListenableFuture<Void>, K> sendSessionResultWhenReady(', start)
methods += '\n' + text[start:end]
java = '''package com.soundq.android.mixselection;
import static androidx.media3.common.Player.*;
import com.google.common.util.concurrent.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.*;
public class PinnedCommandQueue {
 static final int ERROR_PERMISSION_DENIED=-4;
 public interface IMediaController {}
 public static class ControllerInfo implements IMediaController {}
 public interface PlayerWrapper extends Player {
  void seekToNextMediaItem(); void seekToPreviousMediaItem(); void seekBack(); void seekForward();
  void seekToDefaultPosition(); void seekTo(long position); void seekToNext(); void seekToPrevious();
 }
 static class SessionResult { @interface Code {} static final int RESULT_SUCCESS=0; final int code; SessionResult(int c){code=c;}}
 interface Player {
  void seekToNextMediaItem(); void seekToPreviousMediaItem(); void seekBack(); void seekForward();
  void seekToDefaultPosition(); void seekTo(long position); void seekToNext(); void seekToPrevious();
 }
 interface SessionTask<T,K> {T run(K session,ControllerInfo controller,int seq);}
 interface ControllerPlayerTask {void run(PlayerWrapper player,ControllerInfo controller);}
 public static class MediaSessionImpl {
  final PlayerWrapper player; final IntUnaryOperator callback;
  MediaSessionImpl(PlayerWrapper p,IntUnaryOperator c){player=p;callback=c;}
  boolean isReleased(){return false;} PlayerWrapper getPlayerWrapper(){return player;}
  int onPlayerCommandRequestOnHandler(ControllerInfo c,int command){return callback.applyAsInt(command);}
  Runnable callWithControllerForCurrentRequestSet(ControllerInfo c,Runnable r){return r;}
 }
 static class Manager {
  final ArrayDeque<Supplier<ListenableFuture<Void>>> tasks=new ArrayDeque<>();
  boolean isConnected(ControllerInfo c){return true;}
  boolean isPlayerCommandAvailable(ControllerInfo c,int cmd){return true;}
  void addToCommandQueue(ControllerInfo c,int cmd,Supplier<ListenableFuture<Void>> task){tasks.add(task);}
 }
 final AtomicReference<MediaSessionImpl> sessionImpl;
 final Manager connectedControllersManager=new Manager();
 final ControllerInfo controller=new ControllerInfo();
 public PinnedCommandQueue(PlayerWrapper player,IntUnaryOperator callback){sessionImpl=new AtomicReference<>(new MediaSessionImpl(player,callback));}
 void verifyApplicationThread(){}
 interface PlayerCommandTask {void run(ControllerInfo controller,int seq);}
 void dispatchPlayerCommand(IMediaController c,int seq,PlayerCommandTask task){task.run((ControllerInfo)c,seq);}
 static void sendSessionResult(MediaSessionImpl s,ControllerInfo c,int seq,SessionResult r){}
 void dispatchAndQueueSessionTaskWithPlayerCommand(IMediaController c,int seq,int cmd,SessionTask<ListenableFuture<Void>,MediaSessionImpl> task){queueSessionTaskWithPlayerCommand((ControllerInfo)c,seq,cmd,task);}
 // Synchronous task subset of ConnectedControllersManager 381-405: run admitted
 // consuming tasks in FIFO order. No pending custom-command future is enqueued.
 public void flush() throws Exception {
  while(!connectedControllersManager.tasks.isEmpty()) {
   ListenableFuture<Void> future=connectedControllersManager.tasks.remove().get();
   if(!future.isDone())throw new AssertionError("Unexpected async player task"); future.get();
  }
 }
 public int queued(){return connectedControllersManager.tasks.size();}
 public void next(){seekToNextMediaItem(controller,1);}
 public void previousItem(){seekToPreviousMediaItem(controller,2);}
 public void back(){seekBack(controller,3);}
 public void forward(){seekForward(controller,4);}
 public void defaultPosition(){seekToDefaultPosition(controller,5);}
 public void seek(long position){seekTo(controller,6,position);}
 public void nextGeneric(){seekToNextForControllerInfo(controller,7);}
 public void previousGeneric(){seekToPreviousForControllerInfo(controller,8);}
''' + methods + '\n}\n'
prelude = '''package com.soundq.android.mixselection
import com.soundq.android.data.*
import com.soundq.android.data.mix.*
import com.soundq.android.playback.MediaGrant
import com.soundq.android.playback.ArrangementIdentity
import com.soundq.android.playback.AcceptedArrangement
import com.soundq.android.playback.arrangementPlan
import com.soundq.android.playback.arrangementMetadata
import com.soundq.android.data.timeline.TimelineDocument
import com.soundq.android.data.timeline.matchesOccurrences
import com.soundq.android.data.timeline.globalEndMs
import com.soundq.android.data.timeline.sourceAt
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.encodeToString
import com.google.common.util.concurrent.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger
import mockwebserver3.*
import okhttp3.OkHttpClient
import okhttp3.tls.*

private const val UNDO="soundq.queue.undo"
private const val PLAY_MIX="soundq.mix.play"
private const val JAM_ADMIT="soundq.jam.admit"
private const val APPLY_ARRANGEMENT="soundq.arrangement.apply"
private const val RETURN_SOURCES="soundq.arrangement.sources"
private const val LIKE="soundq.library.like."
private class Bundle {
 private val fields=mutableMapOf<String,Any>()
 fun putLong(k:String,v:Long){fields[k]=v}; fun getLong(k:String,default:Long=0L)=fields[k] as? Long ?: default
 fun putString(k:String,v:String){fields[k]=v}; fun getString(k:String)=fields[k] as? String
 fun putBoolean(k:String,v:Boolean){fields[k]=v}; fun getBoolean(k:String)=fields[k] as? Boolean ?: false
 companion object {val EMPTY=Bundle()}
}
private class Uri private constructor(val raw:String) {
 val scheme get()=raw.substringBefore(':'); override fun toString()=raw
 companion object {fun parse(v:String)=Uri(v)}
}
private class MediaMetadata {
 var title="";var extras:Bundle?=null
 class Builder {private val m=MediaMetadata();fun setTitle(v:String)=apply{m.title=v};fun setArtist(v:String)=this;fun setIsPlayable(v:Boolean)=this;fun setIsBrowsable(v:Boolean)=this;fun setExtras(v:Bundle)=apply{m.extras=v};fun build()=m}
}
private class MediaItem {
 class RequestMetadata {class Builder {fun setExtras(v:Bundle)=this;fun build()=RequestMetadata()}}
 class LocalConfiguration(val uri:Uri)
 var mediaId="";var localConfiguration:LocalConfiguration?=null;var mediaMetadata=MediaMetadata()
 class Builder {private val m=MediaItem();fun setMediaId(v:String)=apply{m.mediaId=v};fun setUri(v:Uri)=apply{m.localConfiguration=LocalConfiguration(v)};fun setMimeType(v:String)=this;fun setMediaMetadata(v:MediaMetadata)=apply{m.mediaMetadata=v};fun setRequestMetadata(v:RequestMetadata)=this;fun build()=m}
}
private typealias Player=androidx.media3.common.Player
private object SessionError {const val ERROR_NOT_SUPPORTED=-6;const val ERROR_PERMISSION_DENIED=-4;const val ERROR_BAD_VALUE=-3;const val ERROR_INVALID_STATE=-2}
private class SessionResult(val resultCode:Int,val extras:Bundle=Bundle()) {companion object {const val RESULT_SUCCESS=0}}
private class SessionCommand(val customAction:String,val extras:Bundle)
private class MediaSession {class ControllerInfo;var extras=Bundle.EMPTY;fun setSessionExtras(b:Bundle){extras=b}}
// Additional unrelated service boundaries. Jam insertion is separately exercised
// by its exact-body probe; entering it here is an error, never a synthetic success.
private class JamPort {fun refused(id:String){};fun consumeWithProvenance(id:String,insert:(Track,com.soundq.android.data.jam.JamOccurrence?,Boolean)->String):Boolean=error("Jam outside mix-selection fixture")}
private object QueuePolicy {const val MAX_CONTEXT_TRACKS=500;fun acceptsAppend(n:Int,a:Int)=com.soundq.android.playback.QueuePolicy.acceptsAppend(n,a);fun manualInsert(v:List<Boolean>,i:Int)=i+1}
private class TimelineFacade {
 fun cancelAudition(){}
 fun admitsAudition(id:String,scope:AccountScope,document:TimelineDocument):Boolean=error("Arrangement outside mix-selection fixture")
 fun installAudition(id:String,scope:AccountScope,document:TimelineDocument,install:()->Unit):Boolean=error("Arrangement outside mix-selection fixture")
}
private class ContextStartsBoundary {fun retire(){}}
private class Graph(val session:AccountSession,val api:SoundQApi){val contextStarts=ContextStartsBoundary();
 val directory=java.nio.file.Files.createTempDirectory(java.io.File(System.getenv("TMPDIR")!!).toPath(),"blend-consumer-").toFile()
 lateinit var mediaClient:OkHttpClient
 val downloads by lazy {com.soundq.android.data.offline.DeviceDownloads(java.io.File(directory,"downloads"),session,api,mediaClient)}
 val playlistDetail=com.soundq.android.data.playlists.PlaylistDetailRepository(api);val playlistBlend by lazy {com.soundq.android.data.playlists.PlaylistBlendRepository(api,playlistDetail,downloads)};val timeline=TimelineFacade();val jamAdmission=JamPort();fun rememberTracks(v:List<Track>){}}
private class Interruptions {fun command(){}}
private class TransportFacade(private val player:PlayerFacade){fun rejectSelection(){player.pause()};fun selectionCommitted(){};fun retire(){};fun pause(){player.pause()}}
private class PlayerFacade: PinnedCommandQueue.PlayerWrapper {
 var items=listOf<MediaItem>();var currentMediaItemIndex=0;var currentPosition=0L
 val mediaItemCount get()=items.size
 val currentMediaItem get()=items.getOrNull(currentMediaItemIndex)
 fun addMediaItem(index:Int,item:MediaItem){items=items.toMutableList().also{it.add(index,item)}}
 var playing=false;var ready=false;var replacements=0;var plays=0;var pauses=0
 fun getMediaItemAt(i:Int)=items[i]
 fun pause(){pauses++;playing=false}
 fun clearMediaItems(){items=emptyList();currentMediaItemIndex=0;currentPosition=0;replacements++;ready=false}
 fun setMediaItems(v:List<MediaItem>,index:Int,position:Long){items=v;currentMediaItemIndex=index;currentPosition=position;replacements++;ready=false}
 fun setMediaItem(v:MediaItem)=setMediaItems(listOf(v),0,0)
 var load:(()->Unit)?=null
 fun prepare(){load?.invoke();ready=true}
 fun play(){check(ready);playing=true;plays++}
 override fun seekToNextMediaItem(){if(currentMediaItemIndex<items.lastIndex){currentMediaItemIndex++;currentPosition=0}}
 override fun seekToPreviousMediaItem(){if(currentMediaItemIndex>0){currentMediaItemIndex--;currentPosition=0}}
 override fun seekBack(){currentPosition=(currentPosition-5000).coerceAtLeast(0)}
 override fun seekForward(){currentPosition+=5000}
 override fun seekToDefaultPosition(){currentPosition=0}
 override fun seekTo(position:Long){currentPosition=position}
 override fun seekToNext()=seekToNextMediaItem()
 override fun seekToPrevious(){if(currentPosition>3000)currentPosition=0 else seekToPreviousMediaItem()}
}
private class ExtractedService(val graph:Graph,val player:PlayerFacade,val jobs:CoroutineScope) {
  fun validateSelection(items:List<MediaItem>,index:Int,position:Long){}
 fun supportsSourceActions()=true // Ordinary-source facade. Bounded policy executes with real service tests.
 var pendingArrangement:Pair<AcceptedArrangement,Long>?=null;var acceptedArrangement:AcceptedArrangement?=null;var arrangementItems:List<MediaItem>?=null
 val serviceIncarnation="outside-arrangement";val sourceQueueIncarnation="outside-arrangement"
 fun sourceOccurrences():List<com.soundq.android.playback.QueueOccurrence> = error("Arrangement outside mix-selection fixture")
 fun arrangementCurrent(accepted:AcceptedArrangement):Boolean=error("Arrangement outside mix-selection fixture")
 fun retireArrangement():Unit=error("Arrangement outside mix-selection fixture")
 private val continuation=object {fun command(){}}
 val interruptions=Interruptions();val transport=TransportFacade(player)
 fun own(c:MediaSession.ControllerInfo)=true
 fun admitted(c:MediaSession.ControllerInfo)=true
 fun publishSessionExtras(){}
 fun likeCommand(c:MediaSession.ControllerInfo,v:SessionCommand):ListenableFuture<SessionResult> = error("Like outside mix-selection fixture")
 fun resolve(items:List<MediaItem>):List<MediaItem> = error("Jam resolution outside mix-selection fixture")
 val grants=ConcurrentHashMap<String,MediaGrant>()
 val mixGrants=ConcurrentHashMap<String,com.soundq.android.playback.mix.MixGrant>()
 var selectionEpoch=0L;val mixLoads=AtomicInteger();var account=graph.session.capture()
 var undo:List<MediaItem>?=null;var undoScope:AccountScope?=null;var undoIndex=0;var undoPosition=0L;var saveJob:Job?=null
'''
fixture = '''
}
private class ControllerFacade(val h:Harness) {
 val duration=90000L
 fun seekTo(position:Long)=h.queue.seek(position)
 fun seekToNextMediaItem()=h.queue.next()
 fun sendCustomCommand(command:SessionCommand,args:Bundle)=h.service.onCustomCommand(h.session,h.info,command,args)
}
private class ExtractedActions(val controller:ControllerFacade?) {
''' + next_action + '\n' + undo_action + '\n' + seek_action + '''
}
private class ExtractedPlaylistController(private val controller:ControllerFacade?) {
 private var closed=false
 private val connection=object {fun accepts(c:ControllerFacade)=true}
 private val handler=object {fun post(r:Runnable){r.run()}}
 var plainCalls=0
 fun playContext(tracks:List<Track>,index:Int){plainCalls++}
''' + play_mix_action + '''
}
private class ExtractedPlaylistModel(val graph:Graph,val controller:ExtractedPlaylistController,val viewModelScope:CoroutineScope=CoroutineScope(Job()),val dispatcher:CoroutineDispatcher=Dispatchers.IO) {
''' + playlist_action + '\n' + blend_actions + '''
}
private class Store:SessionStore {
 var tokens:SecretTokens?=null
 override fun load(endpoint:ApiEndpoint)=tokens
 override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){this.tokens=tokens}
 override fun clear(){tokens=null}
}
private class Harness:AutoCloseable {
 val server=MockWebServer();val release=CountDownLatch(1);val entered=CountDownLatch(1)
 val main=Executors.newSingleThreadExecutor().asCoroutineDispatcher();val jobs=CoroutineScope(SupervisorJob()+main)
 val session=MediaSession();val info=MediaSession.ControllerInfo();val player=PlayerFacade()
 val graph:Graph;val service:ExtractedService;val queue:PinnedCommandQueue;val actions:ExtractedActions
 val id="00000000-0000-4000-8000-000000000001"
 init {
  val cert=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
  server.useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory())
  server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
   check(request.method=="GET");check(request.url.encodedPath=="/api/v1/mix-plans/$id");check(request.headers["Authorization"]=="Bearer synthetic-access")
   entered.countDown();check(release.await(10,TimeUnit.SECONDS))
   return MockResponse.Builder().code(200).body("""{"id":"$id","schemaVersion":1,"name":"Held mix","clips":[{"clipId":"c1","queueItemId":"o1","trackId":7,"sourceStartMs":0,"sourceEndMs":1000,"timelineStartMs":0,"gainDb":0,"pitchMode":"preserve","tempoPolicy":"volumeOnly"}],"version":1,"summary":{"clipCount":1,"trackIds":[7],"durationMs":1000},"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}""").build()
  }}
  server.start()
  val trust=HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
  val account=AccountSession(ApiEndpoint.parse(server.url("/api/v1").toString()),Store())
  check(account.accept(account.beginIntent(),SecretTokens("synthetic-access","synthetic-refresh","fixture")))
  val client=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
  graph=Graph(account,SoundQApi(account,client));graph.mediaClient=client
  seed(7);seed(9)

  service=ExtractedService(graph,player,jobs)
  player.load={player.currentMediaItem?.localConfiguration?.uri?.takeIf {it.scheme=="soundqmix"}?.let {uri ->
   MixDataSource(graph,service.mixGrants).let {source ->try {
    check(source.open(DataSpec(uri))>44);val header=ByteArray(44);check(source.read(header,0,44)==44);check(String(header,0,4)=="RIFF")
    val pcm=ByteArray(16);check(source.read(pcm,0,pcm.size)==pcm.size)
   }finally {source.close()}}
  }}
  queue=PinnedCommandQueue(player){cmd -> service.onPlayerCommandRequest(session,info,cmd)}
  actions=ExtractedActions(ControllerFacade(this))
  player.setMediaItems(listOf(item("A",1),item("B",2),item("C",3)),0,12000)
 }
 fun seed(id:Long,source:ByteArray=java.io.File(System.getenv("SOUNDQ_BLEND_SOURCE")).readBytes()) {
  val original=server.dispatcher
  server.dispatcher=object:Dispatcher(){override fun dispatch(r:RecordedRequest):MockResponse {
   if(r.url.encodedPath.startsWith("/media/")){check(r.headers["Authorization"]==null);return MockResponse.Builder().body(okio.Buffer().write(source)).build()}
   return MockResponse.Builder().body("""{"urls":[{"trackId":$id,"url":"${server.url("/media/$id.opus")}","expiresAt":"2030-01-01T00:00:00Z","contentType":"audio/opus","sizeBytes":${source.size}}]}""").build()
  }}
  val scope=graph.session.capture()!!;graph.downloads.load(scope)
  graph.downloads.transfer(graph.downloads.claim(scope,Track(TrackId(id),"Fixture",durationMs=2000)){true}!!)
  check(graph.downloads.state.value.rows.last().status==com.soundq.android.data.offline.DownloadStatus.Complete)
  server.dispatcher=original
 }
 fun item(id:String,track:Long)=MediaItem.Builder().setMediaId(id).setUri(Uri.parse("soundq://track/$track/$id")).setMediaMetadata(MediaMetadata.Builder().setTitle(id).setExtras(Bundle().apply{putLong("trackId",track)}).build()).build()
 fun <T> onMain(action:()->T):T=runBlocking {withContext(main){action()}}
 fun hold():ListenableFuture<SessionResult> {
  val f=onMain {service.onCustomCommand(session,info,SessionCommand(PLAY_MIX,Bundle.EMPTY),Bundle().apply {putString("planId",id);putLong("version",1)})}
  check(entered.await(5,TimeUnit.SECONDS));check(!f.isDone);return f
 }
 fun finish(f:ListenableFuture<SessionResult>):SessionResult {release.countDown();return f.get(5,TimeUnit.SECONDS)}
 override fun close(){release.countDown();runBlocking{jobs.coroutineContext[Job]!!.cancelAndJoin()};main.close();service.mixGrants.values.forEach {it.close()};server.close();graph.directory.deleteRecursively()}
}
class MixSelectionExtractedTest {
 private fun heldSeek(action:(Harness)->Unit,expectedIndex:Int,expectedPosition:Long,releaseBeforeFlush:Boolean=false) {
  Harness().use {h ->
   val f=h.hold();val replacements=h.player.replacements;val plays=h.player.plays
   h.onMain {action(h);assertEquals(1,h.queue.queued());assertFalse(f.isDone)}
   if(!releaseBeforeFlush)h.onMain {h.queue.flush();assertEquals(expectedIndex,h.player.currentMediaItemIndex);assertEquals(expectedPosition,h.player.currentPosition)}
   assertEquals("Superseded PLAY_MIX must refuse",SessionError.ERROR_BAD_VALUE,h.finish(f).resultCode)
   if(releaseBeforeFlush)h.onMain {h.queue.flush()}
   h.onMain {
    assertEquals(listOf("A","B","C"),h.player.items.map{it.mediaId});assertEquals(expectedIndex,h.player.currentMediaItemIndex);assertEquals(expectedPosition,h.player.currentPosition)
    assertEquals("No stale mixed-source grant",0,h.service.mixGrants.size);assertEquals(replacements,h.player.replacements);assertEquals(plays,h.player.plays);assertFalse(h.player.playing)
   }
  }
 }
 @Test fun heldMixCannotReplaceActualShippedNextAfterQueuedTask(){heldSeek({it.actions.next()},1,0)}
 @Test fun heldMixRetiresAtNextAdmissionBeforeQueuedTask(){heldSeek({it.actions.next()},1,0,true)}
 @Test fun heldMixCannotReplacePreviousMediaItem(){heldSeek({it.player.currentMediaItemIndex=1;it.queue.previousItem()},0,0)}
 @Test fun heldMixCannotReplaceSeekBack(){heldSeek({it.queue.back()},0,7000)}
 @Test fun heldMixCannotReplaceSeekForward(){heldSeek({it.queue.forward()},0,17000)}
 @Test fun heldMixCannotReplaceDefaultPosition(){heldSeek({it.queue.defaultPosition()},0,0)}
 @Test fun heldMixCannotReplaceShippedPositionSeek(){heldSeek({it.actions.seek(2345)},0,2345)}
 @Test fun heldMixCannotReplaceGenericNext(){heldSeek({it.queue.nextGeneric()},1,0)}
 @Test fun heldMixCannotReplaceGenericPrevious(){heldSeek({it.queue.previousGeneric()},0,0)}
 @Test fun acceptedUndoRestoresPausedQueueAndDefeatsHeldGet(){
  Harness().use {h ->
   val original=h.player.items
   h.onMain {
    assertEquals(0,h.service.onPlayerCommandRequest(h.session,h.info,Player.COMMAND_CHANGE_MEDIA_ITEMS))
    h.player.setMediaItems(listOf(h.item("Edited",4)),0,99);h.player.prepare();h.player.play()
   }
   val f=h.hold()
   h.onMain {h.actions.undo();assertEquals(original,h.player.items);assertEquals(12000L,h.player.currentPosition);assertFalse(h.player.playing)}
   val replacements=h.player.replacements;val plays=h.player.plays
   assertEquals(SessionError.ERROR_BAD_VALUE,h.finish(f).resultCode)
   h.onMain {assertEquals(original,h.player.items);assertEquals(12000L,h.player.currentPosition);assertFalse(h.player.playing);assertEquals(replacements,h.player.replacements);assertEquals(plays,h.player.plays);assertEquals(0,h.service.mixGrants.size);assertEquals(3,h.service.grants.size)}
  }
 }
 @Test fun tappedOccurrenceStartsAtFetchedClipStartWithoutReordering(){Harness().use {h ->
  val f=h.onMain {h.service.onCustomCommand(h.session,h.info,SessionCommand(PLAY_MIX,Bundle.EMPTY),Bundle().apply {putString("planId",h.id);putLong("version",1);putString("startOccurrence","missing-occurrence")})}
  assertTrue(h.entered.await(5,TimeUnit.SECONDS))
  val before=h.player.items
  assertEquals("An unmapped tapped occurrence must refuse before replacing the sole player",SessionError.ERROR_BAD_VALUE,h.finish(f).resultCode)
  h.onMain {assertSame(before,h.player.items);assertEquals(0,h.player.plays);assertEquals(0,h.service.mixGrants.size)}
 }}
 private fun preparePlaylist(h:Harness):com.soundq.android.data.playlists.PlaylistLaunch.Mixed {
  h.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
   check(request.headers["Authorization"]=="Bearer synthetic-access")
   val body=when(request.url.encodedPath){
    "/api/v1/playlists/41"->playlistDetail()
    "/api/v1/playlists/41/auto-mix"->{check(request.method=="POST");blendAck()}
    "/api/v1/mix-plans/$blendPlanId"->blendPlan()
    else->error("unexpected fixture path")
   }
   return MockResponse.Builder().code(200).body(body).build()
  }}
  h.graph.playlistDetail.open(com.soundq.android.data.playlists.PlaylistId(41))
  h.graph.playlistBlend.generate(h.graph.playlistBlend.capture()!!)!!()
  return h.graph.playlistBlend.launch(h.graph.playlistDetail.capturePlayback()!!,TrackId(7)) as com.soundq.android.data.playlists.PlaylistLaunch.Mixed
 }
 @Test fun productionViewModelControllerServiceChainStartsTappedAndNeverRetriesFailurePlain(){Harness().use {h ->
  preparePlaylist(h)
  val controller=ExtractedPlaylistController(ControllerFacade(h));val model=ExtractedPlaylistModel(h.graph,controller)
  h.onMain {model.playPlaylist(h.graph.playlistDetail.capturePlayback()!!,TrackId(7))}
  val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
  while(h.player.plays==0 && System.nanoTime()<deadline)Thread.sleep(5)
  h.onMain {assertEquals(115000L,h.player.currentPosition);assertEquals(0,controller.plainCalls)}
  h.server.dispatcher=object:Dispatcher(){override fun dispatch(r:RecordedRequest)=MockResponse.Builder().code(503).body("{}").build()}
  h.onMain {model.playPlaylist(h.graph.playlistDetail.capturePlayback()!!,TrackId(7))}
  val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
  while(h.graph.playlistBlend.pendingStarts()>0 && System.nanoTime()<end)Thread.sleep(5)
  h.onMain {assertEquals(0,controller.plainCalls);assertEquals(1,h.player.plays);assertNotNull(h.graph.playlistBlend.state.value.notice)}
 }}
 @Test fun playlistTicketStartsTappedOccurrenceThroughActualServiceCallback(){Harness().use {h ->
  val launch=preparePlaylist(h);val ticket=h.graph.playlistBlend.reserveStart(launch)!!
  val f=h.onMain {h.service.onCustomCommand(h.session,h.info,SessionCommand(PLAY_MIX,Bundle.EMPTY),Bundle().apply {putString("planId",launch.plan.id);putLong("version",launch.plan.version);putString("startOccurrence",launch.occurrence);putString("playlistStart",ticket)})}
  assertEquals(0,f.get(5,TimeUnit.SECONDS).resultCode)
  h.onMain {assertEquals(115000L,h.player.currentPosition);assertTrue(h.player.playing);assertEquals(0,h.graph.playlistBlend.pendingStarts())}
 }}
 @Test fun revokedPlaylistTicketCannotReplaceExistingPlayback(){Harness().use {h ->
  val launch=preparePlaylist(h);val ticket=h.graph.playlistBlend.reserveStart(launch)!!
  h.graph.playlistBlend.visible(false);h.graph.playlistBlend.visible(true)
  val before=h.player.items
  val f=h.onMain {h.service.onCustomCommand(h.session,h.info,SessionCommand(PLAY_MIX,Bundle.EMPTY),Bundle().apply {putString("planId",launch.plan.id);putLong("version",launch.plan.version);putString("startOccurrence",launch.occurrence);putString("playlistStart",ticket)})}
  assertEquals(SessionError.ERROR_BAD_VALUE,f.get(5,TimeUnit.SECONDS).resultCode)
  h.onMain {assertSame(before,h.player.items);assertEquals(0,h.player.plays);assertTrue(h.service.mixGrants.isEmpty())}
 }}
 @Test fun heldPlaylistGetCannotInstallAfterStopResumeOrRouteReopen(){for(kind in listOf("lifecycle","route","account"))Harness().use {h ->
  val launch=preparePlaylist(h);val token=h.graph.playlistBlend.reserveStart(launch)!!
  h.server.dispatcher=object:Dispatcher(){override fun dispatch(r:RecordedRequest):MockResponse {h.entered.countDown();check(h.release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().body(blendPlan()).build()}}
  val before=h.player.items
  val f=h.onMain {h.service.onCustomCommand(h.session,h.info,SessionCommand(PLAY_MIX,Bundle.EMPTY),Bundle().apply {putString("planId",launch.plan.id);putLong("version",1);putString("playlistStart",token);putString("startOccurrence",launch.occurrence)})}
  assertTrue(h.entered.await(3,TimeUnit.SECONDS))
  when(kind){"lifecycle"->{h.graph.playlistBlend.visible(false);h.graph.playlistBlend.visible(true)};"route"->{h.graph.playlistBlend.leave();h.graph.playlistDetail.retire()};else->{h.graph.session.retire();h.graph.session.accept(h.graph.session.beginIntent(),SecretTokens("replacement","r2","fixture"))}}
  assertEquals(SessionError.ERROR_BAD_VALUE,h.finish(f).resultCode)
  h.onMain {assertSame(before,h.player.items);assertEquals(0,h.player.plays);assertTrue(h.service.mixGrants.isEmpty())}
 }}
 @Test fun freshMixStillLoadsGrantsPreparesAndPlays(){Harness().use {h ->
  val f=h.hold();assertEquals(0,h.finish(f).resultCode)
  h.onMain {assertEquals("mix:${h.id}:1",h.player.items.single().mediaId);assertEquals(1,h.service.mixGrants.size);assertTrue(h.player.ready);assertTrue(h.player.playing);assertEquals(1,h.player.plays)}
 }}
 @Test fun ordinaryNextStillExecutesOnlyWhenQueueFlushes(){Harness().use {h ->h.onMain {
  h.actions.next();assertEquals(0,h.player.currentMediaItemIndex);assertEquals(1,h.queue.queued());h.queue.flush();assertEquals(1,h.player.currentMediaItemIndex);assertEquals(0L,h.player.currentPosition);assertEquals(0,h.player.plays)
 }}}
 @Test fun ordinaryPopulatedUndoStillRestoresExactPausedSelection(){Harness().use {h ->h.onMain {
  val before=h.player.items
  h.service.onPlayerCommandRequest(h.session,h.info,Player.COMMAND_CHANGE_MEDIA_ITEMS)
  h.player.setMediaItems(listOf(h.item("Edited",4)),0,99);h.player.prepare();h.player.play();h.actions.undo()
  assertEquals(before,h.player.items);assertEquals(0,h.player.currentMediaItemIndex);assertEquals(12000L,h.player.currentPosition);assertFalse(h.player.playing);assertNull(h.service.undo)
 }}}
 @Test fun rejectedEmptyUndoDoesNotSupersedeFreshMix(){Harness().use {h ->
  val f=h.hold();h.onMain {h.actions.undo()};assertEquals(0,h.finish(f).resultCode);assertTrue(h.player.playing)
 }}
 @Test fun rejectedAccountCommandDoesNotBecomeAcceptedNext(){Harness().use {h ->
  h.graph.session.retire();h.onMain {assertEquals(SessionError.ERROR_PERMISSION_DENIED,h.service.onPlayerCommandRequest(h.session,h.info,Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM))};assertEquals(0,h.player.currentMediaItemIndex)
 }}
}
'''
fixture += r'''
private class HeldDispatcher:CoroutineDispatcher() {
 val pending=java.util.ArrayDeque<Runnable>()
 override fun dispatch(context:kotlin.coroutines.CoroutineContext,block:Runnable){pending.add(block)}
 fun drain(){while(pending.isNotEmpty())pending.removeFirst().run()}
}
class BlendSchedulingExtractedTest {
 private fun setup(h:Harness) {
  h.server.dispatcher=object:Dispatcher(){override fun dispatch(r:RecordedRequest):MockResponse {
   val body=when(r.url.encodedPath){"/api/v1/playlists/41"->playlistDetail();"/api/v1/playlists/41/auto-mix"->blendAck();else->blendPlan()}
   return MockResponse.Builder().body(body).build()
  }}
  h.graph.playlistDetail.open(com.soundq.android.data.playlists.PlaylistId(41))
 }
 @Test fun actualGenerateCancelledBeforeEntryReleasesOnlyItsReservationWithoutTls(){Harness().use {h->
  setup(h);val held=HeldDispatcher();val owner=Job();val model=ExtractedPlaylistModel(h.graph,ExtractedPlaylistController(null),CoroutineScope(owner),held)
  val before=h.graph.playlistBlend.state.value
  model.generatePlaylistBlend(h.graph.playlistBlend.capture()!!);assertTrue(h.graph.playlistBlend.state.value.loading)
  assertNull(h.graph.playlistBlend.generate(h.graph.playlistBlend.capture()!!))
  owner.cancel();held.drain()
  assertEquals("Never entered POST must restore usable prior presentation",before,h.graph.playlistBlend.state.value)
  assertEquals(5,h.server.requestCount)
  val fresh=h.graph.playlistBlend.generate(h.graph.playlistBlend.capture()!!);assertNotNull(fresh)
  fresh!!();assertEquals(com.soundq.android.data.playlists.BlendStatus.Ready,h.graph.playlistBlend.state.value.status)
  assertEquals(7,h.server.requestCount)
 }}
 @Test fun actualKnownIdRecoveryCancelledBeforeEntryReleasesLoadingWithoutTls(){Harness().use {h->
  setup(h);h.graph.playlistBlend.generate(h.graph.playlistBlend.capture()!!)!!()
  val before=h.graph.playlistBlend.state.value;val requests=h.server.requestCount
  val held=HeldDispatcher();val owner=Job();val model=ExtractedPlaylistModel(h.graph,ExtractedPlaylistController(null),CoroutineScope(owner),held)
  model.recoverPlaylistBlend(h.graph.playlistBlend.capture()!!);assertTrue(h.graph.playlistBlend.state.value.loading)
  assertNull(h.graph.playlistBlend.recover(h.graph.playlistBlend.capture()!!))
  owner.cancel();held.drain()
  assertEquals("Never entered GET restores exact accepted prior state",before,h.graph.playlistBlend.state.value)
  assertEquals(requests,h.server.requestCount)
  h.graph.playlistBlend.recover(h.graph.playlistBlend.capture()!!)!!()
  assertEquals(requests+1,h.server.requestCount)
 }}

 @Test fun neverEnteredCompletionCannotReviveRouteAccountOrLocalLockAba(){for(kind in listOf("route","account","lock"))Harness().use {h->
  setup(h);val held=HeldDispatcher();val owner=Job();val model=ExtractedPlaylistModel(h.graph,ExtractedPlaylistController(null),CoroutineScope(owner),held)
  val capture=h.graph.playlistBlend.capture()!!;model.generatePlaylistBlend(capture)
  when(kind) {
   "route"->{h.graph.playlistBlend.leave();h.graph.playlistDetail.retire();h.graph.playlistDetail.open(com.soundq.android.data.playlists.PlaylistId(41))}
   "account"->{h.graph.session.retire();h.graph.playlistBlend.retireAccount();h.graph.session.accept(h.graph.session.beginIntent(),SecretTokens("new","r","fixture"));h.graph.playlistDetail.open(com.soundq.android.data.playlists.PlaylistId(41))}
   else->{assertTrue(h.graph.session.lockLocal());h.graph.playlistBlend.retireAccount();assertTrue(h.graph.session.completeLocalUnlock(h.graph.session.localUnlockTicket()!!));h.graph.playlistDetail.open(com.soundq.android.data.playlists.PlaylistId(41))}
  }
  val oldState=h.graph.playlistBlend.state.value;owner.cancel();held.drain();assertFalse(h.graph.playlistBlend.state.value.loading)
  assertNull("Old captures never revived",h.graph.playlistBlend.generate(capture))
  assertNotNull("Current scope remains usable",h.graph.playlistBlend.generate(h.graph.playlistBlend.capture()!!))
  assertEquals(6,h.server.requestCount)
 }}
 @Test fun cancellationAfterPostEntryRetainsUnknownOutcomeWithoutReplay(){Harness().use {h->
  setup(h);val post=CountDownLatch(1);val release=CountDownLatch(1)
  h.server.dispatcher=object:Dispatcher(){override fun dispatch(r:RecordedRequest):MockResponse {check(r.method=="POST");post.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().code(503).body("{}").build()}}
  val owner=Job();val model=ExtractedPlaylistModel(h.graph,ExtractedPlaylistController(null),CoroutineScope(owner),Dispatchers.IO)
  try {
   model.generatePlaylistBlend(h.graph.playlistBlend.capture()!!);assertTrue(post.await(3,TimeUnit.SECONDS));owner.cancel();release.countDown()
   runBlocking {owner.join()}
   assertEquals(com.soundq.android.data.playlists.BlendStatus.UnknownCreate,h.graph.playlistBlend.state.value.status)
   assertFalse(h.graph.playlistBlend.state.value.loading);assertNull(h.graph.playlistBlend.generate(h.graph.playlistBlend.capture()!!));assertEquals(6,h.server.requestCount)
  }finally {release.countDown()}
 }}

 @Test fun cancelledOldRecoveryCompletionCannotClearNewerLoadingOrReady(){Harness().use {h->
  setup(h);h.graph.playlistBlend.generate(h.graph.playlistBlend.capture()!!)!!()
  val held=HeldDispatcher();val owner=Job();val model=ExtractedPlaylistModel(h.graph,ExtractedPlaylistController(null),CoroutineScope(owner),held)
  model.recoverPlaylistBlend(h.graph.playlistBlend.capture()!!)
  h.graph.playlistBlend.visible(false);h.graph.playlistBlend.visible(true)
  val fresh=h.graph.playlistBlend.recover(h.graph.playlistBlend.capture()!!)!!;val loading=h.graph.playlistBlend.state.value
  owner.cancel();held.drain();assertSame(loading,h.graph.playlistBlend.state.value)
  fresh();val ready=h.graph.playlistBlend.state.value
  assertEquals(com.soundq.android.data.playlists.BlendStatus.Ready,ready.status);assertFalse(ready.loading);held.drain();assertSame(ready,h.graph.playlistBlend.state.value)
  assertEquals(8,h.server.requestCount)
 }}
 @Test fun oldCompletionCannotClearNewGenerationAfterRouteRetirement(){Harness().use {h->
  setup(h);val held=HeldDispatcher();val owner=Job();val model=ExtractedPlaylistModel(h.graph,ExtractedPlaylistController(null),CoroutineScope(owner),held)
  model.generatePlaylistBlend(h.graph.playlistBlend.capture()!!)
  h.graph.playlistBlend.visible(false);h.graph.playlistBlend.visible(true)
  val fresh=h.graph.playlistBlend.generate(h.graph.playlistBlend.capture()!!)!!;val pending=h.graph.playlistBlend.state.value
  owner.cancel();held.drain();assertSame(pending,h.graph.playlistBlend.state.value)
  fresh();assertEquals(com.soundq.android.data.playlists.BlendStatus.Ready,h.graph.playlistBlend.state.value.status)
  assertEquals(7,h.server.requestCount)
 }}
}
'''
fixture += r'''
class BlendSourceAdmissionExtractedTest {
 private fun preparePlaylist(h:Harness):com.soundq.android.data.playlists.PlaylistLaunch.Mixed {
  h.server.dispatcher=object:Dispatcher(){override fun dispatch(r:RecordedRequest):MockResponse {
   val body=when(r.url.encodedPath){"/api/v1/playlists/41"->playlistDetail();"/api/v1/playlists/41/auto-mix"->blendAck();else->blendPlan()}
   return MockResponse.Builder().body(body).build()
  }}
  h.graph.playlistDetail.open(com.soundq.android.data.playlists.PlaylistId(41))
  h.graph.playlistBlend.generate(h.graph.playlistBlend.capture()!!)!!()
  return h.graph.playlistBlend.launchAt(h.graph.playlistDetail.capturePlayback()!!,1) as com.soundq.android.data.playlists.PlaylistLaunch.Mixed
 }
 private fun playingOld(h:Harness) {
  val clip=MixJson.clip(Json.parseToJsonElement("""{"clipId":"old","queueItemId":"old-occ","trackId":7,"sourceStartMs":0,"sourceEndMs":1000,"timelineStartMs":0,"gainDb":0,"tempoPolicy":"volumeOnly"}""").jsonObject)
  val p=SavedMix(h.id,1,"Old working",listOf(clip))
  val grant=com.soundq.android.playback.mix.MixGrant(h.graph.session.capture()!!,p)
  val uri=Uri.parse("soundqmix://old/playing");h.service.mixGrants[uri.toString()]=grant
  h.onMain {h.player.setMediaItem(MediaItem.Builder().setMediaId("old-playing").setUri(uri).build());h.player.prepare();h.player.play();assertTrue(h.player.ready);assertTrue(h.player.playing)}
 }
 private fun assertNoLeases(h:Harness) {
  val field=h.graph.downloads.javaClass.getDeclaredField("leases");field.isAccessible=true
  assertTrue("All refused preparation leases closed",(field.get(h.graph.downloads) as Map<*,*>).isEmpty())
  assertFalse(h.graph.directory.listFiles()!!.any {it.name.startsWith("mix-")})
 }
 @Test fun absentRequiredSourcePreservesPlayingMusicThroughActualVmControllerServiceAndLoader(){Harness().use {h->
  val launch=preparePlaylist(h);playingOld(h)
  assertTrue(h.graph.downloads.remove(h.graph.session.capture()!!,h.graph.downloads.state.value.rows.filter {it.track.id==TrackId(9)}))
  val items=h.player.items;val pauses=h.player.pauses;val replacements=h.player.replacements;val plays=h.player.plays
  val controller=ExtractedPlaylistController(ControllerFacade(h));val model=ExtractedPlaylistModel(h.graph,controller)
  h.onMain {model.playPlaylist(h.graph.playlistDetail.capturePlayback()!!,TrackId(7))}
  val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
  while(h.graph.playlistBlend.state.value.notice==null && System.nanoTime()<deadline)Thread.sleep(5)
  h.onMain {
   assertNotNull("Visible source refusal",h.graph.playlistBlend.state.value.notice)
   assertSame("Missing source must not replace the sole player",items,h.player.items)
   assertTrue(h.player.playing);assertEquals(pauses,h.player.pauses);assertEquals(replacements,h.player.replacements);assertEquals(plays,h.player.plays)
   assertEquals(0,controller.plainCalls);assertEquals(0,h.graph.playlistBlend.pendingStarts())
  };assertNoLeases(h)
 }}
 @Test fun ordinarySavedMixMissingDownloadAlsoPreservesWorkingPlayer(){Harness().use {h->
  playingOld(h);assertTrue(h.graph.downloads.remove(h.graph.session.capture()!!,h.graph.downloads.state.value.rows))
  val items=h.player.items;val pauses=h.player.pauses;val plays=h.player.plays
  val f=h.hold();assertEquals(SessionError.ERROR_BAD_VALUE,h.finish(f).resultCode)
  h.onMain {assertSame(items,h.player.items);assertTrue(h.player.playing);assertEquals(pauses,h.player.pauses);assertEquals(plays,h.player.plays)};assertNoLeases(h)
 }}

 @Test fun requiredSourceRevokedWhileActualPreparationHeldNeverTouchesWorkingPlayer(){for(kind in listOf("download","route","selection","account","lock","cancel"))Harness().use {h->
  val launch=preparePlaylist(h);playingOld(h)
  val items=h.player.items;val pauses=h.player.pauses;val plays=h.player.plays;val replacements=h.player.replacements
  val token=h.graph.playlistBlend.reserveStart(launch)!!
  val get=CountDownLatch(1)
  h.server.dispatcher=object:Dispatcher(){override fun dispatch(r:RecordedRequest):MockResponse {get.countDown();return MockResponse.Builder().body(blendPlan()).build()}}
  lateinit var future:ListenableFuture<SessionResult>
  synchronized(h.graph.downloads) {
   future=h.onMain {h.service.onCustomCommand(h.session,h.info,SessionCommand(PLAY_MIX,Bundle.EMPTY),Bundle().apply {putString("planId",launch.plan.id);putLong("version",1);putString("playlistStart",token)})}
   assertTrue(get.await(3,TimeUnit.SECONDS))
   val until=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
   while(System.nanoTime()<until && !Thread.getAllStackTraces().any {(thread,stack)->thread.state==Thread.State.BLOCKED && stack.any {it.className.endsWith("DeviceDownloads") && it.methodName=="load"}})Thread.sleep(2)
   assertTrue("Actual source owner held off the player looper",Thread.getAllStackTraces().any {(thread,stack)->thread.state==Thread.State.BLOCKED && stack.any {it.className.endsWith("DeviceDownloads") && it.methodName=="load"}})
   when(kind) {
    "download"->assertTrue(h.graph.downloads.remove(h.graph.session.capture()!!,h.graph.downloads.state.value.rows.filter {it.track.id==TrackId(9)}))
    "route"->{h.graph.playlistBlend.visible(false);h.graph.playlistBlend.visible(true)}
    "selection"->h.onMain {h.actions.next();h.queue.flush()}
    "account"->{h.graph.session.retire();h.graph.session.accept(h.graph.session.beginIntent(),SecretTokens("b","r","fixture"))}
    "lock"->{assertTrue(h.graph.session.lockLocal());assertTrue(h.graph.session.completeLocalUnlock(h.graph.session.localUnlockTicket()!!))}
    else->assertTrue(future.cancel(true))
   }
   h.onMain {assertSame(items,h.player.items);assertTrue(h.player.playing);assertEquals(pauses,h.player.pauses)}
  }
  if(kind!="cancel")assertEquals(SessionError.ERROR_BAD_VALUE,future.get(5,TimeUnit.SECONDS).resultCode)
  val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
  while(h.service.mixLoads.get()!=0 && System.nanoTime()<end)Thread.sleep(2)
  h.onMain {assertEquals(0,h.service.mixLoads.get());assertSame(items,h.player.items);assertTrue(h.player.playing);assertEquals(pauses,h.player.pauses);assertEquals(plays,h.player.plays);assertEquals(replacements,h.player.replacements)}
  assertNoLeases(h)
 }}
 @Test fun exactPreparedGrantSurvivesLoaderReopenAndClosesOwnedLeasesOnRetirement(){Harness().use {h->
  val launch=preparePlaylist(h);val token=h.graph.playlistBlend.reserveStart(launch)!!
  val f=h.onMain {h.service.onCustomCommand(h.session,h.info,SessionCommand(PLAY_MIX,Bundle.EMPTY),Bundle().apply {putString("planId",launch.plan.id);putLong("version",1);putString("playlistStart",token)})}
  assertEquals(0,f.get(5,TimeUnit.SECONDS).resultCode)
  val uri=h.player.currentMediaItem!!.localConfiguration!!.uri
  val old=h.service.mixGrants[uri.toString()]!!
  // Removal defers owned bytes while the installed source capability remains in use.
  assertTrue(h.graph.downloads.remove(h.graph.session.capture()!!,h.graph.downloads.state.value.rows))
  repeat(2){MixDataSource(h.graph,h.service.mixGrants).let {source->try {assertTrue(source.open(DataSpec(uri,44+48*8))>0);val pcm=ByteArray(32);assertEquals(32,source.read(pcm,0,32))}finally {source.close()}}}
  h.service.mixGrants.remove(uri.toString());old.close();old.close();assertNoLeases(h)
  assertFalse(h.graph.directory.walkTopDown().any {it.extension=="audio"})
 }}


 @Test fun ownedButUndecodableDownloadRefusesBeforeDestructiveInstall(){Harness().use {h->
  preparePlaylist(h);playingOld(h)
  assertTrue(h.graph.downloads.remove(h.graph.session.capture()!!,h.graph.downloads.state.value.rows.filter {it.track.id==TrackId(9)}))
  h.seed(9,ByteArray(128){it.toByte()})
  val items=h.player.items;val pauses=h.player.pauses;val replacements=h.player.replacements;val plays=h.player.plays
  val controller=ExtractedPlaylistController(ControllerFacade(h));val model=ExtractedPlaylistModel(h.graph,controller)
  h.onMain {model.playPlaylist(h.graph.playlistDetail.capturePlayback()!!,TrackId(7))}
  val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
  while(h.graph.playlistBlend.state.value.notice==null && System.nanoTime()<end)Thread.sleep(2)
  h.onMain {assertNotNull(h.graph.playlistBlend.state.value.notice);assertSame(items,h.player.items);assertTrue(h.player.playing);assertEquals(pauses,h.player.pauses);assertEquals(replacements,h.player.replacements);assertEquals(plays,h.player.plays);assertEquals(0,controller.plainCalls)}
  assertNoLeases(h)
 }}
 @Test fun missingDeviceSourceRefusesGenerationBeforeAnyPost(){Harness().use {h->
  h.server.dispatcher=object:Dispatcher(){override fun dispatch(r:RecordedRequest):MockResponse {
   return MockResponse.Builder().body(if(r.method=="POST")blendAck() else if(r.url.encodedPath=="/api/v1/playlists/41")playlistDetail() else blendPlan()).build()
  }}
  h.graph.playlistDetail.open(com.soundq.android.data.playlists.PlaylistId(41))
  assertTrue(h.graph.downloads.remove(h.graph.session.capture()!!,h.graph.downloads.state.value.rows.filter {it.track.id==TrackId(9)}))
  val requests=h.server.requestCount
  val work=h.graph.playlistBlend.generate(h.graph.playlistBlend.capture()!!)!!;work()
  assertEquals("Missing known device source must refuse before create",com.soundq.android.data.playlists.BlendStatus.Refused,h.graph.playlistBlend.state.value.status)
  assertFalse(h.graph.playlistBlend.state.value.loading);assertNotNull(h.graph.playlistBlend.state.value.notice)
  assertEquals("No automatic acquisition or POST",requests,h.server.requestCount);assertNoLeases(h)
 }}
 @Test fun readySourcesLaunchAndActualLoaderReadsPcmWithoutAcquiringAgain(){Harness().use {h->
  val launch=preparePlaylist(h);val token=h.graph.playlistBlend.reserveStart(launch)!!
  val f=h.onMain {h.service.onCustomCommand(h.session,h.info,SessionCommand(PLAY_MIX,Bundle.EMPTY),Bundle().apply {putString("planId",launch.plan.id);putLong("version",1);putString("playlistStart",token);putString("startOccurrence",launch.occurrence)})}
  assertEquals(0,f.get(5,TimeUnit.SECONDS).resultCode)
  h.onMain {assertTrue(h.player.playing);assertEquals(115000L,h.player.currentPosition)}
 }}
}
'''
a.generate.mkdir(parents=True, exist_ok=True)
compat=a.generate/'PredecessorBlendConstructor.kt'
if 'private val downloads:' not in (base/'data/playlists/PlaylistBlendRepository.kt').read_text():
    compat.write_text("""package com.soundq.android.data.playlists
// Test-only predecessor constructor compatibility; source admission is deliberately absent.
fun PlaylistBlendRepository(api:com.soundq.android.data.SoundQApi,detail:PlaylistDetailRepository,downloads:com.soundq.android.data.offline.DeviceDownloads)=PlaylistBlendRepository(api,detail)
""")
elif compat.exists():
    compat.unlink()
loader=(base/'playback/mix/MixDataSource.kt').read_text()
loader=loader.replace('package com.soundq.android.playback.mix','package com.soundq.android.mixselection').replace('import android.net.Uri','').replace('import androidx.media3.datasource.*','').replace('import com.soundq.android.AppGraph','import com.soundq.android.playback.mix.*').replace('private val graph:AppGraph','private val graph:Graph').replace('internal class MixDataSource','private class MixDataSource').replace('@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)','')
# MixGrant itself is compiled from production; only the consuming DataSource body is extracted.
loader=loader[loader.index('/** Decode'):]
platform='\nprivate fun com.soundq.android.playback.mix.MixGrant.close() {} // predecessor compatibility only; successor member shadows\nprivate class DataSpec(val uri:Uri,val position:Long=0,val length:Long=-1)\nprivate interface TransferListener\nprivate interface DataSource {fun addTransferListener(listener:TransferListener);fun open(dataSpec:DataSpec):Long;fun read(buffer:ByteArray,offset:Int,length:Int):Int;fun getUri():Uri?;fun close()}\n'
prelude=prelude.replace('import java.util.concurrent.*','import java.util.concurrent.*\nimport java.io.File\nimport java.nio.file.Files\nimport androidx.media3.common.C\nimport com.soundq.android.playback.mix.*')
(a.generate / 'MixSelectionExtractedTest.kt').write_text(prelude + callbacks + fixture + platform + loader)
(a.generate / 'PinnedCommandQueue.java').write_text(java)
(a.generate / 'extraction.json').write_text(json.dumps({
    'serviceSha256': hashlib.sha256(service.encode()).hexdigest(),
    'loaderSha256': hashlib.sha256((base/'playback/mix/MixDataSource.kt').read_bytes()).hexdigest(),
    'fixtureSha256': hashlib.sha256(fixture.encode()).hexdigest(),
    'viewModelSha256': hashlib.sha256((base/'product/ProductViewModel.kt').read_bytes()).hexdigest(),
    'projectionSha256': hashlib.sha256(projection.encode()).hexdigest(),
    'media3StubSha256': hashlib.sha256(stub.read_bytes()).hexdigest(),
    'markers': markers,
    'bodyTransformations': ['remove Kotlin override modifier', 'remove Java source annotations; no body edits'],
}, indent=2) + '\n')
print('Generated actual callbacks, actions and pinned admission/consuming task bodies:', a.generate)
