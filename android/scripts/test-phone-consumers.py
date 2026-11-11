#!/usr/bin/env python3
"""Exact service resolution -> canonical prepare/start -> journal consumer on JVM.
Android MediaItem/Looper/provider/JNI are declared hardware boundaries. The actual
production method bodies, typed refs, domain store and binding journal execute.
No Android decoder, mounted UI, MediaSession or audio-device claim.
"""
from pathlib import Path
import argparse, hashlib, json
p=argparse.ArgumentParser();p.add_argument('--generate',type=Path,required=True);a=p.parse_args()
b=Path(__file__).resolve().parents[1]/'app/src/main/kotlin/com/soundq/android'
def block(path,marker):
    text=(b/path).read_text();start=text.index(marker);i=text.index('{',start)+1;depth=1
    while depth:
        depth+=(text[i]=='{')-(text[i]=='}');i+=1
    return text[start:i]
service='\n'.join(block('playback/SoundQLibraryService.kt',m) for m in ['    private fun resolveDevice(','    private fun grantFor(','    private fun resolve(']).replace('private fun resolve(','fun resolve(')
prepare=block('playback/nativeengine/NativeCallbackPlayer.kt','    override fun handlePrepare(').replace('override fun','fun',1)
bind=block('playback/nativeengine/NativeCallbackPlayer.kt','    private suspend fun bindJournal(')
seek=block('playback/nativeengine/NativeCallbackPlayer.kt','    private fun seekNative(')
repeat=block('playback/nativeengine/NativeCallbackPlayer.kt','else if (successor == index)').replace('else if','if',1)
source=block('playback/nativeengine/NativeCallbackSource.kt','    override fun prepare(item:').replace('override fun','fun',1)
grant=block('playback/SignedAudioDataSource.kt','internal class MediaGrant').replace('internal class MediaGrant','private class MediaGrant').replace('AppGraph','Graph')
journal=(b/'playback/nativeengine/NativeListeningJournal.kt').read_text()
journal='\n'.join(l for l in journal.splitlines() if not l.startswith(('package ','import '))).replace('internal class NativeListeningJournal','private class NativeListeningJournal').replace('AppGraph','Graph')
header='''package com.soundq.android.phoneconsumerprobe
import com.soundq.android.data.*
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.playback.PlaybackRef
import com.soundq.android.playback.QueuePolicy
import com.soundq.android.playback.QueueOrigin
import com.soundq.android.playback.QueueSnapshot
import com.soundq.android.playback.SavedOccurrence
import com.soundq.android.playback.SavedRepeatMode
import com.soundq.android.playback.nativeengine.*
import com.soundq.android.data.device.PhoneSourceAdmission
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.security.MessageDigest
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.Futures
import org.junit.Assert.*
import org.junit.Test

private object Player {const val STATE_IDLE=1;const val STATE_BUFFERING=2;const val STATE_READY=3}
private class Bundle {val fields=mutableMapOf<String,Any>();fun getLong(k:String)=fields[k] as? Long ?: 0;fun getBoolean(k:String)=fields[k] as? Boolean ?: false;fun getString(k:String)=fields[k] as? String;fun putLong(k:String,v:Long){fields[k]=v};fun putBoolean(k:String,v:Boolean){fields[k]=v};fun putString(k:String,v:String){fields[k]=v}}
private class Uri(val raw:String) {val scheme get()=raw.substringBefore(':');override fun toString()=raw;companion object {fun parse(v:String)=Uri(v)}}
private class MediaMetadata(val title:String="",val artist:String="",val album:String="",val extras:Bundle?=null) {class Builder {var title="";var artist="";var album="";var extras:Bundle?=null;fun setTitle(v:String)=apply{title=v};fun setArtist(v:String)=apply{artist=v};fun setAlbumTitle(v:String)=apply{album=v};fun setArtworkUri(v:Uri?)=this;fun setIsPlayable(v:Boolean)=this;fun setIsBrowsable(v:Boolean)=this;fun setExtras(v:Bundle)=apply{extras=v};fun build()=MediaMetadata(title,artist,album,extras)}}
private class MediaItem {class Local(val uri:Uri);class Request(val extras:Bundle?=null,val mediaUri:Uri?=null);object RequestMetadata {class Builder {var e:Bundle?=null;fun setExtras(v:Bundle)=apply{e=v};fun build()=Request(e)}};var mediaId="";var localConfiguration:Local?=null;var mediaMetadata=MediaMetadata();var requestMetadata=Request()
 class Builder {val m=MediaItem();fun setMediaId(v:String)=apply{m.mediaId=v};fun setUri(v:Uri)=apply{m.localConfiguration=Local(v)};fun setMimeType(v:String)=this;fun setMediaMetadata(v:MediaMetadata)=apply{m.mediaMetadata=v};fun setRequestMetadata(v:Request)=apply{m.requestMetadata=v};fun build()=m}}
private class Store:SessionStore {override fun load(endpoint:ApiEndpoint):SecretTokens?=null;override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){};override fun clear(){}}
private class Phone(val graph:Graph) {
 val store=DeviceListeningStore(File(graph.directory,"journal.json"));var access=store.unlock();val mutex=Mutex();var authorityVersion=0L;var available=true;var stageCalls=0;var stageGate:java.util.concurrent.CountDownLatch?=null;val stageEntered=java.util.concurrent.CountDownLatch(1);var journalGate:java.util.concurrent.CountDownLatch?=null;val journalEntered=java.util.concurrent.CountDownLatch(1)
 val grant=ScanGrant(ScanGrantId(UUID.randomUUID()),GrantKind.FILE,"Phone file",ProviderLocator("fixture","fixture:source"),true)
 val original=File(graph.directory,"original.wav").apply{writeBytes(ByteArray(64){it.toByte()})}
 val row:DeviceAudio
 init {store.putGrant(access,grant);store.publishScan(store.beginScan(access,grant.id)!!,listOf(DiscoveredAudio(ProviderObjectId("fixture","one"),grant.locator,ContentRevision("a".repeat(64),64),OriginalMetadata("one.wav","Original title","Original artist","Original album"),601000)));row=store.snapshot(access)!!.files.single()}
 // Signed-in phone access exists only after the repository accepts that exact session version.
 @Volatile var accepted=-1L
 fun current(version:Long)=graph.session.owns(version)&&(graph.session.state.value is AuthState.SignedOut||accepted==version)
 fun observed(ref:PlaybackRef.Device)=row.takeIf {available&&ref.id==it.id.value.toString()&&ref.sha256==it.revision.sha256&&ref.incarnation==it.incarnation}
 suspend fun admit(row:DeviceAudio):PhoneSourceAdmission?=journal {s,_->s.captureSource(access,row.id)?.let{PhoneSourceAdmission(row,it,graph.session.version(),s.bookmark(it)?.positionMs ?: 0)}}
 suspend fun prepare(admission:PhoneSourceAdmission,valid:()->Boolean):File {stageCalls++;check(valid());stageEntered.countDown();stageGate?.await();check(valid());return File.createTempFile("app-owned-",".stage",graph.directory).apply {writeBytes(ByteArray(64){it.toByte()});check(valid())}}
 suspend fun reportFailure(admission:PhoneSourceAdmission,f:Exception) {available=false}
 suspend fun <T> journal(publishState:Boolean=false,block:(DeviceListeningStore,AccessCapture)->T):T?=withContext(Dispatchers.IO){journalGate?.let {journalEntered.countDown();it.await()};mutex.withLock {block(store,access)}}
}
private class Graph(val directory:File) {val endpoint=ApiEndpoint.parse("https://fixture.invalid/api/v1");val session=AccountSession(endpoint,Store()).apply{retire()};val phoneAudio=Phone(this);fun track(id:TrackId):Track?=null}
private class Service(val graph:Graph) {val grants=ConcurrentHashMap<String,MediaGrant>();fun localAccess()=graph.phoneAudio.current(graph.session.version());fun validateSelection(items:List<MediaItem>,index:Int,position:Long){require(index in items.indices&&position>=0)}
SERVICE
}
GRANT
private class Source(val graph:Graph,val grants:ConcurrentHashMap<String,MediaGrant>) {fun prepareBounded(item:MediaItem,max:Long,current:()->Boolean):File=error("Server source hardware outside phone fixture");val MAX_BYTES=128L*1024*1024
SOURCE
}
JOURNAL
private class Hardware {
 var loaded:File?=null;var identity=0L;var position=0L;var plays=0;var revision=1L
 fun deck()=NativeCallbackDeck(identity,identity,position,601000,48000,28848000,true,false,plays>0,0,0,rate=1.0,traversalRevision=revision)
 suspend fun snapshot(current:()->Boolean)=if(current())NativeCallbackSnapshot("",0,deck())else null
 suspend fun recoverOutput(current:()->Boolean)=current()
 suspend fun load(file:File,id:Long,generation:Long,p:Long,current:()->Boolean):Boolean {if(!current())return false;loaded=file;identity=id;position=p;return true}
 suspend fun control(operation:Int,value:Double,current:()->Boolean)=current()
 suspend fun arrangement(operation:Int,value:Long,current:()->Boolean)=current()
 suspend fun controlDeck(slot:Int,operation:Int,value:Double=0.0,current:()->Boolean):Boolean {if(!current())return false;if(operation==3){position=value.toLong();revision++};return true}
}
private class CanonicalPrepare(val graph:Graph,val grants:ConcurrentHashMap<String,MediaGrant>,val items:List<MediaItem>,val lifetime:CoroutineScope) {
 var intent=true;var released=false;var pending:Job?=null;var tail:Job?=null;var selectedLoaded=false;var arrangement:Any?=null;var activeGrant:MediaGrant?=null;var activeUri:String?=null;var queueScope:AccountScope?=null
 var epoch=1L;var sourceSequence=0L;var ordinaryDeck=0;var ordinaryIdentity=0L;var playback=Player.STATE_IDLE;var error:Any?=null;var eofCount=0L;var position=0L;val preparing=AtomicInteger();var explicitSeek=0L;var seekRevision=0L;var submittedSeek:Long?=null;var desiredSeek:Long?=null;var acknowledgedSeekPosition:Long?=null;var outputUnavailable=false;val volume=1f
 val source=Source(graph,grants);val owner=Hardware();val journal=NativeListeningJournal(graph,lifetime)
 fun selected()=items.firstOrNull();fun validate(rows:List<MediaItem>){check(rows.all {grants[it.localConfiguration!!.uri.toString()]?.current(graph)==true})}
 fun assignmentCurrent()=activeGrant?.current(graph)==true
 fun retrySeek(target:Long){seekNative(target)}
 fun automaticRepeat(){val successor=0;val index=0;REPEAT}
 fun dispatchIntent(generation:Long=epoch,recoverOutput:Boolean=false){if(generation==epoch&&selectedLoaded&&activeGrant!!.current(graph))owner.plays++}
 fun retireSelection(){epoch++;selectedLoaded=false};fun fail(m:String){error=m};fun currentScope()=if(queueScope!=null)queueScope?.let(graph.session::current)==true else graph.phoneAudio.current(graph.session.version());fun invalidateState(){};fun done():ListenableFuture<*> = Futures.immediateVoidFuture()
PREPARE
BIND
SEEK
 suspend fun settled(){tail?.join()}
}
class PhoneCanonicalConsumersTest {
 @Test fun queuedNativeAdvanceSurvivesPauseButNeverSeekRetirementOrNewOwner()=runBlocking {
  for(terminal in listOf("pause","seek","retire","owner")) {
   val dir=java.nio.file.Files.createTempDirectory("queued-recency-").toFile();val graph=Graph(dir);val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default);val release=java.util.concurrent.CountDownLatch(1)
   try {
    val service=Service(graph);val native=CanonicalPrepare(graph,service.grants,service.resolve(listOf(request(graph))),scope)
    native.handlePrepare();native.settled()
    graph.phoneAudio.journalGate=release
    native.journal.observe(NativeCallbackSnapshot("",0,native.owner.deck()))
    assertTrue(graph.phoneAudio.journalEntered.await(5,java.util.concurrent.TimeUnit.SECONDS))
    native.journal.observe(NativeCallbackSnapshot("",0,native.owner.deck().copy(positionMs=200)))
    when(terminal){"pause"->native.journal.transportIntent(false);"seek"->native.journal.fenceSeek(0);"retire"->native.journal.freeze();else->graph.phoneAudio.authorityVersion++}
    release.countDown();withTimeout(5000){while(scope.coroutineContext[Job]!!.children.any {it.isActive})delay(1)}
    val history=graph.phoneAudio.store.snapshot(graph.phoneAudio.access)!!.history
    if(terminal=="pause")assertNotNull("Genuine native advancement queued before Pause must retain recency",history.singleOrNull()?.playedAtEpochMs)
    else assertTrue("Retired cursor/source evidence must stay refused: $terminal",history.isEmpty())
    native.owner.loaded?.delete()
   }finally{release.countDown();scope.cancel();graph.phoneAudio.store.close();dir.deleteRecursively()}
  }
 }
 @Test fun advancingFinalNativePauseQualifiesWithoutAnotherPlayingPoll()=runBlocking {
  val dir=java.nio.file.Files.createTempDirectory("final-pause-recency-").toFile();val graph=Graph(dir);val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default)
  try {
   val service=Service(graph);val native=CanonicalPrepare(graph,service.grants,service.resolve(listOf(request(graph))),scope)
   native.handlePrepare();native.settled();native.journal.observe(NativeCallbackSnapshot("",0,native.owner.deck()))
   withTimeout(5000){while(scope.coroutineContext[Job]!!.children.any {it.isActive})delay(1)}
   native.journal.transportIntent(false)
   native.journal.observe(NativeCallbackSnapshot("",0,native.owner.deck().copy(positionMs=200,playing=false)),allowNatural=false)
   withTimeout(5000){while(scope.coroutineContext[Job]!!.children.any {it.isActive})delay(1)}
   assertNotNull("Final native pause cursor proves advancement after the playing observation",graph.phoneAudio.store.snapshot(graph.phoneAudio.access)!!.history.singleOrNull()?.playedAtEpochMs)
   native.owner.loaded?.delete();Unit
  }finally{scope.cancel();graph.phoneAudio.store.close();dir.deleteRecursively()}
 }
 @Test fun deviceJournalDoesNotReadPreparedPcmButServerStillRequiresExactContent()=runBlocking {
  val dir=java.nio.file.Files.createTempDirectory("journal-no-rehash-").toFile();val graph=Graph(dir);val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default)
  try {
   val service=Service(graph);val item=service.resolve(listOf(request(graph))).single();val grant=service.grants.getValue(item.localConfiguration!!.uri.toString())
   grant.phoneAdmission=graph.phoneAudio.admit(graph.phoneAudio.row)
   val journal=NativeListeningJournal(graph,scope);val deck=Hardware().deck().copy(identity=51,generation=51)
   assertEquals(0L,journal.bind(item,grant,File(dir,"absent-decoded-pcm"),deck,0){true})
   assertTrue(graph.session.accept(graph.session.beginIntent(),SecretTokens("fixture-access","fixture-refresh","fixture-account")))
   val server=MediaGrant(graph.session.capture()!!,TrackId(1))
   try {journal.bind(item,server,File(dir,"absent-server-content"),deck,1){true};fail("Server must hash validated content")}
   catch(expected:java.io.FileNotFoundException){}
  }finally{scope.cancel();graph.phoneAudio.store.close();dir.deleteRecursively()}
 }
 @Test fun serverPreparationFailureNeverSuggestsPhoneAccessRecovery()=runBlocking {
  val dir=java.nio.file.Files.createTempDirectory("server-prepare-error-").toFile();val graph=Graph(dir);val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default)
  try {
   assertTrue(graph.session.accept(graph.session.beginIntent(),SecretTokens("fixture-access","fixture-refresh","fixture-account")))
   val service=Service(graph);val uri=Uri("soundq:server");service.grants[uri.toString()]=MediaGrant(graph.session.capture()!!,TrackId(1))
   val item=MediaItem.Builder().setMediaId(UUID.randomUUID().toString()).setUri(uri).build();val native=CanonicalPrepare(graph,service.grants,listOf(item),scope)
   native.handlePrepare();native.settled()
   assertEquals("Audio source could not be prepared. Try again when the server is available.",native.error)
   assertFalse(native.selectedLoaded);assertEquals(0,native.owner.plays)
  }finally{scope.cancel();graph.phoneAudio.store.close();dir.deleteRecursively()}
 }
 @Test fun repeatedServerContentPreloadStartsAtZeroButFreshRestorationRetainsResume()=runBlocking {
  val dir=java.nio.file.Files.createTempDirectory("duplicate-replay-server-").toFile();val graph=Graph(dir);val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default)
  try {
   assertTrue(graph.session.accept(graph.session.beginIntent(),SecretTokens("fixture-access","fixture-refresh","fixture-account")))
   val account=graph.session.capture()!!;graph.phoneAudio.access=graph.phoneAudio.store.unlock(ServerAccount(graph.endpoint.identity,account.accountId))
   val grant=MediaGrant(account,TrackId(1));val journal=NativeListeningJournal(graph,scope)
   fun item()=MediaItem.Builder().setMediaId(UUID.randomUUID().toString()).setUri(Uri("soundq:fixture")).build()
   fun deck(p:Long,playing:Boolean=true)=NativeCallbackDeck(51,51,p,601000,48000,28848000,true,false,playing,0,0,rate=1.0,traversalRevision=1)
   assertEquals(0L,journal.bind(item(),grant,graph.phoneAudio.original,deck(0,false),0){true})
   journal.observe(NativeCallbackSnapshot("",0,deck(0)));journal.observe(NativeCallbackSnapshot("",0,deck(42000)))
   withTimeout(5000){while(scope.coroutineContext[Job]!!.children.any {it.isActive})delay(1)}
   val fresh=NativeListeningJournal(graph,scope)
   assertEquals(42000L,fresh.bind(item(),grant,graph.phoneAudio.original,deck(0,false).copy(identity=13,generation=13),0){true})
   fresh.retire();withTimeout(5000){while(scope.coroutineContext[Job]!!.children.any {it.isActive})delay(1)}
   assertEquals("Duplicate server preload must not cache outgoing progress",0L,journal.bind(item(),grant,graph.phoneAudio.original,deck(0,false).copy(identity=12,generation=12),1){true})
   journal.observe(NativeCallbackSnapshot("",0,deck(601000,false).copy(eofCount=1,naturalEnd=NativeNaturalEndReceipt(1,51,51,1))))
   withTimeout(5000){while(scope.coroutineContext[Job]!!.children.any {it.isActive})delay(1)}
   assertNull(graph.phoneAudio.store.snapshot(graph.phoneAudio.access)!!.history.single().bookmark)
   Unit
  }finally{scope.cancel();graph.phoneAudio.store.close();dir.deleteRecursively()}
 }
 @Test fun duplicateSourcePreloadDoesNotCacheOutgoingResumeForReplay()=runBlocking {
  val dir=java.nio.file.Files.createTempDirectory("duplicate-replay-phone-").toFile();val graph=Graph(dir);val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default)
  try {
   val service=Service(graph);val rows=service.resolve(listOf(request(graph)));val native=CanonicalPrepare(graph,service.grants,rows,scope)
   native.handlePrepare();native.settled();native.journal.observe(NativeCallbackSnapshot("",0,native.owner.deck()));native.owner.position=42000
   native.journal.observe(NativeCallbackSnapshot("",0,native.owner.deck()));withTimeout(5000){while(scope.coroutineContext[Job]!!.children.any {it.isActive})delay(1)}
   assertEquals(42000L,graph.phoneAudio.store.snapshot(graph.phoneAudio.access)!!.history.single().bookmark!!.positionMs)
   val incoming=service.resolve(listOf(request(graph))).single();val grant=service.grants.getValue(incoming.localConfiguration!!.uri.toString())
   grant.phoneAdmission=graph.phoneAudio.admit(graph.phoneAudio.row)
   val resume=native.journal.bind(incoming,grant,native.owner.loaded!!,native.owner.deck().copy(identity=12,generation=12,positionMs=0,playing=false),1){true}
   assertEquals("A prepared duplicate replay cannot retain the outgoing bookmark",0L,resume)
   val id=native.owner.identity
   native.journal.observe(NativeCallbackSnapshot("",0,native.owner.deck().copy(positionMs=601000,playing=false,eofCount=1,naturalEnd=NativeNaturalEndReceipt(1,id,id,1))))
   withTimeout(5000){while(scope.coroutineContext[Job]!!.children.any {it.isActive})delay(1)}
   assertNull(graph.phoneAudio.store.snapshot(graph.phoneAudio.access)!!.history.single().bookmark)
   native.owner.loaded?.delete();Unit
  }finally{scope.cancel();graph.phoneAudio.store.close();dir.deleteRecursively()}
 }
 @Test fun heldAutomaticRepeatRetiredByPauseKeepsBookmarkAndDoesNotLatchFreshSeek()=runBlocking {
  val dir=java.nio.file.Files.createTempDirectory("held-repeat-phone-").toFile();val graph=Graph(dir);val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default);val release=java.util.concurrent.CountDownLatch(1)
  try {
   val service=Service(graph);val native=CanonicalPrepare(graph,service.grants,service.resolve(listOf(request(graph))),scope)
   native.handlePrepare();native.settled();native.journal.observe(NativeCallbackSnapshot("",0,native.owner.deck()));native.owner.position=20000
   native.journal.observe(NativeCallbackSnapshot("",0,native.owner.deck()));withTimeout(5000){while(scope.coroutineContext[Job]!!.children.any {it.isActive})delay(1)}
   graph.phoneAudio.journalGate=release
   val identity=native.owner.identity;val end=native.owner.deck().copy(positionMs=601000,playing=false,eofCount=1,naturalEnd=NativeNaturalEndReceipt(1,identity,identity,1))
   native.journal.observe(NativeCallbackSnapshot("",0,end,naturalEndVersion=1))
   assertTrue(graph.phoneAudio.journalEntered.await(5,java.util.concurrent.TimeUnit.SECONDS))
   native.automaticRepeat();native.journal.transportIntent(false)
   release.countDown();withTimeout(5000){while(scope.coroutineContext[Job]!!.children.any {it.isActive})delay(1)}
   assertNull("Retired automatic seek must release its submitted target",native.submittedSeek)
   assertEquals(20000L,graph.phoneAudio.store.snapshot(graph.phoneAudio.access)!!.history.single().bookmark!!.positionMs)
   assertEquals(20000L,native.owner.position)
   native.retrySeek(0);withTimeout(5000){while(scope.coroutineContext[Job]!!.children.any {it.isActive})delay(1)}
   assertEquals(0L,native.owner.position);native.owner.loaded?.delete();Unit
  }finally{release.countDown();scope.cancel();graph.phoneAudio.store.close();dir.deleteRecursively()}
 }

 @Test fun consumedNaturalEndDrainsBeforeAutomaticRepeatMintsSuccessorTraversal()=runBlocking {
  val dir=java.nio.file.Files.createTempDirectory("repeat-phone-").toFile();val graph=Graph(dir);val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default)
  try {
   val service=Service(graph);val native=CanonicalPrepare(graph,service.grants,service.resolve(listOf(request(graph))),scope)
   native.handlePrepare();native.settled()
   native.journal.observe(NativeCallbackSnapshot("",0,native.owner.deck()));native.owner.position=20000
   native.journal.observe(NativeCallbackSnapshot("",0,native.owner.deck()))
   withTimeout(5000){while(scope.coroutineContext[Job]!!.children.any {it.isActive})delay(1)}
   assertNotNull(graph.phoneAudio.store.snapshot(graph.phoneAudio.access)!!.history.single().bookmark)
   val identity=native.owner.identity
   val end=native.owner.deck().copy(positionMs=601000,playing=false,eofCount=1,naturalEnd=NativeNaturalEndReceipt(1,identity,identity,1))
   native.journal.observe(NativeCallbackSnapshot("",0,end,naturalEndVersion=1))
   native.automaticRepeat()
   withTimeout(5000){while(scope.coroutineContext[Job]!!.children.any {it.isActive})delay(1)}
   assertNull("Already consumed natural end must clear before automatic repeat",graph.phoneAudio.store.snapshot(graph.phoneAudio.access)!!.history.single().bookmark)
   assertEquals(0L,native.owner.position)
   native.owner.loaded?.delete();Unit
  }finally{scope.cancel();graph.phoneAudio.store.close();dir.deleteRecursively()}
 }

 private fun request(graph:Graph):MediaItem {val row=graph.phoneAudio.row;val ref=PlaybackRef.Device(row.id.value.toString(),row.revision.sha256,row.revision.byteLength,row.incarnation);return MediaItem.Builder().setMediaId("device:${ref.id}").setRequestMetadata(MediaItem.RequestMetadata.Builder().setExtras(Bundle().apply {putString("playbackRef",ref.wire())}).build()).build()}
 @Test fun heldProviderPreparationCannotStartAfterAccountOrGrantRetirement()=runBlocking {
  for(account in listOf(true,false)) {
   val dir=java.nio.file.Files.createTempDirectory("held-phone-").toFile();val graph=Graph(dir);val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default)
   val release=java.util.concurrent.CountDownLatch(1);graph.phoneAudio.stageGate=release
   try {
    val service=Service(graph);val rows=service.resolve(listOf(request(graph)));val native=CanonicalPrepare(graph,service.grants,rows,scope)
    native.handlePrepare();assertTrue(graph.phoneAudio.stageEntered.await(5,java.util.concurrent.TimeUnit.SECONDS))
    if(account)graph.session.retire()else graph.phoneAudio.authorityVersion++
    release.countDown();native.settled()
    assertEquals(0,native.owner.plays);assertNull(native.owner.loaded);assertTrue(graph.phoneAudio.original.exists());assertTrue(graph.phoneAudio.store.snapshot(graph.phoneAudio.access)!!.history.isEmpty())
   }finally{release.countDown();scope.cancel();graph.phoneAudio.store.close();dir.deleteRecursively()}
  }
 }
 @Test fun freshCanonicalPrepareRestoresDurableSourceBookmarkAfterOwnerReopen()=runBlocking {
  val dir=java.nio.file.Files.createTempDirectory("resume-phone-").toFile();val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default)
  var graph=Graph(dir)
  try {
   val service=Service(graph);val rows=service.resolve(listOf(request(graph)));val native=CanonicalPrepare(graph,service.grants,rows,scope)
   native.handlePrepare();native.settled();native.journal.observe(NativeCallbackSnapshot("",0,native.owner.deck()));native.owner.position=42000
   native.journal.observe(NativeCallbackSnapshot("",0,native.owner.deck()));native.journal.finalCursor(NativeCallbackSnapshot("",0,native.owner.deck()));native.owner.loaded?.delete()
   graph.phoneAudio.store.close();graph=Graph(dir)
   val successor=Service(graph);val fresh=CanonicalPrepare(graph,successor.grants,successor.resolve(listOf(request(graph))),scope)
   fresh.handlePrepare();fresh.settled();assertNull(fresh.error);assertEquals(42000L,fresh.position);assertEquals(42000L,fresh.owner.position);assertEquals(1,fresh.owner.plays)
   fresh.owner.loaded?.delete();Unit
  }finally{scope.cancel();graph.phoneAudio.store.close();dir.deleteRecursively()}
 }

 @Test fun signedOutTypedServiceResolutionReachesCanonicalPreparationAndStartWithoutTrackId()=runBlocking {
  val dir=java.nio.file.Files.createTempDirectory("phone-canonical-").toFile();val graph=Graph(dir);val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default)
  try {
   val row=graph.phoneAudio.row;val ref=PlaybackRef.Device(row.id.value.toString(),row.revision.sha256,row.revision.byteLength,row.incarnation)
   val service=Service(graph);val request=MediaItem.Builder().setMediaId("device:${ref.id}").setRequestMetadata(MediaItem.RequestMetadata.Builder().setExtras(Bundle().apply{putString("playbackRef",ref.wire())}).build()).build()
   val accepted=service.resolve(listOf(request));assertEquals("Original title",accepted.single().mediaMetadata.title);assertFalse(accepted.single().mediaMetadata.extras!!.fields.containsKey("trackId"))
   val native=CanonicalPrepare(graph,service.grants,accepted,scope);native.handlePrepare();native.settled()
   assertNull(native.error);assertTrue(native.selectedLoaded);assertEquals(1,native.owner.plays);assertEquals(1,graph.phoneAudio.stageCalls)
   assertNotEquals(graph.phoneAudio.original,native.owner.loaded);assertTrue(graph.phoneAudio.original.exists());assertNull(graph.session.capture())
   native.journal.observe(NativeCallbackSnapshot("",0,native.owner.deck()));native.owner.position=200
   native.journal.observe(NativeCallbackSnapshot("",0,native.owner.deck()));native.journal.finalCursor(NativeCallbackSnapshot("",0,native.owner.deck()))
   assertNotNull(graph.phoneAudio.store.snapshot(graph.phoneAudio.access)!!.history.single().playedAtEpochMs)
   assertEquals(200L,graph.phoneAudio.store.snapshot(graph.phoneAudio.access)!!.history.single().bookmark!!.positionMs)
   graph.phoneAudio.available=false;assertTrue(runCatching {service.resolve(listOf(request))}.isFailure)
   native.owner.loaded?.delete();assertTrue(graph.phoneAudio.original.exists())
  }finally{scope.cancel();graph.phoneAudio.store.close();dir.deleteRecursively()}
 }
}
'''
text=header
for key,value in [('SERVICE',service),('GRANT',grant),('SOURCE',source),('JOURNAL',journal),('PREPARE',prepare),('BIND',bind),('SEEK',seek),('REPEAT',repeat)]:text=text.replace(key,value)
# Service queue persistence and same-session renewal. Inserted after the token pass above:
# these production bodies legitimately contain upper-case words used as tokens there.
svc=(b/'playback/SoundQLibraryService.kt').read_text()
guest=svc[svc.index('    private var guestRestoredVersion'):svc.index('    private fun renewPhoneGrants(')]
schedule=block('playback/SoundQLibraryService.kt','    private fun scheduleSave(')
renewal=block('playback/SoundQLibraryService.kt','if(next!=null&&account?.let(graph.session::resumesLocal)==true)')
renewal=renewal.replace('player is com.soundq.android.playback.nativeengine.NativeCallbackPlayer','(player as Any) is com.soundq.android.playback.nativeengine.NativeCallbackPlayer')
grant_for=block('playback/SoundQLibraryService.kt','    private fun grantFor(')
text=text.replace('private object Player {const val STATE_IDLE=1;','private object Player {const val REPEAT_MODE_OFF=0;const val REPEAT_MODE_ONE=1;const val REPEAT_MODE_ALL=2;const val STATE_IDLE=1;')
queue_probe='''
private object GuestReadGate {@Volatile var gate:java.util.concurrent.CountDownLatch?=null;@Volatile var reading=java.util.concurrent.CountDownLatch(1)}
/** Real paged store; only the restore read can be held at its declared IO boundary. */
private class QueueSnapshotStore(file:File) {
 val real=com.soundq.android.playback.QueueSnapshotStore(file)
 fun write(saved:QueueSnapshot,current:()->Boolean={true})=real.write(saved,current)
 fun read(endpoint:String,account:String,current:()->Boolean={true}):QueueSnapshot? {GuestReadGate.reading.countDown();GuestReadGate.gate?.await();return real.read(endpoint,account,current)}
}
private interface QueuePlayer {val mediaItemCount:Int;val currentMediaItemIndex:Int;val currentPosition:Long;var shuffleModeEnabled:Boolean;var repeatMode:Int
 fun getMediaItemAt(i:Int):MediaItem;fun pause();fun stop();fun setMediaItems(rows:List<MediaItem>);fun setMediaItems(rows:List<MediaItem>,index:Int,position:Long);fun clearMediaItems()}
private class LogicalPlayer:QueuePlayer {
 @Volatile var rows=emptyList<MediaItem>();override var currentMediaItemIndex=0;override var currentPosition=0L;override var shuffleModeEnabled=false;override var repeatMode=Player.REPEAT_MODE_OFF;var stops=0
 override val mediaItemCount get()=rows.size;override fun getMediaItemAt(i:Int)=rows[i];override fun pause(){};override fun stop(){stops++}
 override fun setMediaItems(rows:List<MediaItem>){setMediaItems(rows,0,0)};override fun setMediaItems(rows:List<MediaItem>,index:Int,position:Long){this.rows=rows;currentMediaItemIndex=index;currentPosition=position};override fun clearMediaItems(){rows=emptyList()}
}
private class QueueTransport {var revision=0L;var committed=0;var rejected=0;fun selectionCommitted(){committed++};fun rejectSelection(){rejected++}}
private class QueueService(val graph:Graph,val jobs:CoroutineScope) {
 val grants=ConcurrentHashMap<String,MediaGrant>();val mixGrants=ConcurrentHashMap<String,com.soundq.android.playback.mix.MixGrant>()
 val player:QueuePlayer=LogicalPlayer();val transport=QueueTransport()
 var account:AccountScope?=null;var restoring=false;var rejectedQueue=false;var saveJob:Job?=null;val queueFileLock=Any()
 @Volatile var queueSaveEpoch=0L;@Volatile var selectionEpoch=0L
 var acceptedArrangement:com.soundq.android.playback.AcceptedArrangement?=null;var arrangementItems:List<MediaItem>?=null
 fun retireArrangement(){acceptedArrangement=null;arrangementItems=null}
 fun localAccess()=graph.phoneAudio.current(graph.session.version())
 fun <T> QueuePlayer.restoringShuffle(enabled:Boolean,action:()->T):T=action()
 fun restoreModes(saved:QueueSnapshot){}
 fun queueObservation(scope:AccountScope):QueueSnapshot=error("Account queue persistence is outside this guest probe")
 fun writeQueueObservation(scope:AccountScope,observed:QueueSnapshot){error("Account queue persistence is outside this guest probe")}
@@GRANTFOR@@
@@SCHEDULE@@
@@GUEST@@
 fun renewSameSession(){val next=graph.session.capture()
@@RENEWAL@@
 }
 fun restore()=restoreGuestQueue();fun modeChanged()=scheduleSave()
}
class PhoneQueueServiceTest {
 private fun device(graph:Graph):MediaItem {val row=graph.phoneAudio.row;val ref=PlaybackRef.Device(row.id.value.toString(),row.revision.sha256,row.revision.byteLength,row.incarnation)
  return MediaItem.Builder().setMediaId(UUID.randomUUID().toString()).setUri(Uri.parse("soundqdevice://source/"+UUID.randomUUID())).setMediaMetadata(MediaMetadata.Builder().setTitle("Original title").setExtras(Bundle().apply {putString("playbackRef",ref.wire());putBoolean("localOnly",true)}).build()).build()}
 private suspend fun settled(jobs:CoroutineScope)=withTimeout(10000){while(jobs.coroutineContext[Job]!!.children.any {it.isActive})delay(5)}
 @Test fun sameSessionUnlockBeforePhoneAcceptanceDefersDeviceGrantWithoutStoppingRenewal()=runBlocking {
  val dir=java.nio.file.Files.createTempDirectory("unlock-renewal-").toFile();val graph=Graph(dir);val jobs=CoroutineScope(SupervisorJob()+Dispatchers.Default)
  try {
   assertTrue(graph.session.accept(graph.session.beginIntent(),SecretTokens("fixture-access","fixture-refresh","fixture-account")))
   val service=QueueService(graph,jobs);service.account=graph.session.capture()
   val phone=device(graph);val server=MediaItem.Builder().setMediaId(UUID.randomUUID().toString()).setUri(Uri.parse("soundq://track/1")).setMediaMetadata(MediaMetadata.Builder().setExtras(Bundle().apply {putLong("trackId",1)}).build()).build()
   service.player.setMediaItems(listOf(phone,server),0,42000)
   assertTrue(graph.session.lockLocal());assertTrue(graph.session.completeLocalUnlock(graph.session.localUnlockTicket()!!))
   assertFalse("Phone audio has not accepted the resumed session version yet",service.localAccess())
   service.renewSameSession()
   assertTrue("Renewal must still adopt the resumed account",graph.session.current(service.account!!))
   assertEquals(2,service.player.mediaItemCount);assertEquals(42000L,service.player.currentPosition)
   assertTrue(service.grants.getValue("soundq://track/1").current(graph))
   val deferred=service.grants.getValue(phone.localConfiguration!!.uri.toString())
   assertFalse("Device grant carries no capability before phone acceptance",deferred.current(graph))
   graph.phoneAudio.accepted=graph.session.version()
   assertTrue("Device grant becomes current once phone audio accepts this version",deferred.current(graph))
  }finally{jobs.cancel();graph.phoneAudio.store.close();dir.deleteRecursively()}
 }
 @Test fun emptyModeSaveDuringGuestRestoreCannotReplaceSavedQueueButLaterClearPersists()=runBlocking {
  val dir=java.nio.file.Files.createTempDirectory("guest-restore-save-").toFile();val graph=Graph(dir)
  val main=java.util.concurrent.Executors.newSingleThreadExecutor().asCoroutineDispatcher();val jobs=CoroutineScope(SupervisorJob()+main)
  val file=File(dir,"phone-queue-guest.json");val gate=java.util.concurrent.CountDownLatch(1)
  try {
   val row=graph.phoneAudio.row;val ref=PlaybackRef.Device(row.id.value.toString(),row.revision.sha256,row.revision.byteLength,row.incarnation)
   com.soundq.android.playback.QueueSnapshotStore(file).write(QueueSnapshot(graph.endpoint.identity,"guest",listOf(SavedOccurrence(UUID.randomUUID().toString(),0,"Original title","Original artist",true,true,601000,ref=ref)),0,42000))
   val service=QueueService(graph,jobs);GuestReadGate.reading=java.util.concurrent.CountDownLatch(1);GuestReadGate.gate=gate
   withContext(main){service.restore()}
   assertTrue(GuestReadGate.reading.await(5,java.util.concurrent.TimeUnit.SECONDS))
   withContext(main){service.player.repeatMode=Player.REPEAT_MODE_ONE;service.modeChanged()} // empty player, restore still reading
   delay(700);gate.countDown();settled(jobs)
   assertEquals("Saved guest queue must be restored",1,withContext(main){service.player.mediaItemCount})
   assertEquals("Empty mode save must not replace the queue being restored",1,com.soundq.android.playback.QueueSnapshotStore(file).read(graph.endpoint.identity,"guest")!!.items.size)
   withContext(main){service.player.clearMediaItems();service.modeChanged()};settled(jobs)
   assertEquals("Intentional clear after restore completion persists",0,com.soundq.android.playback.QueueSnapshotStore(file).read(graph.endpoint.identity,"guest")!!.items.size)
  }finally{gate.countDown();GuestReadGate.gate=null;jobs.cancel();main.close();graph.phoneAudio.store.close();dir.deleteRecursively()}
 }
}
'''
for key,value in [('@@GRANTFOR@@',grant_for),('@@SCHEDULE@@',schedule),('@@GUEST@@',guest),('@@RENEWAL@@',renewal)]:queue_probe=queue_probe.replace(key,value)
text+=queue_probe
a.generate.mkdir(parents=True,exist_ok=True)
(a.generate/'PhoneCanonicalConsumersTest.kt').write_text(text)
# Keep queue mutation consumer bodies in the same registered unit-test cohort.
import subprocess, sys
subprocess.run([sys.executable,str(Path(__file__).with_name('test-local-media-mutations.py')),'--generate',str(a.generate)],check=True)
(a.generate/'source-blocks.json').write_text(json.dumps({k:hashlib.sha256(v.encode()).hexdigest() for k,v in {'service':service,'grant':grant,'prepare':prepare,'bind':bind,'journal':journal,'source':source}.items()},indent=2))
