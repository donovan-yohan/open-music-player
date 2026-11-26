package com.soundq.android.data.originalimport

import com.soundq.android.data.TrackId
import com.soundq.android.data.deviceaudio.*
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.NoSuchFileException
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.nio.file.StandardOpenOption.READ
import java.nio.file.attribute.BasicFileAttributes
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

internal enum class OriginalImportPhase { Unconfirmed, Closed, Refused, ReadbackRequired, Added, RemovalPending, Removed }
internal data class OriginalImportEntry(
    val intent: OriginalImportIntent,
    val phase: OriginalImportPhase,
    val commit: CommittedOriginal? = null,
    val membership: OriginalMembership? = null,
    val removal: UUID? = null,
) {
    init {
        require((commit != null) == (phase in liveOriginalReceipts || phase == OriginalImportPhase.RemovalPending || phase == OriginalImportPhase.Removed))
        require(commit == null || commit.revision == intent.original.revision)
        require(phase == OriginalImportPhase.RemovalPending || (membership != null) == (phase == OriginalImportPhase.Added))
        when (phase) {
            OriginalImportPhase.RemovalPending -> require(removal != null)
            OriginalImportPhase.Removed -> Unit // Also accepts v1 retirements without a DELETE operation.
            else -> require(removal == null)
        }
        if (membership != null) require(membership.original == commit && membership.destination == intent.destination &&
            membership.display == intent.display)
    }
}

internal data class OriginalImportSnapshot(val ready: Boolean = false, val rejected: Boolean = false, val rows: List<OriginalImportEntry> = emptyList()) {
    private val byOperation = rows.associateBy { it.intent.operation }
    fun entry(operation: UUID): OriginalImportEntry? = byOperation[operation]
}

/** A DELETE may race an earlier upload whose canonical track is still unknown. */
private data class RemovalConflict(val upload: UUID, val track: TrackId, val removal: UUID, val confirmed: Boolean = false)

/** One app-owned, no-backup file. A rejected/future journal never authorizes upload or overwrite. */
internal class OriginalImportJournal(private val file: File) {
    private val mutable = MutableStateFlow(OriginalImportSnapshot())
    val state: StateFlow<OriginalImportSnapshot> = mutable
    private var loadedBytes: ByteArray? = null
    private var loadedRows = emptyList<OriginalImportEntry>()
    private var conflicts = emptyList<RemovalConflict>()
    // Only operations in this set are certified never to have gained wire admission.
    private var prepared = emptySet<UUID>()
    private var initialReadFailed = false
    private enum class Write { Prepare, Enter, Retract, Confirm }
    private data class RemovalWrite(val owner: ServerAccount, val track: TrackId, val operation: UUID, val kind: Write)
    private data class UnverifiedRemoval(val write: RemovalWrite, val bytes: ByteArray,
        val rows: List<OriginalImportEntry>, val conflicts: List<RemovalConflict>, val prepared: Set<UUID>)
    private var unverifiedRemoval: UnverifiedRemoval? = null

    @Synchronized fun load() {
        if (state.value.ready || state.value.rejected) return
        try {
            val bytes = try { read() } catch (_: IOException) { initialReadFailed = true; return }
            // Disappearance after a failed read is not evidence of a fresh, empty journal.
            if (bytes == null && initialReadFailed) return
            val disk = bytes?.let { Json.decodeFromString<Disk>(it.decodeToString(throwOnInvalidSequence = true)) }
            if (disk != null) {
                require(disk.version in 1..4 && disk.rows.size <= MAX_ROWS && disk.conflicts.size <= MAX_ROWS)
                require((disk.version == 4) == disk.prepared.isNotEmpty() && disk.prepared.size <= MAX_ROWS)
                if (disk.version == 1) require(disk.rows.none { it.removal != null || it.phase == OriginalImportPhase.RemovalPending.name })
                if (disk.version < 3) require(disk.conflicts.isEmpty())
            }
            val rows = disk?.rows.orEmpty().map(DiskRow::domain)
            val restoredConflicts = disk?.conflicts.orEmpty().map(DiskConflict::domain)
            val restoredPrepared = disk?.prepared.orEmpty().map(::canonicalUuid).toSet()
            require(restoredPrepared.size == disk?.prepared.orEmpty().size)
            validate(rows, restoredConflicts, restoredPrepared)
            loadedBytes = bytes
            publish(rows, restoredConflicts, restoredPrepared)
        } catch (_: Exception) {
            mutable.value = OriginalImportSnapshot(rejected = true)
        }
    }

