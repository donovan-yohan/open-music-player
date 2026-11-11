package com.soundq.android.product.timeline

import com.soundq.android.data.timeline.*

/** One fit per mounted Queue waveform view, after real width and sources arrive.
 * Only projection changes: source positions, trims and global placement never do. */
internal class WaveformOverview {
    private var fitted=false
    fun update(viewport:TimelineViewport,clips:List<TimelineClip>,width:Float):TimelineViewport {
        if(width<=1f||!width.isFinite()||clips.isEmpty())return viewport
        val measured=viewport.copy(widthPx=width)
        if(fitted)return measured
        val shown=clips.take(2)
        val first=shown.minOf {it.globalStartMs}
        val end=shown.maxOf {it.globalEndMs}
        fitted=true
        return measured.copy(pixelsPerSecond=width.toDouble()*1000/maxOf(1L,end-first),offsetMs=first)
    }
}
