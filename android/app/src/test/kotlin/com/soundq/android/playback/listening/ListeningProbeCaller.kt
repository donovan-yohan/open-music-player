package com.soundq.android.playback.listening
import com.soundq.android.data.timeline.*
import com.soundq.android.playback.mix.*
internal fun createProbeCaller():ProbeCaller = object:ProbeCaller {
 override fun open(sources:List<TimelineSource>,overlapMs:Long,paths:Map<String,String>) = NativeMixStream(ListeningSchedule.compile(sources,overlapMs).renderPlan(paths))
}

internal fun createClockProbe(sources:List<TimelineSource>,overlapMs:Long):ClockProbe {
 val s=ListeningSchedule.compile(sources,overlapMs)
 return object:ClockProbe {
  override val starts=s.occurrences.map {it.startMs}
  override fun globalAt(occurrence:String,sourceMs:Long)=s.globalAt(occurrence,sourceMs)
  override fun observe(globalMs:Long):ClockReading {
   val o=s.observe(globalMs)
   fun point(p:ListeningPosition)=ClockPoint(p.occurrence.source.occurrence,p.sourceMs,p.occurrence.source.durationMs,p.gain,p.occurrence.source.segment)
   return ClockReading(o.active.map(::point),o.selected?.let(::point))
  }
 }
}
