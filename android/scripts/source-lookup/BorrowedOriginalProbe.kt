package com.soundq.android.lookupprobe

import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.system.Os
import androidx.media3.common.MediaItem
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import com.soundq.android.data.device.*
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.data.originalimport.*
import com.soundq.android.playback.*
import com.soundq.android.playback.nativeengine.*
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

// Player crossfade/retirement bodies and owner drain are inserted verbatim. Only
// queue command delivery, journal scheduling and native output/codec are facades.
private class Output(private val graph:AppGraph) {
    val dispatcher=Dispatchers.Unconfined
    private val borrowed=mutableSetOf<File>()
    private val borrowedOriginals=mutableSetOf<NativePlaybackSource.BorrowedOriginal>()
    private val ordinaryOriginals=mutableMapOf<Int,NativePlaybackSource.BorrowedOriginal>()
    private val ordinaryFiles=mutableMapOf<Int,File>()
    private val previews=mutableMapOf<Int,Any>()
    fun descriptorsDrained(fileId:String?)=graph.phoneAudio.originalDescriptorsDrained(fileId)
    val empty=NativeCallbackDeck(0,0,0,0,0,0,false,false,false,0,0)
    val decks=mutableListOf(empty, empty)
    var loads=0;var arms=0
    private var outgoingId=0L
    fun installOutgoing(identity:Long) { outgoingId=identity;decks[0]=deck(identity) }
    private fun deck(id:Long)=NativeCallbackDeck(id,id,0,6000,48000,288000,true,false,false,0,0)
    fun original(deck:Int)=ordinaryOriginals.getValue(deck)
    suspend fun loadDeck(deck:Int,source:NativePlaybackSource,id:Long,generation:Long,position:Long,current:()->Boolean,speed:Double):Boolean {
        check(id==generation&&position==0L&&current())
        val original=source as NativePlaybackSource.BorrowedOriginal
        check(original.versionCurrent());loads++;decks[deck]=deck(id);ordinaryOriginals[deck]=original
        return true
    }
    suspend fun unloadDeck(deck:Int):Boolean {
        decks[deck]=empty
        val original=ordinaryOriginals[deck] ?: return true
        original.reader.revoke()
        if (!original.release()) return false
        ordinaryOriginals.remove(deck)
        return true
    }
    suspend fun releaseUnborrowed(source:NativePlaybackSource)=source.release()
    suspend fun controlDeck(deck:Int,command:Int,value:Double,current:()->Boolean)=current()
    suspend fun crossfade(a:Int,aid:Long,b:Int,bid:Long,milliseconds:Long,current:()->Boolean):Boolean {
        check(decks[a].identity==aid&&decks[b].identity==bid)
        if (!current()) return false
        if (milliseconds>0) arms++
        return true
    }
    suspend fun snapshot(current:()->Boolean)=if (current()) state() else null
    fun state()=NativeCallbackSnapshot("",0,decks[0],decks.toList())
    fun overlap(eof:Boolean) {
        check(arms==1&&decks[0].identity==outgoingId)
        decks[0]=decks[0].copy(playing=!eof,positionMs=if(eof)6000 else 5000,boundaryGain=if(eof)0.0 else 0.4,eofCount=if(eof)1 else 0)
        decks[1]=decks[1].copy(playing=true,positionMs=if(eof)2000 else 1000,boundaryGain=if(eof)1.0 else 0.8)
    }
    // INSERT_DRAIN
}

