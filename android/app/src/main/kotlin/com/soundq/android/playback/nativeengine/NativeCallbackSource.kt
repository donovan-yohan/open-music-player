package com.soundq.android.playback.nativeengine

import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.datasource.DataSpec
import com.soundq.android.AppGraph
import com.soundq.android.playback.MediaGrant
import com.soundq.android.playback.SignedAudioDataSource
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CancellationException

/** One immutable encoded file. Native borrows this path until concrete unload or close. */
internal fun interface NativeCallbackSource {
    fun prepare(item: MediaItem, current: () -> Boolean): File
}

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class GrantedNativeCallbackSource(
    private val graph: AppGraph,
    private val grants: ConcurrentHashMap<String, MediaGrant>,
) : NativeCallbackSource {
    override fun prepare(item: MediaItem, current: () -> Boolean): File {
        val permit=grants[item.localConfiguration?.uri.toString()] ?: error("Source grant required")
        val device=permit.device ?: return prepareBounded(item, MAX_BYTES, current)
        return kotlinx.coroutines.runBlocking {
            check(current()&&permit.current(graph))
            val row=graph.phoneAudio.observed(device) ?: error("Phone audio unavailable")
            val admission=graph.phoneAudio.admit(row) ?: error("Phone source retired")
            try {graph.phoneAudio.prepare(admission) {current()&&grants[item.localConfiguration?.uri.toString()]===permit&&permit.current(graph)}.also {permit.phoneAdmission=admission}}
            catch(failure:Exception){if(current()&&permit.current(graph))graph.phoneAudio.reportFailure(admission,failure);throw failure}
        }
    }
    internal fun prepareBounded(item: MediaItem, maxBytes: Long, current: () -> Boolean): File {
        require(maxBytes in 1..MAX_BYTES)
        val uri = requireNotNull(item.localConfiguration).uri
        val grant = requireNotNull(grants[uri.toString()])
        require(uri.scheme == "soundq")
        fun checkCurrent() {
            if (!current() || grants[uri.toString()] !== grant) throw CancellationException("Source retired")
            graph.session.checkScope(grant.scope)
        }
        checkCurrent()
        val file = File.createTempFile("callback-", ".encoded", graph.directory)
        var accepted = false
        val source = SignedAudioDataSource(graph, grants)
        try {
            checkCurrent()
            val expected = source.open(DataSpec.Builder().setUri(uri).build())
            require(expected == C.LENGTH_UNSET.toLong() || expected in 1..maxBytes)
            file.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    checkCurrent()
                    // One extra byte detects dishonest known lengths and unknown length overflow.
                    val limit = minOf(buffer.size.toLong(), maxBytes - total + 1).toInt()
                    val count = source.read(buffer, 0, limit)
                    checkCurrent()
                    if (count == C.RESULT_END_OF_INPUT) break
                    check(count > 0) { "Encoded source made no progress" }
                    total += count
                    require(total <= maxBytes && (expected == C.LENGTH_UNSET.toLong() || total <= expected))
                    output.write(buffer, 0, count)
                }
                require(total > 0 && (expected == C.LENGTH_UNSET.toLong() || total == expected))
            }
            checkCurrent()
            accepted = true
            return file
        } finally {
            try { source.close() }
            catch (failure: Exception) { accepted = false; throw failure }
            finally { if (!accepted) file.delete() }
        }
    }

    companion object { const val MAX_BYTES = 128L * 1024 * 1024 }
}
