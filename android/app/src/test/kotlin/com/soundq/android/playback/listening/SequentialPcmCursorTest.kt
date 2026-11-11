package com.soundq.android.playback.listening

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CompletableFuture
import org.junit.Assert.*
import org.junit.Test

/** Actual memory windows, not host codec decode. JNI runs in this plain JVM only. */
class SequentialPcmCursorTest {
    @Test fun missingCursorIsAnAdditiveApiDiscoveryNotAProductRegression() {
        Class.forName("com.soundq.android.playback.listening.SequentialPcmCursor")
    }

    @Test fun misalignedRequestsConsumeImmutableWindowsWithoutLosingSourceCoordinates() {
        val input = MemorySource(7021, 733)
        val cursor = cursor(input)
        assertPcm(193, cursor.read(193, 2048))
        assertPcm(2241, cursor.read(2241, 17))
        assertPcm(2258, cursor.read(2258, 2048))
        assertPcm(4306, cursor.read(4306, 2048))
        assertPcm(6354, cursor.read(6354, 667))
        assertTrue(cursor.completeExtent)
        assertTrue(cursor.retiredSuccessfully)
        assertEquals(1, input.drains)
        assertTrue(input.requests.all { it in 1..2048 })
        assertThrows(IllegalStateException::class.java) { cursor.read(0, 1) }
        cursor.close()
        assertEquals(1, input.drains)
    }

    @Test fun explicitCloseFencesAReadAlreadyWaitingForItsEofDrain() {
        val source = MemorySource(5, 5)
        val requested = java.util.concurrent.CountDownLatch(1)
        val drain = CompletableFuture<Media3ListeningLane.DrainReceipt>()
        val cursor = seam(5, source::next, { requested.countDown(); drain }, 1000)
        val pool = java.util.concurrent.Executors.newSingleThreadExecutor()
        try {
            val read = pool.submit<FloatArray> { cursor.read(0, 5) }
            assertTrue(requested.await(1, java.util.concurrent.TimeUnit.SECONDS))
            assertFalse(cursor.completeExtent)
            val closer = java.util.concurrent.Executors.newSingleThreadExecutor()
            val closingThread = java.util.concurrent.atomic.AtomicReference<Thread>()
            try {
                val close = closer.submit {
                    closingThread.set(Thread.currentThread())
                    cursor.close()
                }
                val deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(1)
                while (closingThread.get()?.state != Thread.State.TIMED_WAITING) {
                    check(System.nanoTime() < deadline) { "Close did not reach retained drain wait" }
                    Thread.yield()
                }
                assertFalse(cursor.retiredSuccessfully)
                drain.complete(Media3ListeningLane.DrainReceipt(1, 0, 0))
                close.get(2, java.util.concurrent.TimeUnit.SECONDS)
            } finally {
                drain.complete(Media3ListeningLane.DrainReceipt(1, 0, 0))
                closer.shutdownNow()
                assertTrue(closer.awaitTermination(2, java.util.concurrent.TimeUnit.SECONDS))
            }
            val failure = assertThrows(java.util.concurrent.ExecutionException::class.java) {
                read.get(2, java.util.concurrent.TimeUnit.SECONDS)
            }
            assertTrue(failure.cause is IllegalStateException)
            assertFalse(cursor.completeExtent)
            cursor.close()
        } finally {
            drain.complete(Media3ListeningLane.DrainReceipt(1, 0, 0))
            pool.shutdownNow()
            assertTrue(pool.awaitTermination(2, java.util.concurrent.TimeUnit.SECONDS))
        }
    }

    @Test fun invalidIntervalsPreserveAHealthyCursorAndOneBoundedCarry() {
        val input = MemorySource(10000, 2048)
        val cursor = cursor(input)
        assertPcm(0, cursor.read(0, 1))
        val carryField = SequentialPcmCursor::class.java.getDeclaredField("carry").apply { isAccessible = true }
        val carry = carryField.get(cursor) as ListeningMemoryOutput.Window
        assertEquals(2048, carry.frameCount)
        assertEquals(1, input.requests.size)
        for ((origin, count) in listOf(-1L to 1, 0L to 1, 1L to 0, 1L to 2049, 9999L to 2, Long.MAX_VALUE to 1)) {
            assertThrows(IllegalArgumentException::class.java) { cursor.read(origin, count) }
            assertEquals(1, input.requests.size)
            assertSame(carry, carryField.get(cursor))
        }
        assertPcm(1, cursor.read(1, 2048))
        assertPcm(9000, cursor.read(9000, 1000))
        assertTrue(cursor.completeExtent)
        assertNull(carryField.get(cursor))
    }

