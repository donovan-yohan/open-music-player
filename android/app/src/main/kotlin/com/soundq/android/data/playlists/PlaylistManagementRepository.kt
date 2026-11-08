package com.soundq.android.data.playlists

import com.soundq.android.data.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** Route capabilities are not the account-owned operation or Undo receipt. */
class PlaylistManagementRoute internal constructor(internal val scope: AccountScope)
class PlaylistManagementTarget internal constructor(internal val route: PlaylistManagementRoute, internal val detail: PlaylistDetail, internal val intent: Long, internal val destinationVersion: Long) {
    val playlist: PlaylistSummary get() = detail.playlist
}
enum class PlaylistManagementKind { Rename, Remove, Undo, Delete, Add, BatchRemove }
class PlaylistBatchConfirmation internal constructor(internal val target: PlaylistManagementTarget, internal val tracks: List<TrackId>) {
    val count: Int get() = tracks.size
    val name: String get() = target.playlist.name
}
class PlaylistRemovalReceipt internal constructor(internal val scope: AccountScope, val playlist: PlaylistSummary, val track: Track, internal val before: List<TrackId>, internal val position: Int)
class PlaylistDeleteConfirmation internal constructor(internal val target: PlaylistManagementTarget) {
    val name: String get() = target.playlist.name
}
class PlaylistUndoTarget internal constructor(internal val route: PlaylistManagementRoute, internal val receipt: PlaylistRemovalReceipt, internal val intent: Long, internal val destinationVersion: Long)
data class PlaylistManagementState(
    val kind: PlaylistManagementKind? = null, val playlist: PlaylistSummary? = null,
    val outcome: MutationOutcome? = null, val error: SafeFailure.Reason? = null,
    val loading: Boolean = false, val reconciled: Boolean = false,
    val observed: PlaylistDetail? = null, val missing: Boolean = false,
    val undo: PlaylistRemovalReceipt? = null, val ack: PlaylistAddAck? = null,
)
private class ManagementOperation(val target: PlaylistManagementTarget, val kind: PlaylistManagementKind, val draft: PlaylistDraft? = null, val removal: PlaylistRemovalReceipt? = null) {
    var entered = false
    var acknowledged = false
    var dispatched = false
}
/** One narrow feature owner. No controller, Library or listening-queue writes. */
class PlaylistManagementRepository internal constructor(
    private val api: SoundQApi,
    private val detail: PlaylistDetailRepository,
    private val readSnapshot: (AccountScope, PlaylistId, () -> Boolean) -> PlaylistDetail?,
) {
    constructor(api: SoundQApi, detail: PlaylistDetailRepository) : this(api, detail, api::playlistManagementSnapshot)
    private val mutable = MutableStateFlow(PlaylistManagementState())
    val state: StateFlow<PlaylistManagementState> = mutable
    private var route: PlaylistManagementRoute? = null
    private var intent = 0L
    private var readVersion = 0L
    private var operation: ManagementOperation? = null
    private var confirmation: PlaylistDeleteConfirmation? = null
    private var batchConfirmation: PlaylistBatchConfirmation? = null
    @Synchronized private fun owns(owner: PlaylistManagementRoute) = route === owner && api.session.current(owner.scope)
    @Synchronized fun enter(): PlaylistManagementRoute? {
        val scope = api.session.capture() ?: return null
        if (operation?.target?.route?.scope?.let { !api.session.current(it) } == true || mutable.value.undo?.scope?.let { !api.session.current(it) } == true) retire()
        route?.let(::leave)
        return PlaylistManagementRoute(scope).also { route = it }
    }
    @Synchronized fun leave(owner: PlaylistManagementRoute) {
        if (route !== owner) return
        route = null; confirmation = null; batchConfirmation = null; readVersion++
        val op = operation
        if (op != null && !op.entered && mutable.value.outcome == MutationOutcome.Pending) mutable.value = mutable.value.copy(outcome = MutationOutcome.Refused)
        mutable.value = mutable.value.copy(loading = false)
    }
    @Synchronized fun retire() { route = null; operation = null; confirmation = null; batchConfirmation = null; intent++; readVersion++; mutable.value = PlaylistManagementState() }
    @Synchronized fun capture(owner: PlaylistManagementRoute): PlaylistManagementTarget? {
        val value = detail.managementDetail() ?: return null
        if (!owns(owner) || !value.canManage || !available()) return null
        return PlaylistManagementTarget(owner, value, intent, detail.managementVersion())
    }
    private fun available() = !mutable.value.loading && mutable.value.outcome != MutationOutcome.Pending &&
        (mutable.value.outcome !in listOf(MutationOutcome.Uncertain, MutationOutcome.ReadbackFailed) || mutable.value.reconciled)
    @Synchronized private fun valid(target: PlaylistManagementTarget) = owns(target.route) && target.intent == intent && detail.ownsManagement(target.detail) && target.detail.canManage && available()
    @Synchronized private fun claim(target: PlaylistManagementTarget, kind: PlaylistManagementKind, draft: PlaylistDraft? = null, removal: PlaylistRemovalReceipt? = null): ManagementOperation? {
        if (!valid(target)) return null
        intent++; readVersion++; confirmation = null; batchConfirmation = null
        val op = ManagementOperation(target, kind, draft, removal)
        operation = op
        mutable.value = mutable.value.copy(kind = kind, playlist = target.playlist, outcome = MutationOutcome.Pending, error = null, loading = false, reconciled = false, observed = null, missing = false)
        return op
    }
    @Synchronized fun askDelete(target: PlaylistManagementTarget): PlaylistDeleteConfirmation? {
        if (!valid(target)) return null
        return PlaylistDeleteConfirmation(target).also { confirmation = it }
    }
    @Synchronized fun cancelDelete(value: PlaylistDeleteConfirmation) { if (confirmation === value) confirmation = null }
    @Synchronized fun confirmDelete(value: PlaylistDeleteConfirmation): (() -> Unit)? {
        if (confirmation !== value) return null
        val op = claim(value.target, PlaylistManagementKind.Delete) ?: return null
        return {
            if (begin(op)) try {
                api.deletePrivatePlaylist(op.target.route.scope,op.target.playlist.id) { dispatchOwns(op) }
                op.acknowledged=true
                synchronized(this) {
                    if (accountOwns(op)) {
                        detail.publishManagement(op.target.detail,null)
                        mutable.value=mutable.value.copy(outcome=MutationOutcome.Confirmed,missing=true,undo=mutable.value.undo?.takeUnless { it.playlist.id==op.target.playlist.id })
                    }
                }
            } catch(error: Exception) { fail(op,error) }
        }
    }
    @Synchronized fun recoveryAction(owner: PlaylistManagementRoute, enqueue: (() -> Unit) -> Unit): (() -> Unit)? {
        val captured=operation ?: return null
        if (!owns(owner)) return null
        val revision=intent
        val destinationVersion=detail.managementVersion()
        val destination=detail.managementDetail()
        return { synchronized(this) {
            if(operation===captured && owns(owner) && intent==revision && detail.managementVersion()==destinationVersion && detail.managementDetail()===destination) recover(owner)?.let(enqueue)
        } }
    }
    @Synchronized fun recover(owner: PlaylistManagementRoute): (() -> Unit)? {
        val op=operation ?: return null
        if (!owns(owner) || !api.session.current(op.target.route.scope) || mutable.value.loading || mutable.value.outcome !in listOf(MutationOutcome.Uncertain,MutationOutcome.ReadbackFailed)) return null
        readVersion++; val version=readVersion
        // Capture current destination at admission; never capture a replacement in delayed IO.
        val destinationVersion=detail.managementVersion()
        val destination=detail.managementDetail()
        val shown=destination?.takeIf { it.playlist.id==op.target.playlist.id }
        mutable.value=mutable.value.copy(loading=true,error=null)
        return {
            fun presentationOwns()=synchronized(this) { owns(owner) && operation===op && readVersion==version }
            fun current()=presentationOwns() && detail.managementVersion()==destinationVersion && detail.managementDetail()===destination
            try {
                val observed=readSnapshot(owner.scope,op.target.playlist.id,::current)
                synchronized(this) {
                    if (current()) {
                        shown?.let { detail.publishManagement(it,observed) }
                        intent++
                        // A read reconciles observed truth, never manufactures a write acknowledgement.
                        // Partial composite Undo is retired; it is never automatically replayed.
                        mutable.value=mutable.value.copy(loading=false,error=null,reconciled=true,observed=observed,missing=observed==null,
                            undo=if(op.kind==PlaylistManagementKind.Undo || observed==null) null else mutable.value.undo)
                    }
                }
            } catch(error: Exception) {
                synchronized(this) { if(presentationOwns()) mutable.value=mutable.value.copy(loading=false,error=(error as? SafeFailure)?.reason ?: SafeFailure.Reason.Network) }
            } finally {
                // Destination eligibility gates publication, not this ticket's lifetime.
                synchronized(this) { if(presentationOwns()) mutable.value=mutable.value.copy(loading=false) }
            }
        }
    }
    fun remove(target: PlaylistManagementTarget, track: TrackId): (() -> Unit)? {
        val index = target.detail.tracks.indexOfFirst { it.id == track }
        if (index < 0) return null
        val receipt = PlaylistRemovalReceipt(target.route.scope, target.playlist, target.detail.tracks[index], target.detail.tracks.map { it.id }, index)
        val op = claim(target, PlaylistManagementKind.Remove, removal = receipt) ?: return null
        return {
            if (begin(op)) try {
                val observed = api.removePlaylistMember(target.route.scope, target.playlist.id, track) { dispatchOwns(op) }
                op.acknowledged = true
                require(observed.tracks.map { it.id } == receipt.before.filter { it != track })
                accept(op,observed,receipt)
            } catch(error: Exception) { fail(op,error) }
        }
    }
    /** Uses the existing operation/uncertainty lane, never a Library picker or second writer. */
    @Synchronized fun addHarmonic(target:PlaylistManagementTarget,track:TrackId,admit:()->Boolean):(() -> Unit)? {
        if(!admit() || target.playlist.draft.isPublic)return null
        val op=claim(target,PlaylistManagementKind.Add)?:return null
        mutable.value=mutable.value.copy(ack=null)
        return {
            val admitted=synchronized(this) {
                if(!admit()) {
                    if(accountOwns(op)&&!op.entered)mutable.value=mutable.value.copy(outcome=MutationOutcome.Refused)
                    false
                } else begin(op)
            }
            if(admitted)try {
                val ack=api.addQueuePlaylistTracks(target.route.scope,target.playlist.id,listOf(track),{accountOwns(op)},{(dispatchOwns(op)&&admit()).also {if(it)op.dispatched=true}})
                require(!ack.playlist.draft.isPublic)
                synchronized(this) {if(accountOwns(op)){op.acknowledged=true;mutable.value=mutable.value.copy(ack=ack,outcome=MutationOutcome.ReadbackFailed)}}
                if(!dispatchOwns(op)||!admit())throw SafeFailure(SafeFailure.Reason.Retired)
                val observed=api.playlistDetail(target.route.scope,target.playlist.id){dispatchOwns(op)&&admit()}
                require(!observed.playlist.draft.isPublic&&observed.tracks.any {it.id==track})
                require(observed.playlist==ack.playlist)
                synchronized(this) {if(dispatchOwns(op)&&admit())accept(op,observed,mutable.value.undo)}
            }catch(error:Exception){fail(op,error)}
        }
    }
    @Synchronized fun captureUndo(owner: PlaylistManagementRoute): PlaylistUndoTarget? {
        val receipt = mutable.value.undo ?: return null
        if (!owns(owner) || !available() || !api.session.current(receipt.scope)) return null
        return PlaylistUndoTarget(owner, receipt, intent, detail.managementVersion())
    }
    @Synchronized fun undo(target: PlaylistUndoTarget): (() -> Unit)? {
        if (!owns(target.route) || !available() || target.intent != intent || target.destinationVersion != detail.managementVersion() || mutable.value.undo !== target.receipt || !api.session.current(target.receipt.scope)) return null
        val receipt = target.receipt
        val before = detail.managementDetail()?.takeIf { it.playlist.id == receipt.playlist.id } ?: PlaylistDetail(receipt.playlist, emptyList())
        val captured = PlaylistManagementTarget(target.route,before,intent,detail.managementVersion())
        val op = ManagementOperation(captured,PlaylistManagementKind.Undo,removal=receipt)
        intent++; readVersion++; operation=op; confirmation=null
        mutable.value=mutable.value.copy(kind=PlaylistManagementKind.Undo,playlist=receipt.playlist,outcome=MutationOutcome.Pending,error=null,observed=null,reconciled=false)
        return {
            if (begin(op)) try {
                val scope = target.route.scope; val id = receipt.playlist.id
                // First read the original target. An intervening edit invalidates safe composite restoration.
                val current = api.playlistDetail(scope,id) { dispatchOwns(op) }
                require(current.canManage && current.tracks.map { it.id } == receipt.before.filter { it != receipt.track.id })
                val ack = api.addPlaylistTrack(scope,id,receipt.track.id) { dispatchOwns(op) }
                require(ack.added == listOf(receipt.track.id) && ack.skipped.isEmpty())
                op.acknowledged = true // From this point a refused/failed reorder is a partial Undo, never a repeatable add.
                val restored = api.restorePlaylistPosition(scope,id,receipt.track.id,receipt.position) { dispatchOwns(op) }
                require(restored.canManage && restored.tracks.map { it.id } == receipt.before)
                accept(op,restored,null)
            } catch(error: Exception) { fail(op,error) }
        }
    }
    @Synchronized private fun dispatchOwns(op: ManagementOperation): Boolean = accountOwns(op) && owns(op.target.route) &&
        (if(op.kind == PlaylistManagementKind.Undo) detail.managementVersion()==op.target.destinationVersion else detail.ownsManagement(op.target.detail))
    @Synchronized private fun accept(op: ManagementOperation, observed: PlaylistDetail, undo: PlaylistRemovalReceipt?) {
        if (!accountOwns(op)) return
        detail.publishManagement(op.target.detail,observed)
        mutable.value = mutable.value.copy(outcome=MutationOutcome.Confirmed,error=null,observed=observed,undo=undo)
    }
    fun rename(target: PlaylistManagementTarget, name: String): (() -> Unit)? {
        if (name.isBlank()) return null
        return update(target, target.playlist.draft.copy(name = name))
    }
    fun update(target: PlaylistManagementTarget, draft: PlaylistDraft): (() -> Unit)? {
        if (draft == target.playlist.draft) return null
        val op = claim(target, PlaylistManagementKind.Rename, draft) ?: return null
        return { executeRename(op) }
    }
    @Synchronized fun askRemove(target: PlaylistManagementTarget, tracks: List<TrackId>): PlaylistBatchConfirmation? {
        if (!valid(target) || tracks.size !in 1..100 || tracks.distinct().size != tracks.size) return null
        val ordered = target.detail.tracks.map { it.id }.filter { it in tracks }
        if (ordered.size != tracks.size) return null
        return PlaylistBatchConfirmation(target, ordered).also { batchConfirmation = it }
    }
    @Synchronized fun cancelRemove(value: PlaylistBatchConfirmation) { if (batchConfirmation === value) batchConfirmation = null }
    @Synchronized fun confirmRemove(value: PlaylistBatchConfirmation): (() -> Unit)? {
        if (batchConfirmation !== value) return null
        val op = claim(value.target, PlaylistManagementKind.BatchRemove) ?: return null
        return {
            if (begin(op)) try {
                val observed = api.removePlaylistMembers(op.target.route.scope, op.target.playlist.id, value.tracks) { dispatchOwns(op) }
                op.acknowledged = true
                require(observed.tracks.map { it.id } == op.target.detail.tracks.map { it.id }.filter { it !in value.tracks })
                // No synthetic composite Undo; the existing receipt covers one member only.
                accept(op, observed, null)
            } catch (error: Exception) { fail(op, error) }
        }
    }
    @Synchronized private fun begin(op: ManagementOperation): Boolean {
        if (operation !== op || mutable.value.outcome != MutationOutcome.Pending || op.entered) return false
        if (!owns(op.target.route) || (if(op.kind == PlaylistManagementKind.Undo) detail.managementVersion()!=op.target.destinationVersion else !detail.ownsManagement(op.target.detail))) {
            mutable.value = mutable.value.copy(outcome = MutationOutcome.Refused); return false
        }
        op.entered = true
        return true
    }
    @Synchronized private fun accountOwns(op: ManagementOperation) = operation === op && api.session.current(op.target.route.scope)
    private fun executeRename(op: ManagementOperation) {
        if (!begin(op)) return
        try {
            api.renamePlaylist(op.target.route.scope, op.target.playlist.id, op.draft!!) { accountOwns(op) && owns(op.target.route) && detail.ownsManagement(op.target.detail) }
            op.acknowledged = true
            readAfter(op)
        } catch (error: Exception) { fail(op,error) }
    }
    private fun readAfter(op: ManagementOperation) {
        // No old route may acquire a fresh read capability after navigation.
        synchronized(this) {
            if (!accountOwns(op)) return
            mutable.value = mutable.value.copy(outcome = MutationOutcome.ReadbackFailed)
            if (!owns(op.target.route) || !detail.ownsManagement(op.target.detail)) return
        }
        val observed = api.playlistDetail(op.target.route.scope, op.target.playlist.id) { accountOwns(op) && owns(op.target.route) && detail.ownsManagement(op.target.detail) }
        require(op.draft == null || observed.playlist.draft == op.draft)
        synchronized(this) {
            if (!accountOwns(op)) return
            detail.publishManagement(op.target.detail, observed)
            mutable.value = mutable.value.copy(outcome = MutationOutcome.Confirmed, observed = observed, error = null)
        }
    }
    @Synchronized private fun fail(op: ManagementOperation, error: Exception) {
        if (!accountOwns(op)) return
        val reason = (error as? SafeFailure)?.reason ?: SafeFailure.Reason.InvalidResponse
        mutable.value = mutable.value.copy(outcome = if(op.acknowledged) MutationOutcome.ReadbackFailed else if(reason == SafeFailure.Reason.Refused || op.kind==PlaylistManagementKind.Add&&!op.dispatched) MutationOutcome.Refused else MutationOutcome.Uncertain, error = reason)
    }
}
/** Constructed on the real Playlists route; all work is claimed before enqueue. */
class PlaylistManagementActions(private val repository: PlaylistManagementRepository, private val enqueue: (() -> Unit) -> Unit) {
    private val route = repository.enter()
    fun capture() = route?.let(repository::capture)
    fun askDelete(target: PlaylistManagementTarget) = repository.askDelete(target)
    fun cancelDelete(value: PlaylistDeleteConfirmation) = repository.cancelDelete(value)
    fun confirmDelete(value: PlaylistDeleteConfirmation) { repository.confirmDelete(value)?.let(enqueue) }
    fun recoveryAction(): (() -> Unit)? = route?.let { repository.recoveryAction(it,enqueue) }
    fun recover() { recoveryAction()?.invoke() }
    fun captureUndo() = route?.let(repository::captureUndo)
    fun undo(target: PlaylistUndoTarget) { repository.undo(target)?.let(enqueue) }
    fun remove(target: PlaylistManagementTarget, track: TrackId) { repository.remove(target,track)?.let(enqueue) }
    fun rename(target: PlaylistManagementTarget, name: String) { repository.rename(target,name)?.let(enqueue) }
    fun update(target: PlaylistManagementTarget, draft: PlaylistDraft) { repository.update(target,draft)?.let(enqueue) }
    fun askRemove(target: PlaylistManagementTarget, tracks: List<TrackId>) = repository.askRemove(target,tracks)
    fun cancelRemove(value: PlaylistBatchConfirmation) = repository.cancelRemove(value)
    fun confirmRemove(value: PlaylistBatchConfirmation) { repository.confirmRemove(value)?.let(enqueue) }
    fun close() { route?.let(repository::leave) }
}
