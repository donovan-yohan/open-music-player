package com.soundq.android.data.device

import android.net.Uri
import com.soundq.android.AppGraph
import com.soundq.android.data.AuthState
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.playback.nativeengine.PhoneAudioStage
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.util.UUID

/** [permission] is all files access, the single user-facing grant; [indexedAccess] is MediaStore audio read
 * access. While [refreshing], both are the values the running refresh was admitted with. */
internal data class PhoneAudioState(val ready: Boolean = false, val snapshot: DeviceListeningSnapshot? = null,
    val refreshing: Boolean = false, val permission: Boolean = false, val message: String? = null,
    val scan: PhoneScanObservation? = null, val indexedAccess: Boolean = false)
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
    private var access: AccessCapture? = null
    @Volatile private var acceptedVersion = -1L
    @Volatile private var lastScan: PhoneScanObservation? = null
    private val mutable = MutableStateFlow(PhoneAudioState())
    val state: StateFlow<PhoneAudioState> = mutable.asStateFlow()
    fun start() {
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
    @Volatile var authorityVersion=0L
        private set
    private fun publish(message: String? = null) {
        val snapshot = access?.let { store?.snapshot(it) }
        val previous=mutable.value.snapshot
        if(previous!=null&&snapshot!=null&&(previous.grants!=snapshot.grants||previous.files.any {old->snapshot.files.singleOrNull {it.id==old.id}?.let {it.owner!=old.owner||it.aliases!=old.aliases}==true}))authorityVersion++
        mutable.value = PhoneAudioState(snapshot != null, snapshot, false, platform.storageAllowed(), message ?: if (snapshot == null) "Local audio storage is unavailable. Saved state has not been replaced." else null, lastScan, platform.indexedAllowed())
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
    private data class RefreshScope(val version:Long,val indexed:Boolean,val trees:Set<String>,val reads:Set<String>,val storage:Boolean=false)
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
        val scope=RefreshScope(graph.session.version(),platform.indexedAllowed(),platform.persistedTrees().toSet(),
            graph.applicationContext.contentResolver.persistedUriPermissions.filter {it.isReadPermission}.map {it.uri.toString()}.toSet(),platform.storageAllowed())
        if(refreshRunning){
            if(refreshScope!=scope)refreshEpoch.incrementAndGet()
            refreshScope=scope
            pendingRefresh={refresh(valid)};return
        }
        refreshScope=scope
        refreshRunning=true
        val refresh=refreshEpoch.incrementAndGet()
        val version = scope.version
        fun active()=valid()&&current(version)&&refreshEpoch.get()==refresh
        jobs.launch {
            try {
                if (!active()) return@launch
                // Publish the access this refresh was admitted with, so a grant after admission is not masked.
                mutable.value = mutable.value.copy(refreshing = true, permission = scope.storage, indexedAccess = scope.indexed, message = null)
                val owner = requireNotNull(store); val accepted = requireNotNull(access)
                val prior = owner.snapshot(accepted) ?: error("Local audio state refused")
                val indexed = ScanGrant(grantId("indexed:external-audio"), GrantKind.INDEXED, "Android audio index", ProviderLocator("android", "indexed:external-audio"), false,
                    if (scope.indexed) AccessState.AVAILABLE else AccessState.REVOKED)
                refreshLocked{if(!active())throw CancellationException();check(owner.putGrant(accepted, indexed) != Mutation.REFUSED)}
                val retained = scope.trees
                val grants = listOf(indexed) + prior.grants.filter { it.kind != GrantKind.INDEXED && it.state != AccessState.REMOVED }
                var partial = false
                var indexedScan: PhoneScanObservation? = null
                var storageComplete = true
                for (old in grants) {
                    if (!active()) throw CancellationException()
                    val granted = when {
                        old.kind == GrantKind.INDEXED -> indexed
                        old.kind == GrantKind.FOLDER -> old.copy(state = if (old.locator.value in retained) AccessState.AVAILABLE else AccessState.REVOKED)
                        old.persisted -> old.copy(state = if (old.locator.value in scope.reads) AccessState.AVAILABLE else AccessState.REVOKED)
                        else -> old
                    }
                    refreshLocked{if(!active())throw CancellationException();check(owner.putGrant(accepted, granted) != Mutation.REFUSED)}
                    if (granted.state != AccessState.AVAILABLE) { if (granted.kind == GrantKind.INDEXED) indexedScan = PhoneScanObservation(false, true, scope.storage); continue }
                    val scan = owner.beginScan(accepted, granted.id) ?: continue
                    var complete=true
                    val descriptors = try {
                        val rows = when (granted.kind) {
                            GrantKind.FILE -> listOf(platform.metadata(Uri.parse(granted.locator.value), granted.locator.value))
                            GrantKind.INDEXED -> {
                                // All files access: index audio MediaStore missed, then read the index as before.
                                val indexedUnlisted = !scope.storage || try { platform.indexUnlisted { active() } } catch (e: CancellationException) { throw e } catch (_: Exception) { false }
                                if (!indexedUnlisted) { storageComplete = false; partial = true }
                                val result = platform.discover(emptyList(), { active() })
                                check(result.indexedComplete && !result.truncated) { "Android audio coverage is partial" }; result.observations
                            }
                            GrantKind.FOLDER -> {
                                val result = platform.discover(listOf(granted.locator.value), { active() }, includeIndexed = false)
                                check(result.unavailableGrants.isEmpty() && !result.truncated) { "Folder access unavailable or partial" }; result.observations
                            }
                        }
                        rows.mapNotNull { observation ->
                            if (!active()) throw CancellationException()
                            try {
                                val proof = platform.proof(observation.locator) { active() }
                                DiscoveredAudio(ProviderObjectId("android-content", observation.providerObject), locator(observation.locator), ContentRevision(proof.sha256, proof.bytes),
                                    OriginalMetadata(observation.filename, observation.title, observation.artist, observation.album, observation.locator), observation.durationMs?.takeIf { it > 0 },
                                    formerObjectIds = (observation.aliases - observation.providerObject).map { ProviderObjectId("android-content", it) }.toSet())
                            } catch(e:CancellationException){throw e}
                            catch(_:Exception){complete=false;partial=true;null}
                        }
                    } catch (e: CancellationException) { throw e }
                    catch (_: Exception) {
                        // A denied/partial grant is not an empty scan and must not block siblings.
                        // Incomplete enumeration is not permission to publish a prefix.
                        partial = true
                        if (granted.kind == GrantKind.INDEXED) indexedScan = PhoneScanObservation(true, false, scope.storage)
                        continue
                    }
                    refreshLocked{
                        if (!active()) throw CancellationException()
                        check(owner.publishScan(scan, descriptors, complete) != Mutation.REFUSED)
                    }
                    if (granted.kind == GrantKind.INDEXED) indexedScan = PhoneScanObservation(true, complete && storageComplete, scope.storage)
                }
                refreshLocked { if (!active()) throw CancellationException(); lastScan = indexedScan }
                publish(if (partial) "Some audio could not be refreshed. Existing files and saved progress were kept."
                    else "Available audio refreshed. Coverage is limited to audio Android exposes and added locations.")
            } catch (_: CancellationException) { if(refreshEpoch.get()==refresh)mutable.value = mutable.value.copy(refreshing = false) }
            catch (_: Exception) { if(active())publish("Some audio could not be refreshed. Existing files and saved progress were kept.") }
            finally {
                val next=refreshLocked{refreshRunning=false;pendingRefresh.also {pendingRefresh=null}}
                next?.invoke()
            }
        }
    }
    fun selected(uri: Uri, flags: Int, folder: Boolean, valid: () -> Boolean) {
        val version = graph.session.version()
        jobs.launch { serial.withLock {
            if (!valid() || !current(version)) return@withLock
            try {
                if (folder) require(platform.validTree(uri))
                val persisted = runCatching { platform.persist(uri, flags, folder); true }.getOrDefault(false)
                require(!folder || persisted) { "Folder read access could not be retained" }
                if (!valid() || !current(version)) return@withLock
                val name = if (folder) platform.folderLabel(uri.toString()) else platform.metadata(uri).filename
                val grant = ScanGrant(grantId((if (folder) "folder:" else "file:") + uri), if (folder) GrantKind.FOLDER else GrantKind.FILE,
                    name, locator(uri.toString()), persisted)
                refreshLocked {
                    refreshEpoch.incrementAndGet()
                    check(requireNotNull(store).putGrant(requireNotNull(access), grant) != Mutation.REFUSED)
                }
                publish()
            } catch (_: Exception) { fail("Couldn’t retain audio access. Choose an accessible audio file or subfolder.") }
        }; refresh(valid) }
    }
    fun remove(grant: ScanGrant, valid: () -> Boolean) {
        if(valid())authorityVersion++
        val version = graph.session.version()
        jobs.launch { serial.withLock {
            if (!valid() || !current(version)) return@withLock
            try {
                refreshLocked {
                    refreshEpoch.incrementAndGet()
                    check(requireNotNull(store).removeGrant(requireNotNull(access), grant.id) != Mutation.REFUSED)
                }
                if (grant.persisted) runCatching { platform.release(grant.locator.value) }
                publish("Folder removed. Your files and saved progress were not deleted.")
            } catch (_: Exception) { fail("Folder removal was not confirmed. Your files and saved progress were kept.") }
        } }
    }
    /** A saved reference to a row later folded into another (one provider object) resolves to the survivor. */
    fun observed(ref: com.soundq.android.playback.PlaybackRef.Device): DeviceAudio? =
        state.value.snapshot?.resolve(DeviceFileId(UUID.fromString(ref.id)), ContentRevision(ref.sha256, ref.bytes), ref.incarnation)
    fun reference(row:DeviceAudio)=com.soundq.android.playback.PlaybackRef.Device(row.id.value.toString(),row.revision.sha256,row.revision.byteLength,row.incarnation)
    suspend fun <T> journal(publishState:Boolean=false,block:(DeviceListeningStore,AccessCapture)->T):T?=withContext(Dispatchers.IO) {serial.withLock {
        if(!current(graph.session.version()))return@withLock null
        val owner=store ?: return@withLock null;val accepted=access ?: return@withLock null
        block(owner,accepted).also {if(publishState)publish()}
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
        journal(true) {owner,_->
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
    override fun close() { acceptedVersion = -1; jobs.cancel(); jobs.launch(NonCancellable) { serial.withLock { store?.close(); store = null; access = null } } }
    private fun grantId(value: String) = ScanGrantId(UUID.nameUUIDFromBytes(value.toByteArray(Charsets.UTF_8)))
    private fun locator(value: String) = ProviderLocator(Uri.parse(value).authority ?: "android", value)
}
