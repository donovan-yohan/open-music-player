package com.soundq.android.data.originalimport

import com.soundq.android.data.*
import com.soundq.android.data.deviceaudio.*
import java.util.UUID
import java.util.concurrent.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** Runs on app IO, except for capture and read-only projection. No playback or scan commands. */
internal class OriginalImportRepository(
    private val session: AccountSession,
    private val journal: OriginalImportJournal,
    private val open: (ContentOwner, () -> Boolean) -> ImportOriginalRead?,
    private val originalCurrent: (ContentOwner) -> Boolean,
    private val sourceStamp: (ContentOwner) -> OriginalSourceStamp? = { if (originalCurrent(it)) OriginalSourceStamp(0, 0) else null },
    private val onAdded: (AccountScope, TrackId) -> Unit = { _, _ -> },
) {
    @Volatile private var transport: OriginalImportTransport? = null
    @Volatile private var mayWrite = false
    enum class Work { Upload, Check }
    private val mutableWork = MutableStateFlow<Map<ServerAccount, Work>>(emptyMap())
    val work: StateFlow<Map<ServerAccount, Work>> = mutableWork
    val state = journal.state
    private data class Member(val owner: ServerAccount, val track: TrackId)
    private data class Proof(val epoch: Long, val aliases: Map<UUID, OriginalAssociation>)
    private val membershipLock = Any()
    private val reads = mutableMapOf<Member, Any>()
    private val failedRetirements = mutableSetOf<Member>()
    private val proofs = MutableStateFlow<Map<Member, Proof>>(emptyMap())
    private val proofSequence = MutableStateFlow(0L)
    val membershipRevision: StateFlow<Long> = proofSequence
    private var observedRestoreEpoch: Long? = null

    /** Composition boundary, not a rollout flag. Old/disabled servers never get a guessed route. */
    @Synchronized fun installTransport(adapter: OriginalImportTransport, writes: Boolean = true) {
        check(transport == null); mayWrite = writes; transport = adapter
    }
    fun load() = journal.load()
    val enabled: Boolean get() = transport != null
    fun ready(scope: AccountScope) = transport != null && session.remoteCurrent(scope) && state.value.ready
    fun writeReady(scope: AccountScope) = ready(scope) && mayWrite
    private fun owner(scope: AccountScope) = ServerAccount(session.endpoint.identity, scope.accountId)
    fun entries(scope: AccountScope): List<OriginalImportEntry> = if (session.current(scope))
        state.value.rows.filter { it.intent.destination == owner(scope) } else emptyList()
    private fun live(binding: OriginalAssociation, snapshot: OriginalImportSnapshot) =
        snapshot.entry(binding.intent.operation)?.let { it.phase == OriginalImportPhase.Added && it.intent == binding.intent } == true
    /** Historical journal bytes are never a projection or decoder permit, including on DeviceOnly startup. */
    fun associations(scope: AccountScope): List<OriginalAssociation> {
        if (!enabled || !session.remoteCurrent(scope)) return emptyList()
        val accepted = proofs.value
        val snapshot = state.value
        return accepted.filter { (key, proof) -> key.owner == owner(scope) && proof.epoch == scope.epoch }
            .values.flatMap { proof -> proof.aliases.values.filter { live(it, snapshot) } }
    }
    fun association(scope: AccountScope, track: TrackId, operation: UUID): OriginalAssociation? =
        if (enabled && session.remoteCurrent(scope)) proofs.value[Member(owner(scope), track)]
            ?.takeIf { it.epoch == scope.epoch }?.aliases?.get(operation)?.takeIf { live(it, state.value) } else null
    fun playbackTrack(scope: AccountScope, track: TrackId, operation: String): Track? {
        val id = runCatching { UUID.fromString(operation).also { require(it.toString() == operation) } }.getOrNull() ?: return null
        val binding = association(scope, track, id) ?: return null
        if (!originalCurrent(binding.intent.original)) return null
        val display = binding.membership.display
        return Track(track, display.title, display.artist, display.album, binding.membership.durationMs)
    }
    fun owns(scope: AccountScope, association: OriginalAssociation) =
        association(scope, association.track, association.intent.operation) === association
    fun canPlay(scope: AccountScope, association: OriginalAssociation) = owns(scope, association) && originalCurrent(association.intent.original)

    /** One bounded, read-only restore sweep per authenticated epoch. Larger libraries are checked on demand. */
    fun reconcileRestored(scope: AccountScope) {
        val adapter = transport ?: return
        if (!session.remoteCurrent(scope)) return
        load()
        val targets = synchronized(membershipLock) {
            if (!session.remoteCurrent(scope) || observedRestoreEpoch == scope.epoch) return
            observedRestoreEpoch = scope.epoch
            entries(scope).asReversed().asSequence().filter { it.phase == OriginalImportPhase.Added }
                .mapNotNull { it.commit?.track }.distinct().take(MAX_RESTORE_READS).toList()
        }
        for (track in targets) {
            if (!session.remoteCurrent(scope)) break
            // Unknown/unreachable is not absence and must not fan out more calls into an outage.
            val result = reconcile(adapter, scope, track)
            if (result == Action.ReadbackRequired || result == Action.StorageUnavailable) break
        }
    }

    /** Ordinary online borrowing needs a fresh exact membership read, not a filtered Library page. */
    fun admitOnlinePlayback(scope: AccountScope, track: TrackId): List<OriginalAssociation> {
        val adapter = transport ?: return emptyList()
        if (!session.remoteCurrent(scope)) return emptyList()
        load()
        if (entries(scope).none { it.phase == OriginalImportPhase.Added && it.commit?.track == track &&
                originalCurrent(it.intent.original) }) return emptyList()
        if (reconcile(adapter, scope, track) != Action.Added) return emptyList()
        return proofs.value[Member(owner(scope), track)]?.takeIf { it.epoch == scope.epoch && session.remoteCurrent(scope) }
            ?.aliases?.values?.let { aliases -> val snapshot = state.value; aliases.filter { live(it, snapshot) } }.orEmpty()
    }

    /** An explicitly local-only occurrence may borrow without IO to the server, but only from
     * exact proof accepted in this continuously authenticated app epoch. DeviceOnly and cold
     * offline launch can play the ordinary phone row, not a historical numeric Library alias. */
    fun admitExplicitOriginal(scope: AccountScope, track: TrackId, operation: String): List<OriginalAssociation> {
        val id = runCatching { UUID.fromString(operation).also { require(it.toString() == operation) } }.getOrNull() ?: return emptyList()
        val binding = association(scope, track, id) ?: return emptyList()
        return if (canPlay(scope, binding)) listOf(binding) else emptyList()
    }

    class RemovalFence internal constructor(internal val scope: AccountScope, internal val owner: ServerAccount,
        internal val track: TrackId, internal val operation: UUID)

    fun removalPending(scope: AccountScope, track: TrackId): Boolean {
        load()
        return entries(scope).any { it.matches(owner(scope), track) && it.phase == OriginalImportPhase.RemovalPending }
    }

    /** Called at the authenticated DELETE's dispatch boundary, even when import is disabled. */
    fun prepareRemoval(scope: AccountScope, track: TrackId, mounted: () -> Boolean): RemovalFence? = synchronized(membershipLock) {
        fun current() = session.remoteCurrent(scope) && mounted()
        if (!current()) throw SafeFailure(SafeFailure.Reason.Retired)
        if (removalPending(scope, track)) throw SafeFailure(SafeFailure.Reason.RemovalUnconfirmed)
        val key = Member(owner(scope), track)
        val fence = RemovalFence(scope, key.owner, track, UUID.randomUUID())
        val prepared = try { journal.prepareRemoval(key.owner, track, fence.operation, ::current) }
        catch (_: Exception) {
            if (!current()) throw SafeFailure(SafeFailure.Reason.Retired)
            throw SafeFailure(SafeFailure.Reason.RemovalNotSent)
        }
        if (!prepared) return@synchronized null
        reads.remove(key)
        publishProof(key, null)
        fence
    }

    /** Only the exact current 204 confirms. Only the caller that never entered may retract. */
    fun finishRemoval(fence: RemovalFence, acknowledged: Boolean): Boolean = synchronized(membershipLock) {
        try {
            journal.finishRemoval(fence.owner, fence.track, fence.operation, acknowledged) {
                !acknowledged || session.remoteCurrent(fence.scope)
            }
            if (acknowledged) failedRetirements.remove(Member(fence.owner, fence.track))
            true
        } catch (_: Exception) { false }
    }

    class Choice internal constructor(internal val repository: OriginalImportRepository, internal val scope: AccountScope,
        val intent: OriginalImportIntent, internal val stamp: OriginalSourceStamp, internal val mounted: () -> Boolean) {
        internal val used = java.util.concurrent.atomic.AtomicBoolean()
    }
    enum class Action { Added, Unconfirmed, ReadbackRequired, Closed, Absent, RemovalUnconfirmed, Refused, Unavailable, StorageUnavailable, AlreadyInProgress, Retired }

    fun choose(scope: AccountScope, original: ContentOwner, display: ImportDisplay, overrideRevision: Long? = null, mounted: () -> Boolean): Choice? {
        if (!writeReady(scope) || !mounted()) return null
        val stamp = sourceStamp(original) ?: return null
        return try {
            val intent = OriginalImportIntent(owner(scope), UUID.randomUUID(), original, display, overrideRevision)
            if (transport?.canEncode(scope, intent) == true) Choice(this, scope, intent, stamp, mounted) else null
        }
        catch (_: IllegalArgumentException) { null }
    }

    fun confirm(choice: Choice): Action {
        if (choice.repository !== this || !mayWrite || !choice.used.compareAndSet(false, true)) return Action.Retired
        return interact(choice.scope, Work.Upload) { adapter ->
            if (!choice.mounted() || sourceStamp(choice.intent.original) != choice.stamp) return@interact Action.Unavailable
            val rows = entries(choice.scope)
            if (rows.any { it.intent.original.revision == choice.intent.original.revision && it.phase == OriginalImportPhase.RemovalPending })
                return@interact Action.RemovalUnconfirmed
            rows.firstOrNull { it.intent.original == choice.intent.original && it.phase == OriginalImportPhase.Added }?.let {
                return@interact reconcile(adapter, choice.scope, requireNotNull(it.commit).track)
            }
            if (rows.any { it.intent.original.revision == choice.intent.original.revision && it.phase == OriginalImportPhase.Closed }) return@interact Action.Closed
            if (rows.any { it.intent.original.revision == choice.intent.original.revision && it.phase == OriginalImportPhase.Removed }) return@interact Action.Absent
            if (rows.any { it.phase in activeImportPhases }) return@interact Action.AlreadyInProgress
            send(adapter, choice)
        }
    }

    /** Explicit recovery is GET only: a generic 404 or transient error is not a replay permit. */
    fun check(scope: AccountScope, operation: UUID, mounted: () -> Boolean): Action = interact(scope, Work.Check) { adapter ->
        if (!mounted()) return@interact Action.Retired
        val entry = entries(scope).singleOrNull { it.intent.operation == operation } ?: return@interact Action.Retired
        when (entry.phase) {
            OriginalImportPhase.Unconfirmed -> {
                val receipt = exchange { adapter.status(scope, entry.intent) }
                settle(adapter, scope, entry, receipt, true)
            }
            OriginalImportPhase.ReadbackRequired, OriginalImportPhase.Added -> readback(adapter, scope, entry)
            OriginalImportPhase.Closed -> Action.Closed
            OriginalImportPhase.RemovalPending -> Action.RemovalUnconfirmed
            OriginalImportPhase.Removed -> Action.Absent
            OriginalImportPhase.Refused -> Action.Refused
        }
    }


    private inline fun interact(scope: AccountScope, work: Work, block: (OriginalImportTransport) -> Action): Action {
        val adapter = transport ?: return Action.Retired
        if (!session.remoteCurrent(scope)) return Action.Retired
        val owner = owner(scope)
        synchronized(mutableWork) {
            if (owner in mutableWork.value) return Action.AlreadyInProgress
            mutableWork.value = mutableWork.value + (owner to work)
        }
        try {
            journal.load()
            if (!state.value.ready) return Action.StorageUnavailable
            if (!session.remoteCurrent(scope)) return Action.Retired
            return block(adapter)
        } finally { synchronized(mutableWork) { mutableWork.value = mutableWork.value - owner } }
    }

    private fun send(adapter: OriginalImportTransport, choice: Choice): Action {
        val scope = choice.scope
        val intent = choice.intent
        fun current() = session.remoteCurrent(scope) && sourceStamp(intent.original) == choice.stamp
        fun canSend() = current() && choice.mounted()
        if (!canSend()) return Action.Unavailable
        val opened = exchange { open(intent.original, ::current) } ?: return Action.Unavailable
        val entry = OriginalImportEntry(intent, OriginalImportPhase.Unconfirmed)
        val receipt = try {
            val body = exchange { VerifiedOriginalBody.verify(opened, intent.original.revision, ::current, ::canSend) } ?: return Action.Unavailable
            if (!canSend()) return Action.Retired
            if (!save(scope, entry, null)) return Action.StorageUnavailable
            if (!canSend()) return Action.Unconfirmed
            exchange { adapter.upload(scope, intent, body, ::canSend) }
        } finally {
            // Descriptor custody tracks a close failure independently; it cannot undo an ACK.
            runCatching { opened.close() }
        }
        return settle(adapter, scope, entry, receipt, false)
    }

    private fun settle(adapter: OriginalImportTransport, scope: AccountScope, entry: OriginalImportEntry, receipt: OriginalImportReceipt?, isRead: Boolean): Action {
        if (!session.remoteCurrent(scope)) return Action.Retired
        val status = receipt?.takeIf { it.destination == entry.intent.destination && it.operation == entry.intent.operation }?.status
        val next = when (status) {
            is OriginalReceiptStatus.Committed -> if (status.original.revision == entry.intent.original.revision)
                entry.copy(phase = OriginalImportPhase.ReadbackRequired, commit = status.original) else null
            OriginalReceiptStatus.Closed -> if (isRead) entry.copy(phase = OriginalImportPhase.Closed) else null
            OriginalReceiptStatus.Refused -> entry.copy(phase = OriginalImportPhase.Refused)
            else -> null
        }
        if (next == null) return Action.Unconfirmed
        if (!save(scope, next, entry)) return Action.StorageUnavailable
        return when (next.phase) {
            OriginalImportPhase.ReadbackRequired -> readback(adapter, scope, next)
            OriginalImportPhase.Closed -> Action.Closed
            else -> Action.Refused
        }
    }

    private fun readback(adapter: OriginalImportTransport, scope: AccountScope, entry: OriginalImportEntry): Action {
        val commit = requireNotNull(entry.commit)
        val result = reconcile(adapter, scope, commit.track)
        return if (result == Action.Added && association(scope, commit.track, entry.intent.operation) == null)
            Action.ReadbackRequired else result
    }

    private fun reconcile(adapter: OriginalImportTransport, scope: AccountScope, track: TrackId): Action {
        val key = Member(owner(scope), track)
        val ticket = Any()
        synchronized(membershipLock) {
            if (!session.remoteCurrent(scope)) return Action.Retired
            if (!state.value.ready) return Action.StorageUnavailable
            if (removalPending(scope, track)) return Action.RemovalUnconfirmed
            if (key in failedRetirements) return retireMember(scope, key)
            if (entries(scope).none { it.commit?.track == track && it.phase in liveOriginalReceipts }) return Action.Absent
            reads[key] = ticket
        }
        var added = false
        val outcome = try {
            val result = exchange { adapter.membership(scope, track) }
            synchronized(membershipLock) {
                if (!session.remoteCurrent(scope)) return@synchronized Action.Retired
                if (!state.value.ready || removalPending(scope, track)) return@synchronized Action.Retired
                // An owned affirmative absence is terminal for the operation even if another
                // reader began meanwhile. Neither a pending nor a later positive can revive it.
                if (result is OriginalMembershipResult.Absent && result.destination == key.owner && result.track == track)
                    return@synchronized if (entries(scope).any { it.commit?.track == track && it.phase in liveOriginalReceipts })
                        retireMember(scope, key) else Action.Absent
                if (reads[key] !== ticket) return@synchronized Action.Retired
                val row = (result as? OriginalMembershipResult.Present)?.row
                if (row?.destination != key.owner || row.original.track != track) return@synchronized Action.ReadbackRequired
                val aliases = mutableMapOf<UUID, OriginalAssociation>()
                val priorProof = proofs.value[key]?.takeIf { it.epoch == scope.epoch }
                for (entry in entries(scope).filter { it.commit == row.original && it.phase in liveOriginalReceipts && it.intent.display == row.display }) {
                    if (entry.phase == OriginalImportPhase.ReadbackRequired) {
                        if (!save(scope, entry.copy(phase = OriginalImportPhase.Added, membership = row), entry))
                            return@synchronized Action.StorageUnavailable
                        added = true
                    }
                    val binding = OriginalAssociation(entry.intent, row)
                    // Only continuous exact proof may preserve a previously entered decoder lease.
                    aliases[entry.intent.operation] = priorProof?.aliases?.get(entry.intent.operation)?.takeIf { it == binding } ?: binding
                }
                if (!session.remoteCurrent(scope)) return@synchronized Action.Retired
                publishProof(key, if (aliases.isEmpty()) null else Proof(scope.epoch, aliases))
                if (aliases.isEmpty()) Action.ReadbackRequired else Action.Added
            }
        } finally {
            synchronized(membershipLock) { if (reads[key] === ticket) reads.remove(key) }
        }
        if (added && outcome == Action.Added && session.remoteCurrent(scope)) exchange { onAdded(scope, track) }
        return outcome
    }

    private fun retireMember(scope: AccountScope, key: Member): Action {
        reads.remove(key) // Fence a held older 200 before touching durable state.
        publishProof(key, null)
        return try {
            journal.retireMembership(key.owner, key.track) { session.remoteCurrent(scope) }
            failedRetirements.remove(key)
            Action.Absent
        } catch (_: Exception) {
            if (!session.remoteCurrent(scope)) Action.Retired
            else { failedRetirements.add(key); Action.StorageUnavailable }
        }
    }

    private fun publishProof(key: Member, proof: Proof?) {
        val before = proofs.value
        val next = if (proof == null) before - key else before.filterValues { it.epoch == proof.epoch } + (key to proof)
        if (next != before) { proofs.value = next; proofSequence.value++ }
    }

    private fun save(scope: AccountScope, entry: OriginalImportEntry, expected: OriginalImportEntry?) =
        try { journal.put(entry, expected) { session.remoteCurrent(scope) }; true } catch (_: Exception) { false }
    private inline fun <T> exchange(block: () -> T): T? = try { block() } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { null }

    private companion object {
        const val MAX_RESTORE_READS = 8
    }
}

internal data class OriginalSourceStamp(val source: Long, val access: Long, val resolvedOwner: ContentOwner? = null)
