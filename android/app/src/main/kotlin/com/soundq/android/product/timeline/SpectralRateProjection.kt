package com.soundq.android.product.timeline

import com.soundq.android.data.timeline.TimelineClip
import com.soundq.android.data.timeline.sourceAt
import com.soundq.android.data.timeline.globalAt
import com.soundq.android.data.timeline.globalEndMs
import kotlin.math.floor

/** Preparation-local rate integral. Same interval precedence, operation order and rounded
 * inverse as RateAutomation; only the repeated breakpoint/list construction is removed.
 * No cross-clip cache or playback timing authority. At most 513 intervals (256 segments).
 */
internal class SpectralRateProjection(private val clip:TimelineClip) {
    private val baseRate=clip.rates.baseRate
    private val segments=clip.rates.segments.toList()
    private val points=(listOf(clip.globalStartMs)+segments.flatMap {listOf(it.startMs,it.endMs)}.filter {it>clip.globalStartMs}).distinct().sorted()
    private val owners=Array(points.size) {i ->
        val a=points[i]
        if(i==points.lastIndex)null else segments.lastOrNull {it.startMs<=a&&it.endMs>=points[i+1]}
    }
    private val prefix=DoubleArray(points.size).also {sums ->
        for(i in 1 until points.size)sums[i]=sums[i-1]+integral(i-1,points[i])
    }
    private fun integral(index:Int,end:Long):Double {
        val start=points[index]
        val segment=owners[index]
        fun rate(t:Long):Double = if(segment==null)baseRate else segment.startRate+(segment.endRate-segment.startRate)*(t-segment.startMs).toDouble()/(segment.endMs-segment.startMs)
        return (end-start)*(rate(start)+rate(end))/2
    }
    private fun sourceElapsed(globalMs:Long):Long {
        if(globalMs<=clip.globalStartMs)return 0
        var low=0
        var high=points.lastIndex
        while(low<high) {
            val mid=low+(high-low+1)/2
            if(points[mid]<=globalMs)low=mid else high=mid-1
        }
        return floor(prefix[low]+integral(low,globalMs)+0.5).toLong()
    }
    fun sourceAt(globalMs:Long):Long=if(clip.tempoMap!=null)clip.sourceAt(globalMs) else clip.sourceInMs+sourceElapsed(globalMs)
    fun globalAt(sourceMs:Long):Long {
        if(clip.tempoMap!=null)return clip.globalAt(sourceMs)
        val elapsed=sourceMs-clip.sourceInMs
        if(elapsed<=0)return clip.globalStartMs
        var low=clip.globalStartMs
        var high=low+elapsed*4+1
        while(low<high) {
            val mid=low+(high-low)/2
            if(sourceElapsed(mid)>=elapsed)high=mid else low=mid+1
        }
        return low
    }
    val globalEndMs:Long get()=if(clip.tempoMap!=null)clip.globalEndMs else globalAt(clip.sourceOutMs)
}
