package com.soundq.android.data.trackdetails

import kotlinx.serialization.json.*

data class AnalysisDetail(val revision:Long,val status:String,val generated:JsonObject,val effective:JsonObject,val overrides:JsonObject) {
    fun number(section:String,field:String="value"):Double?=((effective[section]?:generated[section]) as? JsonObject)?.get(field)?.jsonPrimitive?.doubleOrNull
    fun text(section:String):String?=((overrides[section]?.takeUnless {it is JsonNull}?:generated[section]) as? JsonObject)?.get("value")?.let {if(it is JsonNull)null else it.jsonPrimitive.content}
}
/** Empty fields mean no new correction, not invented zero facts. Only explicit changes are submitted. */
data class AnalysisCorrection(val bpm:Double?=null,val anchorMs:Long?=null,val meter:Int?=null,val phase:Int?=null,val phraseBars:Int?=null,val key:String?=null,val camelot:String?=null,val reset:Boolean=false) {
    init {
        require(bpm==null||bpm.isFinite()&&bpm in 30.0..300.0)
        require(anchorMs==null||anchorMs>=0)
        require(meter==null||meter in 1..32)
        require(phase==null||meter!=null&&phase in 0 until meter)
        require(phraseBars==null||phraseBars in 1..128)
        require(key==null||key.length<=100);require(camelot==null||camelot.length<=20)
    }
}
