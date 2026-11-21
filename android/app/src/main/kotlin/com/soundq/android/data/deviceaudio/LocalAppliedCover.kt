package com.soundq.android.data.deviceaudio

import java.security.MessageDigest
import java.util.Base64

/** A locally encoded, bounded thumbnail plus exact public CAA provenance, never a fetch URL. */
internal class LocalAppliedCover private constructor(val kind: Kind, val mbid: String,
    val jpegBase64: String, val sha256: String) {
    enum class Kind { RELEASE, RELEASE_GROUP }

    fun jpeg(): ByteArray = Base64.getDecoder().decode(jpegBase64)
    override fun equals(other: Any?): Boolean = other is LocalAppliedCover && kind == other.kind &&
        mbid == other.mbid && sha256 == other.sha256 && jpegBase64 == other.jpegBase64
    override fun hashCode(): Int = sha256.hashCode()
    override fun toString() = "LocalAppliedCover([redacted])"

    companion object {
        const val MAX_IMAGE_BYTES = 48 * 1024
        // Encoded bytes across the entire listening store; no eviction of accepted metadata.
        const val MAX_STORED_CHARS = 2 * 1024 * 1024
        private const val MAX_IMAGE_CHARS = MAX_IMAGE_BYTES / 3 * 4
        private val id = Regex("[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
        private fun digest(jpeg: ByteArray) = buildString(64) {
            val hex = "0123456789abcdef"
            for (byte in MessageDigest.getInstance("SHA-256").digest(jpeg)) {
                val value = byte.toInt() and 255
                append(hex[value ushr 4]); append(hex[value and 15])
            }
        }

        fun encoded(kind: Kind, mbid: String, jpeg: ByteArray): LocalAppliedCover =
            restore(kind, mbid, Base64.getEncoder().encodeToString(jpeg.also { require(it.size <= MAX_IMAGE_BYTES) }), digest(jpeg))

        fun restore(kind: Kind, mbid: String, encoded: String, sha256: String): LocalAppliedCover {
            require(id.matches(mbid) && mbid != "00000000-0000-0000-0000-000000000000")
            require(encoded.length in 1..MAX_IMAGE_CHARS && sha256.length == 64)
            val jpeg = Base64.getDecoder().decode(encoded)
            require(jpeg.size in 5..MAX_IMAGE_BYTES && jpeg[0] == 0xff.toByte() && jpeg[1] == 0xd8.toByte() &&
                jpeg[jpeg.lastIndex - 1] == 0xff.toByte() && jpeg.last() == 0xd9.toByte())
            require(Base64.getEncoder().encodeToString(jpeg) == encoded && digest(jpeg) == sha256)
            return LocalAppliedCover(kind, mbid, encoded, sha256)
        }
    }
}