    @Synchronized fun put(entry: OriginalImportEntry, expected: OriginalImportEntry?, current: () -> Boolean): OriginalImportEntry {
        load()
        check(state.value.ready && current())
        val rows = state.value.rows
        val previous = state.value.entry(entry.intent.operation)
        check(previous == expected && (previous == null || previous.intent == entry.intent))
        check(previous?.removal == null && entry.removal == null)
        if (entry.phase == OriginalImportPhase.Unconfirmed) check(rows.none {
            it.intent.destination == entry.intent.destination && it.intent.original.revision == entry.intent.original.revision &&
                it.phase in setOf(OriginalImportPhase.RemovalPending, OriginalImportPhase.Removed)
        })
        val matched = if (previous?.phase == OriginalImportPhase.Unconfirmed && entry.commit != null)
            conflicts.filter { it.upload == entry.intent.operation && it.track == entry.commit.track } else emptyList()
        val conflict = matched.firstOrNull { it.confirmed } ?: matched.firstOrNull()
        val settled = if (conflict == null) entry else entry.copy(
            phase = if (conflict.confirmed) OriginalImportPhase.Removed else OriginalImportPhase.RemovalPending,
            removal = conflict.removal, membership = null)
        val nextConflicts = if (entry.phase == OriginalImportPhase.Unconfirmed) conflicts else
            conflicts.filterNot { it.upload == entry.intent.operation && it.confirmed }
        replace(rows.filterNot { it.intent.operation == entry.intent.operation } + settled, current, nextConflicts,
            mayReclaimRefusals = previous == null || previous.phase == OriginalImportPhase.Unconfirmed && entry.commit != null,
            admittingUpload = previous == null && entry.phase == OriginalImportPhase.Unconfirmed,
            refusingUpload = previous?.phase == OriginalImportPhase.Unconfirmed && entry.phase == OriginalImportPhase.Refused)
        return settled
    }

    /** An owned GET absence retires live receipts; it cannot settle or undo a DELETE fence. */
    @Synchronized fun retireMembership(destination: ServerAccount, track: TrackId, current: () -> Boolean) {
        load()
        check(state.value.ready && current())
        val rows = state.value.rows
        val next = rows.map { row ->
            if (row.matches(destination, track) && row.phase in liveOriginalReceipts)
                row.copy(phase = OriginalImportPhase.Removed, membership = null) else row
        }
        if (next != rows) replace(next, current)
    }

    @Synchronized fun pendingRemoval(destination: ServerAccount, track: TrackId): UUID? {
        load()
        val snapshot = state.value
        return snapshot.rows.firstOrNull { it.matches(destination, track) && it.phase == OriginalImportPhase.RemovalPending }?.removal
            ?: conflicts.firstOrNull { !it.confirmed && it.track == track &&
                snapshot.entry(it.upload)?.intent?.destination == destination }?.removal
    }

    @Synchronized fun preparedRemoval(destination: ServerAccount, track: TrackId): UUID? =
        pendingRemoval(destination, track)?.takeIf { it in prepared }

