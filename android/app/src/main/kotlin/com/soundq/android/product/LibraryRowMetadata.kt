package com.soundq.android.product

import com.soundq.android.data.LibraryAnalysisFacts
import com.soundq.android.data.preferences.KeyNotationState
import com.soundq.android.product.trackdetails.formatAnalysisKey


internal data class LibraryMetadataField(val display:String,val spoken:String)
/** Duration-bearing member rows explicitly distinguish unavailable from a known zero. */
internal fun memberDurationMetadata(durationMs:Long):List<LibraryMetadataField> =
    if(durationMs>0)libraryRowMetadata(durationMs,null,KeyNotationState()).take(1)
    else listOf(LibraryMetadataField("—:—","Duration unavailable"))
internal fun libraryRowMetadata(durationMs:Long,facts:LibraryAnalysisFacts?,notation:KeyNotationState):List<LibraryMetadataField> = buildList {
    if(durationMs>0) {
        val seconds=durationMs/1000;val hours=seconds/3600;val minutes=seconds/60%60;val remaining=seconds%60
        val display=if(hours>0)"$hours:${minutes.toString().padStart(2,'0')}:${remaining.toString().padStart(2,'0')}" else "${seconds/60}:${remaining.toString().padStart(2,'0')}"
        val spoken=buildList {
            fun unit(value:Long,name:String){add("$value $name${if(value==1L)"" else "s"}")}
            if(hours>0)unit(hours,"hour")
            if(minutes>0)unit(minutes,"minute")
            if(remaining>0||isEmpty())unit(remaining,"second")
        }.joinToString(" ")
        add(LibraryMetadataField(display,"Duration $spoken"))
    }
    facts?.bpm?.takeIf {it.isFinite()&&it>0}?.let {bpm->
        // Decimal rounding avoids Int saturation for valid facts outside a DJ tempo range.
        val value=java.math.BigDecimal.valueOf(bpm).setScale(0,java.math.RoundingMode.HALF_UP).toPlainString()
        add(LibraryMetadataField("$value BPM","Tempo $value BPM"))
    }
    if(notation.ready)formatAnalysisKey(facts?.musicalKey,facts?.camelot,notation.choice)?.let {add(LibraryMetadataField(it,"Key $it"))}
}