private class PairDriver(val graph:AppGraph,val lifetime:CoroutineScope,val itemsAtStart:List<MediaItem>,val grants:ConcurrentHashMap<String,MediaGrant>) {
    private object Player { const val STATE_IDLE=1; const val STATE_BUFFERING=2; const val STATE_READY=3 }
    private val source=OriginalAwareNativeSource(graph,grants)
    val owner=Output(graph)
    private val journal=Journal()
    private class Journal {
        var sourceCurrent:(()->Boolean)?=null
        fun initialResume(s:NativePlaybackSource,g:MediaGrant,d:Int)=0L
        fun retire(deck:Int,drain:Boolean) {}
    }
    private suspend fun bindJournal(item:MediaItem,grant:MediaGrant,source:NativePlaybackSource,deck:Int,id:Long,resume:Boolean,current:()->Boolean,journalCurrent:()->Boolean=current) {
        check(current());journal.sourceCurrent=journalCurrent
    }
    val boundCurrent get()=checkNotNull(journal.sourceCurrent).invoke()
    private val scope=graph.session.capture()!!
    var items=itemsAtStart;var index=0;var released=false;var epoch=2L;var transportRevision=0L
    private var sourceSequence=2L;private var ordinaryDeck=0;private var ordinaryIdentity=2L
    var activeUri:String?=items.firstOrNull()?.localConfiguration?.uri?.toString()
    var activeGrant=activeUri?.let(grants::get)
    private val preview:Any?=null;private val arrangement:Any?=null
    private class Parked(val items:List<MediaItem>)
    private val parkedQueue:Parked?=null;private val arrangementSourceItems=emptyList<MediaItem>()
    private val repeat=0;private var selectedLoaded=items.isNotEmpty();private var playback=Player.STATE_READY
    private var intent=true;private val desiredSeek:Long?=null;private val durations=mutableMapOf<String,Long>()
    private val volume=1f;private val preparing=java.util.concurrent.atomic.AtomicInteger()
    private var tail:Job?=null;private var pending:Job?=null
    private var position=0L;private var eofCount=0L;private var acknowledgedPlaying=false
    val completed=mutableListOf<String>()
    private val completions=listOf<(MediaItem)->Unit>({completed+=it.mediaId})
    init { if (items.size==2) owner.installOutgoing(ordinaryIdentity) }
    private fun selected()=items.getOrNull(index)
    private fun currentScope()=graph.session.current(scope)
    private fun activeOrder()=items.indices.toList()
    private fun loadSpeed(item:MediaItem)=1.0
    private fun fail(message:String):Nothing=error(message)
    private fun pause(){intent=false}
    private fun stop(){retireSelection()}
    private fun retireSelection(){cancelSuccessor();epoch++;activeGrant=null;activeUri=null;selectedLoaded=false}
    private fun dispatchIntent():Nothing=error("expected the retained incoming deck already playing")
    private fun invalidateState(){}
    private fun finishDiscoveryPreview():Nothing=error("preview outside this fixture")
    private fun rebuilt(rows:List<MediaItem>,fallback:Int)=rows.indices.toList()
    private fun mutate(rows:List<MediaItem>,order:List<Int>,fallback:Int,preserve:Boolean){items=rows;index=fallback}
    // INSERT_CROSSFADE
    // INSERT_RETIRE_FILE
    suspend fun arm():OriginalAudioReadLease {
        prepareSuccessor();tail!!.join()
        check(!observeSuccessor(owner.state()));yield();check(owner.arms==1)
        return (owner.original(1).reader as AndroidPlatformWindowReader).lease
    }
    fun advance(eof:Boolean) {owner.overlap(eof);check(observeSuccessor(owner.state())==eof);check(selected()?.mediaId=="incoming")}
    fun editPair()=cancelSuccessor()
    suspend fun drain(){tail?.join()}
    suspend fun close(){owner.unloadDeck(0);owner.unloadDeck(1)}
}

// Actual Delete continuation; the provider, validated capture and installed
// membership are seams, not permission to issue a real filesystem delete.
    // INSERT_OUTCOME
private class Deletion(private val graph:AppGraph,private val resolver:DeleteIterator) {
    class DeleteIterator {
        var calls=0
        fun delete(uri:Uri,where:String,args:Array<String>):Int {calls++;return 1}
        fun query(uri:Uri,c:Array<String>,s:String?,v:Array<String>?,o:String?):android.content.Cursor?=null
    }
    data class Stamp(val deletionSafe:Boolean=true)
    data class PhoneFileTarget(val ref:PlaybackRef.Device,val admission:PhoneSourceAdmission) {
        val stamp=Stamp();val uri=Uri.parse("content://test/survivor");val path="/soundq-fixture-does-not-exist"
        val providerValues=listOf("fixtureId" to "1")
    }
    private val mutation=Mutex()
    private val deleteUnavailableReason:String?=null
    private fun current(t:PhoneFileTarget)=graph.phoneAudio.current(t.admission.sessionVersion)
    private fun matches(t:PhoneFileTarget)=current(t)
    val calls get()=resolver.calls
    suspend fun submit(ref:PlaybackRef.Device,admission:PhoneSourceAdmission,retire:suspend ()->Boolean)=delete(PhoneFileTarget(ref,admission),{true},retire)
    // INSERT_DELETE
}

