package com.soundq.android.playback

import android.os.Bundle
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Runtime-only capabilities. None of these values belong to a TimelineDocument or SavedMix. */
@Serializable data class PerformanceTarget(val identity: ArrangementIdentity, val occurrence: String)
@Serializable data class ScratchLease(val target: PerformanceTarget, val id: Long, val token: String, val transport: Long)
@Serializable data class TempoPreviewLease(val target: PerformanceTarget, val token: String, val transport: Long,
    val source: com.soundq.android.data.timeline.TempoSourceIdentity, val originBpm: Double)
@Serializable enum class TempoPreviewPhase { Ready, Preparing, Applied, Saving, Restoring, Saved, Restored, Refused, Retired }
@Serializable data class TempoPreviewState(val lease: TempoPreviewLease, val revision: Long = 0,
    val desiredTag: Long = 0, val desiredBpm: Double = lease.originBpm, val appliedTag: Long = 0,
    val appliedBpm: Double = lease.originBpm, val phase: TempoPreviewPhase = TempoPreviewPhase.Ready, val message: String? = null)
@Serializable enum class LiveSyncState { Off, Pending, Locked, ScratchSuspended, Rejoining, Failed }
@Serializable data class QualifiedLiveGrid(
    val bpm: Double, val anchorMs: Double, val groupOriginMs: Double?,
    val sourceKey: String, val revision: String, val provenance: String = "local_manual",
) {
    fun valid(durationMs: Long, beats: Int): Boolean {
        if (beats !in listOf(1, 4, 16, 32) || !bpm.isFinite() || bpm !in 10.0..600.0 ||
            !anchorMs.isFinite() || anchorMs !in 0.0..durationMs.toDouble() ||
            sourceKey.isBlank() || sourceKey.length > 512 || revision.isBlank() || revision.length > 512 ||
            provenance !in listOf("local_manual", "manual_timing_v2")) return false
        val origin = groupOriginMs ?: return beats == 1
        if (!origin.isFinite() || origin !in 0.0..durationMs.toDouble()) return false
        val ordinal = (origin - anchorMs) * bpm / 60000.0
        return kotlin.math.abs(ordinal - kotlin.math.round(ordinal)) <= 1e-7
    }
}
@Serializable data class PerformanceDeck(
    val target: PerformanceTarget, val sourcePositionMs: Double, val rate: Double,
    val nominalSourcePositionMs: Double, val ready: Boolean, val playing: Boolean,
    val scratching: Boolean, val gesture: Long, val heldZero: Boolean,
    val syncReferenceOccurrence: String?, val syncBeats: Int, val syncState: LiveSyncState,
    val syncPhaseErrorFrames: Double, val lastMoveEventNanos: Long,
    val lastMoveAppliedNanos: Long, val lastMoveSequence: Long,
    val keylock: Boolean = false,
    val processingEpoch: Long = 0, val effectiveBpm: Double? = null, val tempoGeneration: Long = 0,
)

/** Explicit bounded payloads for own-app MediaSession commands. */
internal object PerformanceCommands {
    const val BEGIN = "soundq.performance.scratch.begin"
    const val MOVE = "soundq.performance.scratch.move"
    const val END = "soundq.performance.scratch.end"
    const val CANCEL = "soundq.performance.scratch.cancel"
    const val SYNC = "soundq.performance.sync"
    const val UNLINK = "soundq.performance.unlink"
    const val TEMPO_BEGIN = "soundq.performance.tempo.begin"
    const val TEMPO_PREVIEW = "soundq.performance.tempo.preview"
    const val TEMPO_CANCEL = "soundq.performance.tempo.cancel"
    const val TEMPO_SAVE = "soundq.performance.tempo.save"
    const val TEMPO_STATE = "tempoPreview"
    val tempo = listOf(TEMPO_BEGIN, TEMPO_PREVIEW, TEMPO_CANCEL, TEMPO_SAVE)
    val all = listOf(BEGIN, MOVE, END, CANCEL, SYNC, UNLINK) + tempo
    const val DECKS = "performanceDecks"
    fun target(target: PerformanceTarget) = Bundle().apply { putString("target", Json.encodeToString(target)) }
    fun lease(lease: ScratchLease, eventNanos: Long) = target(lease.target).apply {
        putString("lease", Json.encodeToString(lease)); putLong("eventNanos", eventNanos)
    }
    inline fun <reified T> read(args: Bundle, key: String): T? = args.getString(key)?.takeIf { it.length <= 8192 }
        ?.let { runCatching { Json.decodeFromString<T>(it) }.getOrNull() }
}