    @Test fun duplicateRecordingsHaveIndependentOccurrencePositions() {
        val a = MemorySource(5000, 997)
        val b = MemorySource(5000, 613)
        val outgoing = cursor(a)
        val incoming = cursor(b)
        assertPcm(1000, outgoing.read(1000, 100))
        assertPcm(0, incoming.read(0, 73))
        assertPcm(1100, outgoing.read(1100, 333))
        assertPcm(73, incoming.read(73, 200))
        outgoing.close()
        assertFalse(outgoing.completeExtent)
        assertPcm(273, incoming.read(273, 100))
        incoming.close()
        assertEquals(1, a.drains)
        assertEquals(1, b.drains)
    }

    @Test fun shortExcessMisorderedMalformedAndNonfiniteSourcesTerminalizeWithoutPadding() {
        val malformed = ByteArray(9)
        val nan = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putFloat(Float.NaN).putFloat(0f).array()
        val oversized = ByteArray(2049 * 8)
        val one = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putFloat(.1f).putFloat(.2f).array()
        val cases = listOf(
            listOf<ListeningMemoryOutput.Window?>(null),
            listOf(ListeningMemoryOutput.Window(0, one), null),
            listOf(ListeningMemoryOutput.Window(0, ByteArray(3 * 8))),
            listOf(ListeningMemoryOutput.Window(1, one)),
            listOf(ListeningMemoryOutput.Window(0, one), ListeningMemoryOutput.Window(0, one)),
            listOf(ListeningMemoryOutput.Window(0, malformed)),
            listOf(ListeningMemoryOutput.Window(0, nan)),
            listOf(ListeningMemoryOutput.Window(0, oversized)),
            listOf(ListeningMemoryOutput.Window(0, ByteArray(2 * 8)), ListeningMemoryOutput.Window(2, one)),
        )
        cases.forEachIndexed { index, windows ->
            var demands = 0
            var drains = 0
            val cursor = seam(2, { CompletableFuture.completedFuture(windows.getOrNull(demands++)) }, {
                drains++
                CompletableFuture.completedFuture(Media3ListeningLane.DrainReceipt(1, 0, 0))
            })
            assertThrows("malformed source $index", IllegalStateException::class.java) { cursor.read(0, 2) }
            assertFalse(cursor.completeExtent)
            assertTrue(cursor.retiredSuccessfully)
            assertThrows(IllegalStateException::class.java) { cursor.read(0, 1) }
            cursor.close()
            assertEquals(1, drains)
        }
    }

    @Test fun declaredEndRequiresAnAdditionalRealEosAndCloseRetriesRetainDrainOwnership() {
        val input = MemorySource(2, 2)
        val eos = CompletableFuture<ListeningMemoryOutput.Window?>()
        val pendingDrain = CompletableFuture<Media3ListeningLane.DrainReceipt>()
        var demands = 0
        var drains = 0
        val cursor = seam(2, { n -> if (demands++ == 0) input.next(n) else eos }, { drains++; pendingDrain }, 20)
        val failure = assertThrows(java.util.concurrent.TimeoutException::class.java) { cursor.read(0, 2) }
        assertEquals(2, demands)
        assertFalse(eos.isCancelled)
        assertFalse(cursor.completeExtent)
        assertFalse(cursor.retiredSuccessfully)
        assertEquals(1, failure.suppressed.size)
        assertThrows(java.util.concurrent.TimeoutException::class.java) { cursor.close() }
        assertEquals(1, drains)
        pendingDrain.complete(Media3ListeningLane.DrainReceipt(1, 0, 0))
        cursor.close()
        assertEquals(1, drains)
        assertTrue(cursor.retiredSuccessfully)
        assertFalse(cursor.completeExtent)
    }

