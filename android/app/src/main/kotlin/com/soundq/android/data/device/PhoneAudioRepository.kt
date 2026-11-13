package com.soundq.android.data.device

import android.net.Uri
import com.soundq.android.AppGraph
import com.soundq.android.data.AuthState
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.playback.nativeengine.PhoneAudioStage
import com.soundq.android.playback.nativeengine.AndroidPlatformWindowReader
import com.soundq.android.playback.nativeengine.LiveOriginalVersions
import com.soundq.android.playback.nativeengine.NativePlaybackSource
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.util.UUID

/** [permission] is all files access, the only phone-audio grant. While [refreshing], it is the access the running
 * refresh was admitted with. */
internal data class PhoneAudioState(val ready: Boolean = false, val snapshot: DeviceListeningSnapshot? = null,
    val refreshing: Boolean = false, val permission: Boolean = false, val message: String? = null,
    val scan: PhoneScanObservation? = null)
/** What the last finished refresh in this scope observed: [indexed] when the Android audio index was
 * enumerated and published, [storage] when it ran with all files access (shared storage walked and
 * unlisted audio indexed first), [complete] when that coverage was whole and every row was proved. Not persisted. */
internal data class PhoneScanObservation(val indexed: Boolean, val complete: Boolean, val storage: Boolean = false)
internal data class PhoneSourceAdmission(val row: DeviceAudio, val source: SourceCapture, val sessionVersion: Long, val resumeMs: Long)

/** Android composition for the single released catalog/journal. Every disk-backed store call is IO-only.
 * UI observes copied StateFlow data. It never calls snapshot/capture or invents playback receipts.
 */
