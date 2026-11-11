package com.soundq.android.data.playlists

import com.soundq.android.data.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

class LibraryTrackCapture internal constructor(internal val scope: AccountScope, val track: Track, internal val lifetime: Long)
class LibraryPlaylistRoute internal constructor(internal val scope: AccountScope)
class MembershipPicker internal constructor(internal val route: LibraryPlaylistRoute, val source: LibraryTrackCapture) { internal var intent = 0L }
sealed class MembershipOperation(internal val picker: MembershipPicker, internal val intent: Long) { internal var consumed = false; internal var entered = false }
class MembershipSubmit internal constructor(picker: MembershipPicker, val row: PlaylistSummary, intent: Long) : MembershipOperation(picker,intent)
private class MembershipCreation(picker: MembershipPicker, val draft: PlaylistDraft, intent: Long) : MembershipOperation(picker,intent) {
    var dispatched = false
    var created: PlaylistSummary? = null
    var addDispatched = false
}
internal class MembershipRead(val picker: MembershipPicker, val version: Long, val offset: Int, val recover: Boolean)
data class PlaylistMembershipState(
    val rows: List<PlaylistSummary> = emptyList(), val total: Int? = null, val loading: Boolean = false,
    val error: SafeFailure.Reason? = null, val target: PlaylistId? = null, val outcome: MutationOutcome? = null,
    val ack: PlaylistAddAck? = null, val detail: PlaylistDetail? = null, val reconciled: Boolean = false,
    val excludedTarget: PlaylistId? = null,
    val created: PlaylistSummary? = null, val creationDraft: PlaylistDraft? = null,
    val creationBlocked: Boolean = false, val canContinueCreated: Boolean = false,
)
/** Narrow membership continuation. It never writes Library, playlist-detail route, or playback state.
 * Account-owned consumed operation survives sheet closure; presentation/read tickets do not. */
