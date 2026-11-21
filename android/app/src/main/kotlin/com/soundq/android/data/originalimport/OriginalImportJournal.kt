package com.soundq.android.data.originalimport

import com.soundq.android.data.TrackId
import com.soundq.android.data.deviceaudio.*
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
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
        if (membership != null) {
            require(membership.original == commit)
            OriginalAssociation(intent, membership)
        }
    }
}

internal data class OriginalImportSnapshot(val ready: Boolean = false, val rejected: Boolean = false, val rows: List<OriginalImportEntry> = emptyList()) {
    private val byOperation = rows.associateBy { it.intent.operation }
    fun entry(operation: UUID): OriginalImportEntry? = byOperation[operation]
}

/** One app-owned, no-backup file. A rejected/future journal never authorizes upload or overwrite. */
internal class OriginalImportJournal(private val file: File) {
    private val mutable = MutableStateFlow(OriginalImportSnapshot())
    val state: StateFlow<OriginalImportSnapshot> = mutable
    private var loadedBytes: ByteArray? = null

    @Synchronized fun load() {
        if (state.value.ready || state.value.rejected) return
        try {
            val bytes = read()
            val rows = bytes?.let {
                Json.decodeFromString<Disk>(it.decodeToString(throwOnInvalidSequence = true)).let { disk ->
                    require(disk.version in 1..2 && disk.rows.size <= MAX_ROWS)
                    if (disk.version == 1) require(disk.rows.none { it.removal != null || it.phase == OriginalImportPhase.RemovalPending.name })
                    disk.rows.map(DiskRow::domain).also(::validate)
                }
            }.orEmpty()
            loadedBytes = bytes
            publish(rows)
        } catch (_: Exception) {
            mutable.value = OriginalImportSnapshot(rejected = true)
        }
    }

