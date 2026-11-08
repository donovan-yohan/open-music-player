package com.soundq.android.data.jam

import com.soundq.android.data.connect.*
import kotlinx.serialization.json.*

/** Metadata on an actual canonical occurrence, never permission to create one.
 * The enclosing queue observation supplies endpoint/account custody. */
data class JamOccurrence(val admissionKey:String,val requestId:String,val sessionId:String) {
    init {
        require(Regex("[0-9a-f]{64}").matches(admissionKey));uuid(requestId)
        require(sessionId.isNotBlank()&&sessionId.toByteArray().size<=128)
    }
    fun json()=buildJsonObject {put("admissionKey",admissionKey);put("requestId",requestId);put("sessionId",sessionId)}
    fun encode()=json().toString()
    override fun toString()="JamOccurrence([redacted])"
    companion object {
        fun parse(row:JsonObject):JamOccurrence {
            keys(row,setOf("admissionKey","requestId","sessionId"))
            return JamOccurrence(text(row,"admissionKey",64),text(row,"requestId",36),text(row,"sessionId",128))
        }
        fun decode(raw:String?):JamOccurrence?=raw?.let {require(it.toByteArray().size<=512);parse(Json.parseToJsonElement(it).jsonObject)}
    }
}