class PlaylistMembershipRepository(private val api: SoundQApi, private val library: LibraryRepository) {
    private val mutable = MutableStateFlow(PlaylistMembershipState())
    val state: StateFlow<PlaylistMembershipState> = mutable
    private var route: LibraryPlaylistRoute? = null
    private var picker: MembershipPicker? = null
    private var readVersion = 0L
    private var operation: MembershipOperation? = null
    private var receipt = PlaylistMembershipState()
    @Synchronized fun enter(): LibraryPlaylistRoute? {
        val scope = api.session.capture() ?: return null
        if (operation?.picker?.source?.scope?.let { !api.session.current(it) } == true) { operation = null; receipt = PlaylistMembershipState() }
        picker = null; readVersion++
        return LibraryPlaylistRoute(scope).also { route = it; mutable.value = PlaylistMembershipState() }
    }
    @Synchronized private fun owns(owner: MembershipPicker) = picker === owner && route === owner.route && api.session.current(owner.source.scope)
    @Synchronized fun open(owner: LibraryPlaylistRoute, source: LibraryTrackCapture): MembershipPicker? {
        if (route !== owner || !api.session.current(owner.scope) || !library.owns(source)) return null
        if (receipt.outcome == MutationOutcome.Pending && operation?.picker?.source?.track?.id != source.track.id) return null
        readVersion++
        val same = operation?.picker?.source?.let { it.track.id == source.track.id && api.session.current(it.scope) } == true
        mutable.value = if (same) receipt.copy(rows = emptyList(), total = null, loading = false) else PlaylistMembershipState()
        return MembershipPicker(owner, source).also { picker = it }
    }
    @Synchronized private fun settleQueued(owner: MembershipPicker) {
        operation?.takeIf { it.picker === owner && !it.entered && receipt.outcome == MutationOutcome.Pending }?.let { receipt = receipt.copy(outcome = MutationOutcome.Refused) }
    }
    @Synchronized fun close(owner: MembershipPicker) { if (picker === owner) { settleQueued(owner); picker = null; readVersion++; mutable.value = PlaylistMembershipState() } }
    @Synchronized fun leave(owner: LibraryPlaylistRoute) { if (route === owner) { picker?.let(::settleQueued); route = null; picker = null; readVersion++; mutable.value = PlaylistMembershipState() } }
    @Synchronized fun retire() { route = null; picker = null; operation = null; receipt = PlaylistMembershipState(); readVersion++; mutable.value = PlaylistMembershipState() }
    @Synchronized fun select(owner: MembershipPicker, row: PlaylistSummary): MembershipSubmit? {
        val s = mutable.value
        if (!owns(owner) || !library.owns(owner.source) || s.loading || s.error != null || s.outcome != null || s.excludedTarget == row.id || s.rows.none { it === row }) return null
        return MembershipSubmit(owner, row, owner.intent)
    }
    @Synchronized fun claim(submit: MembershipSubmit): Boolean {
        val owner = submit.picker; val s = mutable.value
        if (submit.consumed || submit.intent != owner.intent || !owns(owner) || !library.owns(owner.source) || s.loading || s.error != null || s.outcome != null ||
            s.excludedTarget == submit.row.id || s.rows.none { it === submit.row } || receipt.outcome == MutationOutcome.Pending) return false
        submit.consumed = true; owner.intent++; operation = submit; readVersion++
        mutable.value = s.copy(target = submit.row.id, outcome = MutationOutcome.Pending, ack = null, detail = null, error = null, reconciled = false, created = null, creationDraft = null, creationBlocked = false, canContinueCreated = false)
        receipt = mutable.value
        return true
    }
    fun add(submit: MembershipSubmit) {
        // A consumed callback queued before close must never acquire replacement authority.
        synchronized(this) {
            if (operation !== submit || !owns(submit.picker) || !library.owns(submit.picker.source)) {
                if (operation === submit && api.session.current(submit.picker.source.scope)) {
                    receipt = receipt.copy(outcome = MutationOutcome.Refused)
                    picker?.takeIf { it.source.track.id == submit.picker.source.track.id }?.let { mutable.value = receipt }
                }
                return
            }
            submit.entered = true
        }
        fun current() = synchronized(this) { operation === submit && api.session.current(submit.picker.source.scope) }
        var ack: PlaylistAddAck? = null
        var outcome = MutationOutcome.Confirmed
        try { ack = api.addQueuePlaylistTracks(submit.picker.source.scope, submit.row.id, listOf(submit.picker.source.track.id), ::current, { current() && owns(submit.picker) && library.owns(submit.picker.source) }) }
        catch (error: Exception) {
            outcome = if (reason(error) == SafeFailure.Reason.Refused) MutationOutcome.Refused else MutationOutcome.Uncertain
        }
        synchronized(this) {
            if (!current()) return
            receipt = receipt.copy(outcome = outcome, ack = ack, error = null)
            // A reopened picker may observe this account-owned receipt, but receives no old read authority.
            picker?.takeIf { it.source.track.id == submit.picker.source.track.id }?.let { mutable.value = mutable.value.copy(target = submit.row.id, outcome = outcome, ack = ack, error = null) }
        }
        if (ack != null) admitRead(submit.picker, recover = true)?.let(::read)
    }
    @Synchronized internal fun admitRead(owner: MembershipPicker, more: Boolean = false, recover: Boolean = false): MembershipRead? {
        val s = mutable.value
        if (!owns(owner) || s.loading || s.outcome == MutationOutcome.Pending) return null
        if (more && (s.outcome != null || s.total == null || s.rows.size >= s.total)) return null
        if (recover && (s.target == null && operation !is MembershipCreation || s.outcome == MutationOutcome.Refused)) return null
        readVersion++
        mutable.value = s.copy(loading = true, error = null)
        return MembershipRead(owner, readVersion, if(more) s.rows.size else 0, recover)
    }
    internal fun read(request: MembershipRead) {
        fun current() = synchronized(this) { owns(request.picker) && readVersion == request.version }
        val scope = request.picker.source.scope
        val target = synchronized(this) { if (!current()) return; mutable.value.target }
        try {
            val detail = if (request.recover && target != null) api.playlistDetail(scope, target, ::current) else null
            val page = api.playlists(scope, request.offset, ::current)
            synchronized(this) {
                if (!current()) return
                val s = mutable.value
                val rows = if(request.offset == 0) page.rows else s.rows + page.rows
                require(rows.map { it.id }.distinct().size == rows.size && rows.size <= page.total)
                require(page.rows.isNotEmpty() || rows.size >= page.total)
                if (request.recover && s.ack != null) require(detail?.tracks?.any { it.id == request.picker.source.track.id } == true && detail.playlist == s.ack.playlist)
                val creation = operation as? MembershipCreation
                val canContinue = request.recover && creation?.created != null && !creation.addDispatched &&
                    detail != null && detail.playlist.id == creation.created?.id && detail.canManage && detail.playlist.draft == creation.draft &&
                    detail.tracks.isEmpty()
                mutable.value = s.copy(rows = rows, total = page.total, loading = false, error = null, detail = detail ?: s.detail,
                    outcome = if(request.recover && s.outcome == MutationOutcome.ReadbackFailed && s.ack != null) MutationOutcome.Confirmed else s.outcome,
                    reconciled = request.recover || s.reconciled, canContinueCreated = canContinue)
                if (request.recover) receipt = mutable.value
            }
        } catch (error: Exception) {
            synchronized(this) {
                if (!current()) return
                val s = mutable.value
                mutable.value = s.copy(loading = false, error = reason(error), outcome = if(request.recover && s.ack != null) MutationOutcome.ReadbackFailed else s.outcome)
                if (request.recover) receipt = mutable.value
            }
        }
    }
    @Synchronized fun startNew(owner: MembershipPicker): Boolean {
        val s = mutable.value
        if (!owns(owner) || s.loading || s.outcome == null || s.outcome == MutationOutcome.Pending || (s.outcome in listOf(MutationOutcome.Uncertain,MutationOutcome.ReadbackFailed) && !s.reconciled)) return false
        owner.intent++
        mutable.value = s.copy(outcome = null, ack = null, detail = null, target = null, error = null, canContinueCreated = false,
            excludedTarget = if(s.outcome == MutationOutcome.Uncertain) s.target else null)
        // Retain the receipt for close/reopen until a genuinely new submit claims it.
        return true
    }
    private fun reason(error: Exception) = (error as? SafeFailure)?.reason ?: SafeFailure.Reason.Network

