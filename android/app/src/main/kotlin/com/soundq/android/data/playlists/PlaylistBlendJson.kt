package com.soundq.android.data.playlists

import com.soundq.android.data.*
import com.soundq.android.data.mix.*
import kotlinx.serialization.json.*

/** Keep the original saved response for exact readback, not the decoder's projection. */
data class MixPlanDocument(val raw:JsonObject,val plan:SavedMix)
data class PlaylistBlendAck(val document:MixPlanDocument,val transitions:List<JsonObject>)
internal object PlaylistBlendJson {
    private fun fields(o:JsonObject,required:Set<String>,optional:Set<String> = emptySet()) {
        require(o.keys.containsAll(required) && o.keys.all {it in required || it in optional} && o.values.none {it===JsonNull})
    }
    private fun bool(o:JsonObject,key:String):Boolean = o.getValue(key).jsonPrimitive.let {require(!it.isString);it.boolean}
    fun document(raw:JsonObject)=MixPlanDocument(raw,MixJson.saved(raw))
    fun sources(plan:SavedMix,detail:PlaylistDetail) {
        require(plan.clips.size==detail.tracks.size && plan.clips.size>=2)
        require(plan.clips.zip(detail.tracks).withIndex().all {(i,pair)->
            val (clip,track)=pair
            clip.track==track.id.value && clip.occurrence=="playlist-${detail.playlist.id.value}-pos-${i+1}" &&
                clip.sourceStart==0L && track.durationMs>0 && clip.sourceEnd==track.durationMs
        })
        require(plan.clips.map {it.occurrence}.distinct().size==plan.clips.size)
    }
    fun ack(o:JsonObject,detail:PlaylistDetail):PlaylistBlendAck {
        fields(o,setOf("playlistId","mixPlan","transitions"))
        require(MixJson.number(o,"playlistId")==detail.playlist.id.value)
        val document=document(o.getValue("mixPlan").jsonObject)
        sources(document.plan,detail)
        val clips=document.plan.clips
        require(clips.first().start==0L)
        val transitions=o.getValue("transitions").jsonArray.map {it.jsonObject}
        require(transitions.size==clips.size-1)
        transitions.forEachIndexed {i,t->
            fields(t,setOf("index","outgoingTrackId","incomingTrackId","preset","bars","overlapMs","confidence"))
            require(MixJson.number(t,"index")==i.toLong() && MixJson.number(t,"outgoingTrackId")==clips[i].track && MixJson.number(t,"incomingTrackId")==clips[i+1].track)
            require(MixJson.text(t,"preset") in setOf("Blend","Fade","Rise"))
            MixJson.number(t,"bars")
            val overlap=MixJson.number(t,"overlapMs")
            require(clips[i+1].start==clips[i].end-overlap && clips[i].fadeOut==overlap && clips[i+1].fadeIn==overlap)
            val confidence=t.getValue("confidence").jsonObject
            fields(confidence,setOf("keyMatch","tempoMatched","tempoShift","simpleFade"),setOf("tempoDeltaPercent"))
            confidence.keys.filter {it!="tempoDeltaPercent"}.forEach {bool(confidence,it)}
            confidence["tempoDeltaPercent"]?.jsonPrimitive?.let {require(!it.isString && it.double.isFinite() && it.double>=0)}
        }
        return PlaylistBlendAck(document,transitions)
    }
}
