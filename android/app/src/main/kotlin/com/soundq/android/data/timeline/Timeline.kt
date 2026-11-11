package com.soundq.android.data.timeline

import kotlinx.serialization.Serializable

/** Segment describes admission origin, never inferred from track identity. */
enum class QueueSegment { Manual, Context, Continuation }
@Serializable data class TimelineSource(val occurrence: String, val track: Long, val title: String, val durationMs: Long, val segment: QueueSegment)
@Serializable data class TimelineClip(val occurrence: String, val track: Long, val title: String, val sourceDurationMs: Long,
    val sourceInMs: Long, val sourceOutMs: Long, val globalStartMs: Long, val segment: QueueSegment,
    val rates: RateAutomation = RateAutomation(), val explicitPlacement: Boolean = false,
    val fadeInMs: Long = 0, val fadeOutMs: Long = 0,
    @kotlinx.serialization.Transient val tempoMap: ClipTempoMap? = null,
    @kotlinx.serialization.Transient val heldTempo:TempoPlaybackIntent?=null)
@Serializable data class RateSegment(val startMs: Long, val endMs: Long, val startRate: Double, val endRate: Double)
@Serializable data class RateAutomation(val baseRate: Double = 1.0, val segments: List<RateSegment> = emptyList()) {
    init {
        require(baseRate.isFinite() && baseRate in 0.25..4.0 && segments.size <= 256)
        require(segments.all {it.startMs >= 0 && it.endMs > it.startMs && it.startRate.isFinite() && it.endRate.isFinite() && it.startRate in 0.25..4.0 && it.endRate in 0.25..4.0})
    }
    fun sourceElapsed(startMs: Long, globalMs: Long): Long {
        if(globalMs <= startMs)return 0
        val points=(listOf(startMs,globalMs)+segments.flatMap {listOf(it.startMs,it.endMs)}.filter {it>startMs&&it<globalMs}).distinct().sorted()
        var elapsed=0.0
        points.zipWithNext().forEach {(a,b) ->
            val segment=segments.lastOrNull {it.startMs<=a&&it.endMs>=b}
            fun rate(t:Long):Double = if(segment==null)baseRate else segment.startRate+(segment.endRate-segment.startRate)*(t-segment.startMs).toDouble()/(segment.endMs-segment.startMs)
            elapsed+=(b-a)*(rate(a)+rate(b))/2
        }
        return kotlin.math.floor(elapsed+0.5).toLong()
    }
    fun sourceDelta(fromMs:Long,toMs:Long):Long=if(toMs>=fromMs)sourceElapsed(fromMs,toMs) else -sourceElapsed(toMs,fromMs)
    fun globalForSource(startMs: Long, sourceElapsed: Long): Long {
        if(sourceElapsed<=0)return startMs
        var low=startMs
        var high=startMs+sourceElapsed*4+1
        while(low<high) {
            val mid=low+(high-low)/2
            if(sourceElapsed(startMs,mid)>=sourceElapsed) high=mid else low=mid+1
        }
        return low
    }
}
/** One immutable original-source map shared by editor geometry and the native payload. */
data class ClipTempoMap(val intent:TempoRampIntent,val sourceBpm:Double,val sourceAtStartMs:Double) {
    val law:SharedTempoLaw=SharedTempoLaw(intent.overlapStartMs,intent.overlapEndMs,intent.outgoingEffectiveStartBpm,
        if(intent.target.kind==TempoTargetKind.Original)intent.incoming.sourceBpm else intent.target.customBpm!!,intent.curve)
}
fun TimelineClip.sourceAtExact(globalMs:Double):Double {
    val map=tempoMap
    return if(map!=null&&globalMs>=map.intent.overlapStartMs)map.sourceAtStartMs+map.law.sourceDeltaMs(map.intent.overlapStartMs,globalMs,map.sourceBpm)
    else sourceInMs+rates.sourceElapsedExact(globalStartMs.toDouble(),globalMs)
}
fun TimelineClip.globalAtExact(sourceMs:Double):Double {
    val map=tempoMap
    if(map!=null&&sourceMs>=map.sourceAtStartMs)return map.law.globalForSourceDeltaMs(map.intent.overlapStartMs,sourceMs-map.sourceAtStartMs,map.sourceBpm)
    var low=globalStartMs.toDouble();var high=low+maxOf(0.0,sourceMs-sourceInMs)*4+1
    repeat(64){val mid=(low+high)/2;if(sourceAtExact(mid)>=sourceMs)high=mid else low=mid}
    return high
}
val TimelineClip.globalEndMs: Long get() = if(tempoMap==null&&heldTempo==null)rates.globalForSource(globalStartMs,sourceOutMs-sourceInMs) else kotlin.math.ceil(globalAtExact(sourceOutMs.toDouble())-1e-7).toLong()
fun TimelineClip.sourceAt(globalMs: Long): Long = kotlin.math.floor(sourceAtExact(globalMs.toDouble())+0.5).toLong()
fun TimelineClip.globalAt(sourceMs: Long): Long = if(tempoMap==null)rates.globalForSource(globalStartMs,sourceMs-sourceInMs) else kotlin.math.floor(globalAtExact(sourceMs.toDouble())+0.5).toLong()
fun RateAutomation.rateAtExact(globalMs:Double):Double = segments.lastOrNull {globalMs>=it.startMs&&globalMs<=it.endMs}?.let {it.startRate+(it.endRate-it.startRate)*(globalMs-it.startMs)/(it.endMs-it.startMs)} ?: baseRate
fun RateAutomation.sourceElapsedExact(startMs:Double,globalMs:Double):Double {
    if(globalMs<=startMs)return 0.0
    val points=(listOf(startMs,globalMs)+segments.flatMap {listOf(it.startMs.toDouble(),it.endMs.toDouble())}.filter {it>startMs&&it<globalMs}).distinct().sorted()
    return points.zipWithNext().sumOf {(a,b)->
        val segment=segments.lastOrNull {it.startMs<=a&&it.endMs>=b}
        fun rate(t:Double)=segment?.let {it.startRate+(it.endRate-it.startRate)*(t-it.startMs)/(it.endMs-it.startMs)} ?: baseRate
        (b-a)*(rate(a)+rate(b))/2
    }
}

fun sequentialTimeline(sources: List<TimelineSource>): List<TimelineClip> {
    require(sources.size <= 500 && sources.map { it.occurrence }.distinct().size == sources.size)
    var start = 0L
    return sources.map { s ->
        require(s.occurrence.isNotBlank() && s.track > 0 && s.durationMs in 1..604800000L)
        TimelineClip(s.occurrence,s.track,s.title,s.durationMs,0,s.durationMs,start,s.segment).also { start += s.durationMs }
    }
}
