package com.soundq.android.data.deviceaudio

import java.io.File
import java.util.UUID

/** One installation-local storage owner, no queue, player, network, or source-file IO.
 * All calls serialize under this monitor. Persistent mutations acknowledge only after commit.
 * Capture, local-lock and retirement calls are process-local and never write a playback cursor.
 * Snapshots are observations, not permission to open a provider URI. */
internal class DeviceListeningStore(file: File, commitFault: (String) -> Unit = {}) : AutoCloseable {
    private val disk = DomainFile(file, commitFault)
    private val instance = UUID.randomUUID()
    private var epoch = 0L
    private var sourceEpoch = 0L
    private var unlocked = false
    private var closed = false
    private var account: ServerAccount? = null
    private var scanSequence = 0L
    private val scans = mutableMapOf<ScanGrantId, Long>()
    private val state get() = disk.state
    val loadState: LoadState @Synchronized get() = if (disk.rejected) LoadState.REJECTED else LoadState.READY

    @Synchronized fun unlock(account: ServerAccount? = null): AccessCapture {
        check(!closed)
        if (!unlocked || this.account != account) { epoch = Math.addExact(epoch, 1); scans.clear(); active.clear() }
        unlocked = true; this.account = account
        return AccessCapture(instance, epoch, account)
    }
    @Synchronized fun lock() { if (!closed) { epoch = Math.addExact(epoch, 1); unlocked = false; scans.clear(); active.clear() } }
    private fun current(access: AccessCapture): Boolean = !closed && unlocked && access == AccessCapture(instance, epoch, account) && disk.intact()
    private fun permitted(key: HistoryKey): Boolean = key is HistoryKey.Device || (key is HistoryKey.Server && key.scope == account)
    private fun accessChanged() { sourceEpoch = Math.addExact(sourceEpoch, 1); scans.clear(); active.clear() }
    private fun commit(next: DomainState): Mutation = if (next == state) Mutation.UNCHANGED else if (disk.commit(next)) Mutation.APPLIED else Mutation.REFUSED

