package com.soundq.android.playback.listening

import com.soundq.android.data.timeline.TimelineSource
import com.soundq.android.playback.mix.MixRenderClip
import com.soundq.android.playback.mix.MixRenderPlan
import kotlin.math.PI
import kotlin.math.sin

internal data class ListeningPosition(val occurrence: ListeningOccurrence, val sourceMs: Long, val gain: Double)
internal data class ListeningObservation(val globalMs: Long, val active: List<ListeningPosition>, val selected: ListeningPosition?)

internal data class ListeningOccurrence(
    val source: TimelineSource,
    val startMs: Long,
    val endMs: Long,
    val fadeInMs: Long,
    val fadeOutMs: Long
)

/** Rate-one, unanalysed metadata. The caller owns order, accepted revision and clock. */
internal class ListeningSchedule private constructor(val defaultOverlapMs: Long, occurrences: List<ListeningOccurrence>) {
    val occurrences: List<ListeningOccurrence> = java.util.Collections.unmodifiableList(occurrences.toList())
    val durationMs: Long = occurrences.lastOrNull()?.endMs ?: 0

    /** Half-open source extents. No inferred elapsed time or persistent selected occurrence. */
    fun observe(globalMs: Long): ListeningObservation {
        require(globalMs >= 0)
        val active = occurrences.filter { globalMs >= it.startMs && globalMs < it.endMs }.map { c ->
            val local = globalMs - c.startMs
            // Use the same sine expression on both sides so an exact midpoint is an exact tie.
            val gain = when {
                c.fadeInMs > 0 && local < c.fadeInMs -> sin(local.toDouble() / c.fadeInMs * PI / 2)
                c.fadeOutMs > 0 && c.endMs - globalMs < c.fadeOutMs -> sin((c.endMs - globalMs).toDouble() / c.fadeOutMs * PI / 2)
                else -> 1.0
            }
            ListeningPosition(c, local, gain)
        }
        val selected = active.maxWithOrNull(compareBy<ListeningPosition> { it.gain }.thenBy { it.occurrence.startMs })
        return ListeningObservation(globalMs, java.util.Collections.unmodifiableList(active), selected)
    }

    /** Maps an explicit source-local seek, including the outgoing tail, without truncating a source. */
    fun globalAt(occurrence: String, sourceMs: Long): Long {
        val c = occurrences.single { it.source.occurrence == occurrence }
        require(sourceMs in 0..c.source.durationMs)
        return Math.addExact(c.startMs, sourceMs)
    }

    /** Exhausted history is immutable. Only future suffix pairs may overlap. */
    fun appendExhausted(sources: List<TimelineSource>): ListeningSchedule {
        require(sources.isNotEmpty() && occurrences.size + sources.size <= 500)
        val suffix = compile(sources, defaultOverlapMs)
        require((occurrences.map { it.source.occurrence } + sources.map { it.occurrence }).distinct().size == occurrences.size + sources.size)
        return ListeningSchedule(defaultOverlapMs, occurrences + suffix.occurrences.map {
            it.copy(startMs = Math.addExact(durationMs, it.startMs), endMs = Math.addExact(durationMs, it.endMs))
        })
    }

    /** Exact occurrence binding, never recording-ID lookup. Caller retains immutable file custody. */
    fun renderPlan(pathsByOccurrence: Map<String, String>): MixRenderPlan {
        require(pathsByOccurrence.keys == occurrences.map { it.source.occurrence }.toSet())
        return MixRenderPlan(durationMs, occurrences.map { c ->
            MixRenderClip(c.startMs, c.endMs, 0, c.fadeInMs, c.fadeOutMs,
                paths = listOf(pathsByOccurrence.getValue(c.source.occurrence)))
        })
    }

    companion object {
        fun compile(sources: List<TimelineSource>, defaultOverlapMs: Long): ListeningSchedule {
            require(defaultOverlapMs in 0..12000 && sources.size <= 500)
            require(sources.map { it.occurrence }.distinct().size == sources.size)
            sources.forEach { s ->
                require(s.occurrence.isNotBlank() && s.track > 0 && s.durationMs in 1..604800000L)
            }
            val overlaps = sources.zipWithNext { a, b -> minOf(defaultOverlapMs, a.durationMs / 2, b.durationMs / 2) }
            var start = 0L
            val occurrences = sources.mapIndexed { i, s ->
                val fadeIn = if (i == 0) 0 else overlaps[i - 1]
                val fadeOut = overlaps.getOrElse(i) { 0 }
                val end = Math.addExact(start, s.durationMs)
                ListeningOccurrence(s, start, end, fadeIn, fadeOut).also {
                    start = Math.subtractExact(end, fadeOut)
                }
            }
            return ListeningSchedule(defaultOverlapMs, occurrences)
        }
    }
}
