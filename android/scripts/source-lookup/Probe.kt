package com.soundq.android.lookupprobe

import com.soundq.android.AppGraph
import com.soundq.android.data.*
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.playback.*
import com.soundq.android.playback.nativeengine.*
import androidx.media3.common.MediaItem
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

private fun id(n:Long)=DeviceFileId(UUID(0,n))
private val revision=ContentRevision("a".repeat(64),8)
private val otherRevision=ContentRevision("b".repeat(64),8)
private val grantId=ScanGrantId(UUID(1,1))
private fun alias(n:Int=0,state:AccessState=AccessState.AVAILABLE)=LocatorAccess(grantId,ProviderLocator("fixture","content://media/external/audio/media/$n"),state)
private fun row(n:Long,rev:ContentRevision=revision,inc:Long=1,available:Boolean=true)=DeviceAudio(id(n),ProviderObjectId("fixture","$n"),rev,inc,OriginalMetadata("$n.mp3"),900000,listOf(alias(1,AccessState.MISSING),alias(2,AccessState.MISSING),alias(3,AccessState.MISSING),alias(4,if(available)AccessState.AVAILABLE else AccessState.MISSING)))
private fun ref(r:DeviceAudio)=PlaybackRef.Device(r.id.value.toString(),r.revision.sha256,r.revision.byteLength,r.incarnation)
private fun snapshot(files:List<DeviceAudio>,retired:List<RetiredDeviceIdentity> = emptyList())=DeviceListeningSnapshot(1,files,emptyList(),emptyList(),retired)
private fun legacy(s:DeviceListeningSnapshot,r:PlaybackRef.Device,retained:Boolean=false):DeviceAudio? {
 val file=DeviceFileId(UUID.fromString(r.id));val rev=ContentRevision(r.sha256,r.bytes)
 s.files.singleOrNull {it.id==file}?.let {return it.takeIf {it.revision==rev&&it.incarnation==r.incarnation&&(retained||it.available)}}
 val owner=ContentOwner(HistoryKey.Device(file),rev,r.incarnation)
 val fold=s.retired.singleOrNull {it.from==owner} ?: return null
 return s.files.singleOrNull {it.id==fold.into&&it.revision==rev&&(retained||it.available)}
}
private fun legacyAuthority(s:DeviceListeningSnapshot,r:PlaybackRef.Device):DeviceFileId {
 val file=DeviceFileId(UUID.fromString(r.id));val owner=ContentOwner(HistoryKey.Device(file),ContentRevision(r.sha256,r.bytes),r.incarnation)
 return s.retired.singleOrNull {it.from==owner}?.into ?: file
}
private class Fixture(size:Int=1,folded:Boolean=false):AutoCloseable {
 val dir=java.nio.file.Files.createTempDirectory("lookup-").toFile()
 val graph=AppGraph(dir)
 val phone=graph.phoneAudio
 val store=DeviceListeningStore(java.io.File(dir,"library.json"))
 val access=store.unlock()
 val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default)
 val grants=ConcurrentHashMap<String,MediaGrant>()
 val uri="soundq:device/selected"
 val selected:DeviceAudio
 val reference:PlaybackRef.Device
 val permit:MediaGrant
 val player:CanonicalPrepare
 lateinit var lease:OriginalAudioReadLease
 lateinit var playerCurrent:()->Boolean
 val view:DeviceListeningSnapshot
 init {
  val scanGrant=ScanGrant(grantId,GrantKind.INDEXED,"fixture",alias().locator,true)
  check(store.putGrant(access,scanGrant)!=Mutation.REFUSED)
  check(store.publishScan(checkNotNull(store.beginScan(access,grantId)),listOf(DiscoveredAudio(ProviderObjectId("fixture","selected"),alias().locator,revision,OriginalMetadata("selected.mp3"),900000)))!=Mutation.REFUSED)
  selected=store.snapshot(access)!!.files.single()
  phone.setup(store,access)
  val rows=(1 until size).map {row(it.toLong())}+selected
  val old=ref(row(90001))
  val folds=(1 until size).map {RetiredDeviceIdentity(ContentOwner(HistoryKey.Device(id(100000+it.toLong())),revision,1),selected.id)}+
   if(folded)listOf(RetiredDeviceIdentity(ContentOwner(HistoryKey.Device(id(90001)),revision,1),selected.id))else emptyList()
  Work.reset()
  view=store.snapshot(access)!!.copy(files=rows,retired=folds).sealForTest();phone.install(view)
  println("PUBLICATION files=$size retired=${folds.size} visits/uuid/regex/revision/owner=${Work.snapshot()}")
  reference=if(folded)old else ref(selected)
  permit=MediaGrant(reference,graph.session.version(),phone.sourceAuthority(reference));grants[uri]=permit
  player=CanonicalPrepare(graph,grants,listOf(MediaItem(android.net.Uri.parse(uri))),scope)
  player.owner.onLoad={source,current -> lease=((source as NativePlaybackSource.BorrowedOriginal).reader as AndroidPlatformWindowReader).lease;playerCurrent=current}
 }
 suspend fun prepare(){player.prepare();check(player.selectedLoaded){"ordinary prepare did not accept: ${player.error}"};check(permit.phoneAdmission!=null);check(playerCurrent());lease.beginOperation()}
 override fun close(){player.owner.source?.release();scope.cancel();phone.stop();dir.deleteRecursively();check(android.os.ParcelFileDescriptor.open.isEmpty())}
}
private var passed=0
private val failed=mutableListOf<String>()
private fun test(name:String,body:()->Unit) {try{body();passed++;println("PASS $name")}catch(t:Throwable){failed+=name;println("FAIL $name: $t");t.printStackTrace()}}

