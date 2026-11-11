package com.soundq.android.playback.mix

import com.soundq.android.data.mix.MixJson
import com.soundq.android.data.mix.SavedMix
import kotlinx.serialization.json.*

/** Loader input only. No saved document, queue authority, transport or file ownership. */
internal data class MixRenderEvent(val sourceMs: Long, val bus: Int, val rampMs: Long, val gain: Float)
internal data class MixRenderClip(
    val startMs: Long,
    val endMs: Long,
    val sourceStartMs: Long,
    val fadeInMs: Long = 0,
    val fadeOutMs: Long = 0,
    val gainDb: Double = 0.0,
    val paths: List<String>,
    val events: List<MixRenderEvent> = emptyList()
)

internal class MixRenderPlan(durationMs: Long, clips: List<MixRenderClip>, sources: List<String> = clips.flatMap { it.paths }.distinct()) {
    val durationMs = durationMs
    // Snapshot caller collections before opening a native handle.
    val sources: List<String> = java.util.Collections.unmodifiableList(sources.toList())
    val clips: List<MixRenderClip> = java.util.Collections.unmodifiableList(clips.map {
        it.copy(paths = java.util.Collections.unmodifiableList(it.paths.toList()),
            events = java.util.Collections.unmodifiableList(it.events.toList()))
    })
    init {
        require(durationMs > 0 && this.clips.size in 1..1000)
        require(this.sources.size in 1..32 && this.sources.distinct().size == this.sources.size && this.sources.all { it.isNotBlank() })
        require(this.clips.maxOf { it.endMs } == durationMs)
        require(this.clips.sumOf { it.events.size } <= 4096)
        this.clips.forEach { c ->
            require(c.startMs >= 0 && c.endMs > c.startMs && c.sourceStartMs >= 0)
            Math.addExact(c.sourceStartMs, c.endMs - c.startMs)
            require(c.fadeInMs >= 0 && c.fadeOutMs >= 0 && c.fadeInMs <= c.endMs - c.startMs && c.fadeOutMs <= c.endMs - c.startMs - c.fadeInMs)
            require(c.gainDb.isFinite() && c.gainDb <= 0 && c.paths.size in 1..5 && c.paths.all { it in this.sources })
            c.events.forEach { e ->
                require(e.sourceMs >= 0 && e.bus in c.paths.indices && e.rampMs in 1..250 && e.gain.isFinite() && e.gain in 0f..1f)
            }
        }
    }
}

/** Existing SavedMix callers keep strict document validation and track/stem binding. */
internal fun SavedMix.renderPlan(paths: Map<Long, String>, stems: Map<String, PreparedMixStems>): MixRenderPlan {
    verifyForNative()
    require(playable())
    val sources = (paths.values + stems.values.flatMap { it.paths }).distinct()
    val rendered = clips.map { c ->
        val prepared = stems[c.id]
        require((c.stems != null) == (prepared != null))
        val buses = prepared?.paths ?: listOf(paths.getValue(c.track))
        val events = c.stems?.getValue("events")?.jsonArray?.map { value ->
            val e = value.jsonObject
            val bus = prepared!!.channels.indexOf(MixJson.text(e, "channel"))
            require(bus >= 0)
            MixRenderEvent(MixJson.number(e, "atMs"), bus, MixJson.number(e, "rampMs"), e.getValue("gain").jsonPrimitive.float)
        } ?: emptyList()
        MixRenderClip(c.start, c.end, c.sourceStart, c.fadeIn, c.fadeOut, c.gain, buses, events)
    }
    return MixRenderPlan(duration, rendered, sources)
}
