package com.soundq.android.playback.mix

import com.soundq.android.data.SoundQApi
import com.soundq.android.data.mix.MixJson
import kotlinx.serialization.json.*
import java.time.Instant

/** Validated publication, not readiness. Exact downloaded hashes and decoded extents are checked later. */
internal data class StemMember(val role:String,val url:String,val digest:String,val bytes:Long,val frames:Long,val preSkip:Long)
internal data class StemPublication(val channels:List<String>,val members:List<StemMember>) {
    companion object {
        fun parse(status:JsonObject,track:Long,edits:JsonObject):StemPublication {
            val set=MixJson.text(edits,"channelSet");val model=MixJson.text(edits,"stemModelVersion");val hash=MixJson.text(edits,"sourceFileHash")
            require(MixJson.number(status,"schemaVersion")==1L && MixJson.number(status,"trackId")==track && MixJson.text(status,"status")=="ready")
            require(MixJson.text(status,"channelSet")==set && MixJson.text(status,"stemModelVersion")==model && MixJson.text(status,"sourceFileHash")==hash)
            val generation=MixJson.number(status,"generation");require(generation>0)
            val m=status.getValue("publishedManifest").jsonObject
            require(MixJson.number(m,"schema_version")==1L && MixJson.number(m,"track_id")==track && MixJson.number(m,"generation")==generation)
            require(MixJson.text(m,"channel_set")==set && MixJson.text(m,"stem_model_version")==model && MixJson.text(m,"source_file_hash")==hash)
            MixJson.text(m,"source_storage_key")
            val provenance=m.getValue("provenance").jsonObject
            require(MixJson.text(provenance,"worker")=="stemsep-worker" && MixJson.text(provenance,"worker_version")=="2026-08-30-1")
            val channels=if(set=="stems5-hybrid-v1")listOf("vocals","melody","bass","kick","perc")else listOf("vocals","drums","bass","other")
            val roles=channels+if(channels.size==5)listOf("drums")else emptyList()
            val a=m.getValue("artifacts").jsonObject
            val codec=a.getValue("codec").jsonObject
            require(MixJson.text(codec,"name")=="libopus" && MixJson.number(codec,"sample_rate_hz")==48000L && MixJson.number(codec,"channels")==2L)
            if(channels.size==5) {
                val n=a.getValue("null_sum").jsonObject
                require(n.getValue("passed").jsonPrimitive.boolean && n.getValue("threshold_db").jsonPrimitive.double== -80.0 && n.getValue("residual_db").jsonPrimitive.double<= -80.0)
                require(MixJson.text(n,"against")=="drums" && n.getValue("pair").jsonArray.map {it.jsonPrimitive.content}==listOf("kick","perc"))
            }
            val objects=a.getValue("objects").jsonArray.map {it.jsonObject}
            val downloads=status.getValue("memberDownloads").jsonArray.map {it.jsonObject}
            require(objects.size==roles.size && downloads.size==roles.size)
            require(objects.map {MixJson.text(it,"channel")}.toSet()==roles.toSet() && downloads.map {MixJson.text(it,"channel")}.toSet()==roles.toSet())
            val members=roles.map {role ->
                val o=objects.single {MixJson.text(it,"channel")==role};val d=downloads.single {MixJson.text(it,"channel")==role}
                val digest=MixJson.text(o,"sha256");require(Regex("[0-9a-f]{64}").matches(digest))
                val key="stems/$track/$model/${hash.substring(7)}/g$generation/${if(role=="melody")"other"else role}/$digest.opus"
                require(MixJson.text(o,"key")==key && MixJson.text(d,"key")==key && MixJson.text(d,"sha256")==digest)
                val size=MixJson.number(o,"bytes");require(size in 1..134217728 && MixJson.number(d,"bytes")==size)
                require(o["path"]==null || o["path"]?.jsonPrimitive?.content=="")
                require(MixJson.text(o,"derivation")==if(role in listOf("kick","perc"))"dsp-crossover-lr4-180"else "separator")
                val url=MixJson.text(d,"url");require(SoundQApi.safeMediaUrl(url) && Instant.parse(MixJson.text(d,"expiresAt")).isAfter(Instant.now().plusSeconds(5)))
                val frames=MixJson.number(o,"sample_frames");require(frames>0 && MixJson.number(o,"sample_rate_hz")==48000L && MixJson.number(o,"channels")==2L)
                require(MixJson.number(o,"origin_frame")==0L && MixJson.number(o,"delay_frames")==0L && MixJson.text(o,"delay_provenance")=="ffmpeg-ogg-opus-preskip-end-trim-v1")
                require(kotlin.math.abs(MixJson.number(o,"duration_ms")-frames/48.0)<=1)
                StemMember(role,url,digest,size,frames,MixJson.number(o,"encoder_delay_frames"))
            }
            val energy=a.getValue("energy").jsonObject
            val energyFrames=MixJson.number(energy,"frame_count")
            require(MixJson.number(energy,"frame_hz")==80L && MixJson.text(energy,"encoding")=="uint8-linear")
            require(energyFrames==Math.round(members.first().frames*80.0/48000))
            val energyChannels=energy.getValue("channels").jsonObject;require(energyChannels.keys==roles.toSet())
            roles.forEach {role->val value=energyChannels.getValue(role).jsonPrimitive;require(value.isString);val encoded=value.content;require(encoded.length.toLong()==((energyFrames+2)/3)*4 && java.util.Base64.getDecoder().decode(encoded).size.toLong()==energyFrames)}
            require(members.map {it.frames to it.preSkip}.distinct().size==1 && members.sumOf {it.bytes}<=134217728)
            require(kotlin.math.abs(MixJson.number(m,"duration_ms")-members.first().frames/48.0)<=1)
            return StemPublication(channels,members)
        }
    }
}
internal data class PreparedMixStems(val channels:List<String>,val paths:List<String>)