    /** An unknown-target upload cannot establish that it is unrelated to a pending removal. */
    @Synchronized fun allowsUnknownTargetMutation(destination: ServerAccount): Boolean {
        load()
        val snapshot = state.value
        return snapshot.ready && snapshot.rows.none {
            it.intent.destination == destination && it.phase == OriginalImportPhase.RemovalPending
        } && conflicts.none { !it.confirmed && snapshot.entry(it.upload)?.intent?.destination == destination } &&
            runCatching { read().contentEquals(loadedBytes) }.getOrDefault(false)
    }

    /** Fence known receipts and any still-unresolved upload for this exact member before wire entry. */
    @Synchronized fun prepareRemoval(destination: ServerAccount, track: TrackId, operation: UUID, current: () -> Boolean): Boolean {
        load()
        check(state.value.ready && current() && pendingRemoval(destination, track) == null)
        val rows = state.value.rows
        val next = rows.map { row ->
            if (row.matches(destination, track) && row.phase in liveOriginalReceipts)
                row.copy(phase = OriginalImportPhase.RemovalPending, removal = operation) else row
        }
        val upload = rows.singleOrNull { it.intent.destination == destination && it.phase == OriginalImportPhase.Unconfirmed }
        val nextConflicts = if (upload == null || conflicts.any { it.confirmed && it.upload == upload.intent.operation && it.track == track })
            conflicts else conflicts + RemovalConflict(upload.intent.operation, track, operation)
        if (next == rows && nextConflicts == conflicts) {
            check(read().contentEquals(loadedBytes))
            return false
        }
        replace(next, current, nextConflicts, RemovalWrite(destination, track, operation, Write.Prepare),
            nextPrepared = prepared + operation)
        return true
    }

    /** Cross the irreversible boundary before the caller can allow any request headers. */
    @Synchronized fun enterRemoval(destination: ServerAccount, track: TrackId, operation: UUID, current: () -> Boolean) {
        check(state.value.ready && current() && preparedRemoval(destination, track) == operation)
        replace(loadedRows, current, removalWrite = RemovalWrite(destination, track, operation, Write.Enter),
            nextPrepared = prepared - operation)
    }

    @Synchronized fun removalWriteUnverified(operation: UUID) =
        unverifiedRemoval?.write?.let { it.operation == operation && it.kind == Write.Prepare } == true

    @Synchronized fun finishRemoval(destination: ServerAccount, track: TrackId, operation: UUID, acknowledged: Boolean,
        preparedOnly: Boolean = false, current: () -> Boolean) {
        check(current() && !(acknowledged && preparedOnly))
        val writing = if (acknowledged) Write.Confirm else Write.Retract
        if (!state.value.ready) {
            // Read back only the exact old/candidate bytes for this live operation and disposition.
            val unverified = unverifiedRemoval
            check(unverified != null && unverified.write.owner == destination && unverified.write.track == track &&
                unverified.write.operation == operation && (unverified.write.kind == writing ||
                    !preparedOnly && writing == Write.Retract && unverified.write.kind in setOf(Write.Prepare, Write.Enter)))
            val disk = read()
            check(current())
            val landed = disk.contentEquals(unverified.bytes)
            if (landed) {
                loadedBytes = unverified.bytes
                loadedRows = unverified.rows
                conflicts = unverified.conflicts
                prepared = unverified.prepared
            } else check(disk.contentEquals(loadedBytes))
            val cleanupComplete = when (unverified.write.kind) {
                Write.Prepare -> !landed
                Write.Enter -> false // Both the old prepared and the new entered bytes retain protection.
                else -> landed
            }
            if (cleanupComplete) {
                syncDirectory()
                check(current())
                publish(loadedRows, conflicts, prepared)
                unverifiedRemoval = null
                return
            }
        }
        if (preparedOnly) check(operation in prepared)
        if (acknowledged) check(operation !in prepared)
        val rows = loadedRows
        val next = rows.map { row ->
            if (!row.matches(destination, track) || row.removal != operation || row.phase != OriginalImportPhase.RemovalPending) row
            else if (acknowledged) row.copy(phase = OriginalImportPhase.Removed, membership = null)
            else row.copy(phase = if (row.membership == null) OriginalImportPhase.ReadbackRequired else OriginalImportPhase.Added, removal = null)
        }
        val nextConflicts = conflicts.mapNotNull { conflict ->
            if (conflict.removal != operation || conflict.track != track || conflict.confirmed) return@mapNotNull conflict
            val upload = rows.single { it.intent.operation == conflict.upload }
            check(upload.intent.destination == destination)
            if (acknowledged && upload.phase == OriginalImportPhase.Unconfirmed) conflict.copy(confirmed = true) else null
        }
        check(next != rows || nextConflicts != conflicts)
        replace(next, current, nextConflicts, RemovalWrite(destination, track, operation, writing),
            nextPrepared = prepared - operation)
        unverifiedRemoval = null
    }

