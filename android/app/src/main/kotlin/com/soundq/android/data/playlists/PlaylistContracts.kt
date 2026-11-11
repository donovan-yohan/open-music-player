package com.soundq.android.data.playlists

import com.soundq.android.data.AccountScope
import com.soundq.android.data.MutationOutcome
import com.soundq.android.data.SafeFailure
import com.soundq.android.data.Track
import com.soundq.android.data.TrackId

@JvmInline value class PlaylistId(val value: Long) { init { require(value > 0) } }

/** Complete PUT draft: rename must preserve every other editable field. */
data class PlaylistDraft(val name: String, val description: String = "", val coverUrl: String = "", val isPublic: Boolean = false) {
    init { require(name.isNotBlank()) }
}
data class PlaylistSummary(val id: PlaylistId, val draft: PlaylistDraft, val trackCount: Int, val durationMs: Long) {
    val name: String get() = draft.name
}
data class PlaylistAnalysisSeed(val bpm: Double? = null, val camelot: String? = null)
data class PlaylistDetail(val playlist: PlaylistSummary, val tracks: List<Track>, val analysisSeeds: Map<TrackId, PlaylistAnalysisSeed> = emptyMap(), val canManage: Boolean = !playlist.draft.isPublic)
data class PlaylistPage(val rows: List<PlaylistSummary>, val total: Int, val limit: Int, val offset: Int)
enum class PlaylistSort(val wire: String, val label: String) { Updated("updated_at", "Recently updated"), Name("name", "Name"), Tracks("track_count", "Track count") }
data class PlaylistQuery(val text: String = "", val sort: PlaylistSort = PlaylistSort.Updated, val ascending: Boolean = false)
/** Membership is unique by track, unlike duplicate occurrences in the listening queue. */
data class PlaylistMembership(val playlist: PlaylistId, val track: TrackId)
class PlaylistListCapture internal constructor(internal val scope: AccountScope, internal val lifetime: Long, internal val intent: Long = 0)
class PlaylistDetailCapture internal constructor(internal val scope: AccountScope, internal val lifetime: Long, val detail: PlaylistDetail)
data class PlaylistMutation(val outcome: MutationOutcome, val added: List<TrackId> = emptyList(), val skipped: List<TrackId> = emptyList())
data class PlaylistAddAck(val playlist: PlaylistSummary, val added: List<TrackId>, val skipped: List<TrackId>)
class PlaylistUndoReceipt internal constructor(internal val capture: PlaylistDetailCapture, internal val removed: Track, internal val position: Int)
data class PlaylistState(
    val rows: List<PlaylistSummary> = emptyList(),
    val total: Int? = null,
    val detail: PlaylistDetail? = null,
    val loading: Boolean = false,
    val error: SafeFailure.Reason? = null,
    val mutation: PlaylistMutation? = null,
    val created: PlaylistSummary? = null,
    val undo: PlaylistUndoReceipt? = null,
    val uncertainDraft: PlaylistDraft? = null,
    val reconciled: Boolean = false,
    val renewedDraft: PlaylistDraft? = null,
    val query: PlaylistQuery = PlaylistQuery(),
)