    @Synchronized fun create(owner: MembershipPicker, draft: PlaylistDraft): (() -> Unit)? {
        val s = mutable.value
        if (!owns(owner) || !library.owns(owner.source) || s.loading || s.error != null || s.outcome != null ||
            s.creationBlocked || receipt.outcome == MutationOutcome.Pending || draft.isPublic) return null
        val op = MembershipCreation(owner,draft,owner.intent)
        op.consumed = true; owner.intent++; operation = op; readVersion++
        publishCreation(op, s.copy(outcome=MutationOutcome.Pending, target=null, ack=null, detail=null,
            reconciled=false, created=null, creationDraft=draft, canContinueCreated=false))
        return work@{
            synchronized(this) {
                if (!creationAccount(op) || op.entered) return@work
                if (!creationDispatch(op,owner)) { publishCreation(op,receipt.copy(outcome=MutationOutcome.Refused)); return@work }
                op.entered=true
            }
            try {
                val created=api.createQueuePlaylist(owner.source.scope,draft,{creationAccount(op)},
                    {synchronized(this) {(creationDispatch(op,owner)&&!op.dispatched).also {if(it)op.dispatched=true}}})
                synchronized(this) {
                    if (!creationAccount(op)) return@work
                    op.created=created
                    publishCreation(op,receipt.copy(created=created,target=created.id,outcome=MutationOutcome.ReadbackFailed))
                }
                addCreated(op,owner)
            } catch(error:Exception) {creationFailure(op,error)}
        }
    }
    @Synchronized private fun creationAccount(op: MembershipCreation) = operation === op && api.session.current(op.picker.source.scope)
    @Synchronized private fun creationDispatch(op: MembershipCreation, owner: MembershipPicker) = creationAccount(op) && owns(owner) && library.owns(owner.source)
    @Synchronized private fun publishCreation(op: MembershipCreation, value: PlaylistMembershipState) {
        if (!creationAccount(op)) return
        receipt=value
        picker?.takeIf {it.source.track.id==op.picker.source.track.id}?.let { mutable.value=value }
    }
    private fun addCreated(op: MembershipCreation, owner: MembershipPicker) {
        val created=op.created ?: return
        if (!creationDispatch(op,owner)) return
        try {
            val ack=api.addQueuePlaylistTracks(owner.source.scope,created.id,listOf(owner.source.track.id),{creationAccount(op)},
                {synchronized(this) {(creationDispatch(op,owner)&&!op.addDispatched).also {if(it)op.addDispatched=true}}})
            synchronized(this) {publishCreation(op,receipt.copy(outcome=MutationOutcome.Confirmed,ack=ack,error=null,canContinueCreated=false))}
            admitRead(owner,recover=true)?.let(::read)
        } catch(error:Exception) {creationFailure(op,error)}
    }
    @Synchronized private fun creationFailure(op: MembershipCreation,error: Exception) {
        if (!creationAccount(op)) return
        val outcome=when {
            op.addDispatched -> MutationOutcome.Uncertain
            op.created!=null -> MutationOutcome.ReadbackFailed
            !op.dispatched || reason(error)==SafeFailure.Reason.Refused -> MutationOutcome.Refused
            else -> MutationOutcome.Uncertain
        }
        publishCreation(op,receipt.copy(outcome=outcome,error=null,creationBlocked=op.dispatched&&op.created==null,canContinueCreated=false))
    }
    /** Only an exact known-ID read and an add that never reached the wire grant this continuation. */
    @Synchronized fun continueCreated(owner: MembershipPicker): (() -> Unit)? {
        val op=operation as? MembershipCreation ?: return null
        val s=mutable.value
        if (!creationDispatch(op,owner) || !s.reconciled || !s.canContinueCreated || s.loading || op.addDispatched || s.outcome==MutationOutcome.Pending) return null
        owner.intent++;readVersion++
        publishCreation(op,s.copy(outcome=MutationOutcome.Pending,error=null,canContinueCreated=false))
        return {
            if (creationDispatch(op,owner)) addCreated(op,owner)
            else synchronized(this) {publishCreation(op,receipt.copy(outcome=MutationOutcome.ReadbackFailed))}
        }
    }
}
/** Constructed on Library entry, disposed on route/account/composition exit. */
class LibraryPlaylistActions(private val repository: PlaylistMembershipRepository, private val enqueue: (() -> Unit) -> Unit) {
    private val owner = repository.enter()
    fun open(track: LibraryTrackCapture): MembershipPickerActions? = owner?.let { repository.open(it, track) }?.let { MembershipPickerActions(repository, it, enqueue) }
    fun close() { owner?.let(repository::leave) }
}
class MembershipPickerActions internal constructor(private val repository: PlaylistMembershipRepository, val owner: MembershipPicker, private val enqueue: (() -> Unit) -> Unit) {
    val track: Track get() = owner.source.track
    fun reload() { repository.admitRead(owner)?.let { request -> enqueue { repository.read(request) } } }
    fun more() { repository.admitRead(owner, more = true)?.let { request -> enqueue { repository.read(request) } } }
    fun recover() { repository.admitRead(owner, recover = true)?.let { request -> enqueue { repository.read(request) } } }
    fun select(row: PlaylistSummary) = repository.select(owner, row)
    fun submit(submit: MembershipSubmit) { if(repository.claim(submit)) enqueue { repository.add(submit) } }
    fun create(draft: PlaylistDraft) { repository.create(owner,draft)?.let(enqueue) }
    fun continueCreated() { repository.continueCreated(owner)?.let(enqueue) }
    fun startNew(): Boolean {
        val accepted = repository.startNew(owner)
        if (accepted && repository.state.value.total == null) reload()
        return accepted
    }
    fun close() = repository.close(owner)
}
