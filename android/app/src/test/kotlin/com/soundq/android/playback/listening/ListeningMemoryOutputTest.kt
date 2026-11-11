package com.soundq.android.playback.listening

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.ReadOnlyBufferException
import org.junit.Assert.*
import org.junit.Test

/** Real memory destination only. Does not claim MediaCodec or Android decode coverage. */
class ListeningMemoryOutputTest {
    private fun pcm(vararg values: Int): ByteBuffer = ByteBuffer.allocate(values.size * 2)
        .order(ByteOrder.LITTLE_ENDIAN).also { b -> values.forEach { b.putShort(it.toShort()) }; b.flip() }

    @Test fun sinkBookkeepingDoesNotLeaveFractionalMicrosecondFramePending() {
        val output = ListeningMemoryOutput(1, { true })
        output.write(pcm(1, 2), 1, 0)
        assertTrue("Sink converts positionUs back to frames with floor", output.positionUs * 48000 / 1_000_000 >= output.acceptedFrames)
    }

    @Test fun retirementFencesBufferedAndFuturePublication() {
        var owner = true
        val output = ListeningMemoryOutput(2, { owner })
        output.write(pcm(1, 2), 1, 0)
        owner = false
        assertThrows(IllegalStateException::class.java) { output.take(1) }
        val late = pcm(3, 4)
        assertThrows(IllegalStateException::class.java) { output.write(late, 1, 0) }
        assertEquals(0, late.position())
        output.retire()
        owner = true // same identity becoming valid again cannot resurrect a retired lane.
        assertThrows(IllegalStateException::class.java) { output.take(1) }
        assertEquals(0, output.bufferedFrames)
    }

    @Test fun windowsAreImmutableAndDetachedFromRingReuse() {
        val output = ListeningMemoryOutput(1, { true })
        output.write(pcm(100, 200), 1, 0)
        val window = output.take(1)!!
        assertThrows(ReadOnlyBufferException::class.java) { window.stereoFloatLE.putFloat(1f) }
        output.write(pcm(300, 400), 1, 0)
        output.retire()
        assertEquals(100f / 32768f, window.stereoFloatLE.float, 0f)
    }

    @Test fun malformedFramesAndDiscontinuitiesAreRefused() {
        val output = ListeningMemoryOutput(1, { true })
        assertThrows(IllegalArgumentException::class.java) { output.write(ByteBuffer.allocate(3), 1, 0) }
        output.write(pcm(1, 2), 1, 0)
        assertThrows(IllegalStateException::class.java) { output.flush() }
        output.retire()
        output.flush()
        output.release()
        output.release()
    }

    @Test fun boundedPartialWriteResumesWithoutDroppingFrames() {
        val output = ListeningMemoryOutput(2, { true })
        val input = pcm(-32768, 32767, 16384, -16384, 1, -1)
        assertFalse(output.write(input, 99, 123456L)) // int is access-unit count, NOT bytes.
        assertEquals(8, input.position())
        assertEquals(2, output.bufferedFrames)
        assertFalse(output.write(input, 99, 123456L))
        assertEquals(8, input.position())
        val first = output.take(1)!!
        assertEquals(0L, first.startFrame)
        val firstBytes = first.stereoFloatLE
        assertEquals(-1f, firstBytes.float, 0f)
        assertEquals(32767f / 32768f, firstBytes.float, 0f)
        assertTrue(output.write(input, 99, 123456L))
        val rest = output.take(2)!!
        assertEquals(1L, rest.startFrame)
        val restBytes = rest.stereoFloatLE
        assertArrayEquals(floatArrayOf(.5f, -.5f, 1f / 32768f, -1f / 32768f),
            FloatArray(4) { restBytes.float }, 0f)
        assertEquals(2, output.highWaterFrames)
        assertEquals(3L, output.acceptedFrames)
    }
}
