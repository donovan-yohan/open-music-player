package com.soundq.android.playback.listening

import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.datasource.*
import com.soundq.android.AppGraph
import com.soundq.android.playback.*
import com.soundq.android.playback.mix.*
import java.io.File
import java.nio.file.Files
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicBoolean

/** Internal single-output WAV source. Acquisition copies are not offline entitlements.
 * State reservations/publication are short; acquisition, decoder waits and JNI never own lock.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class PreparedListening private constructor(private val valid: () -> Boolean) : AutoCloseable {
    private val lock = Object()
    private val revoked = AtomicBoolean(false)
    val released = CompletableFuture<Void>()
    private val files = mutableListOf<File>()
    private val sources = mutableListOf<SignedAudioDataSource>()
    private var opus: NativeMixStream? = null
    private var pcm: ListeningPcmGeneration? = null
    private var newPcm: (() -> ListeningPcmGeneration)? = null
    private var rolling: RollingListeningRoot? = null
    fun residency() = rolling?.snapshot()
    private var claimed = false
    private var operations = 1 // preparation, including lane construction
    private var readers = 0
    private var busy = false
    private var opening = false
    private var current: Any? = null
    private var size = 0L
    private var disposed = false
    private var cleanupFailure: Throwable? = null

    private fun checkCurrent() { check(!revoked.get() && valid()) { "Listening owner retired" } }
    private fun finishOperation() {
        synchronized(lock) { operations--; lock.notifyAll() }
        cleanupLater()
    }
    private fun cleanupLater() {
        if (!revoked.get()) return
        // Opus has no asynchronous decoder lifetime; retain its existing synchronous receipt.
        if (newPcm == null) disposeIfDrained() else cleanup.execute { disposeIfDrained() }
    }
    private fun register(generation: ListeningPcmGeneration) {
        val retired = synchronized(lock) { pcm = generation; revoked.get() }
        generation.drained.whenComplete { _, _ -> cleanupLater() }
        if (retired) generation.retire()
    }

    fun acquire(): DataSource {
        checkCurrent()
        return object : DataSource {
            private var token: Any? = null
            private var pending: Any? = null
            private var generation: ListeningPcmGeneration? = null
            private var position = 0L
            private var remaining = 0L
            override fun addTransferListener(transferListener: TransferListener) {}
            override fun getUri(): Uri? = null
            override fun open(dataSpec: DataSpec): Long {
                require(dataSpec.uri.scheme == "soundqlistening")
                require(dataSpec.position in 0..size && (dataSpec.length == -1L || dataSpec.length > 0))
                val next = Any()
                val predecessor: ListeningPcmGeneration?
                val restart: Boolean
                synchronized(lock) {
                    checkCurrent(); check(token == null && !opening) { "Listening open already active" }
                    opening = true; operations++
                    current = next; pending = next
                    predecessor = pcm
                    restart = claimed
                    claimed = true
                }
                var openedGeneration = predecessor
                try {
                    if (restart) {
                        predecessor?.retire()
                        predecessor?.drained?.get(15000, TimeUnit.MILLISECONDS)
                        // A successful concrete drain is necessary, but cannot erase an active read/JNI.
                        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
                        synchronized(lock) {
                            while (busy) {
                                checkCurrent()
                                val left = deadline - System.nanoTime()
                                check(left > 0) { "Listening operation did not exit" }
                                TimeUnit.NANOSECONDS.timedWait(lock, left)
                            }
                        }
                        synchronized(lock) { checkCurrent(); check(pending === next && current === next) }
                        newPcm?.invoke()?.let { fresh ->
                            openedGeneration = fresh
                            register(fresh)
                            val accepted = synchronized(lock) { pending === next && current === next }
                            if (!accepted) fresh.retire()
                            check(accepted) { "Listening open cancelled" }
                            fresh.prime()
                        }
                    }
                    synchronized(lock) {
                        checkCurrent(); check(current === next && pending === next)
                        pending = null; token = next; generation = pcm; readers++
                        position = dataSpec.position
                        remaining = if (dataSpec.length < 0) size - position else minOf(dataSpec.length, size - position)
                        return remaining
                    }
                } catch (failure: Throwable) {
                    if (openedGeneration != null && failure is InterruptedException &&
                        failure.suppressed.all { it is InterruptedException }) {
                        synchronized(lock) { if (current === next) current = null }
                        openedGeneration.retire()
                        Thread.currentThread().interrupt()
                        throw java.io.InterruptedIOException("Listening open interrupted").apply { initCause(failure) }
                    }
                    // A failed restart never permits another generation to bypass its predecessor.
                    val ownsFailure = synchronized(lock) {
                        (current === next).also { if (it) revoked.set(true) }
                    }
                    if (ownsFailure) closeOwnerOnFailure(failure)
                    throw failure
                } finally {
                    synchronized(lock) { pending = null; opening = false }
                    finishOperation()
                }
            }
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                require(offset >= 0 && length >= 0 && offset <= buffer.size && length <= buffer.size - offset)
                val captured: Any
                val at: Long
                val count: Int
                val decoder: ListeningPcmGeneration?
                synchronized(lock) {
                    checkCurrent(); captured = checkNotNull(token); check(current === captured && !busy)
                    if (length == 0) return 0
                    if (remaining == 0L) return -1
                    busy = true; operations++
                    at = position; count = minOf(length.toLong(), remaining, 2048L * 8).toInt()
                    decoder = generation
                }
                try {
                    val bytes = if (decoder != null) decoder.read(at, count) else {
                        ByteArray(count).let { scratch ->
                            val n = opus!!.read(at, scratch, 0, count)
                            check(n > 0); scratch.copyOf(n)
                        }
                    }
                    synchronized(lock) {
                        checkCurrent(); check(token === captured && current === captured) { "Listening read superseded" }
                        bytes.copyInto(buffer, offset)
                        position += bytes.size; remaining -= bytes.size
                        return bytes.size
                    }
                } catch (failure: Throwable) {
                    // A loader interruption retires this forward cursor, not its preparation.
                    // Receipt/extent failures, including failed cleanup, remain terminal.
                    if (decoder != null && failure is InterruptedException &&
                        failure.suppressed.all { it is InterruptedException }) {
                        synchronized(lock) { if (current === captured) current = null }
                        decoder.retire()
                        Thread.currentThread().interrupt()
                        throw java.io.InterruptedIOException("Listening load interrupted").apply { initCause(failure) }
                    }
                    val ownsFailure = synchronized(lock) {
                        (current === captured).also { if (it) revoked.set(true) }
                    }
                    if (ownsFailure) closeOwnerOnFailure(failure) else decoder?.retire()
                    throw failure
                } finally {
                    synchronized(lock) { busy = false; lock.notifyAll() }
                    finishOperation()
                }
            }
            override fun close() {
                val old = synchronized(lock) {
                    if (pending != null) {
                        if (current === pending) current = null
                        pending = null
                        pcm?.retire()
                    }
                    if (token == null) return
                    if (current === token) current = null
                    token = null; readers--; generation.also { generation = null }
                }
                old?.retire()
                // Preserve the existing native-only loader-close receipt. There is no decoder
                // wait on this path; PCM cleanup is always off the application/loader caller.
                if (newPcm == null) disposeIfDrained() else cleanupLater()
            }
        }
    }
    private fun closeOwnerOnFailure(failure: Throwable) {
        try { close() } catch (cleanup: Throwable) { if (failure !== cleanup) failure.addSuppressed(cleanup) }
    }
    override fun close() {
        revoked.set(true)
        val old = synchronized(lock) {
            if (disposed) return
            custodians.add(this)
            current = null; lock.notifyAll(); pcm
        }
        old?.retire() // every registered lane has received its concrete drain request on return
        cleanupLater()
    }
    private fun disposeIfDrained() {
        synchronized(lock) {
            if (disposed || !revoked.get() || readers != 0 || operations != 0) return
            val drain = pcm?.drained
            if (drain != null && (!drain.isDone || drain.isCompletedExceptionally || drain.isCancelled)) return
            // Reserve disposal before releasing lock; no new operations can enter a retired root.
            if (cleanupFailure != null) return
            disposed = true
        }
        try {
            opus?.close(); opus = null
            sources.forEach { it.close() }
            files.forEach { check(!it.exists() || it.delete()) { "Listening copy deletion failed" } }
            sources.clear(); files.clear(); pcm = null
            custodians.remove(this)
            released.complete(null)
        } catch (failure: Throwable) {
            // Retain strong ownership on *any* cleanup failure. Never delete in finally.
            synchronized(lock) { cleanupFailure = failure; disposed = false }
        }
    }

    companion object {
        private val custodians = ConcurrentHashMap.newKeySet<PreparedListening>()
        private val cleanup = Executors.newSingleThreadExecutor { r -> Thread(r, "soundq-listening-custody").apply { isDaemon = true } }
        fun prepareRolling(graph: AppGraph, grants: ConcurrentHashMap<String, MediaGrant>, items: List<MediaItem>, schedule: ListeningSchedule, valid: () -> Boolean): PreparedListening {
            RollingListeningPcm.checkedSize(schedule)
            require(items.isNotEmpty() && items.map { it.mediaId }.toSet() == schedule.occurrences.map { it.source.occurrence }.toSet())
            require(items.map { it.mediaId }.distinct().size == items.size)
            val result = PreparedListening(valid)
            try {
                val root = RollingListeningRoot(graph, grants, items.toList(), schedule) { !result.revoked.get() && valid() }
                result.rolling = root
                result.newPcm = { RollingListeningPcm(root) }
                val generation = result.newPcm!!.invoke()
                result.register(generation); generation.prime(); result.size = generation.size
                result.checkCurrent()
                return result
            } catch (failure: Throwable) { result.closeOwnerOnFailure(failure); throw failure }
            finally { result.finishOperation() }
        }
        fun prepare(graph: AppGraph, grants: ConcurrentHashMap<String, MediaGrant>, items: List<MediaItem>, schedule: ListeningSchedule, valid: () -> Boolean): PreparedListening {
            val result = PreparedListening(valid)
            try {
                require(items.isNotEmpty() && items.map { it.mediaId }.toSet() == schedule.occurrences.map { it.source.occurrence }.toSet())
                require(items.map { it.mediaId }.distinct().size == items.size)
                var bytes = 0L
                val opusFlags = mutableListOf<Boolean>()
                val paths = items.associate { item ->
                    result.checkCurrent()
                    val source = SignedAudioDataSource(graph, grants); result.sources.add(source)
                    val length = source.open(DataSpec(item.localConfiguration!!.uri))
                    require(length <= 128L * 1024 * 1024 - bytes)
                    val file = Files.createTempFile(graph.directory.toPath(), "listening-", ".encoded").toFile(); result.files.add(file)
                    file.outputStream().use { out ->
                        val block = ByteArray(64 * 1024)
                        while (true) {
                            result.checkCurrent(); val n = source.read(block, 0, block.size); result.checkCurrent()
                            if (n < 0) break
                            check(n > 0); bytes = Math.addExact(bytes, n.toLong()); require(bytes <= 128L * 1024 * 1024)
                            out.write(block, 0, n)
                        }
                    }
                    result.checkCurrent()
                    val head = ByteArray(64); file.inputStream().use { check(it.read(head) == head.size) }
                    val marker = "OpusHead".toByteArray()
                    val at = (0..head.size - marker.size).firstOrNull { i -> marker.indices.all { head[i + it] == marker[it] } }
                    opusFlags.add(at != null)
                    if (at != null) {
                        require(at + 12 <= head.size)
                        val preSkip = (head[at + 10].toInt() and 255) or ((head[at + 11].toInt() and 255) shl 8)
                        val duration = schedule.occurrences.single { it.source.occurrence == item.mediaId }.source.durationMs
                        NativeMix.probe(file.absolutePath, Math.multiplyExact(duration, 48), preSkip.toLong())
                    }
                    item.mediaId to file
                }
                result.checkCurrent()
                require(opusFlags.all { it } || opusFlags.none { it }) { "Mixed MP3/Opus listening sources are unsupported" }
                if (opusFlags.all { it }) {
                    result.opus = NativeMixStream(schedule.renderPlan(paths.mapValues { it.value.absolutePath }))
                    result.size = result.opus!!.size
                } else {
                    result.newPcm = { PrivateListeningPcm(graph.applicationContext, schedule, paths) { !result.revoked.get() && valid() } }
                    val generation = result.newPcm!!.invoke()
                    result.register(generation); generation.prime(); result.size = generation.size
                }
                result.checkCurrent()
                return result
            } catch (failure: Throwable) {
                result.closeOwnerOnFailure(failure); throw failure
            } finally { result.finishOperation() }
        }
    }
}
