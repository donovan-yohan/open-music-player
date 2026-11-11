package com.soundq.android.playback.nativeengine

import androidx.media3.common.MediaItem
import com.soundq.android.data.timeline.TimelineDocument
import com.soundq.android.playback.nativeArrangementPayload
import java.io.File

/** Immutable encoded candidate. No PCM or second renderer. Ownership transfers as one set. */
internal class NativeCallbackArrangement(
    val document: TimelineDocument,
    val revision: Long,
    val files: List<File>,
    private val clipFiles: List<File>,
    val values: LongArray,
    val tempo: DoubleArray? = null,
) {
    fun paths(): Array<String> = clipFiles.map { it.absolutePath }.toTypedArray()
    fun close() { files.forEach { it.delete() } }
    companion object {
        const val MAX_ENCODED_BYTES = 128L * 1024 * 1024
        fun prepare(document: TimelineDocument, revision: Long, items: List<MediaItem>, source: NativeCallbackSource, budget: Long = MAX_ENCODED_BYTES, current: () -> Boolean): NativeCallbackArrangement {
            require(budget in 1..MAX_ENCODED_BYTES) { "Arrangement exceeds encoded byte budget" }
            val payload=document.nativeArrangementPayload() // Full rate/fade/overlap validation before IO.
            require(document.clips.size in 1..500)
            val byOccurrence = items.associateBy { it.mediaId }
            require(document.clips.all { it.occurrence in byOccurrence })
            val files = linkedMapOf<String, File>()
            val clipFiles = mutableListOf<File>()
            var total = 0L
            var accepted = false
            try {
                document.clips.forEach { clip ->
                    check(current())
                    val item = byOccurrence.getValue(clip.occurrence)
                    val uri = requireNotNull(item.localConfiguration).uri.toString()
                    require(total < budget || uri in files) { "Arrangement exceeds encoded byte budget" }
                    val file = files[uri] ?: (if (source is GrantedNativeCallbackSource) source.prepareBounded(item, budget-total, current)
                        else source.prepare(item, current)).also {
                        files[uri] = it
                        val bytes = it.length()
                        require(bytes > 0 && bytes <= budget - total) { "Arrangement exceeds encoded byte budget" }
                        total += bytes
                    }
                    clipFiles.add(file)
                }
                check(current())
                // A full-source end is intentional EOF, not an explicit interior
                // trim. Native alone qualifies catalog rounding against decoded frames.
                return NativeCallbackArrangement(document, revision, files.values.toList(), clipFiles, payload.values, payload.tempo).also { accepted = true }
            } finally { if (!accepted) files.values.forEach { it.delete() } }
        }
    }
}
