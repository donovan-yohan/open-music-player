package com.soundq.android.playback

import com.soundq.android.data.TrackId
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.util.UUID

/** Source identity only: no URI, credential, grant or playback authority survives serialization. */
@Serializable sealed interface PlaybackRef {
    @Serializable data class Server(val endpoint:String,val account:String,val id:Long):PlaybackRef {
        init {require(endpoint.isNotBlank()&&account.isNotBlank());TrackId(id)}
        val trackId:TrackId get()=TrackId(id)
    }
    @Serializable data class Device(val id:String,val sha256:String,val bytes:Long,val incarnation:Long):PlaybackRef {
        init {require(UUID.fromString(id).toString()==id);require(sha256.matches(Regex("[a-f0-9]{64}"))&&bytes>=0&&incarnation>0)}
    }
    fun json():JsonObject=buildJsonObject {when(val r=this@PlaybackRef){
        is Server->{put("kind","server");put("endpoint",r.endpoint);put("account",r.account);put("id",r.id)}
        is Device->{put("kind","device");put("id",r.id);put("sha256",r.sha256);put("bytes",r.bytes);put("incarnation",r.incarnation)}
    }}
    fun wire():String=json().toString()
    companion object {
        fun parse(value:JsonObject):PlaybackRef=when(value.getValue("kind").jsonPrimitive.content){
            "server"->Server(value.getValue("endpoint").jsonPrimitive.content,value.getValue("account").jsonPrimitive.content,value.getValue("id").jsonPrimitive.long)
            "device"->Device(value.getValue("id").jsonPrimitive.content,value.getValue("sha256").jsonPrimitive.content,value.getValue("bytes").jsonPrimitive.long,value.getValue("incarnation").jsonPrimitive.long)
            else->error("Unknown playback source")
        }
        fun read(raw:String?):PlaybackRef?=raw?.takeIf {it.length<=20000}?.let {runCatching {parse(Json.parseToJsonElement(it).jsonObject)}.getOrNull()}
    }
}
