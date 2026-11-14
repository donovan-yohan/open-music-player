#!/usr/bin/env python3
"""Execute exact repository refresh against real domain storage and declared provider facade."""
from pathlib import Path
import argparse
p=argparse.ArgumentParser();p.add_argument('--generate',type=Path,required=True);p.add_argument('--root',type=Path);a=p.parse_args()
root=a.root or Path(__file__).resolve().parents[1]
s=(root/'app/src/main/kotlin/com/soundq/android/data/device/PhoneAudioRepository.kt').read_text()
refresh=s[s.index('    private val refreshEpoch='):s.index('    /** A saved reference')]
start=s.index('    private fun advanceAuthority(');end=s.index('{',start)+1;depth=1
while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
advance=s[start:end]
proof_epoch='authoritySequence.get()' if 'val proofAuthority=authoritySequence.get()' in s else 'authorityEpoch.get()'
header='''package com.soundq.android.refreshprobe
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.data.device.PhoneScanObservation
import com.soundq.android.data.device.IndexKeyProof
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID
import java.io.File
import org.junit.Assert.*
import org.junit.Test
private class Uri(val value:String) {companion object {fun parse(v:String)=Uri(v)};override fun toString()=value;val authority:String? get()=null}
private class Session {@Volatile var version=1L;fun version()=version}
private class Graph {val session=Session()}
private data class Observation(val locator:String,val providerObject:String=locator,val filename:String=locator,val title:String=locator,val artist:String?=null,val album:String?=null,val durationMs:Long?=601000,val aliases:Set<String> = setOf(providerObject))
private data class Coverage(val complete:Boolean,val observations:List<Observation>,val truncated:Boolean=false)
private data class Proof(val sha256:String,val bytes:Long=123)
private class Platform {
 var rows=listOf(Observation("one"));var complete=true;var fail:String?=null;var gate:java.util.concurrent.CountDownLatch?=null
 val entered=java.util.concurrent.CountDownLatch(1);var proofs=0;var discoveries=0;var cancelled=0
 @Volatile var storage=true
 @Volatile var indexing=true
 @Volatile var accessRevision=0
 /** Picker keys the provider proves name an audio-index object: old key -> index key. */
 @Volatile var proven=emptyMap<String,IndexKeyProof>()
 @Volatile var walks=true
 @Volatile var sha="a".repeat(64)
 val asked=java.util.Collections.synchronizedList(mutableListOf<Collection<String>>())
 val order=java.util.Collections.synchronizedList(mutableListOf<String>())
 fun storageAllowed()=storage
 fun indexUnlisted(current:()->Boolean):Boolean {order+="index-unlisted";return indexing}
 fun discover(current:()->Boolean):Coverage {discoveries++;order+="discover";return Coverage(complete,rows)}
 fun walksSharedStorage()=walks
 fun provenIndexKeys(ids:Collection<String>):Map<String,IndexKeyProof> {asked+=ids.toList();return proven.filterKeys {it in ids}}
 fun proof(uri:String,current:()->Boolean):Proof {proofs++;entered.countDown();gate?.await();if(!current()){cancelled++;throw CancellationException()};if(uri==fail)error("Unreadable original");return Proof(sha)}
}
private data class State(val refreshing:Boolean=false,val permission:Boolean=true,val message:String?=null)
// Record attempted obsolete publications, not merely domain refusal or eventual trailing state.
private class RecordingStore(val domain:DeviceListeningStore,val platform:Platform) {
 val proofAuthorities=mutableMapOf<ScanCapture,Long>();var authority:()->Long={0L}
 val scans=mutableMapOf<ScanCapture,Int>();var obsoletePublications=0;var publications=0;var retirements=0
 @Volatile var publishGate:java.util.concurrent.CountDownLatch?=null;val publishing=java.util.concurrent.CountDownLatch(1)
 fun snapshot(a:AccessCapture)=domain.snapshot(a)
 @Volatile var grantGate:java.util.concurrent.CountDownLatch?=null;val granting=java.util.concurrent.CountDownLatch(1)
 fun putGrant(a:AccessCapture,g:ScanGrant):Mutation {granting.countDown();grantGate?.await();return domain.putGrant(a,g)}
 fun beginScan(a:AccessCapture,g:ScanGrantId)=domain.beginScan(a,g)?.also {scans[it]=platform.accessRevision;proofAuthorities[it]=authority()}
 fun publishScan(s:ScanCapture,rows:List<DiscoveredAudio>,complete:Boolean=true):Mutation {
  publications++;if(scans[s]!=platform.accessRevision)obsoletePublications++
  publishing.countDown();publishGate?.await()
  if(proofAuthorities[s]!=authority())obsoletePublications++
  return domain.publishScan(s,rows,complete)
 }
 fun legacyObjects(a:AccessCapture)=domain.legacyObjects(a)
 fun retireLegacyAccess(a:AccessCapture):Mutation {retirements++;return domain.retireLegacyAccess(a)}
}
private class Repository(domain:DeviceListeningStore,val jobs:CoroutineScope) {
 val graph=Graph();val platform=Platform();val store=RecordingStore(domain,platform);val access=domain.unlock();val mutable=MutableStateFlow(State())
 val serial=Mutex();private val authoritySequence=java.util.concurrent.atomic.AtomicLong()
 private val authorityEpoch=java.util.concurrent.atomic.AtomicLong();val authorityVersion get()=authorityEpoch.get()
 private val fileAuthorities=java.util.concurrent.ConcurrentHashMap<DeviceFileId,Long>()
ADVANCE
 fun revokeAuthority()=advanceAuthority()
 fun revocationQueued(thread:Thread)=refreshLock.hasQueuedThread(thread)
 init {store.authority={PROOF_EPOCH}}
 @Volatile var lastScan:PhoneScanObservation?=null
 fun current(version:Long)=version==graph.session.version()
 fun publish(message:String?=null){mutable.value=State(message=message)}
 fun fail(message:String){mutable.value=State(message=message)}
 private fun grantId(v:String)=ScanGrantId(UUID.nameUUIDFromBytes(v.toByteArray()))
 private fun locator(v:String)=ProviderLocator("fixture",v)
REFRESH
 suspend fun settled(){withTimeout(10000){while(jobs.coroutineContext[Job]!!.children.any {it.isActive})delay(1)}}
}
/** An upgraded phone's store as an older build wrote it: an indexed row, a file-picker row of the same MediaStore
 * object under its picker key, and a folder-picker row nothing proves. Each has listening history. */
private object Legacy {
 fun id(n:String)=UUID.nameUUIDFromBytes(n.toByteArray())
 val indexed=ScanGrant(ScanGrantId(id("indexed:external-audio")),GrantKind.INDEXED,"Android audio index",ProviderLocator("android","indexed:external-audio"),false)
 val file=ScanGrant(ScanGrantId(id("file")),GrantKind.FILE,"picked.wav",ProviderLocator("fixture","picked"),true)
 val folder=ScanGrant(ScanGrantId(id("folder")),GrantKind.FOLDER,"Mixes",ProviderLocator("fixture","tree"),true)
 val content=ContentRevision("a".repeat(64),123)
 fun row(n:String,key:String,grant:ScanGrant,at:String)=DeviceAudio(DeviceFileId(id(n)),ProviderObjectId("android-content",key),content,1,OriginalMetadata("$n.wav",n),601000,listOf(LocatorAccess(grant.id,ProviderLocator("fixture",at),AccessState.AVAILABLE)))
 val picked=row("picked","picker-key",file,"picked")
 val unproven=row("unproven","unproven-key",folder,"tree/unproven")
 val heard=row("heard","heard-key",indexed,"indexed:9")
 fun entry(r:DeviceAudio,at:Long,pos:Long)=JournalEntry(HistoryKey.Device(r.id),at,Bookmark(r.owner,pos),id("t$at"),2)
 fun write(file:File){file.writeBytes(encodeDomain(DomainState(5,listOf(indexed,this.file,folder),listOf(heard,picked,unproven),emptyList(),
  listOf(entry(heard,1000,700000),entry(picked,3000,650000),entry(unproven,2000,610000)))).toString().toByteArray())}
}
class PhoneRefreshTest {
 @Test fun authorityRevocationAndFinalCheckCommitHaveOneOrder()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-authority-order-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO);val gate=java.util.concurrent.CountDownLatch(1)
  try {DeviceListeningStore(File(root,"domain.json")).use {store->
   val repo=Repository(store,jobs);repo.store.publishGate=gate;repo.refresh()
   assertTrue(repo.store.publishing.await(5,java.util.concurrent.TimeUnit.SECONDS))
   val done=java.util.concurrent.CountDownLatch(1);val requested=java.util.concurrent.CountDownLatch(1)
   val revoke=Thread {requested.countDown();repo.revokeAuthority();done.countDown()};revoke.start();assertTrue(requested.await(5,java.util.concurrent.TimeUnit.SECONDS))
   withTimeout(5000){while(done.count!=0L&&!repo.revocationQueued(revoke))delay(1)}
   gate.countDown();revoke.join(5000);repo.settled()
   assertEquals("No publication forwards to the real store after authority retirement wins",0,repo.store.obsoletePublications)
   assertEquals(1,repo.store.publications);assertEquals(0L,done.count)
  }}finally{gate.countDown();jobs.cancel();root.deleteRecursively()}
 }
 @Test fun revocationBeforeFinalCheckRefusesEvenAttemptingPublication()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-authority-proof-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO);val gate=java.util.concurrent.CountDownLatch(1)
  try {DeviceListeningStore(File(root,"domain.json")).use {store->
   val repo=Repository(store,jobs);repo.platform.gate=gate;repo.refresh();assertTrue(repo.platform.entered.await(5,java.util.concurrent.TimeUnit.SECONDS))
   repo.revokeAuthority();gate.countDown();repo.settled()
   assertEquals(0,repo.store.publications);assertEquals(0,repo.store.obsoletePublications)
   repo.platform.gate=null;repo.refresh();repo.settled();assertEquals(1,repo.store.publications)
  }}finally{gate.countDown();jobs.cancel();root.deleteRecursively()}
 }

 @Test fun indexedObservedRevokeRegrantCannotReviveHeldProof()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-scope-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO)
  val gate=java.util.concurrent.CountDownLatch(1)
  try {DeviceListeningStore(File(root,"domain.json")).use {store->
   val repo=Repository(store,jobs)
   repo.platform.gate=gate;repo.refresh()
   assertTrue(repo.platform.entered.await(5,java.util.concurrent.TimeUnit.SECONDS))
   repo.platform.storage=false;repo.platform.accessRevision++;repo.refresh()
   repo.platform.storage=true;repo.platform.accessRevision++;repeat(20){repo.refresh()}
   gate.countDown();repo.settled()
   assertEquals("Retired proof must never invoke publishScan",0,repo.store.obsoletePublications)
   assertEquals(1,repo.platform.cancelled)
   val snapshot=store.snapshot(repo.access)!!
   assertEquals(1,snapshot.files.size)
   assertEquals(AccessState.AVAILABLE,snapshot.grants.single().state)
   assertEquals(1,repo.store.publications)
  }}finally{gate.countDown();jobs.cancel();root.deleteRecursively()}
 }
 @Test fun changedOwnerRetiresProofAndRetainsOnlyOneFreshTrailingScan()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-owner-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO);val gate=java.util.concurrent.CountDownLatch(1)
  try {DeviceListeningStore(File(root,"domain.json")).use {store->
   val repo=Repository(store,jobs);repo.platform.gate=gate;repo.refresh();assertTrue(repo.platform.entered.await(5,java.util.concurrent.TimeUnit.SECONDS))
   repo.graph.session.version++;repo.platform.accessRevision++;repeat(20){repo.refresh()};gate.countDown();repo.settled()
   assertEquals(0,repo.store.obsoletePublications);assertEquals(1,repo.platform.cancelled);assertEquals(2,repo.platform.discoveries);assertEquals(1,repo.store.publications)
  }}finally{gate.countDown();jobs.cancel();root.deleteRecursively()}
 }
 @Test fun accessChangeRetiresHeldProofBeforeAnyPublication()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-access-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO)
  val gate=java.util.concurrent.CountDownLatch(1)
  try {DeviceListeningStore(File(root,"domain.json")).use {store->
   val repo=Repository(store,jobs);repo.platform.gate=gate;repo.refresh()
   assertTrue(repo.platform.entered.await(5,java.util.concurrent.TimeUnit.SECONDS))
   repo.platform.storage=false;repo.platform.accessRevision++;repo.refresh()
   gate.countDown();repo.settled()
   assertEquals("No obsolete publishScan invocation",0,repo.store.obsoletePublications)
   assertEquals(1,repo.platform.cancelled)
   assertTrue(store.snapshot(repo.access)!!.files.isEmpty())
   assertEquals(AccessState.REVOKED,store.snapshot(repo.access)!!.grants.single().state)
  }}finally{gate.countDown();jobs.cancel();root.deleteRecursively()}
 }
 @Test fun unreadableSiblingPublishesHealthyProofWithoutMissingOmittedKnownRows()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-partial-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO)
  try {DeviceListeningStore(File(root,"domain.json")).use {store->
   val repo=Repository(store,jobs);repo.platform.rows=listOf(Observation("retained"));repo.refresh();repo.settled()
   val old=store.snapshot(repo.access)!!.files.single()
   repo.platform.rows=listOf(Observation("healthy"),Observation("bad"));repo.platform.fail="bad";repo.refresh();repo.settled()
   val rows=store.snapshot(repo.access)!!.files
   assertEquals(setOf("retained","healthy"),rows.map {it.metadata.filename}.toSet())
   assertEquals(old,rows.single {it.id==old.id})
   assertTrue(repo.mutable.value.message!!.contains("Some audio"))
  }}finally{jobs.cancel();root.deleteRecursively()}
 }
 @Test fun finishedRefreshRecordsObservedAccessAndRetiredRefreshDoesNot()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-observed-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO)
  try {DeviceListeningStore(File(root,"domain.json")).use {store->
   val repo=Repository(store,jobs)
   repo.platform.storage=false;repo.refresh();repo.settled()
   assertEquals(PhoneScanObservation(indexed=false,complete=true,storage=false),repo.lastScan)
   assertEquals("Without all files access nothing is read",0,repo.platform.discoveries)
   repo.platform.storage=true;repo.refresh();repo.settled()
   assertEquals(PhoneScanObservation(indexed=true,complete=true,storage=true),repo.lastScan)
   assertNull("A whole scan carries no message",repo.mutable.value.message)
   repo.platform.rows=listOf(Observation("healthy"),Observation("bad"));repo.platform.fail="bad";repo.refresh();repo.settled()
   assertEquals(PhoneScanObservation(indexed=true,complete=false,storage=true),repo.lastScan)
   repo.platform.fail=null;repo.platform.complete=false;repo.refresh();repo.settled()
   assertEquals("Incomplete enumeration observed access without full coverage",PhoneScanObservation(indexed=true,complete=false,storage=true),repo.lastScan)
   // A retired refresh persists an AVAILABLE grant before proving; it must not record an observation.
   repo.lastScan=null;repo.platform.complete=true;val gate=java.util.concurrent.CountDownLatch(1);repo.platform.gate=gate;var valid=true
   val before=repo.platform.proofs
   repo.refresh {valid};withTimeout(5000){while(repo.platform.proofs<=before)delay(1)};valid=false;gate.countDown();repo.settled()
   assertNull(repo.lastScan)
  }}finally{jobs.cancel();root.deleteRecursively()}
 }
 @Test fun runningRefreshPublishesTheAccessItWasAdmittedWith()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-admitted-").toFile()
  val executor=java.util.concurrent.Executors.newSingleThreadExecutor();val jobs=CoroutineScope(SupervisorJob()+executor.asCoroutineDispatcher())
  val hold=java.util.concurrent.CountDownLatch(1)
  try {DeviceListeningStore(File(root,"domain.json")).use {store->
   val repo=Repository(store,jobs);val gate=java.util.concurrent.CountDownLatch(1)
   repo.platform.storage=false;repo.store.grantGate=gate
   executor.submit {hold.await()}
   repo.refresh()   // admits without all files access; its worker is queued behind the held executor
   repo.platform.storage=true;hold.countDown()
   try {
    assertTrue(repo.store.granting.await(5,java.util.concurrent.TimeUnit.SECONDS))
    assertTrue(repo.mutable.value.refreshing)
    assertFalse("A running refresh must publish its admitted access, not access granted after admission",repo.mutable.value.permission)
   } finally {gate.countDown()}
   repo.settled()
   assertEquals("It finished as the scan it was admitted as",PhoneScanObservation(false,true,false),repo.lastScan)
  }}finally{hold.countDown();jobs.cancel();executor.shutdownNow();root.deleteRecursively()}
 }
 @Test fun allFilesAccessIndexesUnlistedAudioBeforeReadingTheIndex()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-storage-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO)
  try {DeviceListeningStore(File(root,"domain.json")).use {store->
   val repo=Repository(store,jobs)
   repo.platform.storage=false;repo.refresh();repo.settled()
   assertEquals("No access: no walk, no index read",emptyList<String>(),repo.platform.order.toList())
   repo.platform.storage=true;repo.refresh();repo.settled()
   assertEquals(listOf("index-unlisted","discover"),repo.platform.order.toList())
   assertEquals(PhoneScanObservation(indexed=true,complete=true,storage=true),repo.lastScan)
   // Incomplete indexing still publishes what the index lists, but is not whole coverage.
   repo.platform.indexing=false;repo.platform.rows=listOf(Observation("one"),Observation("two"));repo.refresh();repo.settled()
   assertEquals(PhoneScanObservation(indexed=true,complete=false,storage=true),repo.lastScan)
   assertEquals(setOf("one","two"),store.snapshot(repo.access)!!.files.filter {it.available}.map {it.metadata.filename}.toSet())
   assertTrue(repo.mutable.value.message!!.contains("Some audio"))
  }}finally{jobs.cancel();root.deleteRecursively()}
 }
 @Test fun refreshBurstDoesNotCancelProofAndHasOnlyOneTrailingScan()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-burst-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO)
  val gate=java.util.concurrent.CountDownLatch(1)
  try {DeviceListeningStore(File(root,"domain.json")).use {store->
   val repo=Repository(store,jobs);repo.platform.gate=gate;repo.refresh()
   assertTrue(repo.platform.entered.await(5,java.util.concurrent.TimeUnit.SECONDS))
   repeat(20){repo.refresh()};gate.countDown();repo.settled()
   assertEquals(0,repo.platform.cancelled);assertEquals(2,repo.platform.discoveries)
   assertEquals(1,store.snapshot(repo.access)!!.files.size)
  }}finally{gate.countDown();jobs.cancel();root.deleteRecursively()}
 }
 @Test fun callerRefreshDoesNotWaitForHeldCatalogPublication()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-caller-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO);val gate=java.util.concurrent.CountDownLatch(1)
  try {DeviceListeningStore(File(root,"domain.json")).use {store->
   val repo=Repository(store,jobs);repo.store.publishGate=gate;repo.refresh()
   assertTrue(repo.store.publishing.await(5,java.util.concurrent.TimeUnit.SECONDS))
   // Production callers are UI callbacks. Publication holds the refresh lock while it commits the catalog.
   val caller=Thread {repo.refresh()};caller.start();caller.join(2000);val blocked=caller.isAlive
   gate.countDown();caller.join(5000);repo.settled()
   assertFalse("refresh() caller waited for the held catalog publication",blocked)
   assertEquals(0,repo.platform.cancelled);assertEquals(2,repo.platform.discoveries);assertEquals(2,repo.store.publications)
   assertEquals(0,repo.store.obsoletePublications);assertEquals(1,store.snapshot(repo.access)!!.files.size)
  }}finally{gate.countDown();jobs.cancel();root.deleteRecursively()}
 }
 @Test fun wholeScanFoldsProvenPickerRowsAndDropsTheRest()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-legacy-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO)
  try {val path=File(root,"domain.json");Legacy.write(path);DeviceListeningStore(path).use {store->
   val repo=Repository(store,jobs)
   repo.platform.rows=listOf(Observation("indexed:9",providerObject="heard-key",filename="heard.wav",title="heard"),Observation("indexed:41",providerObject="index-key",filename="picked.wav",title="picked"))
   repo.platform.proven=mapOf("picker-key" to IndexKeyProof("index-key",sameContent=false))
   repo.refresh();repo.settled()
   assertEquals(setOf("picker-key","unproven-key"),repo.platform.asked.single().toSet())
   val snapshot=store.snapshot(repo.access)!!
   assertEquals("The picked row is re-keyed in place; the unproven one is gone",setOf(Legacy.heard.id,Legacy.picked.id),snapshot.files.map {it.id}.toSet())
   val picked=snapshot.files.single {it.id==Legacy.picked.id}
   assertEquals(ProviderObjectId("android-content","index-key"),picked.objectId)
   assertEquals(listOf("indexed:41"),picked.aliases.map {it.locator.value})
   assertEquals(mapOf(Legacy.heard.id to 1000L,Legacy.picked.id to 3000L),snapshot.history.associate {(it.key as HistoryKey.Device).id to it.playedAtEpochMs})
   assertEquals(650000L,snapshot.history.single {it.key==HistoryKey.Device(Legacy.picked.id)}.bookmark!!.positionMs)
   assertEquals(700000L,snapshot.history.single {it.key==HistoryKey.Device(Legacy.heard.id)}.bookmark!!.positionMs)
   assertEquals(emptySet<ProviderObjectId>(),store.legacyObjects(repo.access)!!.keys)
   assertEquals(listOf(GrantKind.INDEXED),decodeDomain(path.readBytes()).grants.map {it.kind})
   // Idempotent: the next refresh neither asks again nor rewrites the store.
   val bytes=path.readBytes();repo.refresh();repo.settled()
   assertEquals(emptyList<String>(),repo.platform.asked.last().toList());assertArrayEquals(bytes,path.readBytes())
  }}finally{jobs.cancel();root.deleteRecursively()}
 }
 @Test fun pickerRowsWaitForAccessAndForWholeCoverageBeforeAnyIsDropped()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-legacy-wait-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO)
  try {val path=File(root,"domain.json");Legacy.write(path);DeviceListeningStore(path).use {store->
   val repo=Repository(store,jobs)
   repo.platform.rows=listOf(Observation("indexed:9",providerObject="heard-key",filename="heard.wav",title="heard"))
   repo.platform.storage=false;repo.refresh();repo.settled()
   assertEquals("Without access nothing can be proved, so nothing is dropped",2,store.legacyObjects(repo.access)!!.size)
   assertEquals(listOf(Legacy.heard.id),store.snapshot(repo.access)!!.files.map {it.id})
   repo.platform.storage=true;repo.platform.indexing=false;repo.refresh();repo.settled()
   assertEquals("An incomplete walk may not have indexed a picked file yet",2,store.legacyObjects(repo.access)!!.size)
   assertEquals(0,repo.store.retirements)
   repo.platform.indexing=true;repo.platform.fail="indexed:9";repo.refresh();repo.settled()
   assertEquals("An unproved index row keeps them too",2,store.legacyObjects(repo.access)!!.size)
   repo.platform.fail=null;repo.refresh();repo.settled()
   assertEquals(emptySet<ProviderObjectId>(),store.legacyObjects(repo.access)!!.keys)
   assertEquals(listOf(Legacy.heard.id),decodeDomain(path.readBytes()).files.map {it.id})
  }}finally{jobs.cancel();root.deleteRecursively()}
 }
 @Test fun rowOnlyPickerKeysFoldOnlyWithTheSameBytes()=runBlocking {
  for(same in listOf(true,false)) {
   val root=java.nio.file.Files.createTempDirectory("refresh-legacy-bytes-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO)
   try {val path=File(root,"domain.json");Legacy.write(path);DeviceListeningStore(path).use {store->
    val repo=Repository(store,jobs)
    repo.platform.rows=listOf(Observation("indexed:9",providerObject="heard-key",filename="heard.wav",title="heard"),Observation("indexed:41",providerObject="index-key",filename="picked.wav",title="picked"))
    // An Android 10 `provider:` key names the row but not its incarnation: the bytes must match too.
    repo.platform.proven=mapOf("picker-key" to IndexKeyProof("index-key",sameContent=true))
    if(!same)repo.platform.sha="c".repeat(64)
    repo.refresh();repo.settled()
    val files=store.snapshot(repo.access)!!.files
    val picked=files.single {it.objectId==ProviderObjectId("android-content","index-key")}
    if(same)assertEquals(Legacy.picked.id,picked.id) else assertNotEquals("Other bytes are another file: no fold",Legacy.picked.id,picked.id)
    assertEquals(if(same)650000L else null,store.snapshot(repo.access)!!.history.singleOrNull {it.key==HistoryKey.Device(picked.id)}?.bookmark?.positionMs)
   }}finally{jobs.cancel();root.deleteRecursively()}
  }
 }
 @Test fun withoutASharedStorageWalkNoPickerRowIsDropped()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-legacy-nowalk-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO)
  try {val path=File(root,"domain.json");Legacy.write(path);DeviceListeningStore(path).use {store->
   val repo=Repository(store,jobs)
   repo.platform.walks=false  // Android 10 and earlier: the index is read, but storage is never walked.
   repo.platform.rows=listOf(Observation("indexed:9",providerObject="heard-key",filename="heard.wav",title="heard"),Observation("indexed:41",providerObject="index-key",filename="picked.wav",title="picked"))
   repo.platform.proven=mapOf("picker-key" to IndexKeyProof("index-key",sameContent=false))
   repo.refresh();repo.settled()
   assertEquals(PhoneScanObservation(indexed=true,complete=true,storage=true),repo.lastScan)
   assertEquals(0,repo.store.retirements)
   // The proved row still folds (and shows); the unproven one waits, hidden, with its state.
   assertTrue(store.snapshot(repo.access)!!.files.any {it.id==Legacy.picked.id})
   assertTrue(ProviderObjectId("android-content","unproven-key") in store.legacyObjects(repo.access)!!.keys)
   assertTrue(decodeDomain(path.readBytes()).journal.any {it.key==HistoryKey.Device(Legacy.unproven.id)})
  }}finally{jobs.cancel();root.deleteRecursively()}
 }
 @Test fun partialEnumerationAndRetiredProofNeverReplaceAcknowledgedCorpus()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-cancel-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO)
  try {DeviceListeningStore(File(root,"domain.json")).use {store->
   val repo=Repository(store,jobs);repo.refresh();repo.settled();val old=store.snapshot(repo.access)!!.files
   repo.platform.rows=listOf(Observation("prefix"));repo.platform.complete=false;repo.refresh();repo.settled();assertEquals(old,store.snapshot(repo.access)!!.files)
   repo.platform.complete=true;val gate=java.util.concurrent.CountDownLatch(1);repo.platform.gate=gate;var valid=true
   repo.refresh {valid};while(repo.platform.proofs<2)delay(1);valid=false;gate.countDown();repo.settled()
   assertEquals(old,store.snapshot(repo.access)!!.files)
  }}finally{jobs.cancel();root.deleteRecursively()}
 }
}
'''
a.generate.mkdir(parents=True,exist_ok=True)
(a.generate/'PhoneRefreshTest.kt').write_text(header.replace('REFRESH',refresh).replace('ADVANCE',advance).replace('PROOF_EPOCH',proof_epoch))