    @Test fun originalReadFailureSurvivesFailedCleanupAndFailedDrainNeverReleasesCustody() {
        val original = java.io.IOException("source read refused")
        val cleanup = java.io.IOException("source close refused")
        var drains = 0
        val failedDrain = CompletableFuture<Media3ListeningLane.DrainReceipt>().apply { completeExceptionally(cleanup) }
        val cursor = seam(9, { CompletableFuture<ListeningMemoryOutput.Window?>().apply { completeExceptionally(original) } }, {
            drains++; failedDrain
        })
        assertSame(original, assertThrows(java.io.IOException::class.java) { cursor.read(0, 1) })
        assertArrayEquals(arrayOf(cleanup), original.suppressed)
        assertSame(cleanup, assertThrows(java.io.IOException::class.java) { cursor.close() })
        assertEquals(1, drains)
        assertFalse(cursor.retiredSuccessfully)
        assertFalse(cursor.completeExtent)
    }

    @Test fun exceptionalFutureErrorsStillRetireTheConcreteOwner() {
        val original = AssertionError("source task failed")
        var drains = 0
        val cursor = seam(9, {
            CompletableFuture<ListeningMemoryOutput.Window?>().apply { completeExceptionally(original) }
        }, {
            drains++
            CompletableFuture.completedFuture(Media3ListeningLane.DrainReceipt(1, 0, 0))
        })
        assertSame(original, assertThrows(AssertionError::class.java) { cursor.read(0, 1) })
        assertEquals(1, drains)
        assertTrue(cursor.retiredSuccessfully)
        assertThrows(IllegalStateException::class.java) { cursor.read(0, 1) }
    }

    @Test fun closeRequestsDrainSynchronouslyWhileNextIsHeldAndRejectsItsLateWindow() {
        val held = CompletableFuture<ListeningMemoryOutput.Window?>()
        val entered = java.util.concurrent.CountDownLatch(1)
        val drained = CompletableFuture<Media3ListeningLane.DrainReceipt>()
        var drains = 0
        val retired = java.util.concurrent.CountDownLatch(1)
        val cursor = seam(20, { entered.countDown(); held }, { drains++; retired.countDown(); drained }, 1000)
        val pool = java.util.concurrent.Executors.newFixedThreadPool(2)
        try {
            val reading = pool.submit<FloatArray> { cursor.read(0, 1) }
            assertTrue(entered.await(1, java.util.concurrent.TimeUnit.SECONDS))
            assertThrows(IllegalStateException::class.java) { cursor.read(1, 1) }
            val closing = pool.submit { cursor.close() }
            assertTrue(retired.await(1, java.util.concurrent.TimeUnit.SECONDS))
            assertEquals(1, drains)
            assertFalse(cursor.retiredSuccessfully)
            assertFalse(held.isCancelled)
            val memory = MemorySource(20, 20)
            held.complete(memory.next(20).get())
            drained.complete(Media3ListeningLane.DrainReceipt(1, 0, 0))
            val failure = assertThrows(java.util.concurrent.ExecutionException::class.java) {
                reading.get(2, java.util.concurrent.TimeUnit.SECONDS)
            }
            assertTrue(failure.cause is IllegalStateException)
            closing.get(2, java.util.concurrent.TimeUnit.SECONDS)
            cursor.close()
            assertEquals(1, drains)
            assertFalse(cursor.completeExtent)
            assertThrows(IllegalStateException::class.java) { cursor.read(0, 1) }
        } finally {
            held.complete(null)
            drained.complete(Media3ListeningLane.DrainReceipt(1, 0, 0))
            pool.shutdownNow()
            assertTrue(pool.awaitTermination(2, java.util.concurrent.TimeUnit.SECONDS))
        }
    }

