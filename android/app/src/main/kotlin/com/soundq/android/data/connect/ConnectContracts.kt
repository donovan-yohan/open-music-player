package com.soundq.android.data.connect

import com.soundq.android.data.*
import kotlinx.serialization.json.*
import java.time.Instant
import java.util.UUID
import java.security.SecureRandom
import java.util.Base64

internal fun uuid(value:String):String {require(UUID.fromString(value).toString()==value && value!="00000000-0000-0000-0000-000000000000");return value}
internal fun secret():String = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32).also {SecureRandom().nextBytes(it)})
internal fun text(j:JsonObject,key:String,max:Int):String = j.getValue(key).jsonPrimitive.let {require(it.isString);it.content.also {s->require(s.toByteArray().size<=max)}}
internal fun number(j:JsonObject,key:String,min:Long=0,max:Long=9_007_199_254_740_991):Long = j.getValue(key).jsonPrimitive.let {require(!it.isString);it.long.also {n->require(n in min..max)}}
internal fun date(j:JsonObject,key:String):Instant = Instant.parse(text(j,key,40))
internal fun keys(j:JsonObject,required:Set<String>,optional:Set<String> = emptySet()) {require(j.keys.containsAll(required)&&j.keys.all {it in required||it in optional})}
internal fun bounded(s:String,max:Int):String {var n=0;return buildString {s.codePoints().toArray().forEach {cp->val c=String(Character.toChars(cp));if(n+c.toByteArray().size<=max){append(c);n+=c.toByteArray().size}else return@buildString}}}
internal fun <T> decode(block:()->T):T = try {block()} catch(e:SafeFailure){throw e} catch(_:Exception){throw SafeFailure(SafeFailure.Reason.InvalidResponse)}
class FeatureFailure(val status:Int):java.io.IOException("Private feature unavailable") {override fun toString()="Private feature unavailable ($status)"}

data class ConnectedDevice(val deviceId:String,val leaseId:String,val label:String,val platform:String,val sequence:Long,val lastSeen:Instant,val expires:Instant,val title:String?,val artist:String?,val playing:Boolean) {
    companion object {fun parse(j:JsonObject):ConnectedDevice=decode {
        val platform=text(j,"platform",16);require(platform in setOf("android","ios","macos","windows","linux","web"))
        val p=j["playback"]?.takeUnless {it is JsonNull}?.jsonObject
        if(p!=null){text(p,"sessionId",128);number(p,"positionMs");number(p,"durationMs");number(p,"activeVoiceCount",max=4);require(text(p,"processingState",16) in setOf("idle","loading","buffering","ready","completed"))}
        ConnectedDevice(uuid(text(j,"deviceId",36)),uuid(text(j,"leaseId",36)),text(j,"label",64),platform,number(j,"sequence"),date(j,"lastSeenAt"),date(j,"leaseExpiresAt"),p?.get("track")?.jsonObject?.let {text(it,"title",200)},p?.get("track")?.jsonObject?.let {text(it,"artist",200)},p?.get("playing")?.jsonPrimitive?.boolean ?: false)
    }}
}
data class DeviceList(val devices:List<ConnectedDevice>,val serverTime:Instant) {
    companion object {fun parse(j:JsonObject):DeviceList=decode {val rows=j.getValue("devices").jsonArray;require(rows.size<=8);val devices=rows.map {ConnectedDevice.parse(it.jsonObject)};require(devices.map {it.deviceId}.distinct().size==devices.size);DeviceList(devices,date(j,"serverTime"))}}
}
/** Opaque writer capability. Neither UI state nor debug output contains its secret. */
class WriterProof internal constructor(val scope:AccountScope,internal val device:String,internal val lease:String,private val writer:String,private val valid:()->Boolean) {
    fun current()=valid()
    internal fun body(host:Boolean=false)=buildJsonObject {put(if(host)"hostDeviceId" else "deviceId",device);put("leaseId",lease);put("writerSecret",writer)}
    override fun toString()="WriterProof([redacted])"
}
enum class PresenceStatus {Detached,Connecting,Online,Offline,Disabled}
data class PresenceState(val status:PresenceStatus=PresenceStatus.Detached,val devices:List<ConnectedDevice> = emptyList(),val listFailed:Boolean=false)
internal object LeaseRecovery {fun delayMillis(status:Int)=if(status==503||status==429)30_000L else 5_000L}
