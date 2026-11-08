package com.soundq.android.data.imports

import com.soundq.android.data.*
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import kotlinx.serialization.json.*

/** Source values are never printable diagnostics. */
class ImportSource private constructor(val url: String, val provider: String) {
    override fun toString() = "ImportSource([redacted])"
    companion object {
        fun parse(value: String): ImportSource? {
            if(value.toByteArray(Charsets.UTF_8).size>4096)return null
            val raw=value.trim()
            if(!raw.startsWith("https://",ignoreCase=true) || raw.substringAfter("://").substringBefore('/').isEmpty() || raw.any {it.isWhitespace() || it.code<32 || it.code==127 || it=='\\'})return null
            val url=raw.toHttpUrlOrNull() ?: return null
            if(url.scheme!="https" || url.username.isNotEmpty() || url.password.isNotEmpty() || raw.substringAfter("://").substringBefore('/').contains('@'))return null
            val provider=when {
                url.host=="youtube.com" || url.host.endsWith(".youtube.com") || url.host=="youtu.be" -> "youtube"
                url.host=="soundcloud.com" || url.host.endsWith(".soundcloud.com") -> "soundcloud"
                else -> return null
            }
            return ImportSource(url.newBuilder().fragment(null).build().toString(),provider)
        }
    }
}
@JvmInline value class ImportJobId(val value: String) {
    init { require(Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}").matches(value)); require(java.util.UUID.fromString(value)!=java.util.UUID(0,0)) }
}
enum class ImportStatus(val wire: String) { Queued("queued"), Downloading("downloading"), Processing("processing"), Uploading("uploading"), Complete("complete"), Failed("failed") }
data class ImportAcknowledgement(val id: ImportJobId, val status: ImportStatus)
data class ImportJob(val id: ImportJobId, val status: ImportStatus, val progress: Int, val track: TrackId?, val provider: String)