internal class PhoneAudioRepository(private val graph: AppGraph) : AutoCloseable {
    val platform = AndroidAudioAccess(graph.applicationContext)
    private val jobs = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val serial = Mutex()
    private var store: DeviceListeningStore? = null
    private var liveVersions:LiveOriginalVersions? = null
    private var access: AccessCapture? = null
    @Volatile private var acceptedVersion = -1L
    @Volatile private var lastScan: PhoneScanObservation? = null
    private val mutable = MutableStateFlow(PhoneAudioState())
    val state: StateFlow<PhoneAudioState> = mutable.asStateFlow()
    fun start() {
        // Older builds persisted file/folder picker grants. All files access replaces them; holding them is moot.
        jobs.launch { runCatching { platform.releaseUriPermissions() } }
        jobs.launch {
            graph.session.scopeRevision.combine(graph.session.state) { _, auth -> graph.session.version() to auth }.collect { (version, auth) ->
                serial.withLock {
                    try {
                        if (store == null) store = DeviceListeningStore(File(graph.directory, "phone-listening.v1.json"))
                        val owner = requireNotNull(store)
                        if (auth is AuthState.LocalLocked || auth is AuthState.Pending || auth is AuthState.Restoring || auth is AuthState.SaveRequired) {
                            acceptedVersion = -1; owner.lock(); access = null; lastScan = null; mutable.value = PhoneAudioState(); return@withLock
                        }
                        val account = graph.session.capture()?.let { ServerAccount(graph.endpoint.identity, it.accountId) }
                        access = owner.unlock(account); acceptedVersion = version; lastScan = null
                        publish()
                    } catch (_: Exception) { fail("Local audio storage could not be opened. Saved state has not been replaced.") }
                }
                if (acceptedVersion == version) refresh()
            }
        }
    }
    fun current(version: Long) = acceptedVersion == version && graph.session.owns(version) && graph.session.state.value !is AuthState.LocalLocked
    // One sequence fences every proof publication. Broad transport and physical-file
    // grants expose separate epochs so a local mutation never retires unrelated audio.
    private val authoritySequence=java.util.concurrent.atomic.AtomicLong()
    private val authorityEpoch=java.util.concurrent.atomic.AtomicLong()
    val authorityVersion get()=authorityEpoch.get()
    private val fileAuthorities=java.util.concurrent.ConcurrentHashMap<DeviceFileId,Long>()
    private fun advanceAuthority(file:DeviceFileId?=null):Long=refreshLocked {
        val next=authoritySequence.updateAndGet {Math.addExact(it,1L)}
        if(file==null)authorityEpoch.set(next) else fileAuthorities[file]=next
        next
    }
    fun sourceFileId(ref:com.soundq.android.playback.PlaybackRef.Device):DeviceFileId {
        val id=DeviceFileId(UUID.fromString(ref.id))
        val owner=ContentOwner(HistoryKey.Device(id),ContentRevision(ref.sha256,ref.bytes),ref.incarnation)
        return state.value.snapshot?.retired?.singleOrNull {it.from==owner}?.into ?: id
    }
    fun originalDescriptorsDrained(fileId:String?):Boolean {
        val keys=fileId?.let {id->setOf(id)+state.value.snapshot?.files.orEmpty().filter {it.id.value.toString()==id}.flatMap {row->row.aliases.map {it.locator.value}}}
        return com.soundq.android.playback.nativeengine.OriginalDescriptorCustody.drained(keys)
    }
    fun sourceAuthority(ref:com.soundq.android.playback.PlaybackRef.Device):Long =
        maxOf(authorityVersion,fileAuthorities[sourceFileId(ref)] ?: 0L)
    private fun publish(message: String? = null, unavailable: ContentOwner? = null) {
        val snapshot = access?.let { store?.snapshot(it) }
        val previous=mutable.value.snapshot
        // Only an acknowledged row-local failure may spare unrelated transport grants.
        // Ordinary scans, revisions, folds and real access changes retain global cancellation.
        if(previous!=null&&snapshot!=null&&(previous.grants!=snapshot.grants||previous.files.any {old->snapshot.files.singleOrNull {it.id==old.id}?.let {next->
            next.owner!=old.owner||(next.aliases!=old.aliases&&!(old.owner==unavailable&&next.aliases.size==old.aliases.size&&old.aliases.all {alias->
                next.aliases.any {it==alias||(it.grantId==alias.grantId&&it.locator==alias.locator&&it.state in setOf(AccessState.MISSING,AccessState.UNREADABLE,AccessState.UNSUPPORTED))}
            }))
        }==true}))advanceAuthority()
        if(previous!=null&&snapshot!=null&&unavailable!=null) {
            val old=previous.files.singleOrNull {it.owner==unavailable}
            val next=snapshot.files.singleOrNull {it.owner==unavailable}
            if(old!=null&&next!=null&&old.aliases!=next.aliases)advanceAuthority(old.id)
        }
        mutable.value = PhoneAudioState(snapshot != null, snapshot, false, platform.storageAllowed(), message ?: if (snapshot == null) "Local audio storage is unavailable. Saved state has not been replaced." else null, lastScan)
    }
    private fun fail(message: String) { mutable.value = mutable.value.copy(refreshing = false, message = message) }
    private val refreshEpoch=java.util.concurrent.atomic.AtomicLong()
    private val refreshLock=java.util.concurrent.locks.ReentrantLock()
    private inline fun <T> refreshLocked(block:()->T):T {refreshLock.lock();try {return block()} finally {refreshLock.unlock()}}
    private val admissionOrder=Any()
    private var deferredAdmissions=0
    private val admissions=Dispatchers.IO.limitedParallelism(1)
    private var refreshRunning=false
    private var pendingRefresh:(()->Unit)?=null
    private data class RefreshScope(val version:Long,val storage:Boolean)
    private var refreshScope:RefreshScope?=null
    fun refresh(valid: () -> Boolean = { true }) {
        // UI callers never wait for a held catalog publication. Uncontended admission stays inline;
        // otherwise admissions queue in caller order and observe once that publication commits or retires.
        synchronized(admissionOrder) {
            if(deferredAdmissions==0&&refreshLock.tryLock()) {try {admit(valid)} finally {refreshLock.unlock()};return}
            deferredAdmissions++
        }
        jobs.launch(admissions) {try {refreshLocked {admit(valid)}} finally {synchronized(admissionOrder) {deferredAdmissions--}}}
    }
    private fun admit(valid: () -> Boolean) {
        // Only redundant owner/access observations may share admitted exact-byte work.
        // Observe under the same lock as publication; every observed ABA retires the old epoch.
        val scope=RefreshScope(graph.session.version(),platform.storageAllowed())
        if(refreshRunning){
            if(refreshScope!=scope)refreshEpoch.incrementAndGet()
            refreshScope=scope
            pendingRefresh={refresh(valid)};return
        }
        refreshScope=scope
        refreshRunning=true
        val refresh=refreshEpoch.incrementAndGet()
        val version = scope.version
        val proofAuthority=authoritySequence.get()
        fun active()=valid()&&current(version)&&refreshEpoch.get()==refresh&&authoritySequence.get()==proofAuthority
        jobs.launch {
            try {
                if (!active()) return@launch
                // Publish the access this refresh was admitted with, so a grant after admission is not masked.
                mutable.value = mutable.value.copy(refreshing = true, permission = scope.storage, message = null)
                val owner = requireNotNull(store); val accepted = requireNotNull(access)
                val indexed = ScanGrant(grantId("indexed:external-audio"), GrantKind.INDEXED, "Android audio index", ProviderLocator("android", "indexed:external-audio"), false,
                    if (scope.storage) AccessState.AVAILABLE else AccessState.REVOKED)
                refreshLocked{if(!active())throw CancellationException();check(owner.putGrant(accepted, indexed) != Mutation.REFUSED)}
                if (!scope.storage) {
                    refreshLocked { if (!active()) throw CancellationException(); lastScan = PhoneScanObservation(false, true, false) }
                    publish(); return@launch
                }
                val scan = owner.beginScan(accepted, indexed.id) ?: error("Android audio index refused")
                // All files access: index audio MediaStore missed, then read the index.
                val storageComplete = try { platform.indexUnlisted { active() } } catch (e: CancellationException) { throw e } catch (_: Exception) { false }
                var complete = true
                val descriptors = try {
                    val result = platform.discover({ active() })
                    check(result.complete && !result.truncated) { "Android audio coverage is partial" }
                    // Rows an older build's picker keyed fold into the index row the provider proves is the same object.
                    val legacy = (owner.legacyObjects(accepted) ?: throw CancellationException()).mapKeys { it.key.objectId }
                    val proven = platform.provenIndexKeys(legacy.keys)
                    result.observations.mapNotNull { observation ->
                        if (!active()) throw CancellationException()
                        try {
                            val proof = platform.proof(observation.locator) { active() }
                            val revision = ContentRevision(proof.sha256, proof.bytes)
                            val former = proven.filter { (old, key) -> key.key == observation.providerObject && (!key.sameContent || legacy[old] == revision) }.keys
                            DiscoveredAudio(ProviderObjectId("android-content", observation.providerObject), locator(observation.locator), revision,
                                OriginalMetadata(observation.filename, observation.title, observation.artist, observation.album, observation.locator), observation.durationMs?.takeIf { it > 0 },
                                formerObjectIds = (observation.aliases - observation.providerObject + former).map { ProviderObjectId("android-content", it) }.toSet())
                        } catch(e:CancellationException){throw e}
                        catch(_:Exception){complete=false;null}
                    }
                } catch (e: CancellationException) { throw e }
                catch (_: Exception) {
                    // Incomplete enumeration is not an empty scan and never permission to publish a prefix.
                    refreshLocked { if (!active()) throw CancellationException(); lastScan = PhoneScanObservation(true, false, true) }
                    publish("Some audio could not be refreshed. Existing files and saved progress were kept."); return@launch
                }
                val whole = complete && storageComplete
                refreshLocked{
                    if (!active()) throw CancellationException()
                    // The index enumeration is whole even if the walk was not: omitted index rows are gone.
                    check(owner.publishScan(scan, descriptors, complete) != Mutation.REFUSED)
                    // Whole coverage, with shared storage walked, has folded every picker row the provider could prove;
                    // the rest are dropped. Without a walk an unindexed picked file could still be proved later.
                    if (whole && platform.walksSharedStorage()) check(owner.retireLegacyAccess(accepted) != Mutation.REFUSED)
                    lastScan = PhoneScanObservation(true, whole, true)
                }
                publish(if (whole) null else "Some audio could not be refreshed. Existing files and saved progress were kept.")
            } catch (_: CancellationException) { if(refreshEpoch.get()==refresh)mutable.value = mutable.value.copy(refreshing = false) }
            catch (_: Exception) { if(active())publish("Some audio could not be refreshed. Existing files and saved progress were kept.") }
            finally {
                val next=refreshLocked{refreshRunning=false;pendingRefresh.also {pendingRefresh=null}}
                next?.invoke()
            }
        }
    }
    /** A saved reference to a row later folded into another (one provider object) resolves to the survivor. */
    private val fileMutations=java.util.concurrent.ConcurrentHashMap<String,UUID>()
    fun beginFileMutation(ref:com.soundq.android.playback.PlaybackRef.Device):UUID? {
        val row=observed(ref) ?: return null
        val token=UUID.randomUUID()
        return if(fileMutations.putIfAbsent(row.id.value.toString(),token)==null)token else null
    }
    fun endFileMutation(token:UUID) {fileMutations.entries.firstOrNull {it.value==token}?.let {fileMutations.remove(it.key,token)}}
    fun sameFile(a:com.soundq.android.playback.PlaybackRef.Device,b:com.soundq.android.playback.PlaybackRef.Device):Boolean {
        val snapshot=state.value.snapshot ?: return false
        fun resolve(ref:com.soundq.android.playback.PlaybackRef.Device)=snapshot.resolve(DeviceFileId(UUID.fromString(ref.id)),ContentRevision(ref.sha256,ref.bytes),ref.incarnation)
        val left=resolve(a) ?: return false
        return resolve(b)?.id==left.id
    }
    suspend fun markFileMissing(admission:PhoneSourceAdmission,uri:String):Boolean=journal(true,admission.source.owner) {owner,_->
        owner.reportUnavailable(admission.source,ProviderLocator(Uri.parse(uri).authority ?: "android",uri),AccessState.MISSING,allAliases=true)!=Mutation.REFUSED
    }==true
    fun observed(ref: com.soundq.android.playback.PlaybackRef.Device): DeviceAudio? =
        state.value.snapshot?.resolve(DeviceFileId(UUID.fromString(ref.id)), ContentRevision(ref.sha256, ref.bytes), ref.incarnation)
            ?.takeUnless {fileMutations.containsKey(it.id.value.toString())}
    fun reference(row:DeviceAudio)=com.soundq.android.playback.PlaybackRef.Device(row.id.value.toString(),row.revision.sha256,row.revision.byteLength,row.incarnation)
    suspend fun <T> journal(publishState:Boolean=false,unavailable:ContentOwner?=null,block:(DeviceListeningStore,AccessCapture)->T):T?=withContext(Dispatchers.IO) {serial.withLock {
        if(!current(graph.session.version()))return@withLock null
        val owner=store ?: return@withLock null;val accepted=access ?: return@withLock null
        block(owner,accepted).also {if(publishState)publish(unavailable=unavailable)}
    }}
    suspend fun admit(row: DeviceAudio): PhoneSourceAdmission? = withContext(Dispatchers.IO) { serial.withLock {
        val version = graph.session.version()
        if (!current(version)) return@withLock null
        val owner = store ?: return@withLock null; val accepted = access ?: return@withLock null
        val observed = owner.snapshot(accepted)?.files?.singleOrNull { it.id == row.id && it.owner == row.owner && it.available } ?: return@withLock null
        val captured = owner.captureSource(accepted, row.id) ?: return@withLock null
        PhoneSourceAdmission(observed, captured, version, owner.bookmark(captured)?.positionMs ?: 0)
    } }
    suspend fun reportFailure(admission:PhoneSourceAdmission,failure:Exception) {
        journal(true,admission.source.owner) {owner,_->
            if(current(admission.sessionVersion)) {
                val reason=when {failure is java.io.FileNotFoundException->AccessState.MISSING;failure.message?.contains("unsupported",true)==true||failure.message?.contains("not supported",true)==true->AccessState.UNSUPPORTED;else->AccessState.UNREADABLE}
                admission.row.aliases.firstOrNull {it.state==AccessState.AVAILABLE}?.let {owner.reportUnavailable(admission.source,it.locator,reason)}
            }
        }
    }
    suspend fun prepare(admission: PhoneSourceAdmission, valid: () -> Boolean): File = withContext(Dispatchers.IO) {
        check(current(admission.sessionVersion) && valid())
        val route = admission.row.aliases.first { it.state == AccessState.AVAILABLE }.locator.value
        PhoneAudioStage(platform, graph.directory).prepare(route, AudioContentProof(admission.row.revision.byteLength, admission.row.revision.sha256)) {
            current(admission.sessionVersion) && valid()
        }
    }
    /** Direct original acquisition. No encoded copy, checksum or whole PCM preparation.
     * Live-version resume policy is an explicit candidate, NOT old SHA equality. */
    suspend fun openOriginal(admission:PhoneSourceAdmission,valid:()->Boolean):Pair<NativePlaybackSource.BorrowedOriginal,PhoneSourceAdmission> = withContext(Dispatchers.IO) {
        check(current(admission.sessionVersion) && valid())
        val route=admission.row.aliases.first {it.state==AccessState.AVAILABLE}.locator.value
        val live=java.util.concurrent.atomic.AtomicBoolean(true)
        val capture=java.util.concurrent.atomic.AtomicReference(admission)
        fun active()=live.get() && current(admission.sessionVersion) && valid()
        fun changed() {
            if(live.compareAndSet(true,false)) {
                // Revoke synchronously, before any late read/EOF/journal publication.
                advanceAuthority(admission.row.id)
                jobs.launch {serial.withLock {store?.retireChangedOriginal(capture.get().source);publish("Original audio changed. Saved progress was reset; refresh Local audio.")}}
            }
        }
        val original=platform.openOriginal(route,::active,::changed,admission.row.id.value.toString())
        try {
            val accepted=serial.withLock {
                check(active())
                val owner=requireNotNull(store);requireNotNull(access)
                val versions=liveVersions ?: LiveOriginalVersions(File(graph.directory,"phone-live-versions.v1.properties")).also {liveVersions=it}
                val observation=versions.observe("$route:${admission.row.owner}",original.version) {
                    check(owner.retireChangedOriginal(admission.source)!=Mutation.REFUSED)
                }
                if(observation==LiveOriginalVersions.Observation.Changed) {
                    advanceAuthority(admission.row.id) // revoke this original, never unrelated transport
                    throw java.io.IOException("Original audio version changed. Saved progress was reset; refresh Local audio before retrying.")
                } else admission
            }
            capture.set(accepted)
            val result=NativePlaybackSource.BorrowedOriginal(AndroidPlatformWindowReader(original),accepted.resumeMs,accepted.row.durationMs,accepted.row.id.value.toString()) {active() && original.active}
            jobs.launch {
                try {
                    while(original.active && active()) {original.checkCurrent();delay(250)}
                } catch(_:Exception) {
                    if(original.active && live.compareAndSet(true,false))advanceAuthority(admission.row.id)
                }
            }
            result to accepted
        } catch(error:Throwable) {try {original.close()}catch(close:Throwable){error.addSuppressed(close)};throw error}
    }
    override fun close() { acceptedVersion = -1; jobs.cancel(); jobs.launch(NonCancellable) { serial.withLock { store?.close(); store = null; access = null } } }
    private fun grantId(value: String) = ScanGrantId(UUID.nameUUIDFromBytes(value.toByteArray(Charsets.UTF_8)))
    private fun locator(value: String) = ProviderLocator(Uri.parse(value).authority ?: "android", value)
}