    @Synchronized fun putGrant(access: AccessCapture, grant: ScanGrant): Mutation {
        if (!current(access)) return Mutation.REFUSED
        val old = state.grants.find { it.id == grant.id }
        // Changing the identity behind an existing grant is not reselection. Mint a new grant ID.
        if (old != null && (old.locator != grant.locator || old.kind != grant.kind)) return Mutation.REFUSED
        val aliases = state.files.map { f -> f.copy(aliases = f.aliases.map { a ->
            if (a.grantId == grant.id && grant.state != AccessState.AVAILABLE) a.copy(state = grant.state) else a
        }) }
        val next = state.copy(grants = state.grants.filterNot { it.id == grant.id } + grant, files = aliases)
        val result = commit(if (old == grant && aliases == state.files) state else next)
        val newSession = result != Mutation.REFUSED && grant.state == AccessState.AVAILABLE && sessionGrants.add(grant.id)
        if (result == Mutation.APPLIED || newSession) accessChanged()
        return result
    }
    @Synchronized fun removeGrant(access: AccessCapture, id: ScanGrantId): Mutation {
        val g = if (current(access)) state.grants.find { it.id == id } else null
        return g?.let { putGrant(access, it.copy(state = AccessState.REMOVED)) } ?: Mutation.REFUSED
    }
    @Synchronized fun beginScan(access: AccessCapture, grant: ScanGrantId): ScanCapture? {
        if (!current(access) || state.grants.none { it.id == grant && it.state == AccessState.AVAILABLE && (it.persisted || it.id in sessionGrants) }) return null
        scanSequence = Math.addExact(scanSequence, 1); scans[grant] = scanSequence
        return ScanCapture(access, grant, scanSequence)
    }
    /** Acknowledged proofs from ONE grant. Only complete coverage retires omitted aliases.
     * Use complete=false for isolated row-proof failures after enumeration, never a cancelled prefix.
     * Cancelled/denied enumerations must not call this. Repeated identical input is idempotent. */
    @Synchronized fun publishScan(capture: ScanCapture, audio: List<DiscoveredAudio>, complete: Boolean = true): Mutation {
        if (!current(capture.access) || scans[capture.grantId] != capture.sequence || state.grants.none { it.id == capture.grantId && it.state == AccessState.AVAILABLE }) return Mutation.REFUSED
        if (audio.size > DomainFile.MAX_RECORDS || audio.distinctBy { it.locator }.size != audio.size) return Mutation.REFUSED
        if (audio.groupBy { it.objectId }.values.any { rows -> rows.any { it.copy(locator = rows[0].locator, state = rows[0].state) != rows[0] } }) return Mutation.REFUSED
        var files = state.files.map { f -> f.copy(aliases = f.aliases.map { a ->
            val movedTo = audio.find { it.locator == a.locator }
            if ((complete && a.grantId == capture.grantId && audio.none { it.objectId == f.objectId && it.locator == a.locator }) || (movedTo != null && movedTo.objectId != f.objectId)) a.copy(state = AccessState.MISSING) else a
        }) }.toMutableList()
        for (d in audio) {
            val at = files.indexOfFirst { it.objectId == d.objectId }
            val old = files.getOrNull(at)
            val alias = LocatorAccess(capture.grantId, d.locator, d.state)
            val next = DeviceAudio(old?.id ?: DeviceFileId(UUID.randomUUID()), d.objectId, d.revision,
                if (old == null) 1 else if (old.revision == d.revision) old.incarnation else Math.addExact(old.incarnation, 1),
                d.metadata, d.durationMs, (old?.aliases.orEmpty().filterNot { it.grantId == alias.grantId && it.locator == alias.locator } + alias))
            if (at < 0) files.add(next) else files[at] = next
        }
        files = files.map { f -> f.copy(aliases = f.aliases.sortedWith(compareBy({ it.grantId.value.toString() }, { it.locator.provider }, { it.locator.value }))) }.toMutableList()
        if (files.size > DomainFile.MAX_RECORDS) return Mutation.REFUSED
        val invalidateAccess = state.files.any { old -> files.find { it.id == old.id }?.let { it.aliases != old.aliases || it.owner != old.owner } == true }
        val result = commit(state.copy(files = files))
        if (result == Mutation.APPLIED && invalidateAccess) accessChanged()
        // One publication per capture, even if idempotent. Older captures never become current again.
        if (result != Mutation.REFUSED) scans.remove(capture.grantId)
        return result
    }
    @Synchronized fun snapshot(access: AccessCapture): DeviceListeningSnapshot? {
        if (!current(access)) return null
        val grants = state.grants.map { if (!it.persisted && it.state == AccessState.AVAILABLE && !sessionGrants.contains(it.id)) it.copy(state = AccessState.REVOKED) else it }
        val usable = grants.filter { it.state == AccessState.AVAILABLE }.map { it.id }.toSet()
        return DeviceListeningSnapshot(state.revision, state.files.map { f -> f.copy(aliases = f.aliases.map { if (it.grantId !in usable && it.state == AccessState.AVAILABLE) it.copy(state = AccessState.REVOKED) else it }) }, grants.toList(),
            state.journal.filter { permitted(it.key) }.map { ListeningHistory(it.key, it.playedAt, it.bookmark) })
    }
    private data class Active(val capture: TraversalCapture, val duration: Long, val admissionOrder: Long, val played: Boolean = false)
    // Prepared occurrences coexist. Only successful advancing playback acquires the durable journal.
    private val active = mutableMapOf<UUID, Active>()
    private var admissionOrder = 0L
    private val sources = mutableMapOf<HistoryKey, SourceCapture>()
    private val usedAdmissions = mutableMapOf<HistoryKey, UUID>()
    private fun sourceCurrent(source: SourceCapture): Boolean {
        if (!current(source.access) || source.accessGeneration != sourceEpoch || !permitted(source.owner.key)) return false
        if (sources[source.owner.key] != source && active.values.none { it.capture.source == source }) return false
        return when (val k = source.owner.key) {
            is HistoryKey.Device -> snapshot(source.access)?.files?.any { it.id == k.id && it.owner == source.owner && it.available } == true
            is HistoryKey.Server -> state.servers.any { it.owner == source.owner }
        }
    }
    @Synchronized fun captureSource(access: AccessCapture, id: DeviceFileId): SourceCapture? {
        if (!current(access)) return null
        val f = snapshot(access)?.files?.find { it.id == id && it.available } ?: return null
        return SourceCapture(access, f.owner, sourceEpoch, UUID.randomUUID()).also { sources[it.owner.key] = it }
    }
    private fun entry(key: HistoryKey): JournalEntry = state.journal.find { it.key == key } ?: JournalEntry(key)
    private fun journal(next: JournalEntry): Mutation = commit(state.copy(journal = state.journal.filterNot { it.key == next.key } + next))
    /** Call only after identity validation and decoder-measured duration. Preparation never writes a cursor. */
    @Synchronized fun beginTraversal(source: SourceCapture, occurrence: UUID, sourceGeneration: Long, seekIdentity: Long, consumedEndBaseline: Long, decodedDurationMs: Long): TraversalCapture? {
        if (!sourceCurrent(source) || sources[source.owner.key] != source || usedAdmissions[source.owner.key] == source.admission || sourceGeneration <= 0 || seekIdentity < 0 || consumedEndBaseline < 0 || decodedDurationMs <= 0) return null
        val t = TraversalCapture(source, UUID.randomUUID(), occurrence, sourceGeneration, seekIdentity, consumedEndBaseline)
        admissionOrder = Math.addExact(admissionOrder, 1)
        active[t.traversal] = Active(t, decodedDurationMs, admissionOrder)
        usedAdmissions[source.owner.key] = source.admission
        return t
    }
    private fun accepted(t: TraversalCapture, seq: Long): Active? {
        if (!sourceCurrent(t.source)) return null
        val a = active[t.traversal] ?: return null
        val j = entry(t.source.owner.key)
        return a.takeIf { a.capture == t && if (a.played) !j.completed && j.traversal == t.traversal && seq > j.sequence else seq > 0 }
    }
    @Synchronized fun played(receipt: SuccessfulPlaybackReceipt): Mutation {
        val a = accepted(receipt.traversal, receipt.eventSequence) ?: return Mutation.REFUSED
        if (receipt.playedAtEpochMs < 0) return Mutation.REFUSED
        val key = receipt.traversal.source.owner.key
        val result = journal(entry(key).copy(playedAt = receipt.playedAtEpochMs, traversal = a.capture.traversal, sequence = receipt.eventSequence, completed = false))
        if (result != Mutation.REFUSED) {
            // A real newer play permanently supersedes older occurrences, not an optional preload.
            active.entries.removeAll { it.value.capture.source.owner.key == key && it.value.admissionOrder < a.admissionOrder }
            active[a.capture.traversal] = a.copy(played = true)
        }
        return result
    }
    @Synchronized fun checkpoint(checkpoint: SourcePositionCheckpoint): Mutation {
        val a = accepted(checkpoint.traversal, checkpoint.eventSequence) ?: return Mutation.REFUSED
        if (!a.played || a.duration <= 600000 || checkpoint.positionMs !in 0..a.duration) return Mutation.REFUSED
        val owner = checkpoint.traversal.source.owner
        return journal(entry(owner.key).copy(bookmark = Bookmark(owner, checkpoint.positionMs), sequence = checkpoint.eventSequence))
    }
    @Synchronized fun bookmark(source: SourceCapture): Bookmark? {
        if (!sourceCurrent(source)) return null
        return entry(source.owner.key).bookmark?.takeIf { it.owner == source.owner }
    }
    @Synchronized fun complete(evidence: QualifiedNaturalEnd): Mutation {
        val t = evidence.traversal
        val a = accepted(t, evidence.eventSequence) ?: return Mutation.REFUSED
        if (!a.played || evidence.nativeOccurrence != t.occurrence || evidence.nativeSourceGeneration != t.sourceGeneration ||
            evidence.nativeSeekIdentity != t.seekIdentity || evidence.consumedEndCount <= t.consumedEndBaseline) return Mutation.REFUSED
        val key = t.source.owner.key
        val result = journal(entry(key).copy(bookmark = null, sequence = evidence.eventSequence, completed = true))
        if (result != Mutation.REFUSED) active.remove(t.traversal)
        return result
    }
    /** Retire the old traversal BEFORE issuing native seek. Checkpoint only after seek acknowledgement.
     * A seek inherits prior successful playback qualification, never synthesizes recency. */
    @Synchronized fun beginSeek(previous: TraversalCapture, seekIdentity: Long, consumedEndBaseline: Long): TraversalCapture? {
        if (!sourceCurrent(previous.source) || seekIdentity <= previous.seekIdentity || consumedEndBaseline < previous.consumedEndBaseline) return null
        val a = active[previous.traversal]?.takeIf { it.capture == previous } ?: return null
        val next = previous.copy(traversal = UUID.randomUUID(), seekIdentity = seekIdentity, consumedEndBaseline = consumedEndBaseline)
        val key = previous.source.owner.key
        if (a.played && journal(entry(key).copy(traversal = next.traversal, sequence = 0, completed = false)) == Mutation.REFUSED) return null
        active.remove(previous.traversal)
        active[next.traversal] = a.copy(capture = next)
        return next
    }
    /** After final acknowledged pause/stop position, or cancellation. No implicit zero or completion. */
    @Synchronized fun retireTraversal(traversal: TraversalCapture): Mutation {
        if (!sourceCurrent(traversal.source) || active[traversal.traversal]?.capture != traversal) return Mutation.REFUSED
        active.remove(traversal.traversal)
        return Mutation.APPLIED // memory retirement only; existing durable checkpoint is unchanged
    }
    private val serverEvents = mutableMapOf<HistoryKey.Server, ServerHistoryCapture>()
    @Synchronized fun captureServerHistory(access: AccessCapture, key: HistoryKey.Server): ServerHistoryCapture? {
        if (!current(access) || !permitted(key)) return null
        return ServerHistoryCapture(access, key, UUID.randomUUID()).also { serverEvents[key] = it }
    }
    @Synchronized fun playedServer(receipt: SuccessfulServerPlaybackReceipt): Mutation {
        val capture = receipt.capture
        if (!current(capture.access) || !permitted(capture.key) || serverEvents[capture.key] != capture || receipt.playedAtEpochMs < 0) return Mutation.REFUSED
        val result = journal(entry(capture.key).copy(playedAt = receipt.playedAtEpochMs))
        if (result != Mutation.REFUSED) serverEvents.remove(capture.key)
        return result
    }
    @Synchronized fun recent(access: AccessCapture, items: List<RecentItem>): List<RecentItem>? {
        if (!current(access) || items.size > DomainFile.MAX_RECORDS || items.distinctBy { it.key }.size != items.size || items.any { !permitted(it.key) }) return null
        val times = state.journal.associate { it.key to it.playedAt }
        return items.sortedWith { left, right ->
            val a = times[left.key]; val b = times[right.key]
            val time = when { a == null && b == null -> 0; a == null -> 1; b == null -> -1; else -> b.compareTo(a) }
            if (time != 0) time else {
                val title = left.displayTitle.lowercase(java.util.Locale.ROOT).compareTo(right.displayTitle.lowercase(java.util.Locale.ROOT))
                if (title != 0) title else stableSourceIdentity(left.key).compareTo(stableSourceIdentity(right.key))
            }
        }
    }
    /** For already validated immutable server/download content. Scope is still server-owned.
     * Plain server recency uses captureServerHistory and never invents a content digest. */
    @Synchronized fun bindServerContent(access: AccessCapture, key: HistoryKey.Server, revision: ContentRevision, decodedDurationMs: Long): SourceCapture? {
        if (!current(access) || !permitted(key) || decodedDurationMs <= 0) return null
        val old = state.servers.find { it.owner.key == key }
        val changed = old != null && (old.owner.revision != revision || old.durationMs != decodedDurationMs)
        val owner = ContentOwner(key, revision, if (old == null) 1 else if (changed) Math.addExact(old.owner.incarnation, 1) else old.owner.incarnation)
        if (old == null || changed) {
            if (commit(state.copy(servers = state.servers.filterNot { it.owner.key == key } + ServerContent(owner, decodedDurationMs))) == Mutation.REFUSED) return null
        }
        return SourceCapture(access, owner, sourceEpoch, UUID.randomUUID()).also { sources[key] = it }
    }
    @Synchronized fun retireServerHistory(capture: ServerHistoryCapture): Mutation {
        if (!current(capture.access) || serverEvents[capture.key] != capture) return Mutation.REFUSED
        serverEvents.remove(capture.key)
        return Mutation.APPLIED // memory-only admission retirement
    }
    /** Platform/service observed opening failure. No grant minting, source IO, or progress deletion. */
    @Synchronized fun reportUnavailable(source: SourceCapture, locator: ProviderLocator, reason: AccessState): Mutation {
        if (reason !in setOf(AccessState.MISSING, AccessState.UNREADABLE, AccessState.UNSUPPORTED) || !sourceCurrent(source)) return Mutation.REFUSED
        val key = source.owner.key as? HistoryKey.Device ?: return Mutation.REFUSED
        val f = state.files.find { it.id == key.id } ?: return Mutation.REFUSED
        if (f.aliases.none { it.locator == locator }) return Mutation.REFUSED
        val next = f.copy(aliases = f.aliases.map { if (it.locator == locator) it.copy(state = reason) else it })
        val result = commit(state.copy(files = state.files.map { if (it.id == key.id) next else it }))
        if (result == Mutation.APPLIED) accessChanged()
        return result
    }
    private val sessionGrants = mutableSetOf<ScanGrantId>()
    @Synchronized override fun close() {
        if (!closed) {
            closed = true; unlocked = false; scans.clear(); active.clear(); sources.clear()
            usedAdmissions.clear(); serverEvents.clear(); sessionGrants.clear(); disk.close()
        }
    }
}
