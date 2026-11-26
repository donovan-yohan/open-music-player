package com.soundq.android.data.originalimport

import com.soundq.android.data.AccountScope
import com.soundq.android.data.SafeFailure
import com.soundq.android.data.TrackId
import com.soundq.android.data.deviceaudio.ContentRevision
import com.soundq.android.data.deviceaudio.ServerAccount
import java.time.Instant
import java.util.UUID
import kotlinx.serialization.json.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okio.BufferedSink

/** The released private original import contract. Socket/auth authority stays in SoundQApi. */
internal class WireOriginalImportTransport(
    private val endpoint: String,
    private val send: (AccountScope, String, RequestBody?, UUID?, (() -> Boolean)?) -> Reply,
) : OriginalImportTransport {
    internal data class Reply(val code: Int, val body: JsonObject)

    override fun canEncode(scope: AccountScope, intent: OriginalImportIntent): Boolean = try {
        checkIntent(scope, intent); manifest(intent); true
    } catch (_: IllegalArgumentException) { false }

    private fun manifest(intent: OriginalImportIntent): ByteArray {
        val revision = intent.original.revision
        val display = intent.display
        require(listOf(display.title, display.artist, display.album).all { it == it.trim() })
        return buildJsonObject {
            put("sha256", "sha256:${revision.sha256}"); put("byte_length", revision.byteLength)
            put("title", display.title); put("artist", display.artist); put("album", display.album)
        }.toString().encodeToByteArray().also { require(it.size <= 8192) }
    }

    override fun upload(scope: AccountScope, intent: OriginalImportIntent, body: VerifiedOriginalBody, current: () -> Boolean): OriginalImportReceipt {
        checkIntent(scope, intent)
        require(body.revision == intent.original.revision)
        val manifest = manifest(intent)
        val audio = object : RequestBody() {
            override fun contentType() = "audio/mpeg".toMediaType()
            override fun contentLength() = body.revision.byteLength
            override fun isOneShot() = true
            override fun writeTo(sink: BufferedSink) { body.writeTo(sink.outputStream()) }
        }
        val multipart = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("manifest", null, manifest.toRequestBody("application/json".toMediaType()))
            .addFormDataPart("audio", null, audio).build()
        require(multipart.contentLength() - body.revision.byteLength in 1..16384)
        val response = send(scope, "/library/uploads", multipart, intent.operation, current)
        return receipt(intent, response, upload = true)
    }

    override fun status(scope: AccountScope, intent: OriginalImportIntent, admit: () -> Boolean): OriginalImportReceipt {
        checkIntent(scope, intent)
        return receipt(intent, send(scope, "/library/uploads/${intent.operation}", null, null, admit), upload = false)
    }

    override fun membership(scope: AccountScope, track: TrackId): OriginalMembershipResult {
        val owner = destination(scope)
        val reply = send(scope, "/library/tracks/${track.value}", null, null, null)
        if (reply.code == 404 && reply.body.code() == "NOT_FOUND") return OriginalMembershipResult.Absent(owner, track)
        if (reply.code != 200) return OriginalMembershipResult.Unconfirmed
        return validResponse {
            val json = reply.body
            val trackId = TrackId(json.integer("id")); require(trackId == track && json.text("account_id") == owner.account)
            val revision = json.revision()
            val details = ImportDisplay(json.text("title"), json.text("artist"), json.text("album"))
            val duration = json.integer("duration_ms"); require(duration in 1..Int.MAX_VALUE.toLong())
            Instant.parse(json.text("added_at"))
            OriginalMembershipResult.Present(OriginalMembership(owner, CommittedOriginal(trackId, revision), details, duration))
        }
    }

    private fun receipt(intent: OriginalImportIntent, reply: Reply, upload: Boolean): OriginalImportReceipt {
        fun complete(status: OriginalReceiptStatus) = OriginalImportReceipt(intent.destination, intent.operation, status)
        if (reply.code !in 200..299) {
            val code = reply.body.code()
            val noWrite = upload && ((reply.code == 400 && code == "INVALID_UPLOAD") ||
                (reply.code == 413 && code == "UPLOAD_TOO_LARGE") || (reply.code == 415 && code == "UPLOAD_MEDIA"))
            return complete(if (noWrite) OriginalReceiptStatus.Refused else OriginalReceiptStatus.Unconfirmed)
        }
        return validResponse {
            val response = reply.body
            require(response.text("account_id") == intent.destination.account && response.text("operation_id") == intent.operation.toString())
            val status = response.text("status")
            require(if (upload) (status == "committed" && reply.code in setOf(200, 201)) || (status == "pending" && reply.code == 202) else reply.code == 200)
            val phase = when (status) {
                "committed" -> {
                    val revision = response.revision()
                    require(revision == intent.original.revision)
                    OriginalReceiptStatus.Committed(CommittedOriginal(TrackId(response.integer("track_id")), revision))
                }
                "pending" -> OriginalReceiptStatus.Unconfirmed
                "closed", "conflict" -> OriginalReceiptStatus.Closed
                else -> throw SafeFailure(SafeFailure.Reason.InvalidResponse)
            }
            if (status != "committed") require(response.keys == setOf("account_id", "operation_id", "status"))
            complete(phase)
        }
    }

    private fun destination(scope: AccountScope) = ServerAccount(endpoint, scope.accountId.also(::canonicalUuid))
    private fun checkIntent(scope: AccountScope, intent: OriginalImportIntent) {
        require(intent.destination == destination(scope)); canonicalUuid(intent.operation.toString())
    }
    private fun canonicalUuid(text: String) {
        val id = UUID.fromString(text)
        require(id.toString() == text && id != UUID(0, 0))
    }
    private fun JsonObject.revision(): ContentRevision {
        val sha = text("sha256"); require(sha.startsWith("sha256:"))
        val length = integer("byte_length"); require(length in 1..ORIGINAL_IMPORT_MAX_BYTES)
        return ContentRevision(sha.removePrefix("sha256:"), length)
    }
    private fun JsonObject.text(key: String): String = getValue(key).jsonPrimitive.let { require(it.isString); it.content }
    private fun JsonObject.integer(key: String): Long = getValue(key).jsonPrimitive.let { require(!it.isString); it.long }
    private fun JsonObject.code(): String? = (get("code") as? JsonPrimitive)?.takeIf { it.isString }?.content
    private inline fun <T> validResponse(block: () -> T): T = try { block() } catch (_: Exception) { throw SafeFailure(SafeFailure.Reason.InvalidResponse) }
}
