package com.soundq.android.data.trackdetails

import com.soundq.android.data.*
import kotlinx.serialization.json.*
import java.time.Instant

internal object AnalysisJson {
    fun parse(body:JsonObject,id:TrackId):AnalysisDetail=TrackDetailsJson.checked {
        require(TrackDetailsJson.number(body.getValue("track_id"))==id.value)
        require(TrackDetailsJson.number(body.getValue("schema_version"))>=1)
        val revision=TrackDetailsJson.number(body.getValue("override_revision")).also {require(it>=0)}
        val status=TrackDetailsJson.text(body.getValue("status"))
        require(status in setOf("pending","analyzing","analyzed","failed","stale","unsupported"))
        Instant.parse(TrackDetailsJson.text(body.getValue("updated_at")))
        fun obj(key:String)=body[key]?.takeUnless {it is JsonNull}?.jsonObject?:buildJsonObject{}
        val generated=obj("summary");val effective=obj("effective_timing");val overrides=obj("overrides")
        // Validate displayed facts without assuming all analyzer fields exist.
        listOf(generated,effective,overrides).forEach {row->
            listOf("bpm","energy").forEach {key->row[key]?.takeUnless {it is JsonNull}?.let {raw->val value=(raw as? JsonObject)?.get("value")?:raw;value.jsonPrimitive.let {require(!it.isString&&it.double.isFinite())}}}
            listOf("key","camelot").forEach {key->row[key]?.takeUnless {it is JsonNull}?.let {raw->val value=(raw as? JsonObject)?.get("value")?:raw;TrackDetailsJson.text(value)}}
        }
        AnalysisDetail(revision,status,generated,effective,overrides)
    }
    fun acknowledgement(accepted:AnalysisDetail,base:AnalysisDetail,correction:AnalysisCorrection)=TrackDetailsJson.checked {
        require(accepted.revision==base.revision+1)
        val document=accepted.overrides
        if(correction.reset) {
            require(listOf("manual_timing_v2","manual_timing_override","bpm","beat_grid","downbeats").none {document.containsKey(it)})
            require(document["key"]==null||document["key"] is JsonNull)
            require(document["camelot"]==null||document["camelot"] is JsonNull)
        } else {
            val timing=document["manual_timing_v2"]?.jsonObject
            correction.bpm?.let {require(timing?.get("bpm")?.jsonPrimitive?.let {p->!p.isString&&p.double==it}==true)}
            listOf("beat_anchor_ms" to correction.anchorMs,"beats_per_bar" to correction.meter?.toLong(),"downbeat_phase_index" to correction.phase?.toLong(),"phrase_length_bars" to correction.phraseBars?.toLong()).forEach {(key,value)->
                if(value!=null)require(timing?.get(key)?.let(TrackDetailsJson::number)==value)
            }
            listOf("key" to correction.key,"camelot" to correction.camelot).forEach {(key,value)->if(value!=null){
                val raw=document[key]
                if(value.isBlank())require(raw==null||raw is JsonNull) else require(raw?.jsonObject?.get("value")?.let(TrackDetailsJson::text)==value)
            }}
        }
    }
    fun request(base:AnalysisDetail,correction:AnalysisCorrection):JsonObject {
        val timingChanged=listOf(correction.bpm,correction.anchorMs,correction.meter,correction.phase,correction.phraseBars).any {it!=null}
        require(correction.reset||timingChanged||correction.key!=null||correction.camelot!=null)
        val document=base.overrides.toMutableMap()
        val timingKeys=setOf("manual_timing_v2","manualTimingV2","manual_timing_override","manualTimingOverride","bpm","native_bpm","nativeBpm","bpm_confidence","bpmConfidence","beat_grid","beatGrid","beat_grid_ms","beatGridMs","beats_ms","beatsMs","beat_grid_offset_ms","beatGridOffsetMs","offset_ms","offsetMs","downbeats","downbeats_ms","downbeatsMs")
        val legacy=timingKeys.any {it !in setOf("manual_timing_v2","manualTimingV2")&&document.containsKey(it)}
        if(correction.reset) {timingKeys.forEach(document::remove);document.remove("key");document.remove("camelot");document["key"]=JsonNull;document["camelot"]=JsonNull}
        else {
            if(timingChanged) {
                val prior=(document["manual_timing_v2"] as? JsonObject).orEmpty().toMutableMap()
                prior.remove("revision");prior.remove("updated_at");prior["schema_version"]=JsonPrimitive(2)
                correction.bpm?.let {prior["bpm"]=JsonPrimitive(it)}
                correction.anchorMs?.let {prior["beat_anchor_ms"]=JsonPrimitive(it)}
                correction.meter?.let {prior["beats_per_bar"]=JsonPrimitive(it);if(correction.phase==null)prior.remove("downbeat_phase_index")}
                correction.phase?.let {prior["downbeat_phase_index"]=JsonPrimitive(it)}
                correction.phraseBars?.let {prior["phrase_length_bars"]=JsonPrimitive(it)}
                document["manual_timing_v2"]=JsonObject(prior)
            }
            fun fact(value:String)=buildJsonObject {put("value",value);put("provenance","manual_override")}
            correction.key?.let {document["key"]=if(it.isBlank())JsonNull else fact(it)}
            correction.camelot?.let {document["camelot"]=if(it.isBlank())JsonNull else fact(it)}
        }
        return buildJsonObject {
            put("overrides",JsonObject(document));put("expected_revision",base.revision)
            if(correction.reset)put("timing_mutation","clear") else if(timingChanged&&!legacy)put("timing_mutation","replace")
        }
    }
}
