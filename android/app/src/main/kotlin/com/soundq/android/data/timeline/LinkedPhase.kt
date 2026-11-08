package com.soundq.android.data.timeline

import kotlinx.serialization.Serializable
import java.math.BigDecimal

/** Explicit constant grid. A source group origin is authored separately from the beat anchor.
 * Law 1 is the exact integer-ms subset of the rate-one 48kHz adapter (48 frames/ms). */
@Serializable data class PhaseGrid(
    val sourceKey:String, val revision:String, val periodMs:Long, val anchorMs:Long,
    val groupOriginMs:Long?=null, val provenance:String="local_manual", val law:Int=1,
) {
    init {
        require(sourceKey.isNotBlank() && sourceKey.length<=512 && revision.isNotBlank() && revision.length<=512)
        require(law==1 && periodMs in 100..6000 && anchorMs in 0..604800000L)
        require(groupOriginMs==null || (groupOriginMs in 0..604800000L && (groupOriginMs-anchorMs)%periodMs==0L))
        require(provenance in setOf("local_manual","manual_timing_v2"))
    }
    fun ordinal(sourceMs:Long):Long?=groupOriginMs?.let {(sourceMs-it)/periodMs}
    companion object {
        fun manual(sourceKey:String,revision:String,bpm:String,anchorMs:Long,groupOriginMs:Long?):PhaseGrid {
            // No tolerance and no separately rounded beat timestamps. Fractional periods are unavailable.
            val period=BigDecimal(60000).divide(BigDecimal(bpm)).longValueExact()
            return PhaseGrid(sourceKey,revision,period,anchorMs,groupOriginMs)
        }
    }
}
@Serializable data class PhaseLink(
    val reference:String, val incoming:String, val referenceGrid:PhaseGrid, val incomingGrid:PhaseGrid,
    val increment:Int, val relativeSteps:Long,
    val referenceTrack:Long,val incomingTrack:Long,val referenceDurationMs:Long,val incomingDurationMs:Long,
)
data class PhaseEdit(val revision:Long,val reference:TimelineClip,val incoming:TimelineClip,
    val referenceGrid:PhaseGrid,val incomingGrid:PhaseGrid,val increment:Int,val proposedStartMs:Long)
data class PhaseSolution(val link:PhaseLink,val clips:List<TimelineClip>,val guideMs:Long)

internal fun TimelineClip.rateOne()=rates.baseRate==1.0 && rates.segments.all {it.startRate==1.0&&it.endRate==1.0}
internal fun PhaseLink.contains(id:String)=id==reference||id==incoming
/** Individual beats use the beat anchor; grouped placement uses the independently authored origin. */
internal fun PhaseGrid.alignmentAnchor(increment:Int):Long=if(increment==1)anchorMs else requireNotNull(groupOriginMs)
internal fun PhaseLink.guide(clips:List<TimelineClip>):Long {
    val a=clips.single {it.occurrence==reference}
    return a.globalStartMs+referenceGrid.alignmentAnchor(increment)-a.sourceInMs+relativeSteps*increment*referenceGrid.periodMs
}
fun validatePhase(document:TimelineDocument):String? {
    val link=document.phaseLink ?: return null
    val a=document.clips.singleOrNull {it.occurrence==link.reference}
    val b=document.clips.singleOrNull {it.occurrence==link.incoming}
    if(a==null||b==null||a===b)return "Linked occurrences changed. Unlock and select the pair again."
    if(a.track!=link.referenceTrack||b.track!=link.incomingTrack||a.sourceDurationMs!=link.referenceDurationMs||b.sourceDurationMs!=link.incomingDurationMs)return "Linked source identity changed. Unlock and qualify again."
    if(link.increment !in listOf(1,4,16,32) || !a.rateOne() || !b.rateOne() || link.referenceGrid.periodMs!=link.incomingGrid.periodMs)
        return "Linked placement requires equal constant tempo and rate one."
    if(listOf(link.referenceGrid to a,link.incomingGrid to b).any {(g,c)->g.anchorMs>c.sourceDurationMs || (g.groupOriginMs ?: 0)>c.sourceDurationMs})
        return "The captured source anchors are outside the original audio."
    if(link.increment!=1 && (link.referenceGrid.groupOriginMs==null || link.incomingGrid.groupOriginMs==null))return "Supply both absolute group origins for grouped placement."
    if(link.relativeSteps !in -6048000L..6048000L)return "Linked offset is outside the supported range."
    if(link.guide(document.clips)!=b.globalStartMs+link.incomingGrid.alignmentAnchor(link.increment)-b.sourceInMs)return "Saved linked placement does not match its captured grid."
    val masterSource=link.referenceGrid.alignmentAnchor(link.increment)+link.relativeSteps*link.increment*link.referenceGrid.periodMs
    if(masterSource !in 0..a.sourceDurationMs)return "Reference beat is outside the original audio."
    return null
}

