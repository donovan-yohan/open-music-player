package com.soundq.android.product

import com.soundq.android.data.timeline.TimelineClip
import com.soundq.android.data.timeline.TimelineDocument

/** Workspace-only immutable presentation. Neither clip array is reordered or published to playback. */
internal class ChronologicalTimeline internal constructor(
    val base:TimelineDocument,
    val shown:TimelineDocument,
    val clips:List<TimelineClip>,
)

/** Compose keys distinguish equal document replacements, never preview projections. */
internal class TimelineDocumentIdentity(private val document:TimelineDocument) {
    override fun equals(other:Any?)=other is TimelineDocumentIdentity&&document===other.document
    override fun hashCode()=System.identityHashCode(document)
}

internal fun chronologicalTimeline(base:TimelineDocument,candidate:TimelineDocument?=null):ChronologicalTimeline {
    val shown=candidate?.takeIf {it.revision==base.revision&&
        it.clips.map {c->c.occurrence to c.track}.toSet()==base.clips.map {c->c.occurrence to c.track}.toSet()&&
        it.clips.size==base.clips.size} ?: base
    val ordinals=base.clips.mapIndexed {index,clip->clip.occurrence to index}.toMap()
    return ChronologicalTimeline(base,shown,shown.clips.sortedWith(compareBy<TimelineClip> {it.globalStartMs}.thenBy {ordinals.getValue(it.occurrence)}))
}

/** A revision number or structural equality cannot revive a retired captured document. */
internal fun chronologicalTimeline(base:TimelineDocument,previous:ChronologicalTimeline):ChronologicalTimeline =
    if(previous.base===base)previous else chronologicalTimeline(base)