    private fun replace(next: List<OriginalImportEntry>, current: () -> Boolean, nextConflicts: List<RemovalConflict> = conflicts,
        removalWrite: RemovalWrite? = null, mayReclaimRefusals: Boolean = false, nextPrepared: Set<UUID> = prepared,
        admittingUpload: Boolean = false, refusingUpload: Boolean = false) {
        require(nextConflicts.size <= MAX_ROWS)
        // Legacy bytes did not reserve room. Keep their cleanup usable without letting
        // a new upload or any subsequent write consume more of its receipts' allowance.
        val previousBudget = (loadedBytes?.size ?: 0) + receiptReserve(loadedRows)
        val budget = if (admittingUpload) MAX_BYTES else maxOf(MAX_BYTES, previousBudget)
        fun encode(rows: List<OriginalImportEntry>): ByteArray? {
            if (rows.size > MAX_ROWS) return null
            validate(rows, nextConflicts, nextPrepared)
            // Older clients reject prepared bytes. Entered rows retain the conservative v2/v3 form.
            val version = when {
                nextPrepared.isNotEmpty() -> 4
                nextConflicts.isNotEmpty() -> 3
                rows.any { it.removal != null } -> 2
                else -> 1
            }
            return Json.encodeToString(Disk(version, rows.map(DiskRow::from), nextConflicts.map(DiskConflict::from),
                nextPrepared.map(UUID::toString)))
                .encodeToByteArray().takeIf { it.size <= MAX_BYTES && it.size + receiptReserve(rows) <= budget }
        }
        var persisted = next
        var encoded = encode(persisted)
        if (encoded == null && mayReclaimRefusals) {
            // Only definitive no-commit rows are dispensable. Keep every fence and the rows it needs.
            val referenced = nextConflicts.mapTo(mutableSetOf()) { it.upload }
            persisted = next.filterNot { it.phase == OriginalImportPhase.Refused && it.intent.operation !in referenced }
            encoded = encode(persisted)
        }
        val bytes = requireNotNull(encoded)
        check(read().contentEquals(loadedBytes)) { "Original import journal changed outside its owner" }
        val dir = requireNotNull(file.parentFile).toPath()
        val stage = Files.createTempFile(dir, ".original-import-", ".pending")
        try {
            FileOutputStream(stage.toFile()).use { stream -> stream.write(bytes); stream.fd.sync() }
            check(current())
            check(read().contentEquals(loadedBytes)) { "Original import journal changed outside its owner" }
            check(current())
            try {
                Files.move(stage, file.toPath(), ATOMIC_MOVE, REPLACE_EXISTING)
                // Readback proves visibility, not crash durability. A definitive refusal also
                // must survive restart before the caller drops its exact no-write witness.
                if (removalWrite != null || admittingUpload || refusingUpload) syncDirectory()
                check(read().contentEquals(bytes)) { "Original import journal replacement could not be verified" }
            } catch (failure: Exception) {
                // An ambiguous replacement must not leave cached Added rows authorizing reads.
                if (!runCatching { read().contentEquals(loadedBytes) }.getOrDefault(false)) {
                    unverifiedRemoval = removalWrite?.let { UnverifiedRemoval(it, bytes, persisted, nextConflicts, nextPrepared) }
                    mutable.value = OriginalImportSnapshot(rejected = true)
                }
                throw failure
            }
        } finally { runCatching { Files.deleteIfExists(stage) } }
        loadedBytes = bytes
        publish(persisted, nextConflicts, nextPrepared)
    }

