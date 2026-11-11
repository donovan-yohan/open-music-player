package com.soundq.android.playback.listening

import android.content.Context
import android.net.Uri
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.FileDataSource
import com.soundq.android.playback.mix.NativeMix
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CompletableFuture
import java.util.concurrent.atomic.AtomicBoolean

internal interface ListeningPcmGeneration {
    val size: Long
    val drained: CompletableFuture<Void>
    fun prime()
    fun read(position: Long, length: Int): ByteArray
    fun retire()
}

/** One forward-only decoder generation. Only its loader operation touches cursors/carry.
 * Retirement requests all concrete drains synchronously, but never waits for decoder IO.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class PrivateListeningPcm(
    private val context: Context,
    private val schedule: ListeningSchedule,
    private val files: Map<String, File>,
    private val valid: () -> Boolean,
) : ListeningPcmGeneration {
    private class Lane(val actual: Media3ListeningLane, val cursor: SequentialPcmCursor) {
        var drain: CompletableFuture<Media3ListeningLane.DrainReceipt>? = null
        var head: FloatArray? = null
    }
    private val lock = Any()
    private val revoked = AtomicBoolean(false)
    private val lanes = mutableListOf<Lane>()
    private var operations = 0
    private var initialized = false
    override val drained = CompletableFuture<Void>()
    private val frames = Math.multiplyExact(schedule.durationMs, 48)
    override val size = Math.addExact(44, Math.multiplyExact(frames, 8))
    private val carry = ByteArray(2048 * 8)
    private var carryOrigin = -1L
    private var carryFrames = 0
    private val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
        put("RIFF".toByteArray()); putInt((size - 8).toInt()); put("WAVEfmt ".toByteArray()); putInt(16)
        putShort(3); putShort(2); putInt(48000); putInt(384000); putShort(8); putShort(32)
        put("data".toByteArray()); putInt((size - 44).toInt())
    }.array()

    init { require(size <= 0xfffffff0L) }
    private fun checkCurrent() { check(!revoked.get() && valid()) { "PCM generation retired" } }

    private inline fun <T> operation(body: () -> T): T {
        synchronized(lock) { check(!revoked.get()); check(operations == 0); operations++ }
        try { checkCurrent(); return body() } finally {
            synchronized(lock) { operations-- }
            finishDrain()
        }
    }

    /** One retained stereo frame per occurrence forces actual MP3 admission before readiness.
     * This is not whole-source duration proof; the cursor still demands exact extent and real EOS.
     */
    override fun prime() = operation {
        check(!initialized)
        schedule.occurrences.forEach { c ->
            checkCurrent()
            val actual = Media3ListeningLane(context, Uri.fromFile(files.getValue(c.source.occurrence)),
                DataSource.Factory { FileDataSource() }, { !revoked.get() && valid() })
            val lane = Lane(actual, SequentialPcmCursor(actual, Math.multiplyExact(c.source.durationMs, 48)))
            val bornRetired = synchronized(lock) { lanes.add(lane); revoked.get() }
            if (bornRetired) requestDrain(lane)
            checkCurrent()
            lane.head = lane.cursor.read(0, 1)
            checkCurrent()
        }
        initialized = true
    }

    /** Returns private bytes. PreparedListening fences the final caller-buffer publication. */
    override fun read(position: Long, length: Int): ByteArray = operation {
        check(initialized)
        if (position < 44) return@operation header.copyOfRange(position.toInt(), minOf(44L, position + length).toInt())
        val data = position - 44
        val frame = data / 8
        val block = frame / 2048 * 2048
        if (carryOrigin != block) {
            check(carryOrigin < block) { "Forward PCM generation cannot seek backwards" }
            val count = minOf(2048L, frames - block).toInt()
            val fields = mutableListOf<Long>()
            val windows = mutableListOf<FloatArray>()
            schedule.occurrences.forEachIndexed { i, c ->
                val start = Math.multiplyExact(c.startMs, 48)
                val end = Math.multiplyExact(c.endMs, 48)
                val left = maxOf(block, start)
                val right = minOf(block + count, end)
                if (left < right) {
                    checkCurrent()
                    val local = left - start
                    val n = (right - left).toInt()
                    val lane = lanes[i]
                    val head = lane.head
                    val samples = if (local == 0L && head != null) {
                        FloatArray(n * 2).also { out ->
                            head.copyInto(out)
                            if (n > 1) lane.cursor.read(1, n - 1).copyInto(out, 2)
                        }
                    } else lane.cursor.read(local, n)
                    lane.head = null
                    checkCurrent()
                    fields.addAll(listOf(i + 1L, start, end, 0L, Math.multiplyExact(c.source.durationMs, 48),
                        Math.multiplyExact(c.fadeInMs, 48), Math.multiplyExact(c.fadeOutMs, 48), local))
                    windows.add(samples)
                }
            }
            checkCurrent()
            NativeMix.renderPcmBlock(block, count, fields.toLongArray(), windows.toTypedArray(), FloatArray(windows.size) { 1f }, carry)
            checkCurrent()
            carryOrigin = block; carryFrames = count
        }
        val offset = (data - carryOrigin * 8).toInt()
        checkCurrent()
        carry.copyOfRange(offset, offset + minOf(length, carryFrames * 8 - offset))
    }

    override fun retire() {
        revoked.set(true)
        val snapshot = synchronized(lock) { lanes.toList() }
        snapshot.forEach(::requestDrain)
        finishDrain()
    }

    private fun requestDrain(lane: Lane) {
        // retireAndDrain itself is nonblocking and idempotent. Register the actual returned future.
        val future = lane.actual.retireAndDrain()
        val observe = synchronized(lock) {
            if (lane.drain == null) { lane.drain = future; true } else false
        }
        if (observe) future.whenComplete { _, _ -> finishDrain() }
    }

    private fun finishDrain() {
        val terminal = synchronized(lock) {
            if (!revoked.get() || operations != 0 || lanes.any { it.drain?.isDone != true }) return
            // isDone is not a receipt: completion callbacks can be arbitrarily delayed.
            // Inspect each concrete future directly before publishing the aggregate barrier.
            try {
                lanes.forEach { lane ->
                    val receipt = lane.drain!!.join()
                    check(receipt.openSources == 0 && receipt.readsInFlight == 0) { "PCM lane still owns source IO" }
                }
                null
            } catch (failure: Throwable) { failure }
        }
        if (terminal == null) drained.complete(null) else drained.completeExceptionally(terminal)
    }
}