    @Synchronized fun put(entry: OriginalImportEntry, expected: OriginalImportEntry?, current: () -> Boolean) {
        load()
        check(state.value.ready && current())
        val rows = state.value.rows
        val previous = rows.singleOrNull { it.intent.operation == entry.intent.operation }
        check(previous == expected && (previous == null || previous.intent == entry.intent))
        check(previous?.removal == null && entry.removal == null)
        if (entry.phase == OriginalImportPhase.Unconfirmed) check(rows.none {
            it.intent.destination == entry.intent.destination && it.intent.original.revision == entry.intent.original.revision &&
                it.phase in setOf(OriginalImportPhase.RemovalPending, OriginalImportPhase.Removed)
        })
        replace(rows.filterNot { it.intent.operation == entry.intent.operation } + entry, current)
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

    /** One durable operation fences every known live receipt for this exact member before wire entry. */
    @Synchronized fun prepareRemoval(destination: ServerAccount, track: TrackId, operation: UUID, current: () -> Boolean): Boolean {
        load()
        check(state.value.ready && current())
        val rows = state.value.rows
        check(rows.none { it.matches(destination, track) && it.phase == OriginalImportPhase.RemovalPending })
        val next = rows.map { row ->
            if (row.matches(destination, track) && row.phase in liveOriginalReceipts)
                row.copy(phase = OriginalImportPhase.RemovalPending, removal = operation) else row
        }
        if (next == rows) return false
        replace(next, current)
        return true
    }

    @Synchronized fun finishRemoval(destination: ServerAccount, track: TrackId, operation: UUID, acknowledged: Boolean, current: () -> Boolean) {
        check(state.value.ready && current())
        val rows = state.value.rows
        val next = rows.map { row ->
            if (!row.matches(destination, track) || row.removal != operation || row.phase != OriginalImportPhase.RemovalPending) row
            else if (acknowledged) row.copy(phase = OriginalImportPhase.Removed, membership = null)
            else row.copy(phase = if (row.membership == null) OriginalImportPhase.ReadbackRequired else OriginalImportPhase.Added, removal = null)
        }
        check(next != rows)
        replace(next, current)
    }

    private fun replace(next: List<OriginalImportEntry>, current: () -> Boolean) {
        require(next.size <= MAX_ROWS)
        validate(next)
        // Keep writing v1 until a DELETE operation exists. Older clients must reject, not ignore, v2.
        val bytes = Json.encodeToString(Disk(if (next.any { it.removal != null }) 2 else 1, next.map(DiskRow::from))).encodeToByteArray()
        require(bytes.size <= MAX_BYTES)
        check(read().contentEquals(loadedBytes)) { "Original import journal changed outside its owner" }
        val dir = requireNotNull(file.parentFile).toPath()
        val stage = Files.createTempFile(dir, ".original-import-", ".pending")
        try {
            FileOutputStream(stage.toFile()).use { stream -> stream.write(bytes); stream.fd.sync() }
            check(current())
            try {
                Files.move(stage, file.toPath(), ATOMIC_MOVE, REPLACE_EXISTING)
                check(read().contentEquals(bytes)) { "Original import journal replacement could not be verified" }
            } catch (failure: Exception) {
                // An ambiguous replacement must not leave cached Added rows authorizing reads.
                if (!runCatching { read().contentEquals(loadedBytes) }.getOrDefault(false))
                    mutable.value = OriginalImportSnapshot(rejected = true)
                throw failure
            }
        } finally { runCatching { Files.deleteIfExists(stage) } }
        loadedBytes = bytes
        publish(next)
    }

    private fun publish(rows: List<OriginalImportEntry>) {
        mutable.value = OriginalImportSnapshot(ready = true, rows = java.util.Collections.unmodifiableList(rows))
    }

    private fun read(): ByteArray? {
        val path = file.toPath()
        if (Files.notExists(path, NOFOLLOW_LINKS)) return null
        check(Files.isRegularFile(path, NOFOLLOW_LINKS))
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

    private fun validate(rows: List<OriginalImportEntry>) {
        require(rows.distinctBy { it.intent.operation }.size == rows.size)
        val added = rows.filter { it.phase == OriginalImportPhase.Added }
        require(added.groupBy { it.intent.destination to it.commit?.track }.values.all { group ->
            group.map { it.intent.original.revision }.distinct().size == 1
        })
        require(added.distinctBy { it.intent.destination to it.intent.original }.size == added.size)
        val pending = rows.filter { it.phase in activeImportPhases }
        require(pending.distinctBy { it.intent.destination }.size == pending.size)
        val fenced = rows.filter { it.phase == OriginalImportPhase.RemovalPending }.groupBy { it.intent.destination to it.commit?.track }
        require(fenced.values.all { rowsForMember -> rowsForMember.map { it.removal }.distinct().size == 1 })
        require(rows.none { it.phase in liveOriginalReceipts && (it.intent.destination to it.commit?.track) in fenced })
        require(rows.filter { it.removal != null }.groupBy { it.removal }.values.all { group ->
            group.distinctBy { Triple(it.intent.destination, it.commit?.track, it.phase) }.size == 1
        })
    }

    @Serializable private data class Disk(val version: Int, val rows: List<DiskRow>)
    @Serializable private data class DiskRow(
        val endpoint: String, val account: String, val operation: String, val file: String,
        val sha256: String, val length: Long, val incarnation: Long,
        val title: String, val artist: String, val album: String, val phase: String,
        val track: Long? = null, val durationMs: Long? = null, val removal: String? = null,
        val overrideRevision: Long? = null,
    ) {
        fun domain(): OriginalImportEntry {
            fun uuid(value: String) = UUID.fromString(value).also { require(it.toString() == value) }
            val intent = OriginalImportIntent(ServerAccount(endpoint, account), uuid(operation),
                ContentOwner(HistoryKey.Device(DeviceFileId(uuid(file))), ContentRevision(sha256, length), incarnation),
                ImportDisplay(title, artist, album), overrideRevision)
            val commit = track?.let { CommittedOriginal(TrackId(it), intent.original.revision) }
            val membership = durationMs?.let { OriginalMembership(intent.destination, requireNotNull(commit), intent.display, it) }
            return OriginalImportEntry(intent, OriginalImportPhase.valueOf(phase), commit, membership, removal?.let(::uuid))
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
    private companion object { const val MAX_BYTES = 2_000_000; const val MAX_ROWS = 4096 }
}

internal val activeImportPhases = setOf(OriginalImportPhase.Unconfirmed, OriginalImportPhase.ReadbackRequired)
internal val liveOriginalReceipts = setOf(OriginalImportPhase.Added, OriginalImportPhase.ReadbackRequired)
internal fun OriginalImportEntry.matches(destination: ServerAccount, track: TrackId) =
    intent.destination == destination && commit?.track == track