private fun derivedEntries(snapshot:DeviceListeningSnapshot):Int {
 val field=snapshot.javaClass.declaredFields.find {it.name=="lookup"} ?: return 0
 field.isAccessible=true;val lookup=field.get(snapshot) ?: return 0
 val seen=java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Any,Boolean>())
 fun count(value:Any?):Int {
  if(value==null||!seen.add(value))return 0
  if(value is Map<*,*>)return value.size+value.values.sumOf {count(it)}
  if(!value.javaClass.name.startsWith("com.soundq.android.data.deviceaudio.PublishedSourceLookup"))return 0
  return value.javaClass.declaredFields.filterNot {java.lang.reflect.Modifier.isStatic(it.modifiers)}.sumOf {it.isAccessible=true;count(it.get(value))}
 }
 return count(lookup)
}
fun main()=runBlocking {
 test("actualFullCallerLargeLibraryHasNoRepeatedIdentityOrCollectionWork") {
  val observations=mutableListOf<List<Long>>()
  for(size in listOf(1,20000))for(fold in listOf(false,true))Fixture(size,fold).use {f ->
   runBlocking {f.prepare()}
   // Publication, real store admission and descriptor acquisition are outside the hot interval.
   Work.reset()
   f.lease.metadataScan {b -> repeat(128){check(b.readAt(0,ByteArray(4),0,4)==4)}}
   val work=Work.snapshot();observations+=work
   println("WORK files=$size retired=${f.view.retired.size} folded=$fold headers=128 visits/uuid/regex/revision/owner=$work")
   check(Work.callbackChecks>=256&&Work.grantChecks==2*Work.callbackChecks&&Work.repositoryChecks==3*Work.callbackChecks&&Work.sessionChecks==Work.repositoryChecks){"Lost full validator composition"}
   println("COMPOSITION active=${Work.callbackChecks} grants=${Work.grantChecks} repository=${Work.repositoryChecks} session=${Work.sessionChecks}")
   check(f.playerCurrent()&&f.lease.active)
  }
  check(observations.all {it.all {n->n==0L}}){"Repeated full current traverses collections or constructs identity: $observations"}
 }
 test("legacyOracleDirectFoldAmbiguityAndAvailability") {
  Fixture().use {f ->
   val a=row(1);val b=row(2,inc=8);val old=ref(a);val fold=RetiredDeviceIdentity(a.owner,b.id)
   val cases=listOf(
    snapshot(listOf(a)), snapshot(listOf(a.copy(revision=otherRevision),b),listOf(fold)),
    snapshot(listOf(a.copy(incarnation=2),b),listOf(fold)),snapshot(listOf(a.copy(aliases=listOf(alias(state=AccessState.MISSING))),b),listOf(fold)),
    snapshot(listOf(b),listOf(fold)),snapshot(listOf(a,a,b),listOf(fold)),
    snapshot(listOf(b),listOf(fold,fold)),snapshot(listOf(b,b),listOf(fold)),
    snapshot(listOf(b,b.copy(aliases=listOf(alias(state=AccessState.MISSING)))),listOf(fold)),
    snapshot(listOf(b,b.copy(revision=otherRevision)),listOf(fold)),snapshot(emptyList(),listOf(fold)),
    snapshot(listOf(b.copy(revision=ContentRevision(revision.sha256,9))),listOf(fold)),snapshot(listOf(a,b),listOf(fold)),
    snapshot(listOf(a.copy(revision=otherRevision),a.copy(incarnation=3),b),listOf(fold)),
    snapshot(listOf(b),listOf(fold,RetiredDeviceIdentity(a.owner,id(3))))
   )
   for((n,raw) in cases.withIndex()) {
    val s=raw.sealForTest();f.phone.install(s)
    for(r in listOf(old,ref(b),old.copy(bytes=9),old.copy(incarnation=2))) {
     val i=DeviceFileId(UUID.fromString(r.id));val v=ContentRevision(r.sha256,r.bytes)
     check(s.resolve(i,v,r.incarnation)==legacy(raw,r)){"resolve case $n $r"}
     check(s.resolveRetained(i,v,r.incarnation)==legacy(raw,r,true)){"retained case $n $r"}
     check(f.phone.sourceFileId(r)==legacyAuthority(raw,r)){"authority case $n $r"}
    }
   }
   f.phone.install(null);check(f.phone.observed(old)==null&&f.phone.sourceFileId(old)==id(1))
  }
 }
 test("randomizedLegacyOracleKeepsDuplicateAndFoldMultiplicity") {
  val random=java.util.Random(717)
  val rows=(1L..3L).flatMap {n->listOf(row(n),row(n,inc=2),row(n,rev=otherRevision),row(n,available=false))}
  val folds=listOf(RetiredDeviceIdentity(row(4).owner,id(1)),RetiredDeviceIdentity(row(4).owner,id(2)),RetiredDeviceIdentity(row(1).owner,id(2)),RetiredDeviceIdentity(row(2,inc=2).owner,id(3)))
  val refs=(1L..4L).flatMap {n->listOf(ref(row(n)),ref(row(n,inc=2)),ref(row(n,rev=otherRevision)))}
  repeat(1000) {case ->
   val raw=snapshot(List(random.nextInt(9)){rows[random.nextInt(rows.size)]},List(random.nextInt(7)){folds[random.nextInt(folds.size)]})
   val indexed=raw.sealForTest()
   for(r in refs) {
    val i=DeviceFileId(UUID.fromString(r.id));val v=ContentRevision(r.sha256,r.bytes)
    check(indexed.resolve(i,v,r.incarnation)==legacy(raw,r)){"random resolve $case"}
    check(indexed.resolveRetained(i,v,r.incarnation)==legacy(raw,r,true)){"random retained $case"}
   }
   // Arbitrary caller validation order, including direct-first malformed incarnation.
   for(inc in listOf(0L,-1L)) {
    val before=runCatching {raw.resolve(id(1),revision,inc)}
    val after=runCatching {indexed.resolve(id(1),revision,inc)}
    check(before.getOrNull()==after.getOrNull()&&before.exceptionOrNull()?.javaClass==after.exceptionOrNull()?.javaClass)
   }
  }
 }
 for(kind in listOf("session-retire","local-lock","version","permit","generation","release","remove","incarnation","revision","alias","selected-authority","mutation","fold-mutation"))test("fullCurrentRetiresBeforeNextPread-$kind") {
  Fixture(32,kind=="fold-mutation").use {f ->
   runBlocking {f.prepare()}
   if(kind=="local-lock")check(f.graph.session.accept(f.graph.session.beginIntent(),SecretTokens("fixture-access","fixture-refresh","account"))).also {f.phone.acceptVersion(f.graph.session.version())}
   // Local-lock case needs a newly captured session version and grant after real authentication.
   if(kind=="local-lock") {f.player.owner.source?.release();f.grants[f.uri]=MediaGrant(f.reference,f.graph.session.version(),f.phone.sourceAuthority(f.reference));f.player.selectedLoaded=false;runBlocking{f.prepare()}}
   val before=android.system.Os.reads
   val result=runCatching {f.lease.metadataScan {b ->
    b.readAt(0,ByteArray(4),0,4)
    when(kind) {
     "session-retire"->f.graph.session.retire()
     "local-lock"->check(f.graph.session.lockLocal())
     "version"->f.phone.acceptVersion(-1)
     "permit"->f.grants[f.uri]=MediaGrant(f.reference,f.permit.version,f.permit.audioRevision)
     "generation"->f.player.epoch++
     "release"->f.player.released=true
     "remove"->f.phone.install(f.view.copy(files=f.view.files.filterNot {it.id==f.selected.id}).sealForTest())
     "incarnation"->f.phone.install(f.view.copy(files=listOf(f.selected.copy(incarnation=f.selected.incarnation+2))).sealForTest())
     "revision"->f.phone.install(f.view.copy(files=listOf(f.selected.copy(revision=otherRevision))).sealForTest())
     "alias"->f.phone.install(f.view.copy(files=listOf(f.selected.copy(aliases=listOf(alias(state=AccessState.REVOKED))))).sealForTest())
     "selected-authority"->f.phone.authority(f.selected.id)
     "mutation","fold-mutation"->checkNotNull(f.phone.beginFileMutation(f.reference))
    }
    b.readAt(0,ByteArray(4),0,4)
   }}
   check(result.isFailure){"retired callback returned success"};check(android.system.Os.reads-before==1L){"retired before next pread not honored"}
   check(!f.lease.active&&runCatching {f.lease.beginOperation()}.isFailure)
  }
 }
 test("unrelatedFailureHistoryPublicationAndMutationReleaseStayLive") {
  Fixture(32,true).use {f ->
   runBlocking {f.prepare()};f.phone.authority(id(2));check(f.playerCurrent())
   f.phone.install(f.view.copy(history=listOf(ListeningHistory(HistoryKey.Device(id(2)),5,null))).sealForTest());check(f.playerCurrent())
   val mutation=checkNotNull(f.phone.beginFileMutation(f.reference));check(!f.playerCurrent());f.phone.endFileMutation(mutation);check(f.playerCurrent())
   f.lease.metadataScan {check(it.readAt(0,ByteArray(4),0,4)==4)}
  }
 }
 test("derivedStorageIsInputBoundedNotLookupHistory") {
  Fixture(20000,true).use {f ->
   val before=derivedEntries(f.view)
   check(before<=8*(f.view.files.size+f.view.retired.size))
   val refs=(1..128).map {ref(row(500000L+it))}
   repeat(3){for(r in refs)check(f.phone.observed(r)==null)}
   check(derivedEntries(f.view)==before)
   println("STORAGE files=${f.view.files.size} retired=${f.view.retired.size} aliases=${f.view.files.sumOf {it.aliases.size}} derivedMapEntries=$before after384Misses=${derivedEntries(f.view)}")
  }
 }
 test("actualStorePublicationAndRowLocalFailureCompatibility") {
  Fixture().use {f ->
   runBlocking {f.prepare()}
   // StateFlow conflates equal snapshots; publish a real history-only difference.
   f.phone.install(f.view.copy(history=listOf(ListeningHistory(HistoryKey.Device(f.selected.id),5,null))).sealForTest())
   val old=f.phone.state.value.snapshot
   f.phone.republish();check(f.phone.state.value.snapshot!==old&&f.playerCurrent())
   val scan=f.store.beginScan(f.access,grantId)!!
   check(f.store.publishScan(scan,listOf(DiscoveredAudio(ProviderObjectId("fixture","other"),alias(99).locator,revision,OriginalMetadata("other.mp3"),900000)),complete=false)!=Mutation.REFUSED)
   f.phone.republish();check(f.playerCurrent())
   val other=f.phone.state.value.snapshot!!.files.single {it.objectId.objectId=="other"}
   val admission=runBlocking {checkNotNull(f.phone.admit(other))}
   runBlocking {f.phone.reportFailure(admission,java.io.FileNotFoundException("fixture"))}
   check(f.playerCurrent());check(f.phone.observed(ref(other))==null)
   runBlocking {f.phone.reportFailure(checkNotNull(f.permit.phoneAdmission),java.io.FileNotFoundException("fixture"))}
   check(!f.playerCurrent())
   check(runCatching {f.lease.metadataScan {it.readAt(0,ByteArray(4),0,4)}}.isFailure)
  }
 }
 test("oldLeaseNeverResurrectsAfterObservedRemovalOrAccountABA") {
  for(kind in listOf("removal","account","lock"))Fixture().use {f ->
   runBlocking {f.prepare()}
   if(kind=="removal")f.phone.install(f.view.copy(files=emptyList()).sealForTest())
   else if(kind=="account")f.graph.session.retire()
   else {check(f.graph.session.accept(f.graph.session.beginIntent(),SecretTokens("a","b","same")));check(f.graph.session.lockLocal())}
   check(runCatching {f.lease.metadataScan {it.readAt(0,ByteArray(4),0,4)}}.isFailure)
   when(kind){
    "removal"->f.phone.install(f.view)
    "account"->{check(f.graph.session.accept(f.graph.session.beginIntent(),SecretTokens("a","b","same")));f.phone.acceptVersion(f.graph.session.version())}
    else->{check(f.graph.session.completeLocalUnlock(checkNotNull(f.graph.session.localUnlockTicket())));f.phone.acceptVersion(f.graph.session.version())}
   }
   check(runCatching {f.lease.beginOperation()}.isFailure&& !f.lease.active)
  }
 }
 test("wireAndCopyKeepFourPrimaryFieldsAndStrictValidation") {
  val r=ref(row(1));val expected="{\"kind\":\"device\",\"id\":\"${r.id}\",\"sha256\":\"${r.sha256}\",\"bytes\":8,\"incarnation\":1}"
  check(r.wire()==expected&&PlaybackRef.read(expected)==r)
  val encoded=Json.encodeToString(r);check(Json.parseToJsonElement(encoded).jsonObject.keys==setOf("id","sha256","bytes","incarnation"));check(Json.decodeFromString<PlaybackRef.Device>(encoded)==r)
  val next=r.copy(id=id(2).value.toString(),incarnation=2);check(PlaybackRef.read(next.wire())==next&&next!=r)
  for(bad in listOf("A".repeat(64),"a".repeat(63),"g".repeat(64)))check(runCatching {r.copy(sha256=bad)}.isFailure)
  check(runCatching {r.copy(bytes=-1)}.isFailure);check(runCatching {r.copy(incarnation=0)}.isFailure)
  check(runCatching {r.copy(id="0-0-0-0-1")}.isFailure);check(runCatching {r.copy(id="00000000-0000-0000-0000-00000000000A")}.isFailure)
 }
 test("sealedBuilderAliasCopyAndRepublicationCoherence") {
  val aliases=mutableListOf(alias());val files=mutableListOf(row(1).copy(aliases=aliases));val retired=mutableListOf<RetiredDeviceIdentity>();val grants=mutableListOf<ScanGrant>();val history=mutableListOf<ListeningHistory>()
  val raw=DeviceListeningSnapshot(1,files,grants,history,retired);val sealed=raw.sealForTest();val r=ref(files.single())
  aliases.clear();files.clear();retired.add(RetiredDeviceIdentity(row(5).owner,id(2)));history.add(ListeningHistory(HistoryKey.Device(id(5)),1,null))
  check(sealed.resolve(id(1),revision,1)!=null&&sealed.files.single().available&&sealed.retired.isEmpty()&&sealed.history.isEmpty())
  check(runCatching {(sealed.files as MutableList).clear()}.isFailure);check(runCatching {(sealed.files.single().aliases as MutableList).clear()}.isFailure)
  check(runCatching {(sealed.retired as MutableList).clear()}.isFailure);check(runCatching {(sealed.grants as MutableList).clear()}.isFailure);check(runCatching {(sealed.history as MutableList).clear()}.isFailure)
  val copied=sealed.copy(files=listOf(row(2))).sealForTest();check(copied.resolve(id(1),revision,1)==null&&copied.resolve(id(2),revision,1)!=null)
  val sameRevision=sealed.copy(files=listOf(row(1,inc=3))).sealForTest();check(sameRevision.resolve(id(1),revision,1)==null)
  check(PlaybackRef.read(r.wire())==r)
 }
 println("RESULT passed=$passed failed=${failed.size} failures=$failed")
 check(failed.isEmpty())
}
