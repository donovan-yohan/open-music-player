#!/usr/bin/env python3
"""Generate exact production publication/service boundary tests (no Android/hardware).

Facade types stand in for Bundle, Media3, session and native IO only. Domain storage,
preference persistence, publication, grant-current, poll rejection, same-file resolution,
and the complete songSpeed command body are production code. Run --generate from Gradle;
--run is an isolated compiler/JUnit convenience, never invokes Gradle or writes caches.
"""
from pathlib import Path
import argparse
import os
import subprocess
import json
p=argparse.ArgumentParser();p.add_argument('--generate',type=Path,required=True);p.add_argument('--root',type=Path);p.add_argument('--run',action='store_true');a=p.parse_args()
root=a.root or Path(__file__).resolve().parents[1];src=root/'app/src/main/kotlin/com/soundq/android';out=a.generate;out.mkdir(parents=True,exist_ok=True)
def section(path,start,end):
    text=(src/path).read_text();return text[text.index(start):text.index(end,text.index(start))]
publish=section('data/device/PhoneAudioRepository.kt','    private fun publish(','    private fun fail(')
repository=(src/'data/device/PhoneAudioRepository.kt').read_text()
authority=section('data/device/PhoneAudioRepository.kt','    private val authoritySequence=','    private fun publish(') if '    private val authoritySequence=' in repository else 'fun sourceAuthority(ref:PlaybackRef.Device)=authorityVersion'
mutations=section('data/device/PhoneAudioRepository.kt','    private val fileMutations=','    suspend fun admit(')
report=section('data/device/PhoneAudioRepository.kt','    suspend fun reportFailure(','    suspend fun prepare(')
grant=next(l.strip() for l in (src/'playback/SignedAudioDataSource.kt').read_text().splitlines() if 'fun current(graph:AppGraph)' in l)
poll=next(l.strip() for l in (src/'playback/nativeengine/NativeCallbackPlayer.kt').read_text().splitlines() if 'if (!assignmentCurrent()) { intent = false;' in l)
command=section('playback/SoundQLibraryService.kt','    private fun songSpeed(','    private fun admitted(').replace('com.soundq.android.playback.nativeengine.NativeCallbackPlayer','NativeCallbackPlayer').replace('Json.encodeToString(value)','encodeReply(value)')
# Type-only native binding; production preference invalidation body is unmodified.
speedChanged=section('playback/nativeengine/NativeCallbackPlayer.kt','    internal fun speedPreferenceChanged()','    private fun observeSpeed(')
header='''package com.soundq.android.menuprobe
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.playback.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test
private class Uri(val value:String) {val authority:String? get()=value.substringAfter("://").substringBefore('/');companion object {fun parse(v:String)=Uri(v)}}
private data class PhoneSourceAdmission(val row:DeviceAudio,val source:SourceCapture,val sessionVersion:Long,val resumeMs:Long=0)
private data class PhoneAudioState(val ready:Boolean=false,val snapshot:DeviceListeningSnapshot?=null,val refreshing:Boolean=false,val permission:Boolean=true,val message:String?=null,val scan:Any?=null)
private class Platform {var allowed=true;fun storageAllowed()=allowed}
private class Session {var version=1L;var accountId="a";fun version()=version;fun owns(v:Long)=version==v;fun capture()=this;fun current(s:Session)=s===this}
private class Endpoint {var identity="endpoint"}
private class AppGraph {val session=Session();val endpoint=Endpoint();lateinit var phoneAudio:Repository}
private class Repository(val graph:AppGraph,val store:DeviceListeningStore?,val access:AccessCapture?) {
 val platform=Platform();val serial=Mutex();val mutable=MutableStateFlow(PhoneAudioState());val state=mutable.asStateFlow();val lastScan:Any?=null
 private val refreshLock=java.util.concurrent.locks.ReentrantLock()
 private inline fun <T> refreshLocked(block:()->T):T {refreshLock.lock();try {return block()} finally {refreshLock.unlock()}}
 fun proofEpoch()=authoritySequence.get()
 fun revokeOriginal(ref:PlaybackRef.Device)=advanceAuthority(sourceFileId(ref))
 fun current(version:Long)=graph.session.owns(version)
 fun publishNow()=publish()
AUTHORITY
PUBLISH
MUTATIONS
REPORT
}
private class Grant(val device:PlaybackRef.Device?,val version:Long,val audioRevision:Long,val scope:Session) {
GRANT
}
private object Player {const val STATE_IDLE=1}
private class Poll(val grant:Grant,val graph:AppGraph) {
 var intent=true;var playback=3;var retired=false
 fun assignmentCurrent()=grant.current(graph)
 fun retireSelection(){retired=true}
 fun invalidateState(){}
 fun observe(){POLL}
}
private class Bundle {val values=mutableMapOf<String,Any>();fun getLong(k:String,d:Long)=values[k] as? Long ?: d;fun getString(k:String)=values[k] as? String;fun getDouble(k:String,d:Double)=values[k] as? Double ?: d;fun containsKey(k:String)=k in values;fun putString(k:String,v:String){values[k]=v}}
private class SessionResult(val code:Int,val data:Bundle=Bundle()) {companion object {const val RESULT_SUCCESS=0}}
private object SessionError {const val ERROR_INVALID_STATE=-1}
private open class ListenableFuture<T>(var value:T?=null)
private class SettableFuture<T>:ListenableFuture<T>() {fun set(v:T){value=v};companion object {fun <T> create()=SettableFuture<T>()}}
private object Futures {fun <T> immediateFuture(v:T)=ListenableFuture(v)}
private class Extras(val ref:PlaybackRef) {fun getString(k:String)=if(k=="playbackRef")ref.wire() else null}
private class Metadata(val extras:Extras)
private class Item(val mediaId:String,val ref:PlaybackRef) {val mediaMetadata=Metadata(Extras(ref));val localConfiguration=Config(mediaId)}
private data class Config(val uri:String)
private typealias MediaItem=Item
private class Successor(val item:Item,val speed:Double)
private class NativeCallbackPlayer {
 var currentMediaItem:Item?=null;val listeningSpeedBounds=0.5 to 2.0;var rate=1.0;var requests=0;var preferenceEvents=0;var cancels=0
 var position=42000L;var playing=true;var successor:Successor?=null;var preference:(Item)->Double={1.0}
 fun listeningSpeed()=currentMediaItem?.let {ListeningSpeedState(it.mediaId,rate,0.5,2.0)}
 fun requestSpeed(id:String,s:Double,done:(Boolean)->Unit) {requests++;check(currentMediaItem?.mediaId==id);rate=s;done(true)}
 fun loadSpeed(i:Item)=preference(i)
 fun cancelSuccessor(){cancels++;successor=null}
SPEED_CHANGED
}
private class Service(val graph:AppGraph,val player:NativeCallbackPlayer,val speeds:ListeningSpeedPreferences) {
 var reply:SongSpeedState?=null
 fun encodeReply(s:SongSpeedState):String {reply=s;return "state"}
 fun localAccess()=graph.phoneAudio.platform.allowed
 fun publishSessionExtras(){}
 fun speedKey(i:Item)=ListeningSpeedKey.of(i.ref)
 fun execute(ref:PlaybackRef,rate:Double?=null,version:Long=graph.session.version()):SessionResult {
  val b=Bundle();b.values["target"]=ref.wire();b.values["version"]=version;rate?.let {b.values["speed"]=it}
  return checkNotNull(songSpeed(b).value)
 }
COMMAND
}
private class Fixture:AutoCloseable {
 val root=java.nio.file.Files.createTempDirectory("song-menu-").toFile();val store=DeviceListeningStore(File(root,"domain.json"));val access=store.unlock();val graph=AppGraph()
 val grant=ScanGrant(ScanGrantId(UUID.randomUUID()),GrantKind.INDEXED,"index",ProviderLocator("media","index"),true)
 val a:DeviceAudio;val b:DeviceAudio;val repo:Repository
 init {
  store.putGrant(access,grant)
  fun row(n:String)=DiscoveredAudio(ProviderObjectId("media",n),ProviderLocator("media","content://media/"+n),ContentRevision("a".repeat(64),123),OriginalMetadata(n+".wav"),700000)
  store.publishScan(store.beginScan(access,grant.id)!!,listOf(row("a"),row("b")))
  a=store.snapshot(access)!!.files[0];b=store.snapshot(access)!!.files[1]
  repo=Repository(graph,store,access);graph.phoneAudio=repo;repo.publishNow()
 }
 fun ref(r:DeviceAudio)=repo.reference(r)
 override fun close(){store.close();root.deleteRecursively()}
}
class SongMenuBoundaryTest {
 @Test fun missingPublicationPreservesUnrelatedGrantAndPoll()=runBlocking {Fixture().use {f->
  val grant=Grant(f.ref(f.b),1,f.repo.sourceAuthority(f.ref(f.b)),f.graph.session);val a=PhoneSourceAdmission(f.a,f.store.captureSource(f.access,f.a.id)!!,1)
  assertTrue(grant.current(f.graph))
  assertTrue(f.repo.markFileMissing(a,f.a.aliases.single().locator.value))
  val poll=Poll(grant,f.graph);poll.observe()
  assertTrue("A missing must not retire available B",grant.current(f.graph));assertTrue(poll.intent);assertFalse(poll.retired)
  assertNull(f.repo.observed(f.ref(f.a)))
  // Ordinary grant-revoke publication still invalidates B, without transport renewal.
  f.store.putGrant(f.access,f.grant.copy(state=AccessState.REVOKED));f.repo.publishNow();poll.observe()
  assertFalse(grant.current(f.graph));assertFalse(poll.intent);assertTrue(poll.retired)
 }}
 @Test fun physicalRevocationFencesProofsButNotUnrelatedTransport() {Fixture().use {f->
  val a=Grant(f.ref(f.a),1,f.repo.sourceAuthority(f.ref(f.a)),f.graph.session)
  val b=Grant(f.ref(f.b),1,f.repo.sourceAuthority(f.ref(f.b)),f.graph.session)
  val proof=f.repo.proofEpoch();val broad=f.repo.authorityVersion
  f.repo.revokeOriginal(f.ref(f.a))
  assertTrue(f.repo.proofEpoch()>proof);assertEquals(broad,f.repo.authorityVersion)
  assertFalse(a.current(f.graph));assertTrue(b.current(f.graph))
  val fresh=Grant(f.ref(f.a),1,f.repo.sourceAuthority(f.ref(f.a)),f.graph.session);assertTrue(fresh.current(f.graph))
 }}
 @Test fun errorPublicationPreservesUnrelatedGrant()=runBlocking {Fixture().use {f->
  val grant=Grant(f.ref(f.b),1,f.repo.sourceAuthority(f.ref(f.b)),f.graph.session)
  f.repo.reportFailure(PhoneSourceAdmission(f.a,f.store.captureSource(f.access,f.a.id)!!,1),java.io.IOException("unreadable"))
  assertTrue(grant.current(f.graph));assertNull(f.repo.observed(f.ref(f.a)))
 }}
 @Test fun identicalBytesSaveOnlyDoesNotChangeAcceptedAudio() {Fixture().use {f->
  val prefs=ListeningSpeedPreferences(File(f.root,"speed.json"));val native=NativeCallbackPlayer();native.currentMediaItem=Item("B",f.ref(f.b));native.preference={prefs.speed(ListeningSpeedKey.of(it.ref)) ?: 1.0}
  val service=Service(f.graph,native,prefs);val selected=native.currentMediaItem;val position=native.position
  assertEquals(ListeningSpeedKey.of(f.ref(f.a)),ListeningSpeedKey.of(f.ref(f.b)))
  assertEquals(0,service.execute(f.ref(f.a),1.5).code)
  assertEquals("Distinct physical B must not receive an apply",0,native.requests);assertEquals(1.0,native.rate,0.0)
  assertSame(selected,native.currentMediaItem);assertEquals(position,native.position);assertTrue(native.playing);assertFalse(service.reply!!.current)
  assertEquals(1.5,ListeningSpeedPreferences(File(f.root,"speed.json")).speed(ListeningSpeedKey.of(f.ref(f.a)))!!,0.0)
  // Next actual source admission reads the saved, content-shared preference.
  assertEquals(1.5,native.loadSpeed(Item("A",f.ref(f.a))),0.0)
 }}
 @Test fun foldedSamePhysicalReferenceAppliesAndInvalidationRetiresEveryAliasGrant()=runBlocking {Fixture().use {f->
  val old=f.ref(f.a)
  val survivor=DiscoveredAudio(ProviderObjectId("media","survivor"),ProviderLocator("media","content://media/new"),f.a.revision,f.a.metadata,700000,formerObjectIds=setOf(f.a.objectId))
  val other=DiscoveredAudio(f.b.objectId,f.b.aliases.single().locator,f.b.revision,f.b.metadata,700000)
  f.store.publishScan(f.store.beginScan(f.access,f.grant.id)!!,listOf(survivor,survivor.copy(locator=ProviderLocator("media","content://media/new2")),other));f.repo.publishNow()
  val physical=f.store.snapshot(f.access)!!.files.single {it.objectId==survivor.objectId};val current=f.ref(physical)
  assertTrue(f.repo.sameFile(old,current))
  val native=NativeCallbackPlayer();native.currentMediaItem=Item("physical",current)
  val service=Service(f.graph,native,ListeningSpeedPreferences(File(f.root,"speed.json")))
  assertEquals(0,service.execute(old,1.5).code);assertEquals(1,native.requests)
  val oldGrant=Grant(old,1,f.repo.sourceAuthority(old),f.graph.session);val newGrant=Grant(current,1,f.repo.sourceAuthority(current),f.graph.session)
  val fence=f.repo.beginFileMutation(old)!!;assertNull(f.repo.observed(current));f.repo.endFileMutation(fence)
  assertTrue(oldGrant.current(f.graph));assertTrue(newGrant.current(f.graph))
  f.repo.reportFailure(PhoneSourceAdmission(physical,f.store.captureSource(f.access,physical.id)!!,1),java.io.IOException("unreadable"))
  assertNotNull("A remaining route needs a fresh source capture, not an old grant",f.repo.observed(old))
  assertFalse(oldGrant.current(f.graph));assertFalse(newGrant.current(f.graph))
  assertTrue(f.repo.markFileMissing(PhoneSourceAdmission(physical,f.store.captureSource(f.access,physical.id)!!,1),survivor.locator.value))
  assertNull("Confirmed physical deletion retires every folded/alternate route",f.repo.observed(old))
 }}
 @Test fun exactCurrentPhysicalAndServerIdentityApplyButForeignScopeDoesNot() {Fixture().use {f->
  val prefs=ListeningSpeedPreferences(File(f.root,"speed.json"));val native=NativeCallbackPlayer();val service=Service(f.graph,native,prefs)
  native.currentMediaItem=Item("A",f.ref(f.a));assertEquals(0,service.execute(f.ref(f.a),1.5).code);assertEquals(1,native.requests);assertTrue(service.reply!!.current)
  val server=PlaybackRef.Server("endpoint","a",1);native.currentMediaItem=Item("S",server)
  assertEquals(0,service.execute(server,1.25).code);assertEquals(2,native.requests)
  assertEquals(-1,service.execute(server.copy(account="foreign"),1.75).code);assertEquals(2,native.requests)
  assertEquals(-1,service.execute(f.ref(f.a),1.75,0).code);assertEquals(2,native.requests)
  assertEquals(-1,service.execute(f.ref(f.a).copy(incarnation=2),1.75).code);assertEquals(2,native.requests)
 }}
 @Test fun saveOnlyPreferenceNotificationCanCancelStaleSuccessorButDoesNotApplyOutgoingRate() {Fixture().use {f->
  val prefs=ListeningSpeedPreferences(File(f.root,"speed.json"));val native=NativeCallbackPlayer();native.currentMediaItem=Item("B",f.ref(f.b));native.preference={prefs.speed(ListeningSpeedKey.of(it.ref)) ?: 1.0}
  native.successor=Successor(Item("A",f.ref(f.a)),1.0)
  val service=Service(f.graph,native,prefs);service.execute(f.ref(f.a),1.5)
  assertEquals(0,native.requests);assertEquals(1.0,native.rate,0.0);assertEquals(1,native.cancels)
 }}
}
'''
def method(marker):
 text=(src/'playback/nativeengine/NativeCallbackPlayer.kt').read_text();start=text.index(marker);end=text.index('{',start)+1;depth=1
 while depth:
  depth+=(text[end]=='{')-(text[end]=='}');end+=1
 return text[start:end]
