package com.soundq.android.product

import com.soundq.android.playback.AcceptedArrangement
import com.soundq.android.data.timeline.globalEndMs

/** Draft display timing is independent from accepted audible intervals and seek authority. */
internal data class ArrangementQueueRow(
    val occurrence:String,val track:Long,val title:String,val artist:String,
    val startMs:Long,val endMs:Long,val current:Boolean,val seekMs:Long?=null,
)
internal fun arrangementQueueRows(accepted:AcceptedArrangement,positionMs:Long):List<ArrangementQueueRow> {
    return arrangementQueueRows(chronologicalTimeline(accepted.document),accepted,positionMs)
}
internal fun arrangementQueueRows(presentation:ChronologicalTimeline,accepted:AcceptedArrangement?,positionMs:Long,sourceRows:List<com.soundq.android.playback.QueueOccurrence> = accepted?.sources.orEmpty()):List<ArrangementQueueRow> {
    val sources=sourceRows.associateBy {it.occurrenceId}
    val installed=accepted?.document?.clips?.associateBy {it.occurrence}.orEmpty()
    val canSeek=accepted?.document==presentation.shown
    return presentation.clips.map {clip->
        val source=sources[clip.occurrence]
        val audible=installed[clip.occurrence]?.takeIf {it.track==clip.track}
        ArrangementQueueRow(clip.occurrence,clip.track,source?.title?.takeIf {it.isNotBlank()} ?: clip.title,
            source?.artist.orEmpty(),clip.globalStartMs,clip.globalEndMs,
            audible!=null&&positionMs>=audible.globalStartMs&&positionMs<audible.globalEndMs,
            audible?.globalStartMs?.takeIf {canSeek})
    }
}
