package com.soundq.android.playback.listening

import java.nio.ByteOrder
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit

/** One occurrence's forward-only source reader. Call read on one loader thread, never an audio callback.
 * The lane must admit 2048-frame demands. It remains the sole decoder/extractor lifetime owner.
 * No tail correction or duration normalization. A final read also requires real EOS and lane drain.
 */
internal class SequentialPcmCursor private constructor(
    private val sourceFrames: Long,
    private val next: (Int) -> CompletableFuture<ListeningMemoryOutput.Window?>,
    private val drain: () -> CompletableFuture<Media3ListeningLane.DrainReceipt>,
    private val timeoutMs: Long,
) : AutoCloseable {
    constructor(lane: Media3ListeningLane, sourceFrames: Long, timeoutMs: Long = 15000) :
        this(sourceFrames, lane::next, lane::retireAndDrain, timeoutMs)

    private enum class State { OPEN, COMPLETE, CLOSED, FAILED }
    private val lock = Any()
    private var state = State.OPEN
    private var reading = false
    private var position = 0L
    private var nextOrigin = 0L
    private var carry: ListeningMemoryOutput.Window? = null
    private var drainFuture: CompletableFuture<Media3ListeningLane.DrainReceipt>? = null

    init { require(sourceFrames > 0 && timeoutMs > 0) }

    /** Only a successful concrete drain permits the caller to release borrowed source-file custody. */
    val retiredSuccessfully: Boolean get() = synchronized(lock) {
        val future = drainFuture
        future != null && future.isDone && !future.isCompletedExceptionally && !future.isCancelled &&
            future.getNow(null).let { it.openSources == 0 && it.readsInFlight == 0 }
    }
    val completeExtent: Boolean get() = synchronized(lock) { state == State.COMPLETE && retiredSuccessfully }

    /** Exact original source interval. A forward gap is consumed, not sought or filled with silence.
     * The returned array is caller-owned, <=2048 stereo frames, and ready for synchronous JNI.
     * Use sourceFrame unchanged as the native descriptor's window-origin field.
     */
    fun read(sourceFrame: Long, frameCount: Int): FloatArray {
        synchronized(lock) {
            check(state == State.OPEN) { "PCM cursor retired" }
            check(!reading) { "Only one cursor read may be outstanding" }
            require(frameCount in 1..2048 && sourceFrame >= position && sourceFrame <= sourceFrames &&
                frameCount.toLong() <= sourceFrames - sourceFrame) { "Invalid forward PCM interval" }
            reading = true
        }
        try {
            val end = sourceFrame + frameCount
            val samples = FloatArray(frameCount * 2)
            while (true) {
                val finished = synchronized(lock) {
                    check(state == State.OPEN) { "PCM cursor retired" }
                    position == end
                }
                if (finished) break
                val resident = synchronized(lock) { carry } ?: fetchWindow().also { window ->
                    synchronized(lock) {
                        check(state == State.OPEN) { "PCM cursor retired" }
                        checkNotNull(window) { "PCM source ended before declared extent" }
                        validate(window)
                        carry = window
                    }
                }!!
                synchronized(lock) {
                    check(state == State.OPEN) { "PCM cursor retired" }
                    val stop = minOf(end, resident.startFrame + resident.frameCount)
                    val copyStart = maxOf(position, sourceFrame)
                    if (copyStart < stop) {
                        val data = resident.stereoFloatLE.order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
                        data.position(((copyStart - resident.startFrame) * 2).toInt())
                        data.get(samples, ((copyStart - sourceFrame) * 2).toInt(), ((stop - copyStart) * 2).toInt())
                    }
                    position = stop
                    if (position == resident.startFrame + resident.frameCount) carry = null
                }
            }
            if (end == sourceFrames) {
                check(fetchWindow() == null) { "PCM source exceeds declared extent" }
                val future = synchronized(lock) {
                    check(state == State.OPEN) { "PCM cursor retired before EOS publication" }
                    retire(State.COMPLETE)
                }
                awaitDrain(future)
            }
            return synchronized(lock) {
                check(state == State.OPEN || state == State.COMPLETE) { "PCM cursor retired before publication" }
                samples
            }
        } catch (failure: Throwable) {
            val future = synchronized(lock) { retire(State.FAILED) }
            try { awaitDrain(future) } catch (cleanup: Throwable) {
                if (cleanup !== failure) failure.addSuppressed(cleanup)
            }
            if (failure is InterruptedException) Thread.currentThread().interrupt()
            throw failure
        } finally {
            synchronized(lock) { reading = false }
        }
    }

    private fun fetchWindow(): ListeningMemoryOutput.Window? {
        val future = synchronized(lock) {
            check(state == State.OPEN) { "PCM cursor retired" }
            next(2048) // Keep the actual lane-owned future. Never wait while holding the state lock.
        }
        val window = await(future)
        return synchronized(lock) {
            check(state == State.OPEN) { "PCM cursor retired during source read" }
            window
        }
    }

    private fun validate(window: ListeningMemoryOutput.Window) {
        check(window.startFrame == nextOrigin && window.frameCount in 1..2048) { "Noncontiguous PCM window" }
        val data = window.stereoFloatLE.order(ByteOrder.LITTLE_ENDIAN)
        check(data.remaining() == window.frameCount * 8) { "Incomplete stereo PCM window" }
        check(window.frameCount.toLong() <= sourceFrames - nextOrigin) { "PCM source exceeds declared extent" }
        val floats = data.asFloatBuffer()
        while (floats.hasRemaining()) check(floats.get().isFinite()) { "Nonfinite PCM sample" }
        nextOrigin += window.frameCount
    }

    /** Called with lock held. Revocation and the concrete drain request precede any blocking wait. */
    private fun retire(target: State): CompletableFuture<Media3ListeningLane.DrainReceipt> {
        if (state == State.OPEN || state == State.COMPLETE &&
            (target == State.FAILED || target == State.CLOSED && reading)) state = target
        carry = null
        if (drainFuture == null) {
            drainFuture = try { drain() } catch (failure: Throwable) {
                CompletableFuture<Media3ListeningLane.DrainReceipt>().also { it.completeExceptionally(failure) }
            }
        }
        return drainFuture!!
    }

    private fun awaitDrain(future: CompletableFuture<Media3ListeningLane.DrainReceipt>) {
        val receipt = await(future)
        check(receipt.openSources == 0 && receipt.readsInFlight == 0) { "PCM lane drain still owns source IO" }
    }

    private fun <T> await(future: CompletableFuture<T>): T = try {
        future.get(timeoutMs, TimeUnit.MILLISECONDS)
    } catch (failure: ExecutionException) {
        val cause = failure.cause ?: failure
        // An interrupted decoder future is a source fault, not this loader's interrupted wait.
        if (cause is InterruptedException) throw java.io.IOException("PCM decoder failed", cause)
        throw cause
    }

    /** May run concurrently with read. Timeout/failure never releases custody. Retry waits on the
     * same lane drain, even after the read times out. Closing early never certifies exact EOF.
     */
    override fun close() {
        val future = synchronized(lock) { retire(State.CLOSED) }
        try { awaitDrain(future) } catch (failure: InterruptedException) {
            Thread.currentThread().interrupt()
            throw failure
        }
    }
}