retirement='''
private data class Deck(val identity:Long)
private data class RetainedSource(val physicalFileId:String?)
private class RetirementHardware {
 fun descriptorsDrained(id:String?)=true
 val dispatcher=Dispatchers.Unconfined
 val borrowed=mutableSetOf<String>();val ordinaryFiles=mutableMapOf<Int,String>()
 val borrowedOriginals=mutableSetOf<RetainedSource>();val ordinaryOriginals=mutableMapOf<Int,RetainedSource>()
 var drainChecks=0
DRAIN
 val decks=mutableMapOf(0 to 111L,1 to 222L);var hold:CompletableDeferred<Unit>?=null;var entered=false
 suspend fun crossfade(a:Int,b:Long,c:Int,d:Long,e:Long,current:()->Boolean)=current()
 suspend fun unloadDeck(slot:Int):Boolean {entered=true;hold?.await();decks.remove(slot);ordinaryOriginals.remove(slot)?.let {borrowedOriginals.remove(it)};return true}
 suspend fun snapshot(current:()->Boolean)=if(current())Snapshot(decks.values.map(::Deck))else null
 data class Snapshot(val decks:List<Deck>)
}
private class RetirementCandidate(val item:Item,val outgoing:Item,val deck:Int=1,val identity:Long=222,val outgoingDeck:Int=0,val outgoingIdentity:Long=111,val armed:Boolean=true,val arming:Boolean=false)
private class RetirementJournal {val retired=mutableListOf<Int>();fun retire(slot:Int,drain:Boolean=false){retired+=slot}}
private class Retirement(val graph:AppGraph,var items:List<Item>) {
 var index=0;val arrangement:Any?=null;val arrangementSourceItems=emptyList<Item>();var successor:RetirementCandidate?=null
 var pending:Job?=null;var tail:Job?=null;var successorJob:Job?=null;var successorAttempt:String?=null;var successorRevision=0L
 var ordinaryIdentity=111L;var ordinaryDeck=0;var selectedLoaded=true;var playback=3;var position=42000L;var released=false;var error:Any?=null
 var stopped=0;var pauses=0;var retired=0;var prepares=0;var order=items.indices.toList();var queueScope:Session?=null
 val durations=mutableMapOf<String,Long>();val lifetime=CoroutineScope(SupervisorJob()+Dispatchers.Unconfined);val journal=RetirementJournal();val owner=RetirementHardware()
 val grants=items.associate {it.mediaId to Grant(it.ref as? PlaybackRef.Device,1,graph.phoneAudio.sourceAuthority(it.ref as PlaybackRef.Device),graph.session)}
 fun selected()=items.getOrNull(index)
 fun rebuilt(next:List<Item>,at:Int)=next.indices.toList()
 fun pause(){pauses++};fun stop(){stopped++;selectedLoaded=false;playback=Player.STATE_IDLE}
 fun validate(next:List<Item>){check(next.distinctBy {it.mediaId}.size==next.size)}
 fun clearQueue(){items=emptyList()};fun done()=ListenableFuture(Unit);fun handlePrepare(){prepares++}
 fun retireSelection(){retired++};fun invalidateState(){};fun fail(message:String):Nothing=error(message)
RETIRE
CANCEL
MUTATE
}
class SongFileRetirementBoundaryTest {
 @Test fun unqueuedFileDoesNotTouchOutgoingAssignment()=runBlocking {Fixture().use {f->
  val b=Item("B",f.ref(f.b));val native=Retirement(f.graph,listOf(b))
  assertTrue(native.retirePhoneFile(f.ref(f.a)));assertSame(b,native.selected());assertEquals(0,native.stopped);assertEquals(0,native.retired);native.lifetime.cancel()
 }}
 @Test fun failedPreTransferTargetCloseRefusesEvenWithoutQueueOrNativeIdentity()=runBlocking {Fixture().use {f->
  val b=Item("B",f.ref(f.b));val native=Retirement(f.graph,listOf(b))
  native.owner.borrowedOriginals+=RetainedSource(f.a.id.value.toString())
  assertFalse(native.retirePhoneFile(f.ref(f.a)));assertSame(b,native.selected());assertEquals(0,native.stopped)
  native.owner.borrowedOriginals.clear();native.owner.borrowedOriginals+=RetainedSource(f.b.id.value.toString())
  assertTrue(native.retirePhoneFile(f.ref(f.a)));assertSame(b,native.selected());native.lifetime.cancel()
 }}
 @Test fun preloadedTargetCloseMustDrainWithoutWaitingForUnrelatedActiveSource()=runBlocking {Fixture().use {f->
  for(failedClose in listOf(false,true)) {
   val b=Item("B",f.ref(f.b));val a=Item("A",f.ref(f.a));val native=Retirement(f.graph,listOf(b,a))
   native.owner.borrowedOriginals+=RetainedSource(f.b.id.value.toString())
   if(failedClose)native.owner.borrowedOriginals+=RetainedSource(f.a.id.value.toString())
   native.successor=RetirementCandidate(a,b)
   assertEquals(!failedClose,native.retirePhoneFile(f.ref(f.a)))
   assertSame(b,native.selected());assertEquals(0,native.stopped);assertEquals(111L,native.owner.decks[0]);native.lifetime.cancel()
  }
 }}
 @Test fun queuedAndPreloadedAliasesDrainOnlyTheTargetDeckBeforeAcknowledgingRetirement()=runBlocking {Fixture().use {f->
  for(preload in listOf(false,true)) {
   val b=Item("B",f.ref(f.b));val a=Item("A",f.ref(f.a));val native=Retirement(f.graph,listOf(b,a))
   val hold=CompletableDeferred<Unit>();native.owner.hold=hold
   if(preload)native.successor=RetirementCandidate(a,b)
   val fence=f.repo.beginFileMutation(f.ref(f.a))!!
   try {
    val task=async {native.retirePhoneFile(f.ref(f.a))};yield()
    if(preload) {assertTrue(native.owner.entered);assertFalse("Deletion cannot acknowledge before target decoder retirement",task.isCompleted);hold.complete(Unit)}
    assertTrue(task.await());assertEquals(listOf(b),native.items);assertSame(b,native.selected())
    assertEquals(111L,native.ordinaryIdentity);assertEquals(42000L,native.position);assertEquals(0,native.stopped);assertEquals(0,native.retired);assertEquals(0,native.prepares)
    assertEquals(111L,native.owner.decks[0]);if(preload){assertFalse(1 in native.owner.decks);assertEquals(listOf(1),native.journal.retired)}
   } finally {hold.complete(Unit);f.repo.endFileMutation(fence);native.lifetime.cancel()}
  }
 }}
}
'''
ownerText=(src/'playback/nativeengine/NativeCallbackOwner.kt').read_text()
drain=ownerText[ownerText.index('    suspend fun sourcesDrained('):ownerText.index('    suspend fun retainedBytes(')]
retirement=retirement.replace('DRAIN',drain)
retirement=retirement.replace('RETIRE',method('    internal suspend fun retirePhoneFile(')).replace('CANCEL',method('    private fun cancelSuccessor(')).replace('MUTATE',method('    private fun mutate('))
text=header+retirement
for name,value in [('AUTHORITY',authority),('PUBLISH',publish),('MUTATIONS',mutations),('REPORT',report),('GRANT',grant),('POLL',poll),('SPEED_CHANGED',speedChanged),('COMMAND',command)]:text=text.replace(name,value)
(out/'SongMenuBoundaryTest.kt').write_text(text)
(out/'extraction.json').write_text(json.dumps({'source':str(src),'native_type_mapping':'NativeCallbackPlayer -> facade','reply_serializer':'Json.encodeToString(value) -> encodeReply(value)','sections':['publish','file mutations + journal','reportFailure','grant.current','ordinary poll rejection','speedPreferenceChanged','complete songSpeed']},indent=2))
if a.run:
 cache=Path.home()/'.gradle/caches/modules-2/files-2.1'
 def jar(g,n,v):return next((cache/g/n/v).glob('*/*.jar'))
 cp=os.pathsep.join(map(str,[jar('org.jetbrains.kotlinx','kotlinx-serialization-json-jvm','1.9.0'),jar('org.jetbrains.kotlinx','kotlinx-serialization-core-jvm','1.9.0'),jar('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.10.2'),jar('junit','junit','4.13.2'),jar('org.hamcrest','hamcrest-core','1.3')]))
 (out/'Track.kt').write_text('package com.soundq.android.data\n@JvmInline value class TrackId(val value:Long) {init {require(value>0)}}\n')
 files=[str(src/'playback/nativeengine/OriginalDescriptorCustody.kt'),*map(str,(src/'data/deviceaudio').glob('*.kt')),str(src/'playback/PlaybackRef.kt'),str(src/'playback/ListeningSpeed.kt'),str(out/'Track.kt'),str(out/'SongMenuBoundaryTest.kt')]
 commands=[['kotlinc','-J-Xmx512m','-J-XX:ActiveProcessorCount=1',*files,'-cp',cp,'-include-runtime','-d',str(out/'tests.jar')],['java','-Xmx512m','-XX:ActiveProcessorCount=1','-Djava.io.tmpdir='+str(out),'-cp',str(out/'tests.jar')+os.pathsep+cp,'org.junit.runner.JUnitCore','com.soundq.android.menuprobe.SongMenuBoundaryTest','com.soundq.android.menuprobe.SongFileRetirementBoundaryTest']]
 (out/'commands.json').write_text(json.dumps(commands,indent=2))
 for name,cmd in zip(['compile','tests'],commands):
  result=subprocess.run(cmd,capture_output=True,text=True);(out/(name+'.log')).write_text(result.stdout+result.stderr);print(name,result.returncode,result.stdout,result.stderr)
  if result.returncode:raise SystemExit(result.returncode)
