package com.soundq.android.playback.nativeengine

import java.io.File
import java.nio.ByteBuffer

/** Worker-owned decoder peer. Neither an audible player nor a second clock. */
@androidx.annotation.Keep
internal interface NativePcmReader {
    fun open(): Int
    fun read(first: Long, count: Int, destination: ByteBuffer): Int
    /** Zero is unknown. Positive is a same-source, decoded-EOS exact endpoint. */
    fun endFrames(): Long
    /** Real decoded sample strictly beyond 600 seconds, not a duration estimate. */
    fun longFormConfirmed(): Boolean = false
    fun revoke()
    /** Must complete codec, extractor AND original descriptor release. */
    fun closeReader(): Boolean
}

/** Lifetime authority is explicit. Automatic release never unlinks an original. */
internal sealed interface NativePlaybackSource {
    fun release(): Boolean
    data class OwnedTemporary(val file: File) : NativePlaybackSource {
        override fun release() = !file.exists() || file.delete()
    }
    class BorrowedOriginal(
        val reader: NativePcmReader,
        val resumeMs: Long,
        /** Presentation/journal eligibility hint, never an exact PCM endpoint. */
        val durationHintMs: Long?,
        /** Physical catalog identity for target-scoped destructive drain checks. */
        val physicalFileId: String? = null,
        val versionCurrent: () -> Boolean,
    ) : NativePlaybackSource {
        override fun release() = reader.closeReader()
    }
}