private class OriginalFixture : AutoCloseable {
    private val dir=java.nio.file.Files.createTempDirectory("borrowed-playback-").toFile()
    val graph=AppGraph(dir)
    val phone=graph.phoneAudio
    private val store=DeviceListeningStore(File(dir,"library.json"))
    private val access=store.unlock()
    private val scan=ScanGrant(ScanGrantId(UUID(10,1)),GrantKind.INDEXED,"fixture",ProviderLocator("test","content://test/index"),true)
    val encoded=byteArrayOf(1,2,3,4,5,6,7,8)
    val revision=ContentRevision(MessageDigest.getInstance("SHA-256").digest(encoded).joinToString(""){"%02x".format(it)},encoded.size.toLong())
    private fun discovery(name:String,vararg former:String)=DiscoveredAudio(ProviderObjectId("test",name),ProviderLocator("test","content://test/$name"),revision,
        OriginalMetadata("$name.mp3"),6000,formerObjectIds=former.map {ProviderObjectId("test",it)}.toSet())
    init {
        check(graph.session.accept(graph.session.beginIntent(),SecretTokens("a","b","fixture")))
        check(store.putGrant(access,scan)!=Mutation.REFUSED)
        publish(discovery("old"),discovery("survivor"),discovery("peer"))
        phone.setup(store,access)
    }
    private fun publish(vararg rows:DiscoveredAudio) {
        check(store.publishScan(checkNotNull(store.beginScan(access,scan.id)),rows.toList())!=Mutation.REFUSED)
    }
    fun row(name:String)=phone.state.value.snapshot!!.files.single {it.objectId.objectId==name}
    fun fold(){publish(discovery("survivor","old"),discovery("peer"));phone.republish()}
    val grants=ConcurrentHashMap<String,MediaGrant>()
    val outgoing=serverItem("outgoing",TrackId(23))
    val incoming=serverItem("incoming",TrackId(24)).also {
        val destination=ServerAccount(graph.endpoint.identity,graph.session.capture()!!.accountId)
        val display=ImportDisplay("exact original","fixture","fixture")
        graph.originalImports.association=OriginalAssociation(OriginalImportIntent(destination,UUID(4,4),row("old").owner,display),
            OriginalMembership(destination,CommittedOriginal(TrackId(24),revision),display,6000))
    }
    private fun serverItem(name:String,track:TrackId):MediaItem {
        val uri="soundq://track/${track.value}/$name"
        grants[uri]=MediaGrant(graph.session.capture()!!,track)
        return MediaItem(Uri.parse(uri),name)
    }
    fun lease():OriginalAudioReadLease {
        graph.applicationContext.opens=0 // same provider object/bytes for each admission
        return ((OriginalAwareNativeSource(graph,grants).acquire(incoming){true} as NativePlaybackSource.BorrowedOriginal).reader as AndroidPlatformWindowReader).lease
    }
    fun read(lease:OriginalAudioReadLease):ByteArray {
        lease.beginOperation()
        val bytes=ByteArray(encoded.size)
        check(lease.readAt(0,bytes,0,bytes.size)==bytes.size)
        return bytes
    }
    override fun close(){phone.stop();dir.deleteRecursively()}
}

private suspend fun promotion(natural:Boolean) = coroutineScope {
    for (loss in listOf("account","source")) OriginalFixture().use { f ->
        val p=PairDriver(f.graph,this,listOf(f.outgoing,f.incoming),f.grants)
        try {
            val lease=p.arm();check(f.read(lease).contentEquals(f.encoded))
            p.advance(natural)
            if (!natural) p.editPair()
            p.drain()
            check(p.completed==if(natural)listOf("outgoing") else emptyList())
            check(p.owner.loads==1&&p.owner.decks[0].identity==0L&&p.owner.decks[1].playing)
            f.grants.remove(f.outgoing.localConfiguration.uri.toString())
            val outcome=runCatching {f.read(lease)}
            check(outcome.getOrNull()?.contentEquals(f.encoded)==true) {"retained incoming original refused post-handoff positioned read: ${outcome.exceptionOrNull()}"}
            check(p.boundCurrent) {"retained incoming journal lost its live binding"}
            if (loss=="account") f.graph.session.retire() else f.graph.originalImports.association=null
            val before=Os.reads
            check(runCatching {f.read(lease)}.isFailure&&Os.reads==before) {"retired $loss reached pread"}
            println("PASS post-handoff bytes; $loss loss now refuses")
        } finally {p.close()}
    }
}

private suspend fun cancellation() = coroutineScope {
    OriginalFixture().use { f ->
        val p=PairDriver(f.graph,this,listOf(f.outgoing,f.incoming),f.grants)
        try {
            val lease=p.arm();check(f.read(lease).contentEquals(f.encoded))
            p.editPair();val prior=Os.reads
            check(runCatching {f.read(lease)}.isFailure&&Os.reads==prior)
            p.drain();check(p.owner.decks[1].identity==0L&&p.owner.decks[0].identity>0L)
            f.lease().use {fresh->check(f.read(fresh).contentEquals(f.encoded))}
            check(runCatching {f.read(lease)}.isFailure)
        } finally {p.close()}
    }
    println("PASS unpromoted cancellation retires old descriptor, fresh acquisition reads")
}

