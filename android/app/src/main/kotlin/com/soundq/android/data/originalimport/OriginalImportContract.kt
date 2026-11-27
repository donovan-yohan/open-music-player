package com.soundq.android.data.originalimport

import com.soundq.android.data.AccountScope
import com.soundq.android.data.SafeFailure
import com.soundq.android.data.TrackId
import com.soundq.android.data.deviceaudio.*
import java.io.Closeable
import java.io.IOException
import java.io.OutputStream
import java.security.MessageDigest
import java.util.UUID

internal const val ORIGINAL_IMPORT_MAX_BYTES = 64L * 1024 * 1024

/** Display fields only. No locator, filename, history, provider lookup, or credential. */
internal data class ImportDisplay(val title: String, val artist: String, val album: String) {
    init {
        require(title.isNotBlank())
        require(listOf(title, artist, album).all { it.codePointCount(0, it.length) <= 500 && '\u0000' !in it })
    }
}

internal data class OriginalImportIntent(
    val destination: ServerAccount,
    val operation: UUID,
    val original: ContentOwner,
    val display: ImportDisplay,
    /** Local consent provenance only; never emitted on the wire. */
    val overrideRevision: Long? = null,
) {
    init {
        require(original.key is HistoryKey.Device && original.revision.byteLength in 1..ORIGINAL_IMPORT_MAX_BYTES)
        require(overrideRevision == null || overrideRevision > 0)
    }
}

internal data class CommittedOriginal(val track: TrackId, val revision: ContentRevision)

/** Internal typed boundary only: these names are not a wire schema. The implementing
 * authenticated adapter validates endpoint/account, request/response correlation, literal
 * digest/length, and proof of non-commit before producing a definitive status. */
internal interface OriginalImportTransport {
    /** Pure validation before journaling: no auth exchange, file read, or wire dispatch. */
    fun canEncode(scope: AccountScope, intent: OriginalImportIntent): Boolean = true
    fun upload(scope: AccountScope, intent: OriginalImportIntent, body: VerifiedOriginalBody, current: () -> Boolean): OriginalImportReceipt
    /** This exact-operation GET can commit a stored stage and needs a final mutation guard. */
    fun status(scope: AccountScope, intent: OriginalImportIntent, admit: () -> Boolean): OriginalImportReceipt
    fun membership(scope: AccountScope, track: TrackId): OriginalMembershipResult
}

internal data class OriginalImportReceipt(val destination: ServerAccount, val operation: UUID, val status: OriginalReceiptStatus)
internal sealed interface OriginalReceiptStatus {
    data class Committed(val original: CommittedOriginal) : OriginalReceiptStatus
    data object Unconfirmed : OriginalReceiptStatus
    /** Exact terminal status, with no authority to retry either this or a different UUID. */
    data object Closed : OriginalReceiptStatus
    data object Refused : OriginalReceiptStatus
}

/** Exact current owned membership and canonical original evidence, independent of filtered Library pages. */
internal data class OriginalMembership(
    val destination: ServerAccount,
    val original: CommittedOriginal,
    val display: ImportDisplay,
    val durationMs: Long,
) { init { require(durationMs >= 0) } }

internal sealed interface OriginalMembershipResult {
    data class Present(val row: OriginalMembership) : OriginalMembershipResult
    /** Exact, authenticated absence from the registered owned membership endpoint. */
    data class Absent(val destination: ServerAccount, val track: TrackId) : OriginalMembershipResult
    data object Unconfirmed : OriginalMembershipResult
}

internal data class OriginalAssociation(val intent: OriginalImportIntent, val membership: OriginalMembership, val lease: Any = Any()) {
    init {
        require(membership.destination == intent.destination && membership.original.revision == intent.original.revision)
    }
    val track get() = membership.original.track
}

/** Explicit original intent is terminal on any miss. Ordinary playback may only fall back
 * before an original is selected; errors opening that original do not. */
internal fun <T> originalPlayback(
    scope: ServerAccount,
    track: TrackId,
    requestedOperation: String?,
    downloadOnly: Boolean,
    associations: () -> List<OriginalAssociation>,
    available: (OriginalAssociation) -> Boolean,
    original: (OriginalAssociation) -> T,
    ordinary: () -> T,
): T {
    if (downloadOnly && requestedOperation == null) return ordinary()
    val selected = associations().firstOrNull {
        it.intent.destination == scope && it.track == track &&
            (requestedOperation == null || it.intent.operation.toString() == requestedOperation) && available(it)
    }
    if (selected != null) return original(selected)
    if (requestedOperation != null) throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
    return ordinary()
}

/** The platform source retains one exact opened descriptor, never a reopened URI or staged file. */
internal interface ImportOriginalRead : Closeable {
    val length: Long
    fun checkCurrent()
    fun readAt(position: Long, bytes: ByteArray, count: Int): Int
}

internal class VerifiedOriginalBody private constructor(
    private val source: ImportOriginalRead,
    val revision: ContentRevision,
    private val current: () -> Boolean,
) {
    private val written = java.util.concurrent.atomic.AtomicBoolean()

    /** Single-use body. Network client must disable retries, redirects and write replay. */
    fun writeTo(out: OutputStream) {
        check(written.compareAndSet(false, true)) { "Original import body already used" }
        verifyBytes(source, revision, current, out)
    }

    companion object {
        fun verify(source: ImportOriginalRead, revision: ContentRevision, current: () -> Boolean, canStart: () -> Boolean): VerifiedOriginalBody {
            verifyBytes(source, revision, canStart)
            return VerifiedOriginalBody(source, revision, current)
        }
    }
}

internal class OriginalContentMismatch : IOException("Original content changed")
/** Only the one-shot authenticated request owner produces this positive non-entry witness. */
internal class OriginalUploadNotAdmitted : IOException("Original upload was not admitted")

/** Bounded exact proof on the descriptor that will actually be streamed/decoded. */
internal fun verifyBytes(source: ImportOriginalRead, revision: ContentRevision, current: () -> Boolean, out: OutputStream? = null) {
    require(revision.byteLength in 1..ORIGINAL_IMPORT_MAX_BYTES)
    fun fence() { check(current()); source.checkCurrent(); check(current()) }
    fence()
    if (source.length != revision.byteLength) throw OriginalContentMismatch()
    val digest = MessageDigest.getInstance("SHA-256")
    val bytes = ByteArray(64 * 1024)
    var position = 0L
    while (position < revision.byteLength) {
        if (Thread.currentThread().isInterrupted) throw java.io.InterruptedIOException("Original read interrupted")
        fence()
        val wanted = minOf(bytes.size.toLong(), revision.byteLength - position).toInt()
        val n = source.readAt(position, bytes, wanted)
        if (n !in 1..wanted) throw IOException("Original read made no progress")
        fence()
        digest.update(bytes, 0, n)
        out?.write(bytes, 0, n)
        position += n
    }
    fence()
    if (digest.digest().joinToString("") { "%02x".format(it) } != revision.sha256) throw OriginalContentMismatch()
}
