package com.soundq.android.product

import com.soundq.android.playback.AcceptedArrangement
import com.soundq.android.data.timeline.globalEndMs

/** Displayed order and selection come from the installed arrangement, never an unsaved editor. */
internal data class ArrangementQueueRow(
    val occurrence:String,val track:Long,val title:String,val artist:String,
    val startMs:Long,val endMs:Long,val current:Boolean,
)
internal fun arrangementQueueRows(accepted:AcceptedArrangement,positionMs:Long):List<ArrangementQueueRow> {
    val sources=accepted.sources.associateBy {it.occurrenceId}
    return accepted.document.clips.map {clip->
        val source=sources[clip.occurrence]
        ArrangementQueueRow(clip.occurrence,clip.track,source?.title?.takeIf {it.isNotBlank()} ?: clip.title,
            source?.artist.orEmpty(),clip.globalStartMs,clip.globalEndMs,positionMs>=clip.globalStartMs&&positionMs<clip.globalEndMs)
    }
}