private fun access(aba:Boolean) {
    OriginalFixture().use { f ->
        val platform=f.phone.platform
        f.lease().use { lease ->
            lease.beginOperation()
            val before=platform.accessChecks
            if (aba) {
                var sampled=0;var reads=0L
                val result=runCatching { lease.metadataScan { batch ->
                    check(batch.readAt(0,ByteArray(4),0,4)==4)
                    platform.allowed=false;check(!platform.storageAllowed())
                    platform.allowed=true;check(platform.storageAllowed())
                    sampled=platform.accessChecks;reads=Os.reads
                    batch.readAt(4,ByteArray(4),0,4)
                }}
                check(sampled>before&&result.isFailure&&Os.reads==reads) {"observed permission ABA let old metadata/pre-read escape"}
                check(platform.accessChecks==sampled) {"old metadata guard resampled platform permission on observed ABA"}
                f.lease().use { fresh -> check(f.read(fresh).contentEquals(f.encoded)) }
                println("PASS observed deny/regrant rejects held metadata without platform recheck; fresh descriptor reads")
            } else {
                var checksDuringBatch=0
                lease.metadataScan { batch ->
                    val entered=platform.accessChecks
                    repeat(128) {check(batch.readAt(0,ByteArray(4),0,4)==4)}
                    checksDuringBatch=platform.accessChecks-entered
                }
                val first=platform.accessChecks-before
                println("permission checks during metadata=$checksDuringBatch entry/exit included=$first")
                check(checksDuringBatch==0&&first==4) {"structural metadata guard queried platform permission; entry/exit must remain"}
                val periodic=platform.accessChecks
                lease.metadataScan { batch -> repeat(4097) {batch.step()} }
                check(platform.accessChecks-periodic==6) {"periodic permission sample missing"}
            }
        }
    }
}

private suspend fun destructive(queued:Boolean,matching:Boolean)=coroutineScope {
    OriginalFixture().use { f ->
        val old=f.row("old");val peer=f.row("peer")
        check(old.id!=peer.id&&old.revision==peer.revision)
        // Keep an actual failed duplicate close under an old physical ID, without
        // a queued grant, decoder, or native identity. A separate process owns it.
        val retained=if(matching)old else peer
        val path="/synthetic/${retained.canonicalId}"
        Os.paths[path]=Os.Entry(f.encoded.copyOf())
        val lease=ParcelFileDescriptor.open(File(path),ParcelFileDescriptor.MODE_READ_ONLY).use {
            OriginalAudioReadLease.borrow(it.fileDescriptor,0,-1,path,{true},sourceKey=retained.canonicalId)
        }
        ParcelFileDescriptor.failDuplicateClose=true
        try {check(runCatching {lease.close()}.exceptionOrNull() is IOException)} finally {ParcelFileDescriptor.failDuplicateClose=false}
        check(ParcelFileDescriptor.open.size==1)
        f.fold();val survivor=f.row("survivor");val ref=f.phone.reference(survivor)
        check(f.phone.state.value.snapshot!!.retired.single().from==old.owner)
        check(f.phone.sourceFileId(f.phone.reference(old))==survivor.id)
        f.grants.clear()
        val items=if(!queued)emptyList() else {
            val uri="soundqdevice://survivor";f.grants[uri]=MediaGrant(ref,f.graph.session.version(),f.phone.sourceAuthority(ref))
            listOf(MediaItem(Uri.parse(uri),"survivor",mapOf("playbackRef" to ref.wire())))
        }
        val p=PairDriver(f.graph,this,items,f.grants)
        val delete=Deletion(f.graph,Deletion.DeleteIterator())
        val target=checkNotNull(f.phone.admit(survivor))
        check(f.phone.originalDescriptorsDrained(survivor.canonicalId)) // old key only
        val result=delete.submit(ref,target){p.retirePhoneFile(ref)}
        println("queued=$queued matching=$matching deleteCalls=${delete.calls} result=$result oldId=${old.canonicalId} targetId=${survivor.canonicalId}")
        if (matching) check(delete.calls==0&&result==FileDeleteOutcome.Refused) {"provider delete entered with provider-folded old descriptor still retained"}
        else check(delete.calls==1&&result==FileDeleteOutcome.Deleted) {"unrelated different file with same digest blocked Delete"}
        check(ParcelFileDescriptor.open.size==1)
    }
}

fun main(args:Array<String>)=runBlocking {
    when(args.single()) {
        "natural-promotion" -> promotion(true)
        "midpoint-edit" -> promotion(false)
        "unpromoted-cancellation" -> cancellation()
        "access-hot-guard" -> access(false)
        "access-aba" -> access(true)
        "fold-empty" -> destructive(queued=false,matching=true)
        "fold-queued" -> destructive(queued=true,matching=true)
        "distinct-same-digest" -> destructive(queued=false,matching=false)
        else -> error("unknown selector")
    }
}
