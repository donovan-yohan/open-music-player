package com.soundq.android.data.harmonic

import com.soundq.android.data.*
import com.soundq.android.data.playlists.*
import kotlinx.serialization.json.*
import java.util.Locale
import kotlin.math.roundToLong

fun normalizeHarmonicKey(raw:String?):String? = raw?.trim()?.uppercase(Locale.ROOT)?.takeIf {Regex("^(?:[1-9]|1[0-2])[AB]$").matches(it)}
data class HarmonicDraft(val bpm:String="",val camelot:String="",val tolerance:String="5",val history:Boolean=true) {
    fun query():HarmonicQuery? {
        val tempo=bpm.trim().toDoubleOrNull()?.takeIf {it.isFinite()&&it>0&&it<=300} ?: return null
        val range=tolerance.trim().toDoubleOrNull()?.takeIf {it.isFinite()&&it in 0.0..50.0} ?: return null
        return HarmonicQuery(tempo,normalizeHarmonicKey(camelot)?:return null,range,history)
    }
}
data class HarmonicQuery internal constructor(val bpm:Double,val camelot:String,val tolerance:Double,val history:Boolean)
data class HarmonicSeed(val track:TrackId?=null,val draft:HarmonicDraft=HarmonicDraft(),val exclude:TrackId?=null)
fun harmonicSeed(detail:PlaylistDetail):HarmonicSeed {
    var partial:HarmonicSeed?=null
    for(track in detail.tracks) {
        val facts=detail.analysisSeeds[track.id]?:continue
        val bpm=facts.bpm?.takeIf {it.isFinite()&&it>0}?:continue
        val key=normalizeHarmonicKey(facts.camelot)
        val draft=HarmonicDraft(bpm.roundToLong().toString(),key?:"")
        if(key!=null)return HarmonicSeed(track.id,draft,track.id)
        if(partial==null)partial=HarmonicSeed(track.id,draft)
    }
    return partial?:HarmonicSeed()
}
data class NearbyTrack(val id:TrackId,val title:String,val artist:String?=null,val album:String?=null,val durationMs:Long?=null,val bpm:Double?=null,val camelot:String?=null) {
    fun queueTrack(canonical:PlaylistDetail):Track? {
        val original=canonical.tracks.firstOrNull {it.id==id}
        if(original!=null)return original.takeIf {it.durationMs>0}
        return durationMs?.takeIf {it>0}?.let {Track(id,title,artist?:"",album?:"",it)}
    }
}
data class NearbyResult(val tracks:List<NearbyTrack>,val orderedByHistory:Boolean=false)
class NearbyDisabled:java.io.IOException("Harmonic matching is turned off on this server.")
/** Owned metadata only; no source URLs, imports or catalog authority. Preserve wire order and multiplicity. */
internal object NearbyJson {
    fun parse(body:JsonObject):NearbyResult {
        fun text(o:JsonObject,k:String)=(o[k] as? JsonPrimitive)?.takeIf {it.isString}?.content?.trim()?.takeIf {it.isNotEmpty()}
        fun positive(o:JsonObject,k:String)=(o[k] as? JsonPrimitive)?.takeUnless {it.isString}?.doubleOrNull?.takeIf {it.isFinite()&&it>0}
        val tracks=(body["tracks"] as? JsonArray)?.mapNotNull {entry->
            val o=entry as? JsonObject?:return@mapNotNull null
            val id=(o["id"] as? JsonPrimitive)?.takeUnless {it.isString}?.longOrNull?.takeIf {it>0}?:return@mapNotNull null
            val title=text(o,"title")?:return@mapNotNull null
            val duration=(o["duration_ms"] as? JsonPrimitive)?.takeUnless {it.isString}?.longOrNull?.takeIf {it>0}
            NearbyTrack(TrackId(id),title,text(o,"artist"),text(o,"album"),duration,positive(o,"bpm"),normalizeHarmonicKey(text(o,"camelot")))
        }?:emptyList()
        return NearbyResult(tracks,(body["order"] as? JsonPrimitive)?.takeIf {it.isString}?.content=="history")
    }
}
