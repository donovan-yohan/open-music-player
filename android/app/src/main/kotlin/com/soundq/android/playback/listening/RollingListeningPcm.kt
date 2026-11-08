package com.soundq.android.playback.listening

import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.datasource.*
import com.soundq.android.AppGraph
import com.soundq.android.playback.*
import com.soundq.android.playback.mix.NativeMix
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicBoolean

/** Root identity and accounting survive per-open decoder generations. Not a queue or clock. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class RollingListeningRoot(
    val graph: AppGraph,
    val grants: ConcurrentHashMap<String, MediaGrant>,
    items: List<MediaItem>,
    val schedule: ListeningSchedule,
    val valid: () -> Boolean,
) {
    data class Seal(val bytes: Long, val sha256: String)
    data class Snapshot(val slots: Int, val reservedBytes: Long, val slotHighWater: Int,
        val byteHighWater: Long, val acquisitions: List<String>, val actualBytes: Long, val actualByteHighWater: Long,
        val residentOccurrences: List<String>)
    class Slot(val occurrence: ListeningOccurrence) {
        var reserved = 0L
        var actual = 0L
        var file: File? = null
        var source: SignedAudioDataSource? = null
        var lane: Media3ListeningLane? = null
        var cursor: SequentialPcmCursor? = null
        var drain: CompletableFuture<Media3ListeningLane.DrainReceipt>? = null
        var failure: Throwable? = null
    }
    private val lock = Any()
    private val items = items.associateBy { it.mediaId }
    private val seals = mutableMapOf<String, Seal>()
    private val slots = mutableSetOf<Slot>()
    private var bytes = 0L
    private var slotHigh = 0
    private var byteHigh = 0L
    private var actualBytes = 0L
    private var actualHigh = 0L
    private val acquisitions = mutableListOf<String>()
    fun snapshot() = synchronized(lock) { Snapshot(slots.size, bytes, slotHigh, byteHigh, acquisitions.toList(), actualBytes, actualHigh,
        slots.map { it.occurrence.source.occurrence }) }
    fun reserve(c: ListeningOccurrence): Slot = synchronized(lock) {
        check(valid()); check(slots.size < 2) { "Rolling slots still borrowed" }; require(bytes < LIMIT) { "Encoded budget exhausted" }
        Slot(c).also {
            slots.add(it); slotHigh = maxOf(slotHigh, slots.size)
            // Reserve remaining capacity before open, including unknown-length acquisition.
            it.reserved = LIMIT - bytes; require(it.reserved > 0) { "Encoded budget exhausted" }
            bytes += it.reserved; byteHigh = maxOf(byteHigh, bytes)
            if(acquisitions.size == 64) acquisitions.removeAt(0)
            acquisitions.add(c.source.occurrence)
        }
    }
    private fun charge(s: Slot, n: Long) = synchronized(lock) {
        require(n >= 0 && n <= LIMIT - (bytes - s.reserved)) { "Encoded budget exceeded" }
        bytes += n - s.reserved; s.reserved = n; byteHigh = maxOf(byteHigh, bytes)
    }
    fun acquire(s: Slot, current: () -> Unit) {
        current()
        val source = SignedAudioDataSource(graph, grants); s.source = source
        val item = items.getValue(s.occurrence.source.occurrence)
        val announced = source.open(DataSpec(item.localConfiguration!!.uri))
        current()
        if (announced >= 0) charge(s, announced)
        val file = Files.createTempFile(graph.directory.toPath(), "listening-rolling-", ".encoded").toFile(); s.file = file
        val digest = MessageDigest.getInstance("SHA-256")
        var actual = 0L
        file.outputStream().use { out ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                current(); val n = source.read(buffer, 0, buffer.size); current()
                if (n < 0) break
                check(n > 0); actual = Math.addExact(actual, n.toLong())
                if (announced >= 0) require(actual <= announced) { "Source exceeded announced bytes" }
                else require(actual <= s.reserved) { "Unknown-length source exceeded budget" }
                out.write(buffer, 0, n); digest.update(buffer, 0, n)
                synchronized(lock) { s.actual += n; actualBytes += n; actualHigh = maxOf(actualHigh, actualBytes) }
            }
        }
        if (announced >= 0) require(actual == announced) { "Source byte extent mismatch" }
        charge(s, actual)
        try { source.close() } catch (failure: Throwable) { s.failure = failure; throw failure }
        s.source = null
        val seal = Seal(actual, digest.digest().joinToString("") { "%02x".format(it) })
        synchronized(lock) {
            val old = seals[s.occurrence.source.occurrence]
            require(old == null || old == seal) { "Occurrence encoded representation changed" }
            seals[s.occurrence.source.occurrence] = seal
        }
        current()
    }
    /** Only after concrete lane drain plus generation operation/JNI exit. Failure retains capacity. */
    fun dispose(s: Slot) {
        s.failure?.let { throw it }
        try {
            s.drain?.let {
                val receipt = it.get(15, TimeUnit.SECONDS)
                check(receipt.openSources == 0 && receipt.readsInFlight == 0) { "Rolling lane still borrows IO" }
            }
            s.source?.close(); s.source = null
            s.file?.let { check(!it.exists() || it.delete()) { "Rolling copy deletion failed" } }
            synchronized(lock) { check(slots.remove(s)); bytes -= s.reserved; s.reserved = 0; actualBytes -= s.actual; s.actual = 0 }
        } catch (failure: Throwable) { s.failure = failure; throw failure }
    }
    companion object { const val LIMIT = 128L * 1024 * 1024 }
}

