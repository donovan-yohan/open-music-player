package com.soundq.android.playback

/** Source occurrences and their compiled, half-open arrangement intervals. */
data class ArrangementMetadataClip(val occurrence: String, val title: String, val artist: String,
    val startMs: Long, val endMs: Long)
data class ArrangementMetadata(val occurrences: List<String>, val title: String, val artist: String)

/** Presentation only. The caller supplies the accepted native cursor, never an editor preview. */
fun arrangementMetadata(clips: List<ArrangementMetadataClip>, positionMs: Long): ArrangementMetadata {
    require(clips.isNotEmpty())
    val ordered = clips.sortedBy { it.startMs }
    val active = ordered.filter { positionMs >= it.startMs && positionMs < it.endMs }
    // Silence before/between clips names the upcoming source. Completion keeps the last source.
    val selected = active.ifEmpty { listOf(ordered.firstOrNull { it.startMs > positionMs } ?: ordered.maxBy { it.endMs }) }
    return ArrangementMetadata(selected.map { it.occurrence }, selected.joinToString(" → ") { it.title },
        selected.map { it.artist }.filter { it.isNotBlank() }.joinToString(" → "))
}
