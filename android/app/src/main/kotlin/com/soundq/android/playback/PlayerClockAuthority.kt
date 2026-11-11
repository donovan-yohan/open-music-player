package com.soundq.android.playback

import androidx.media3.common.*

/** Read the whole admitted Media3 timeline, including its actual shuffle traversal.
 * TIME_UNSET is never replaced with repository metadata or a partial Library sum. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal fun Player.acceptedClockSpans():List<ClockSpan>? {
    val timeline=currentTimeline
    if(timeline.isEmpty||timeline.windowCount!=mediaItemCount)return null
    val window=Timeline.Window()
    val spans=mutableListOf<ClockSpan>()
    val visited=mutableSetOf<Int>()
    var index=timeline.getFirstWindowIndex(shuffleModeEnabled)
    while(index!=C.INDEX_UNSET) {
        if(!visited.add(index)||index !in 0 until mediaItemCount)return null
        timeline.getWindow(index,window)
        val occurrence=getMediaItemAt(index).mediaId
        if(occurrence.isBlank()||window.mediaItem.mediaId!=occurrence)return null
        spans+=ClockSpan(occurrence,window.durationMs.takeIf {it>0})
        index=timeline.getNextWindowIndex(index,Player.REPEAT_MODE_OFF,shuffleModeEnabled)
    }
    return spans.takeIf {it.size==mediaItemCount&&it.map {s->s.occurrence}.distinct().size==it.size}
}