/** Loader-owned exact global carry; only active participants own resource slots. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class RollingListeningPcm(private val root: RollingListeningRoot) : ListeningPcmGeneration {
    private val lock = Any()
    private val revoked = AtomicBoolean(false)
    private val slots = mutableMapOf<String, RollingListeningRoot.Slot>()
    private var operations = 0
    private var cleanupRunning = false
    override val drained = CompletableFuture<Void>()
    private val occurrences = root.schedule.occurrences
    private val frames = Math.multiplyExact(root.schedule.durationMs, 48)
    override val size = checkedSize(root.schedule)
    private val carry = ByteArray(2048 * 8)
    private var origin = -1L
    private var count = 0
    private val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
        put("RIFF".toByteArray()); putInt((size - 8).toInt()); put("WAVEfmt ".toByteArray()); putInt(16)
        putShort(3); putShort(2); putInt(48000); putInt(384000); putShort(8); putShort(32)
        put("data".toByteArray()); putInt((size - 44).toInt())
    }.array()
    private fun current() { check(!revoked.get() && root.valid()) { "Rolling generation retired" } }
    private inline fun <T> operation(body: () -> T): T {
        synchronized(lock) { current(); check(operations == 0); operations++ }
        try { return body() } finally { synchronized(lock) { operations-- }; cleanupLater() }
    }
    // No source IO at metadata/preparation admission, including late reopen.
    override fun prime() { current() }
    override fun read(position: Long, length: Int): ByteArray = operation {
        current()
        if (position < 44) return@operation header.copyOfRange(position.toInt(), minOf(44L, position + length).toInt())
        val data = position - 44
        val frame = data / 8
        if (origin < 0 || frame !in origin until origin + count) {
            check(origin < 0 || frame >= origin + count) { "Rolling cursor cannot rewind" }
            val active = occurrences.filter { frame >= it.startMs * 48 && frame < it.endMs * 48 }
            require(active.size in 1..2)
            val wanted = active.map { it.source.occurrence }.toSet()
            // Previous render operation exited, so no cursor/JNI window still borrows outgoing.
            slots.keys.filter { it !in wanted }.forEach { key ->
                val s = slots.getValue(key)
                check(s.cursor!!.completeExtent) { "Eviction before genuine source EOS" }
                requestDrain(s); root.dispose(s); synchronized(lock) { slots.remove(key) }
            }
            active.forEach { c ->
                if (c.source.occurrence !in slots) {
                    val s = root.reserve(c)
                    synchronized(lock) { slots[c.source.occurrence] = s }
                    root.acquire(s, ::current)
                    val lane = Media3ListeningLane(root.graph.applicationContext, Uri.fromFile(s.file!!),
                        DataSource.Factory { FileDataSource() }, { !revoked.get() && root.valid() })
                    synchronized(lock) { s.lane = lane; s.cursor = SequentialPcmCursor(lane, c.source.durationMs * 48) }
                    if (revoked.get()) requestDrain(s)
                    current()
                }
            }
            val boundary = occurrences.asSequence().flatMap { sequenceOf(it.startMs * 48, it.endMs * 48) }.filter { it > frame }.minOrNull() ?: frames
            val n = minOf(2048L, frames - frame, boundary - frame).toInt()
            val fields = mutableListOf<Long>()
            val windows = active.map { c ->
                val local = frame - c.startMs * 48
                val s = slots.getValue(c.source.occurrence)
                current()
                val samples = s.cursor!!.read(local, n)
                current()
                fields.addAll(listOf(occurrences.indexOf(c) + 1L, c.startMs * 48, c.endMs * 48,
                    0L, c.source.durationMs * 48, c.fadeInMs * 48, c.fadeOutMs * 48, local))
                samples
            }
            current()
            NativeMix.renderPcmBlock(frame, n, fields.toLongArray(), windows.toTypedArray(), FloatArray(windows.size) { 1f }, carry)
            current(); origin = frame; count = n
        }
        val offset = (data - origin * 8).toInt()
        current(); carry.copyOfRange(offset, offset + minOf(length, count * 8 - offset))
    }
    private fun requestDrain(s: RollingListeningRoot.Slot) {
        s.lane?.let { lane ->
            val future = lane.retireAndDrain()
            synchronized(lock) { if (s.drain == null) s.drain = future }
            future.whenComplete { _, _ -> cleanupLater() }
        }
    }
    override fun retire() {
        revoked.set(true)
        synchronized(lock) { slots.values.toList() }.forEach(::requestDrain)
        cleanupLater()
    }
    private fun cleanupLater() {
        val snapshot = synchronized(lock) {
            if (!revoked.get() || operations != 0 || cleanupRunning || drained.isDone) return
            cleanupRunning = true; slots.values.toList()
        }
        cleanup.execute {
            try {
                snapshot.forEach { requestDrain(it); root.dispose(it) }
                synchronized(lock) { slots.clear() }
                drained.complete(null)
            } catch (failure: Throwable) { drained.completeExceptionally(failure) }
        }
    }
    companion object {
        private val cleanup = Executors.newSingleThreadExecutor { r -> Thread(r, "soundq-rolling-custody").apply { isDaemon = true } }
        fun checkedSize(schedule: ListeningSchedule): Long = Math.addExact(44, Math.multiplyExact(Math.multiplyExact(schedule.durationMs, 48), 8)).also { require(it <= 0xfffffff0L) { "Finite listening WAV extent exceeded" } }
    }
}
