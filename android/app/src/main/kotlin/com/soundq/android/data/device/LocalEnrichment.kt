package com.soundq.android.data.device

import com.soundq.android.data.SafeFailure
import com.soundq.android.data.catalog.RecordingMbid
import com.soundq.android.data.catalog.ReleaseGroupMbid
import com.soundq.android.data.catalog.ReleaseMbid
import com.soundq.android.data.deviceaudio.DeviceAudio
import com.soundq.android.data.deviceaudio.LocalDisplayText
import com.soundq.android.data.deviceaudio.validLocalDisplayText
import kotlinx.serialization.json.*
import java.text.Normalizer

internal const val LOCAL_ENRICHMENT_PATH = "/musicbrainz/local-enrichment/suggestions"

/** A closed sheet never renews. Close leaves the gate before cancelling network/artwork work. */
internal class EnrichmentVisitGate {
    @Volatile private var open = true
    fun active() = open
    @Synchronized fun retire(): Boolean = open.also { open = false }
    @Synchronized fun replaceIfActive(replace: () -> Boolean): Boolean = open && replace()
}

private const val MAX_DURATION_MS = 86_400_000L
private val mediaExtension = "mp3|m4a|mp4|m4b|aac|alac|flac|wav|wave|aif|aiff|aifc|ogg|oga|opus|wma|amr|ape|mka|mkv|webm|dsf|dff|m3u8?|pls"
private val suffix = Regex("(?i)\\.(?:$mediaExtension)$")
private val sourceLike = Regex(
    """(?i)(?:\b[a-z][a-z0-9+.-]*:[^\s]|\bwww\.|%[0-9a-f]{2}|\b[0-9a-f]{32,}\b|\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b|\b[\p{Alnum}._%+-]+@[\p{Alnum}.-]+\.[a-z]{2,}\b|\.(?:$mediaExtension)\b)""",
)
private fun termAllowed(text: String): Boolean {
    if (!validLocalDisplayText(text) || !text.codePoints().anyMatch {
            Character.isLetter(it) || Character.getType(it) in Character.DECIMAL_DIGIT_NUMBER..Character.OTHER_NUMBER
        }) return false
    // Normalize only for refusal, never mutate the reviewed value sent to the server.
    val folded = Normalizer.normalize(text, Normalizer.Form.NFKC)
    return folded.none { it in "/\\∕⁄⧵" } && !sourceLike.containsMatchIn(folded)
}

/** Only these exact, displayed terms can be serialized. No source/ref/account argument. */
internal class LocalEnrichmentTerms private constructor(
    val title: String, val artist: String?, val album: String?, val durationMs: Long?,
) {
    fun json(): JsonObject = buildJsonObject {
        put("title", title)
        artist?.let { put("artist", it) }
        album?.let { put("album", it) }
        durationMs?.let { put("durationMs", it) }
    }
    override fun toString() = "LocalEnrichmentTerms([redacted])"

    companion object {
        fun reviewed(title: String, artist: String, album: String, durationMs: Long?): LocalEnrichmentTerms? {
            val fields = listOf(title, artist, album).filter { it.isNotEmpty() }
            if (title.isEmpty() || fields.any { !termAllowed(it) } || fields.sumOf { it.codePointCount(0, it.length) } > 450 ||
                durationMs != null && durationMs !in 1..MAX_DURATION_MS) return null
            return LocalEnrichmentTerms(title, artist.ifEmpty { null }, album.ifEmpty { null }, durationMs)
                .takeIf { it.json().toString().toByteArray(Charsets.UTF_8).size <= 4096 }
        }
    }
}

internal class LocalEnrichmentDraft(val title: String, val artist: String, val album: String, val durationMs: Long?) {
    override fun toString() = "LocalEnrichmentDraft([redacted])"
    companion object {
        fun from(row: DeviceAudio): LocalEnrichmentDraft {
            fun safe(value: String?) = value?.trim()?.takeIf(::termAllowed).orEmpty()
            val filename = row.metadata.filename
            val tag = row.displayOverride?.text?.title ?: row.metadata.title?.takeIf { it.isNotBlank() && it != filename }
            // A path from a malformed provider is not a basename and must not be mined for terms.
            val basename = filename.takeIf { it.none { ch -> ch in "/\\∕⁄⧵:" } && suffix.containsMatchIn(it) }
                ?.replace(suffix, "")
            // MediaStore synthesizes ALBUM from the containing directory when no embedded tag
            // exists. That projected value has no tag provenance: leave it out unless it is
            // an accepted SoundQ value or the listener deliberately fills the optional field.
            return LocalEnrichmentDraft(safe(tag ?: basename), safe(row.displayArtist), safe(row.displayOverride?.text?.album),
                row.durationMs?.takeIf { it in 1..MAX_DURATION_MS })
        }
    }
}

internal class LocalEnrichmentCandidate(
    val recording: RecordingMbid, val text: LocalDisplayText, val durationMs: Long?,
    val release: ReleaseMbid?, val releaseGroup: ReleaseGroupMbid?,
)

internal sealed interface LocalEnrichmentReply {
    class Suggestions(val candidates: List<LocalEnrichmentCandidate>) : LocalEnrichmentReply
    data object Ambiguous : LocalEnrichmentReply
    data object NoMatch : LocalEnrichmentReply
    data object Disabled : LocalEnrichmentReply
    data object SignIn : LocalEnrichmentReply
    data object Busy : LocalEnrichmentReply
    data object InvalidTerms : LocalEnrichmentReply
    data object Unavailable : LocalEnrichmentReply

    companion object {
        fun decode(body: JsonObject): LocalEnrichmentReply {
            try {
                fun JsonObject.text(name: String): String? = get(name)?.jsonPrimitive?.let { require(it.isString); it.content }
                fun JsonObject.id(name: String): String? = text(name)?.also { require(it != "00000000-0000-0000-0000-000000000000") }
                val rows = body.getValue("candidates").jsonArray
                require(rows.size <= 3)
                val candidates = rows.map {
                    val row = it.jsonObject
                    require(row.keys.all { key -> key in setOf("recordingMbid", "title", "artist", "album", "durationMs", "releaseMbid", "releaseGroupMbid") })
                    val duration = row["durationMs"]?.jsonPrimitive?.let { value ->
                        require(!value.isString); value.long.also { ms -> require(ms in 1..MAX_DURATION_MS) }
                    }
                    LocalEnrichmentCandidate(RecordingMbid(requireNotNull(row.id("recordingMbid"))),
                        LocalDisplayText(requireNotNull(row.text("title")), row.text("artist"), row.text("album")), duration,
                        row.id("releaseMbid")?.let(::ReleaseMbid), row.id("releaseGroupMbid")?.let(::ReleaseGroupMbid))
                }
                require(candidates.distinctBy { it.recording }.size == candidates.size)
                val reason = body.text("reason")
                require(body.keys.all { it in setOf("status", "reason", "candidates") })
                return when (body.text("status")) {
                    "suggestions" -> Suggestions(candidates.also { require(it.isNotEmpty() && reason == null) })
                    "ambiguous" -> Ambiguous.also { require(candidates.size >= 2 && reason == "similar_candidates") }
                    "no_match" -> NoMatch.also { require(candidates.isEmpty() && reason == null) }
                    else -> error("Invalid lookup status")
                }
            } catch (_: Exception) {
                throw SafeFailure(SafeFailure.Reason.InvalidResponse)
            }
        }
    }
}