    @Test fun immutableSourceWindowsFeedActualJniWithOriginalTrimAndFadeCoordinates() {
        val frames = 7021
        val sourceIn = 193
        val clipFrames = frames - sourceIn
        val secondStart = 4700
        val overlap = clipFrames - secondStart
        val total = secondStart + clipFrames
        val a = cursor(MemorySource(frames, 733))
        val b = cursor(MemorySource(frames, 613))
        var maximumError = 0.0
        var compared = 0
        try {
            for (origin in 0 until total step 997) {
                val count = minOf(997, total - origin)
                val fields = mutableListOf<Long>()
                val windows = mutableListOf<FloatArray>()
                for (index in 0..1) {
                    val start = if (index == 0) 0 else secondStart
                    val end = start + clipFrames
                    if (end <= origin || start >= origin + count) continue
                    val local = sourceIn + maxOf(origin, start) - start
                    val stop = sourceIn + minOf(origin + count, end) - start
                    fields += listOf(index + 11L, start.toLong(), end.toLong(), sourceIn.toLong(), frames.toLong(),
                        if (index == 0) 0L else overlap.toLong(), if (index == 0) overlap.toLong() else 0L, local.toLong())
                    windows += (if (index == 0) a else b).read(local.toLong(), stop - local)
                }
                val output = ByteArray(count * 8 + 16) { 37 }
                com.soundq.android.playback.mix.NativeMix.renderPcmBlock(origin.toLong(), count, fields.toLongArray(),
                    windows.toTypedArray(), FloatArray(windows.size) { 1f }, output)
                assertTrue(output.drop(count * 8).all { it == 37.toByte() })
                val actual = ByteBuffer.wrap(output, 0, count * 8).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
                repeat(count) { offset ->
                    val global = origin + offset
                    val progress = ((global - secondStart) / overlap.toDouble()).coerceIn(0.0, 1.0)
                    repeat(2) { channel ->
                        val outgoing = if (global < clipFrames) value(global + sourceIn, channel) / 32768.0 *
                            kotlin.math.cos(progress * kotlin.math.PI / 2) else 0.0
                        val incoming = if (global >= secondStart) value(global - secondStart + sourceIn, channel) / 32768.0 *
                            kotlin.math.sin(progress * kotlin.math.PI / 2) else 0.0
                        val sample = actual.get().toDouble()
                        assertTrue(sample.isFinite())
                        val error = kotlin.math.abs(sample - outgoing - incoming)
                        maximumError = maxOf(maximumError, error)
                        assertTrue("JNI source sample $global/$channel error $error", error <= .000001)
                        compared++
                    }
                }
            }
            assertEquals(total * 2, compared)
            assertTrue(a.completeExtent)
            assertTrue(b.completeExtent)
            println("CURSOR_JNI comparedSamples=$compared maxAbsoluteError=$maximumError sourceIn=$sourceIn block=997")
        } finally {
            a.close(); b.close()
        }
    }

    private class MemorySource(val extent: Int, val chunk: Int) {
        val memory = ListeningMemoryOutput(2048) { true }
        var position = 0
        var drains = 0
        val requests = mutableListOf<Int>()
        fun next(max: Int): CompletableFuture<ListeningMemoryOutput.Window?> {
            requests += max
            val count = minOf(max, chunk, extent - position)
            if (count == 0) return CompletableFuture.completedFuture(null)
            val bytes = ByteBuffer.allocate(count * 4).order(ByteOrder.LITTLE_ENDIAN)
            repeat(count) { offset -> repeat(2) { channel -> bytes.putShort(value(position + offset, channel).toShort()) } }
            bytes.flip()
            check(memory.write(bytes, 1, 0))
            position += count
            val window = memory.take(count)!!
            // Reuse the real ring on the next demand. Published bytes must remain detached.
            return CompletableFuture.completedFuture(window)
        }
        fun drain(): CompletableFuture<Media3ListeningLane.DrainReceipt> {
            drains++
            memory.retire()
            return CompletableFuture.completedFuture(Media3ListeningLane.DrainReceipt(1, 0, 0))
        }
    }

    private fun cursor(source: MemorySource): SequentialPcmCursor = seam(source.extent.toLong(), source::next, source::drain)

    private fun seam(
        extent: Long,
        next: (Int) -> CompletableFuture<ListeningMemoryOutput.Window?>,
        drain: () -> CompletableFuture<Media3ListeningLane.DrainReceipt>,
        timeoutMs: Long = 1000,
    ): SequentialPcmCursor {
        val constructor = SequentialPcmCursor::class.java.declaredConstructors.single { it.parameterCount == 4 }
        constructor.isAccessible = true
        return constructor.newInstance(extent, next, drain, timeoutMs) as SequentialPcmCursor
    }

    private fun assertPcm(origin: Int, samples: FloatArray) {
        assertEquals(0, samples.size % 2)
        samples.forEachIndexed { index, sample ->
            assertEquals("source sample ${origin * 2 + index}", value(origin + index / 2, index % 2) / 32768f, sample, 0f)
        }
    }

    companion object {
        private fun value(frame: Int, channel: Int): Int = ((frame * 31 + channel * 7919) % 28001) - 14000
    }
}
