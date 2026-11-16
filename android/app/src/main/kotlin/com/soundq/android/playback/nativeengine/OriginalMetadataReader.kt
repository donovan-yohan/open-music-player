package com.soundq.android.playback.nativeengine

/** Structural MP3 fields only, never encoded packet payload. A scan's capability
 * is lexical, thread/lease/operation-bound and revoked even on successful return.
 * Results stay private until the owner performs final full source validation. */
internal interface OriginalMetadataReader {
    fun <T> metadataScan(scan: (OriginalMetadataBatch) -> T): T
}

internal interface OriginalMetadataBatch {
    /** Charge traversal even when a header/checkpoint is already cached. */
    fun step()
    /** At most 16 structural bytes per request; attempted IO is charged. */
    fun readAt(position: Long, buffer: ByteArray, bufferOffset: Int, size: Int): Int
}
