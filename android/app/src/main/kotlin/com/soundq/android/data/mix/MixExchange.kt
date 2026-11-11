package com.soundq.android.data.mix

import kotlinx.serialization.json.JsonObject
import java.nio.charset.CodingErrorAction

/** Canned codes only. No server message, hash or supplied JSON enters an exception. */
class ExchangeRefusal(val code:Code):Exception("Mix metadata was not accepted.") {
    enum class Code { MISSING_SOURCES, AMBIGUOUS_SOURCE, SOURCE_MISMATCH, UNSUPPORTED_METADATA }
    override fun toString()="Mix exchange: ${code.name}"
}
internal class ExchangeAdmissionRefused:Exception("Mix metadata was not accepted.")
internal class ExchangeDocument(val body:JsonObject,val text:String) {
    override fun toString()="ExchangeDocument([redacted])"
}
internal fun validateExchangeInput(text:String) {
    require(text.isNotBlank()) {"Mix metadata must be nonempty and 256 KiB or smaller."}
    val encoder=Charsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
    val bytes=try {encoder.encode(java.nio.CharBuffer.wrap(text)).remaining()} catch(_:Exception) {throw IllegalArgumentException("Mix metadata must be valid Unicode.")}
    require(bytes<=256*1024) {"Mix metadata must be nonempty and 256 KiB or smaller."}
}
