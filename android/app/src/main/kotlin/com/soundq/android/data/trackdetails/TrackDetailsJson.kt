package com.soundq.android.data.trackdetails

import com.soundq.android.data.*
import kotlinx.serialization.json.*

internal object TrackDetailsJson {
    fun <T> checked(block:()->T):T=try{block()}catch(e:SafeFailure){throw e}catch(_:Exception){throw SafeFailure(SafeFailure.Reason.InvalidResponse)}
    fun number(value:JsonElement):Long=value.jsonPrimitive.let {require(!it.isString);it.long}
    fun boolean(value:JsonElement):Boolean=value.jsonPrimitive.let {require(!it.isString);it.boolean}
    fun text(value:JsonElement):String=value.jsonPrimitive.let {require(it.isString&&it.content.length<=8192);it.content}
    fun optional(row:JsonObject,key:String):String?=row[key]?.takeUnless {it is JsonNull}?.let(::text)
    fun row(row:JsonObject):TrackDetails {
        val id=TrackId(number(row.getValue("id")))
        val duration=row["duration_ms"]?.let(::number)?.also {require(it>=0)}?:0
        val codec=optional(row,"codec")
        val quality=listOfNotNull(codec,row["bitrate_kbps"]?.let {"${number(it).also {n->require(n>0)}} kbps"},row["sample_rate_hz"]?.let {"${number(it).also {n->require(n>0)}} Hz"},row["channels"]?.let {"${number(it).also {n->require(n>0)}} channels"}).joinToString(" · ").takeIf {it.isNotEmpty()}
        return TrackDetails(Track(id,text(row.getValue("title")),optional(row,"artist").orEmpty(),optional(row,"album").orEmpty(),duration,
            row["is_liked"]?.let(::boolean),SoundQApi.libraryArtworkUrl(row)),boolean(row.getValue("has_metadata_override")),boolean(row.getValue("mb_verified")),quality,optional(row,"mb_recording_id")?.let(::RecordingMbid),row["mb_suggestions"]?.jsonArray?.map {suggestion(it.jsonObject)}?:emptyList(),optional(row,"source_url"))
    }
    fun suggestion(row:JsonObject):MatchSuggestion {
        val confidence=row["confidence"]?.jsonPrimitive?.let {require(!it.isString);it.double.also {n->require(n.isFinite()&&n in 0.0..1.0)}}
        val duration=row["duration"]?.takeUnless {it is JsonNull}?.let(::number)?.also {require(it>=0)}?.takeIf {it>0}
        return MatchSuggestion(RecordingMbid(text(row.getValue("mb_recording_id"))),text(row.getValue("title")),text(row.getValue("artist")),optional(row,"release_id")?.let(::RecordingMbid),optional(row,"artist_mbid")?.let(::RecordingMbid),confidence,optional(row,"album"),duration)
    }
    fun verificationRequest(action:VerificationAction):Pair<String,JsonObject> = when(action) {
        VerificationAction.Rematch->"match" to buildJsonObject {}
        is VerificationAction.Link->"link-mb" to buildJsonObject {put("mb_recording_id",action.recording.value);put("update_metadata",action.updateMetadata)}
        is VerificationAction.Confirm->"confirm-match" to buildJsonObject {put("recordingMbid",action.suggestion.recording.value);action.suggestion.artistMbid?.let {put("artistMbid",it.value)};action.suggestion.release?.let {put("releaseMbid",it.value)}}
    }
    fun verificationAck(body:JsonObject,id:TrackId,action:VerificationAction):List<MatchSuggestion> = checked {
        when(action) {
            VerificationAction.Rematch->{
                require(number(body.getValue("track_id"))==id.value);boolean(body.getValue("verified"))
                body["best_match"]?.takeUnless {it is JsonNull}?.let {suggestion(it.jsonObject)}
                body["suggestions"]?.takeUnless {it is JsonNull}?.jsonArray?.map {suggestion(it.jsonObject)}?:emptyList()
            }
            is VerificationAction.Confirm->{
                require(number(body.getValue("trackId"))==id.value&&boolean(body.getValue("success"))&&boolean(body.getValue("verified")));emptyList()
            }
            is VerificationAction.Link->{
                require(number(body.getValue("track_id"))==id.value&&boolean(body.getValue("verified")))
                require(text(body.getValue("mb_recording_id"))==action.recording.value)
                val updated=boolean(body.getValue("metadata_updated"));require(updated==action.updateMetadata)
                optional(body,"mb_artist_id")?.let(::RecordingMbid);optional(body,"mb_release_id")?.let(::RecordingMbid)
                emptyList()
            }
        }
    }
    fun page(body:JsonObject,offset:Int):Pair<List<TrackDetails>,Int> = checked {
        require(number(body.getValue("offset"))==offset.toLong()&&number(body.getValue("limit"))==100L)
        val total=number(body.getValue("total")).also {require(it in 0..Int.MAX_VALUE)}.toInt()
        val rows=body.getValue("tracks").jsonArray.map {row(it.jsonObject)}
        require(rows.size<=100&&rows.map {it.track.id}.distinct().size==rows.size&&offset+rows.size<=total)
        rows to total
    }
    fun metadata(draft:MetadataDraft)=buildJsonObject {val d=draft.normalized();put("title",d.title?.let(::JsonPrimitive)?:JsonNull);put("artist",d.artist?.let(::JsonPrimitive)?:JsonNull);put("album",d.album?.let(::JsonPrimitive)?:JsonNull)}
    fun metadataAck(body:JsonObject,id:TrackId,draft:MetadataDraft)=checked {
        val d=draft.normalized()
        require(number(body.getValue("track_id"))==id.value)
        require(boolean(body.getValue("has_metadata_override"))==(listOf(d.title,d.artist,d.album).any {it!=null}))
        listOf("title" to d.title,"artist" to d.artist,"album" to d.album).forEach {(key,value)->
            require(body.containsKey(key));require(optional(body,key)==value)
        }
    }
}
