package com.soundq.android.product.trackdetails

/** Local editor measurements only. Never an analysis document or playback clock. */
internal data class TempoDraft(
    val text:String="",
    val tapsMs:List<Long> = emptyList(),
    val error:String?=null,
) {
    fun typed(value:String)=TempoDraft(text=value)

    fun scale(multiplier:Double,effectiveBpm:Double?):TempoDraft {
        val bpm=if(text.isBlank())effectiveBpm else text.trim().toDoubleOrNull()
        if(bpm==null||!bpm.isFinite()||bpm !in 30.0..300.0)return copy(error="Enter a valid tempo from 30–300 BPM before using Half BPM or Double BPM.")
        val scaled=bpm*multiplier
        if(!scaled.isFinite()||scaled !in 30.0..300.0)return copy(error="Result must be 30–300 BPM. The tempo draft is unchanged.")
        return TempoDraft(text=scaled.toString())
    }

    fun tap(timeMs:Long):TempoDraft {
        val taps=(tapsMs+timeMs).takeLast(8)
        val intervals=taps.zipWithNext {a,b->b-a}.filter {it>0}
        if(intervals.isEmpty())return copy(tapsMs=taps,error=null)
        val bpm=60000.0/intervals.average()
        return if(bpm.isFinite()&&bpm in 30.0..300.0)copy(text=bpm.toString(),tapsMs=taps,error=null)
        else copy(tapsMs=taps,error="Tapped tempo must be 30–300 BPM. Tap again or edit the tempo.")
    }
}
