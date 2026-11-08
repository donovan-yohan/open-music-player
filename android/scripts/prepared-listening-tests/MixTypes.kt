package com.soundq.android.playback.mix
import com.soundq.android.data.mix.SavedMix
data class PreparedMixStems(val paths:List<String>)
data class MixRenderEvent(val sourceMs:Long,val bus:Int,val rampMs:Long,val gain:Float)
data class MixRenderClip(val startMs:Long,val endMs:Long,val sourceStartMs:Long,val fadeInMs:Long=0,val fadeOutMs:Long=0,val gainDb:Double=0.0,val paths:List<String>,val events:List<MixRenderEvent> = emptyList())
class MixRenderPlan(val durationMs:Long,val clips:List<MixRenderClip>) {val sources=clips.flatMap{it.paths}.distinct()}
fun SavedMix.renderPlan(paths:Map<Long,String>,stems:Map<String,PreparedMixStems>):MixRenderPlan=error("not a saved mix test")
