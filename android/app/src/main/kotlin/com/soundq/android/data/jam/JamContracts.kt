package com.soundq.android.data.jam

import com.soundq.android.data.*
import com.soundq.android.data.connect.*
import kotlinx.serialization.json.*
import java.time.Instant
import java.net.URI

internal fun guestOrigin(origin:String):String {
    require(origin.toByteArray().size in 1..512)
    val u=URI(origin)
    val local=u.scheme=="http"&&u.host in setOf("localhost","127.0.0.1","[::1]")
    require((u.scheme=="https"||local)&&u.host!=null&&u.rawUserInfo==null&&u.rawQuery==null&&u.rawFragment==null&&u.path in listOf("","/")&&(u.port==-1||u.port in 1..65535))
    return origin.removeSuffix("/")
}
class JamInvite private constructor(private val token:String,val expires:Instant) {
    fun link(origin:String,jamId:String):String {val base=guestOrigin(origin);uuid(jamId);return "$base/join#jamId=$jamId&invite=$token"}
    override fun toString()="JamInvite([redacted])"
    companion object {fun parse(j:JsonObject):JamInvite=decode {keys(j,setOf("joinToken","inviteExpiresAt"));val s=text(j,"joinToken",43);require(Regex("[A-Za-z0-9_-]{43}").matches(s)&&java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(java.util.Base64.getUrlDecoder().decode(s))==s);JamInvite(s,date(j,"inviteExpiresAt"))}}
}
data class AdmissionReceipt(val requestId:String,val sessionId:String,val occurrenceId:String,internal val ownerAfter:String?=null) {
    fun json()=buildJsonObject {put("requestId",requestId);put("sessionId",sessionId);put("occurrenceId",occurrenceId)}
}


data class JamState(val snapshot:JamSnapshot?=null,val invite:JamInvite?=null,val busy:Boolean=false,val message:String?=null,val uncertain:Boolean=false)
