package com.soundq.android.data.deviceaudio

import java.util.UUID

internal data class DeviceFileId(val value: UUID)
internal data class ScanGrantId(val value: UUID)
internal data class ProviderObjectId(val provider: String, val objectId: String) {
    init { bounded(provider); bounded(objectId) }
}
internal data class ProviderLocator(val provider: String, val value: String) {
    init { bounded(provider); bounded(value) }
}
internal data class ContentRevision(val sha256: String, val byteLength: Long) {
    init { require(sha256.matches(Regex("[a-f0-9]{64}"))); require(byteLength >= 0) }
}
internal data class OriginalMetadata(
    val filename: String, val title: String? = null, val artist: String? = null,
    val album: String? = null, val artworkReference: String? = null,
) {
    init { bounded(filename); listOf(title, artist, album, artworkReference).filterNotNull().forEach { bounded(it, true) } }
    val displayTitle: String get() = title?.takeIf { it.isNotBlank() } ?: filename
}
internal enum class GrantKind { INDEXED, FILE, FOLDER }
internal enum class AccessState { AVAILABLE, REVOKED, REMOVED, MISSING, UNREADABLE, UNSUPPORTED }
internal data class ScanGrant(
    val id: ScanGrantId, val kind: GrantKind, val label: String, val locator: ProviderLocator,
    val persisted: Boolean, val state: AccessState = AccessState.AVAILABLE,
) { init { bounded(label) } }
/** The platform adapter must prove object identity. Equal names or bytes are NOT proof. */
internal data class DiscoveredAudio(
    val objectId: ProviderObjectId, val locator: ProviderLocator, val revision: ContentRevision,
    val metadata: OriginalMetadata, val durationMs: Long?, val state: AccessState = AccessState.AVAILABLE,
) { init { require(durationMs == null || durationMs > 0) } }
internal data class LocatorAccess(val grantId: ScanGrantId, val locator: ProviderLocator, val state: AccessState)
internal data class DeviceAudio(
    val id: DeviceFileId, val objectId: ProviderObjectId, val revision: ContentRevision, val incarnation: Long,
    val metadata: OriginalMetadata, val durationMs: Long?, val aliases: List<LocatorAccess>,
) {
    val available: Boolean get() = aliases.any { it.state == AccessState.AVAILABLE }
    val owner: ContentOwner get() = ContentOwner(HistoryKey.Device(id), revision, incarnation)
}
internal data class ServerAccount(val endpoint: String, val account: String) {
    init { bounded(endpoint); bounded(account) }
}
internal data class ServerAudioId(val value: Long) { init { require(value > 0) } }
internal sealed interface HistoryKey {
    data class Device(val id: DeviceFileId) : HistoryKey
    data class Server(val scope: ServerAccount, val id: ServerAudioId) : HistoryKey
}
/** Also usable for an account-owned validated download artifact. Never a phone-file TrackId. */
internal data class ContentOwner(val key: HistoryKey, val revision: ContentRevision, val incarnation: Long) {
    init { require(incarnation > 0) }
}
internal data class AccessCapture(val instance: UUID, val epoch: Long, val account: ServerAccount?)
internal data class ScanCapture(val access: AccessCapture, val grantId: ScanGrantId, val sequence: Long)
internal data class SourceCapture(val access: AccessCapture, val owner: ContentOwner, val accessGeneration: Long, val admission: UUID)
internal data class TraversalCapture(
    val source: SourceCapture, val traversal: UUID, val occurrence: UUID,
    val sourceGeneration: Long, val seekIdentity: Long, val consumedEndBaseline: Long,
)
/** Only the canonical service may qualify this after successful audible-source advancement.
 * Not a UI Play tap, decoder preparation, seek acknowledgement, or queue selection. */
internal data class SuccessfulPlaybackReceipt(
    val traversal: TraversalCapture, val eventSequence: Long, val playedAtEpochMs: Long,
)
/** Acknowledged source position, not output/wall clock. No preparation/cancellation position. */
internal data class SourcePositionCheckpoint(
    val traversal: TraversalCapture, val eventSequence: Long, val positionMs: Long,
)
/** Internal integration contract, NOT a qualifier. The canonical service must validate native
 * consumed-last-frame crossing and source/deck lifetime before constructing this evidence.
 * Generic eofCount / STATE_ENDED / sought endpoint are deliberately not accepted fields. */
internal data class QualifiedNaturalEnd(
    val traversal: TraversalCapture, val eventSequence: Long,
    val nativeOccurrence: UUID, val nativeSourceGeneration: Long, val nativeSeekIdentity: Long,
    val consumedEndCount: Long,
)
internal data class ListeningHistory(val key: HistoryKey, val playedAtEpochMs: Long?, val bookmark: Bookmark?)
internal data class Bookmark(val owner: ContentOwner, val positionMs: Long)
internal data class ServerHistoryCapture(val access: AccessCapture, val key: HistoryKey.Server, val event: UUID)
/** Service-qualified successful server playback only. This never grants access to downloads. */
internal data class SuccessfulServerPlaybackReceipt(val capture: ServerHistoryCapture, val playedAtEpochMs: Long)
internal data class RecentItem(val key: HistoryKey, val displayTitle: String)
internal enum class Mutation { APPLIED, UNCHANGED, REFUSED }
internal enum class LoadState { READY, REJECTED }
internal data class DeviceListeningSnapshot(val revision: Long, val files: List<DeviceAudio>, val grants: List<ScanGrant>, val history: List<ListeningHistory>)
/** Length-prefixed source-scoped encoding. Never concatenate bare account/endpoint/id delimiters. */
internal fun stableSourceIdentity(key: HistoryKey): String {
    fun field(s: String) = "${s.length}:$s"
    return when (key) {
        is HistoryKey.Device -> "device:" + key.id.value.toString()
        is HistoryKey.Server -> "server:" + field(key.scope.endpoint) + field(key.scope.account) + field(key.id.value.toString())
    }
}
internal fun bounded(value: String, allowEmpty: Boolean = false) {
    require((allowEmpty || value.isNotEmpty()) && value.length <= 8192 && '\u0000' !in value)
}