/** Search the admissible lattice, not a rounded/clamped endpoint. Ties choose the earlier beat. */
fun solvePhase(document:TimelineDocument,edit:PhaseEdit):PhaseSolution {
    require(edit.increment in listOf(1,4,16,32)) {"Choose 1, 4, 16 or 32 beats."}
    require(document.phaseLink==null || (document.phaseLink.reference==edit.reference.occurrence && document.phaseLink.incoming==edit.incoming.occurrence)) {"Unlock the existing pair before choosing another."}
    val a=edit.reference;val b=edit.incoming;val ga=edit.referenceGrid;val gb=edit.incomingGrid
    document.phaseLink?.let {held ->require(held.referenceGrid==ga&&held.incomingGrid==gb) {"Unlock before changing captured timing. Accepted audio was not moved."}}
    require(a.occurrence!=b.occurrence) {"Choose different reference and incoming occurrences."}
    require(a.rateOne()&&b.rateOne()&&ga.periodMs==gb.periodMs) {"Only equal constant tempo at rate one is supported. Unequal BPM sync is unavailable."}
    require(ga.anchorMs<=a.sourceDurationMs&&gb.anchorMs<=b.sourceDurationMs) {"Source anchor is outside the original audio."}
    require(edit.increment==1 || (ga.groupOriginMs!=null&&gb.groupOriginMs!=null)) {"Supply both absolute group origins for grouped placement."}
    require(edit.proposedStartMs in -604800000L..302400000000L) {"Requested placement is outside the supported range."}
    require(edit.proposedStartMs==b.globalStartMs || (a.fadeOutMs==0L&&b.fadeInMs==0L)) {"Unlock before retiming an authored paired fade."}
    val step=ga.periodMs*edit.increment
    val referenceAnchor=ga.alignmentAnchor(edit.increment)
    val incomingAnchor=gb.alignmentAnchor(edit.increment)
    val origin=a.globalStartMs+referenceAnchor-a.sourceInMs-(incomingAnchor-b.sourceInMs)
    // At most 6,048,001 source beats. Only candidates close to the requested start are considered,
    // plus each capacity boundary; the nearest valid region must begin/end at one of these edges.
    val low=maxOf(Math.floorDiv(-origin+step-1,step),Math.floorDiv(-referenceAnchor+step-1,step))
    val high=minOf(Math.floorDiv(302400000000L-origin,step),Math.floorDiv(a.sourceDurationMs-referenceAnchor,step))
    require(low<=high) {"No representable reference beat fits this source selection."}
    val wanted=Math.floorDiv(edit.proposedStartMs-origin,step)
    val edges=document.clips.filter {it.occurrence!=b.occurrence}.flatMap {listOf(it.globalStartMs,it.globalEndMs,it.globalStartMs-(b.sourceOutMs-b.sourceInMs),it.globalEndMs-(b.sourceOutMs-b.sourceInMs))}
    val candidates=(listOf(wanted,wanted+1,low,high)+edges.flatMap {val k=Math.floorDiv(it-origin,step);listOf(k-1,k,k+1)}).filter {it in low..high}.distinct()
    val solution=candidates.mapNotNull {k ->
        val start=origin+k*step
        val moved=b.copy(globalStartMs=start,explicitPlacement=true)
        // Existing endpoint-authored fades cannot be retimed by relative movement.
        if(start!=b.globalStartMs && (a.fadeOutMs!=0L||b.fadeInMs!=0L))null else {
            val clips=document.clips.map {if(it.occurrence==b.occurrence)moved else it}
            if(validateTimeline(clips)!=null)null else {
                val link=PhaseLink(a.occurrence,b.occurrence,ga,gb,edit.increment,k,a.track,b.track,a.sourceDurationMs,b.sourceDurationMs)
                val next=document.copy(clips=clips,phaseLink=link)
                if(validatePhase(next)!=null)null else PhaseSolution(link,clips,link.guide(clips))
            }
        }
    }.minWithOrNull(compareBy<PhaseSolution>{kotlin.math.abs(it.clips.single {c->c.occurrence==b.occurrence}.globalStartMs-edit.proposedStartMs)}.thenBy {it.guideMs})
    return solution ?: error("No admissible linked placement. Check source bounds, four-voice capacity and authored fades; Unlock before retiming a paired fade.")
}

/** Keeps the previous source/global map when the linked trim-in changes. */
internal fun TimelineDocument.edited(edit:TimelineEdit):TimelineDocument {
    val link=phaseLink
    if(link==null || !link.contains(edit.original.occurrence)) {
        val next=copy(clips=clips.map {if(it.occurrence==edit.original.occurrence)edit.candidate().copy(tempoMap=null) else it})
        return if(autoBpmCrossfade)next.withAutoBpmCrossfade(true,tempoRamps.flatMap {listOf(it.outgoing,it.incoming)}+playbackTempos.map {it.source}) else next
    }
    if(edit.kind==EditKind.Placement && edit.original.occurrence==link.incoming) {
        val a=clips.single {it.occurrence==link.reference}
        val solved=solvePhase(this,PhaseEdit(revision,a,edit.original,link.referenceGrid,link.incomingGrid,link.increment,edit.valueMs))
        return copy(clips=solved.clips,phaseLink=solved.link)
    }
    if(edit.kind==EditKind.Placement)require(edit.valueMs in 0..302400000000L) {"Pair start is outside the supported timeline."}
    val delta=edit.valueMs-edit.original.globalStartMs
    val next=clips.map {c ->
        if(edit.kind==EditKind.Placement && link.contains(c.occurrence))TimelineEdit(revision,c,EditKind.Placement,c.globalStartMs+delta).candidate()
        else if(c.occurrence==edit.original.occurrence) {
            if(edit.kind==EditKind.TrimIn)c.copy(sourceInMs=edit.valueMs,globalStartMs=c.globalStartMs+edit.valueMs-c.sourceInMs)
            else edit.candidate()
        } else c
    }
    return copy(clips=next)
}