    private fun syncDirectory() {
        FileChannel.open(requireNotNull(file.parentFile).toPath(), READ).use { it.force(true) }
    }

    private fun receiptReserve(rows: List<OriginalImportEntry>): Int = rows.sumOf {
        when (it.phase) {
            OriginalImportPhase.Unconfirmed -> uploadReceiptGrowth
            OriginalImportPhase.ReadbackRequired -> membershipGrowth
            else -> 0
        }
    }

    private fun publish(rows: List<OriginalImportEntry>, nextConflicts: List<RemovalConflict>, nextPrepared: Set<UUID>) {
        loadedRows = java.util.Collections.unmodifiableList(rows)
        conflicts = nextConflicts
        prepared = nextPrepared
        mutable.value = OriginalImportSnapshot(ready = true, rows = loadedRows)
    }

    private fun read(): ByteArray? {
        val path = file.toPath()
        val attributes = try { Files.readAttributes(path, BasicFileAttributes::class.java, NOFOLLOW_LINKS) }
        catch (_: NoSuchFileException) { return null }
        check(attributes.isRegularFile)
        return Files.newInputStream(path, NOFOLLOW_LINKS).use { stream ->
            val bytes = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val n = stream.read(buffer)
                if (n < 0) break
                check(n > 0 && bytes.size() + n <= MAX_BYTES)
                bytes.write(buffer, 0, n)
            }
            bytes.toByteArray()
        }
    }

    private fun validate(rows: List<OriginalImportEntry>, conflicts: List<RemovalConflict>, prepared: Set<UUID>) {
        val byOperation = rows.associateBy { it.intent.operation }
        require(byOperation.size == rows.size)
        val added = rows.filter { it.phase == OriginalImportPhase.Added }
        require(added.groupBy { it.intent.destination to it.commit?.track }.values.all { group ->
            group.map { it.intent.original.revision }.distinct().size == 1
        })
        require(added.distinctBy { it.intent.destination to it.intent.original }.size == added.size)
        val pending = rows.filter { it.phase in activeImportPhases }
        require(pending.distinctBy { it.intent.destination }.size == pending.size)
        val joined = rows.filter { it.removal != null }.groupBy { it.removal }
        require(joined.values.all { group -> group.distinctBy { Triple(it.intent.destination, it.commit?.track, it.phase) }.size == 1 })
        val fenced = rows.filter { it.phase == OriginalImportPhase.RemovalPending }.map { (it.intent.destination to it.commit?.track) to it.removal }.toMutableList()
        require(conflicts.distinctBy { it.removal }.size == conflicts.size)
        for (conflict in conflicts) {
            val upload = requireNotNull(byOperation[conflict.upload])
            if (conflict.confirmed) require(upload.phase == OriginalImportPhase.Unconfirmed)
            val phase = if (conflict.confirmed) OriginalImportPhase.Removed else OriginalImportPhase.RemovalPending
            require(joined[conflict.removal].orEmpty().all { it.phase == phase && it.matches(upload.intent.destination, conflict.track) })
            if (!conflict.confirmed) fenced.add((upload.intent.destination to conflict.track) to conflict.removal)
        }
        val byMember = fenced.groupBy({ it.first }, { it.second })
        require(byMember.values.all { it.distinct().size == 1 })
        val pendingOperations = fenced.mapTo(mutableSetOf()) { it.second }
        require(prepared.size <= MAX_ROWS && prepared.all { it != UUID(0, 0) && it in pendingOperations })
        require(rows.none { it.phase in liveOriginalReceipts && (it.intent.destination to it.commit?.track) in byMember })
    }

    @Serializable private data class Disk(val version: Int, val rows: List<DiskRow>,
        val conflicts: List<DiskConflict> = emptyList(), val prepared: List<String> = emptyList())
    @Serializable private data class DiskConflict(val upload: String, val track: Long, val removal: String, val confirmed: Boolean = false) {
        fun domain() = RemovalConflict(canonicalUuid(upload), TrackId(track), canonicalUuid(removal), confirmed)
        companion object {
            fun from(conflict: RemovalConflict) = DiskConflict(conflict.upload.toString(), conflict.track.value,
                conflict.removal.toString(), conflict.confirmed)
        }
    }
    @Serializable private data class DiskRow(
        val endpoint: String, val account: String, val operation: String, val file: String,
        val sha256: String, val length: Long, val incarnation: Long,
        val title: String, val artist: String, val album: String, val phase: String,
        val track: Long? = null, val durationMs: Long? = null, val removal: String? = null,
        val overrideRevision: Long? = null,
    ) {
        fun domain(): OriginalImportEntry {
            val intent = OriginalImportIntent(ServerAccount(endpoint, account), canonicalUuid(operation),
                ContentOwner(HistoryKey.Device(DeviceFileId(canonicalUuid(file))), ContentRevision(sha256, length), incarnation),
                ImportDisplay(title, artist, album), overrideRevision)
            val commit = track?.let { CommittedOriginal(TrackId(it), intent.original.revision) }
            // Display consent is historical; live display always comes from fresh exact membership.
            val membership = durationMs?.let { OriginalMembership(intent.destination, requireNotNull(commit), intent.display, it) }
            return OriginalImportEntry(intent, OriginalImportPhase.valueOf(phase), commit, membership, removal?.let(::canonicalUuid))
        }
        companion object {
            fun from(row: OriginalImportEntry): DiskRow = row.intent.let { i ->
                DiskRow(i.destination.endpoint, i.destination.account, i.operation.toString(), (i.original.key as HistoryKey.Device).id.value.toString(),
                    i.original.revision.sha256, i.original.revision.byteLength, i.original.incarnation,
                    i.display.title, i.display.artist, i.display.album, row.phase.name, row.commit?.track?.value, row.membership?.durationMs, row.removal?.toString(),
                    i.overrideRevision)
            }
        }
    }
    private companion object {
        const val MAX_BYTES = 2_000_000; const val MAX_ROWS = 4096
        // Field widths are measured by the disk serializer. A pending UUID may resolve
        // into a removal fence instead of ReadbackRequired, or grow through Added.
        private val sample = DiskRow("", "", "", "", "", 1, 1, "", "", "", OriginalImportPhase.Unconfirmed.name)
        private val receipt = sample.copy(phase = OriginalImportPhase.ReadbackRequired.name, track = Long.MAX_VALUE)
        private fun encodedSize(row: DiskRow) = Json.encodeToString(row).encodeToByteArray().size
        private val membershipGrowth = encodedSize(receipt.copy(phase = OriginalImportPhase.Added.name, durationMs = Long.MAX_VALUE)) - encodedSize(receipt)
        private val uploadReceiptGrowth = maxOf(encodedSize(receipt) + membershipGrowth,
            encodedSize(receipt.copy(phase = OriginalImportPhase.RemovalPending.name, removal = UUID(0, 0).toString()))) - encodedSize(sample)
        fun canonicalUuid(value: String) = UUID.fromString(value).also { require(it.toString() == value) }
    }
}

internal val activeImportPhases = setOf(OriginalImportPhase.Unconfirmed, OriginalImportPhase.ReadbackRequired)
internal val liveOriginalReceipts = setOf(OriginalImportPhase.Added, OriginalImportPhase.ReadbackRequired)
internal fun OriginalImportEntry.matches(destination: ServerAccount, track: TrackId) =
    intent.destination == destination && commit?.track == track
