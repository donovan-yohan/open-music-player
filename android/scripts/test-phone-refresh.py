#!/usr/bin/env python3
"""Execute exact repository refresh against real domain storage and declared provider facade."""
from pathlib import Path
import argparse
p=argparse.ArgumentParser();p.add_argument('--generate',type=Path,required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[1]
s=(root/'app/src/main/kotlin/com/soundq/android/data/device/PhoneAudioRepository.kt').read_text()
refresh=s[s.index('    private val refreshEpoch='):s.index('    fun observed(')]
header='''package com.soundq.android.refreshprobe
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.data.device.PhoneScanObservation
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID
import java.io.File
import org.junit.Assert.*
import org.junit.Test
private class Uri(val value:String) {companion object {fun parse(v:String)=Uri(v)};override fun toString()=value}
private class Session {@Volatile var version=1L;fun version()=version}
private class Resolver {@Volatile var persistedUriPermissions=emptyList<Permission>()}
private class Permission(val uri:Uri,val isReadPermission:Boolean=true)
private class Context {val contentResolver=Resolver()}
private class Graph {val session=Session();val applicationContext=Context()}
private data class Observation(val locator:String,val providerObject:String=locator,val filename:String=locator,val title:String=locator,val artist:String?=null,val album:String?=null,val durationMs:Long?=601000)
private data class Coverage(val observations:List<Observation>,val indexedComplete:Boolean=true,val truncated:Boolean=false,val unavailableGrants:Set<String> = emptySet())
private data class Proof(val sha256:String="a".repeat(64),val bytes:Long=123)
private class Platform {
 var rows=listOf(Observation("one"));var complete=true;var fail:String?=null;var gate:java.util.concurrent.CountDownLatch?=null
 val entered=java.util.concurrent.CountDownLatch(1);var proofs=0;var discoveries=0;var cancelled=0
 @Volatile var allowed=true
 @Volatile var trees=emptyList<String>()
 @Volatile var accessRevision=0
 fun indexedAllowed()=allowed
 fun persistedTrees()=trees
 fun metadata(uri:Uri,value:String=uri.toString()):Observation=Observation(value)
 fun validTree(uri:Uri)=uri.toString().startsWith("tree:")
 fun persist(uri:Uri,flags:Int,folder:Boolean){error("Fixture uses session-only selected file")}
 fun folderLabel(value:String)=value
 fun release(value:String){trees=trees.filterNot {it==value}}
 fun discover(trees:List<String>,current:()->Boolean,includeIndexed:Boolean=true):Coverage {discoveries++;return Coverage(rows,indexedComplete=complete)}
 fun proof(uri:String,current:()->Boolean):Proof {proofs++;entered.countDown();gate?.await();if(!current()){cancelled++;throw CancellationException()};if(uri==fail)error("Unreadable original");return Proof()}
}
private data class State(val refreshing:Boolean=false,val permission:Boolean=true,val message:String?=null)
// Record attempted obsolete publications, not merely domain refusal or eventual trailing state.
private class RecordingStore(val domain:DeviceListeningStore,val platform:Platform) {
 val scans=mutableMapOf<ScanCapture,Int>();var obsoletePublications=0;var publications=0
 @Volatile var publishGate:java.util.concurrent.CountDownLatch?=null;val publishing=java.util.concurrent.CountDownLatch(1)
 fun snapshot(a:AccessCapture)=domain.snapshot(a)
 fun putGrant(a:AccessCapture,g:ScanGrant)=domain.putGrant(a,g)
 fun removeGrant(a:AccessCapture,g:ScanGrantId)=domain.removeGrant(a,g)
 fun beginScan(a:AccessCapture,g:ScanGrantId)=domain.beginScan(a,g)?.also {scans[it]=platform.accessRevision}
 fun publishScan(s:ScanCapture,rows:List<DiscoveredAudio>,complete:Boolean=true):Mutation {
  publications++;if(scans[s]!=platform.accessRevision)obsoletePublications++
  publishing.countDown();publishGate?.await()
  return domain.publishScan(s,rows,complete)
 }
}
private class Repository(domain:DeviceListeningStore,val jobs:CoroutineScope) {
 val graph=Graph();val platform=Platform();val store=RecordingStore(domain,platform);val access=domain.unlock();val mutable=MutableStateFlow(State())
 val serial=Mutex();var authorityVersion=0L
 @Volatile var lastScan:PhoneScanObservation?=null
 fun current(version:Long)=version==graph.session.version()
 fun publish(message:String?=null){mutable.value=State(message=message)}
 fun fail(message:String){mutable.value=State(message=message)}
 private fun grantId(v:String)=ScanGrantId(UUID.nameUUIDFromBytes(v.toByteArray()))
 private fun locator(v:String)=ProviderLocator("fixture",v)
REFRESH
 suspend fun settled(){withTimeout(10000){while(jobs.coroutineContext[Job]!!.children.any {it.isActive})delay(1)}}
}
class PhoneRefreshTest {
 private suspend fun accessCase(kind:GrantKind,aba:Boolean) {
  val root=java.nio.file.Files.createTempDirectory("refresh-scope-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO)
  val gate=java.util.concurrent.CountDownLatch(1)
  try {DeviceListeningStore(File(root,"domain.json")).use {store->
   val repo=Repository(store,jobs);val route=if(kind==GrantKind.FOLDER)"tree:one" else "file:one"
   if(kind!=GrantKind.INDEXED) {
    repo.platform.allowed=false
    repo.platform.trees=if(kind==GrantKind.FOLDER)listOf(route) else emptyList()
    repo.graph.applicationContext.contentResolver.persistedUriPermissions=listOf(Permission(Uri(route)))
    assertNotEquals(Mutation.REFUSED,store.putGrant(repo.access,ScanGrant(ScanGrantId(UUID.randomUUID()),kind,"owned",ProviderLocator("fixture",route),true)))
   }
   repo.platform.gate=gate;repo.refresh()
   assertTrue(repo.platform.entered.await(5,java.util.concurrent.TimeUnit.SECONDS))
   if(kind==GrantKind.INDEXED)repo.platform.allowed=false else {
    repo.platform.trees=emptyList();repo.graph.applicationContext.contentResolver.persistedUriPermissions=emptyList()
   }
   repo.platform.accessRevision++;repo.refresh()
   if(aba) {
    if(kind==GrantKind.INDEXED)repo.platform.allowed=true else {
     repo.platform.trees=if(kind==GrantKind.FOLDER)listOf(route) else emptyList()
     repo.graph.applicationContext.contentResolver.persistedUriPermissions=listOf(Permission(Uri(route)))
    }
    repo.platform.accessRevision++;repeat(20){repo.refresh()}
   }
   gate.countDown();repo.settled()
   assertEquals("Retired proof must never invoke publishScan",0,repo.store.obsoletePublications)
   assertEquals(1,repo.platform.cancelled)
   val snapshot=store.snapshot(repo.access)!!
   assertEquals(if(aba)1 else 0,snapshot.files.size)
   assertEquals(if(aba)AccessState.AVAILABLE else AccessState.REVOKED,snapshot.grants.single {it.kind==kind}.state)
   assertEquals(if(aba)1 else 0,repo.store.publications)
  }}finally{gate.countDown();jobs.cancel();root.deleteRecursively()}
 }
 @Test fun indexedObservedRevokeRegrantCannotReviveHeldProof()=runBlocking {accessCase(GrantKind.INDEXED,true)}
 @Test fun persistedFolderRevocationRetiresHeldProof()=runBlocking {accessCase(GrantKind.FOLDER,false)}
 @Test fun persistedFolderObservedRevokeRegrantCannotReviveHeldProof()=runBlocking {accessCase(GrantKind.FOLDER,true)}
 @Test fun persistedFileRevocationRetiresHeldProof()=runBlocking {accessCase(GrantKind.FILE,false)}
 @Test fun persistedFileObservedRevokeRegrantCannotReviveHeldProof()=runBlocking {accessCase(GrantKind.FILE,true)}
 @Test fun changedOwnerRetiresProofAndRetainsOnlyOneFreshTrailingScan()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-owner-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO);val gate=java.util.concurrent.CountDownLatch(1)
  try {DeviceListeningStore(File(root,"domain.json")).use {store->
   val repo=Repository(store,jobs);repo.platform.gate=gate;repo.refresh();assertTrue(repo.platform.entered.await(5,java.util.concurrent.TimeUnit.SECONDS))
   repo.graph.session.version++;repo.platform.accessRevision++;repeat(20){repo.refresh()};gate.countDown();repo.settled()
   assertEquals(0,repo.store.obsoletePublications);assertEquals(1,repo.platform.cancelled);assertEquals(2,repo.platform.discoveries);assertEquals(1,repo.store.publications)
  }}finally{gate.countDown();jobs.cancel();root.deleteRecursively()}
 }
 @Test fun reorderedAndWriteOnlyPersistedPermissionsAreSameEffectiveScope()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-order-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO);val gate=java.util.concurrent.CountDownLatch(1)
  try {DeviceListeningStore(File(root,"domain.json")).use {store->
   val repo=Repository(store,jobs);val resolver=repo.graph.applicationContext.contentResolver
   resolver.persistedUriPermissions=listOf(Permission(Uri("a")),Permission(Uri("b")))
   repo.platform.gate=gate;repo.refresh();assertTrue(repo.platform.entered.await(5,java.util.concurrent.TimeUnit.SECONDS))
   resolver.persistedUriPermissions=listOf(Permission(Uri("b")),Permission(Uri("write-only"),false),Permission(Uri("a")))
   repeat(20){repo.refresh()};gate.countDown();repo.settled()
   assertEquals(0,repo.platform.cancelled);assertEquals(2,repo.platform.discoveries);assertEquals(2,repo.store.publications)
  }}finally{gate.countDown();jobs.cancel();root.deleteRecursively()}
 }
 @Test fun selectedSessionFileRetiresPriorScanEvenWithoutPersistedPermissionChange()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-selected-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO);val gate=java.util.concurrent.CountDownLatch(1)
  try {DeviceListeningStore(File(root,"domain.json")).use {store->
   val repo=Repository(store,jobs);repo.platform.gate=gate;repo.refresh();assertTrue(repo.platform.entered.await(5,java.util.concurrent.TimeUnit.SECONDS))
   repo.platform.accessRevision++;repo.selected(Uri("selected:one"),1,false){true}
   withTimeout(5000){while(store.snapshot(repo.access)!!.grants.none {it.kind==GrantKind.FILE})delay(1)}
   gate.countDown();repo.settled()
   assertEquals(0,repo.store.obsoletePublications);assertEquals(1,repo.platform.cancelled)
   assertTrue(store.snapshot(repo.access)!!.files.any {it.metadata.filename=="selected:one"&&it.available})
  }}finally{gate.countDown();jobs.cancel();root.deleteRecursively()}
 }
 @Test fun removeRetiresPriorScanAndCannotResurrectGrantFromItsOldSnapshot()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-remove-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO);val gate=java.util.concurrent.CountDownLatch(1)
  try {DeviceListeningStore(File(root,"domain.json")).use {store->
   val repo=Repository(store,jobs);val grant=ScanGrant(ScanGrantId(UUID.randomUUID()),GrantKind.FILE,"session",ProviderLocator("fixture","session:one"),false)
   assertNotEquals(Mutation.REFUSED,store.putGrant(repo.access,grant))
   repo.platform.gate=gate;repo.refresh();assertTrue(repo.platform.entered.await(5,java.util.concurrent.TimeUnit.SECONDS))
   repo.platform.accessRevision++;repo.remove(grant){true}
   withTimeout(5000){while(store.snapshot(repo.access)!!.grants.single {it.id==grant.id}.state!=AccessState.REMOVED)delay(1)}
   gate.countDown();repo.settled()
   assertEquals(0,repo.store.obsoletePublications);assertEquals(1,repo.platform.cancelled)
   assertEquals(AccessState.REMOVED,store.snapshot(repo.access)!!.grants.single {it.id==grant.id}.state)
   assertTrue(store.snapshot(repo.access)!!.files.isEmpty())
  }}finally{gate.countDown();jobs.cancel();root.deleteRecursively()}
 }
 @Test fun indexedAccessChangeRetiresHeldProofBeforeAnyPublication()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-access-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO)
  val gate=java.util.concurrent.CountDownLatch(1)
  try {DeviceListeningStore(File(root,"domain.json")).use {store->
   val repo=Repository(store,jobs);repo.platform.gate=gate;repo.refresh()
   assertTrue(repo.platform.entered.await(5,java.util.concurrent.TimeUnit.SECONDS))
   repo.platform.allowed=false;repo.platform.accessRevision++;repo.refresh()
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
 @Test fun finishedRefreshRecordsObservedIndexedAccessAndRetiredRefreshDoesNot()=runBlocking {
  val root=java.nio.file.Files.createTempDirectory("refresh-observed-").toFile();val jobs=CoroutineScope(SupervisorJob()+Dispatchers.IO)
  try {DeviceListeningStore(File(root,"domain.json")).use {store->
   val repo=Repository(store,jobs)
   repo.platform.allowed=false;repo.refresh();repo.settled()
   assertEquals(PhoneScanObservation(indexed=false,complete=true),repo.lastScan)
   repo.platform.allowed=true;repo.refresh();repo.settled()
   assertEquals(PhoneScanObservation(indexed=true,complete=true),repo.lastScan)
   repo.platform.rows=listOf(Observation("healthy"),Observation("bad"));repo.platform.fail="bad";repo.refresh();repo.settled()
   assertEquals(PhoneScanObservation(indexed=true,complete=false),repo.lastScan)
   repo.platform.fail=null;repo.platform.complete=false;repo.refresh();repo.settled()
   assertEquals("Incomplete enumeration observed access without full coverage",PhoneScanObservation(indexed=true,complete=false),repo.lastScan)
   // A retired refresh persists an AVAILABLE grant before proving; it must not record an observation.
   repo.lastScan=null;repo.platform.complete=true;val gate=java.util.concurrent.CountDownLatch(1);repo.platform.gate=gate;var valid=true
   val before=repo.platform.proofs
   repo.refresh {valid};withTimeout(5000){while(repo.platform.proofs<=before)delay(1)};valid=false;gate.countDown();repo.settled()
   assertNull(repo.lastScan)
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
   // Production callers are UI/picker callbacks. Publication holds the refresh lock while it commits the catalog.
   val caller=Thread {repo.refresh()};caller.start();caller.join(2000);val blocked=caller.isAlive
   gate.countDown();caller.join(5000);repo.settled()
   assertFalse("refresh() caller waited for the held catalog publication",blocked)
   assertEquals(0,repo.platform.cancelled);assertEquals(2,repo.platform.discoveries);assertEquals(2,repo.store.publications)
   assertEquals(0,repo.store.obsoletePublications);assertEquals(1,store.snapshot(repo.access)!!.files.size)
  }}finally{gate.countDown();jobs.cancel();root.deleteRecursively()}
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
(a.generate/'PhoneRefreshTest.kt').write_text(header.replace('REFRESH',refresh))
