package com.soundq.android.product.timeline

import com.soundq.android.data.timeline.*
import kotlin.math.abs
import kotlin.math.roundToLong

/** Unaccepted source-local selection. Source replacement never rehomes an old pick. */
internal data class SourceTimingPick(
    val track:Long,val sourceKey:String,val durationMs:Long,
    val bpm:String="",val anchorMs:Long?=null,val groupOriginMs:Long?=null,val adopted:PhaseGrid?=null,
) {
    fun matches(clip:TimelineClip,wave:TrackWaveform)=track==clip.track&&wave.track.value==track&&sourceKey==wave.sourceKey&&durationMs==clip.sourceDurationMs&&wave.durationMs==durationMs
    fun adopt(wave:TrackWaveform):SourceTimingPick? {
        val grid=wave.phaseTiming?.takeIf {it.sourceKey==sourceKey&&wave.durationMs==durationMs&&it.anchorMs<=durationMs&&(it.groupOriginMs ?: 0)<=durationMs} ?: return null
        return copy(bpm=java.math.BigDecimal(60000).divide(java.math.BigDecimal(grid.periodMs),12,java.math.RoundingMode.HALF_UP).stripTrailingZeros().toPlainString(),anchorMs=grid.anchorMs,groupOriginMs=grid.groupOriginMs,adopted=grid)
    }
    fun phaseGrid(clip:TimelineClip,wave:TrackWaveform):PhaseGrid? {
        if(!matches(clip,wave)||anchorMs==null||anchorMs !in 0..durationMs||(groupOriginMs!=null&&groupOriginMs !in 0..durationMs))return null
        val anchor=anchorMs
        return runCatching {
            adopted?.takeIf {it.sourceKey==sourceKey}?.copy(anchorMs=anchor,groupOriginMs=groupOriginMs)
                ?: PhaseGrid.manual(sourceKey,"local:$bpm:$anchor:$groupOriginMs",bpm,anchor,groupOriginMs)
        }.getOrNull()
    }
    companion object {
        fun forSource(clip:TimelineClip,wave:TrackWaveform):SourceTimingPick? =
            if(wave.track.value==clip.track&&wave.durationMs==clip.sourceDurationMs)SourceTimingPick(clip.track,wave.sourceKey,wave.durationMs) else null
    }
}

/** Touches snap only within a physical hit radius of actual producer markers. */
internal fun sourceMarkerAt(x:Float,width:Float,start:Long,end:Long,markers:List<Long>,radius:Float):Long {
    require(width>0&&width.isFinite()&&x.isFinite()&&end>start)
    if(x<=0f)return start
    if(x>=width)return end
    val clamped=x.coerceIn(0f,width)
    val raw=start+((end-start)*clamped.toDouble()/width).roundToLong()
    val nearby=markers.asSequence().filter {it in start..end}.map {it to abs((it-start).toDouble()/(end-start)*width-clamped)}.filter {it.second<=radius}.minWithOrNull(compareBy<Pair<Long,Double>> {it.second}.thenBy {it.first})
    return nearby?.first ?: raw.coerceIn(start,end)
}

/** Use only qualified beat distance, mapped through the clip's existing rate law. */
internal fun timingBeatNudge(clip:TimelineClip,kind:EditKind,value:Long,direction:Int,wave:TrackWaveform?):Long? {
    if(direction !in listOf(-1,1)||wave==null||wave.track.value!=clip.track||wave.durationMs!=clip.sourceDurationMs)return null
    val grid=wave.phaseTiming?.takeIf {it.sourceKey==wave.sourceKey} ?: return null
    val delta=grid.periodMs*direction
    return when(kind) {
        EditKind.Placement->{
            // Difference between the original source anchor and its next beat on this clip map.
            val source=clip.sourceInMs
            val next=source+grid.periodMs
            if(next>clip.sourceOutMs)return null
            (value+direction*(clip.globalAt(next)-clip.globalAt(source))).takeIf {it in 0..302400000000L}
        }
        else->(value+delta).takeIf {it in 0..clip.sourceDurationMs}
    }
}

internal fun fullOverlapFade(revision:Long,outgoing:TimelineClip,incoming:TimelineClip)=
    TimelineFadeEdit(revision,outgoing,incoming,outgoing.globalEndMs-incoming.globalStartMs)
