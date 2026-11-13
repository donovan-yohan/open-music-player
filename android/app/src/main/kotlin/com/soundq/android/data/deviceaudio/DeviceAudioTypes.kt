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
/** [INDEXED] (the Android audio index, read with all files access) is the only grant SoundQ creates. FILE and
 * FOLDER are file/folder picker grants written by older builds: they are decoded only so
 * [DeviceListeningStore.retireLegacyAccess] can fold their rows into the index or drop them. */
internal enum class GrantKind { INDEXED, FILE, FOLDER }
internal enum class AccessState { AVAILABLE, REVOKED, REMOVED, MISSING, UNREADABLE, UNSUPPORTED }
internal data class ScanGrant(
    val id: ScanGrantId, val kind: GrantKind, val label: String, val locator: ProviderLocator,
    val persisted: Boolean, val state: AccessState = AccessState.AVAILABLE,
) { init { bounded(label) } }
/** The platform adapter must prove object identity. Equal names or bytes are NOT proof.
 * [formerObjectIds] are earlier keys the provider proves name this same object (e.g. a MediaStore row once
 * keyed by the collection a file grant reached it through); stored rows under them fold into this one. */
internal data class DiscoveredAudio(
    val objectId: ProviderObjectId, val locator: ProviderLocator, val revision: ContentRevision,
    val metadata: OriginalMetadata, val durationMs: Long?, val state: AccessState = AccessState.AVAILABLE,
    val formerObjectIds: Set<ProviderObjectId> = emptySet(),
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
/** A row folded into [into] because the provider proved both were one object. [from] is the retired row's
 * last owner: a saved reference to exactly that content still resolves to the surviving row. */
internal data class RetiredDeviceIdentity(val from: ContentOwner, val into: DeviceFileId) {
    init { require(from.key is HistoryKey.Device && from.key.id != into) }
}
internal data class DeviceListeningSnapshot(val revision: Long, val files: List<DeviceAudio>, val grants: List<ScanGrant>, val history: List<ListeningHistory>,
    val retired: List<RetiredDeviceIdentity> = emptyList()) {
    /** The available row a saved reference names: itself, or the row its retired identity folded into. */
    fun resolve(id: DeviceFileId, revision: ContentRevision, incarnation: Long): DeviceAudio? =
        resolveIdentity(id, revision, incarnation) { it.available }

    /** Retained source identity, including provider-proven folds, independent of read readiness. */
    fun resolveRetained(id: DeviceFileId, revision: ContentRevision, incarnation: Long): DeviceAudio? =
        resolveIdentity(id, revision, incarnation) { true }

    private fun resolveIdentity(id: DeviceFileId, revision: ContentRevision, incarnation: Long, accepts: (DeviceAudio) -> Boolean): DeviceAudio? {
        files.singleOrNull { it.id == id }?.let { return it.takeIf { it.revision == revision && it.incarnation == incarnation && accepts(it) } }
        val folded = retired.singleOrNull { it.from == ContentOwner(HistoryKey.Device(id), revision, incarnation) } ?: return null
        return files.singleOrNull { it.id == folded.into && it.revision == revision && accepts(it) }
    }
}
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
