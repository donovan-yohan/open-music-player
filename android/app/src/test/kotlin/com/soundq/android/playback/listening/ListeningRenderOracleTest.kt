package com.soundq.android.playback.listening

import com.soundq.android.data.timeline.*
import com.soundq.android.playback.mix.NativeMixStream
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.*

/** Private seam supplied by each source snapshot, not a fake renderer. */
internal interface ProbeCaller {
    fun open(sources: List<TimelineSource>, overlapMs: Long, paths: Map<String, String>): NativeMixStream
}

class ListeningRenderOracleTest {
    private lateinit var fixture: File
    private lateinit var output: File
    @org.junit.Before fun fixtures() {
        val input = System.getProperty("soundq.listening.fixture")
        val destination = System.getProperty("soundq.listening.output")
        org.junit.Assume.assumeNotNull(input, destination)
        fixture = File(input!!); output = File(destination!!)
    }
    private fun decoded(name: String): FloatArray {
        val bytes = File(fixture, "$name.decoded").readBytes()
        return ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().let { b -> FloatArray(b.remaining()).also { b.get(it) } }
    }
    private fun sources(duplicate: Boolean) = listOf(
        TimelineSource("visit-a", 7, "A", 10000, QueueSegment.Context),
        TimelineSource("visit-b", if (duplicate) 7 else 8, "B", 10000, QueueSegment.Manual)
    )
    private fun render(duplicate: Boolean, overlapMs: Long, savedMix: Boolean = false) {
        val label = if (savedMix) "saved" else if (overlapMs == 0L) "zero" else if (duplicate) "duplicate" else "pair"
        val a = decoded("a"); val b = decoded("b")
        assertEquals(480000 * 2, a.size); assertEquals(a.size, b.size)
        val start = (10000 - overlapMs) * 48
        val expectedFrames = (20000 - overlapMs) * 48
        val paths = mapOf("visit-a" to File(fixture, "a.opus").absolutePath, "visit-b" to File(fixture, "b.opus").absolutePath)
        var maxError = 0.0; var compared = 0L; var outgoingOnly = 0.0; var incomingOnly = 0.0; var buttJoint = 0.0
        var actualFrames = 0L
        val stream = if (savedMix) {
            val clips = sources(false).mapIndexed { i, s -> com.soundq.android.data.mix.MixJson.clip(buildJsonObject {
                put("clipId", s.occurrence); put("queueItemId", s.occurrence); put("trackId", s.track)
                put("sourceStartMs", 0); put("sourceEndMs", 10000); put("timelineStartMs", if (i == 0) 0 else 10000 - overlapMs)
                put("fadeInMs", if (i == 0) 0 else overlapMs); put("fadeOutMs", if (i == 0) overlapMs else 0)
            }) }
            NativeMixStream(com.soundq.android.data.mix.SavedMix("00000000-0000-4000-8000-000000000001", 1, "Saved compatibility", clips), mapOf(7L to paths.getValue("visit-a"), 8L to paths.getValue("visit-b")))
        } else createProbeCaller().open(sources(duplicate), overlapMs, paths)
        stream.use { stream ->
            val header = ByteArray(44); assertEquals(44, stream.read(0, header, 0, 44))
            assertEquals("RIFF", String(header, 0, 4)); assertEquals(3, ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN).getShort(20).toInt())
            val bytes = ByteArray(2048 * 8)
            File(output, "$label.f32").outputStream().use { saved ->
                var position = 44L
                while (true) {
                    val n = stream.read(position, bytes, 0, bytes.size)
                    if (n == -1) break
                    assertTrue(n > 0 && n % 8 == 0)
                    saved.write(bytes, 0, n)
                    val floats = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
                    repeat(n / 8) { offset ->
                        val frame = actualFrames + offset
                        repeat(2) { channel ->
                            val av = if (frame < 480000) a[(frame * 2 + channel).toInt()].toDouble() else 0.0
                            val bi = frame - start
                            val bv = if (bi in 0L until 480000L) b[(bi * 2 + channel).toInt()].toDouble() else 0.0
                            val t = if (overlapMs > 0) ((frame - start).toDouble() / (overlapMs * 48)).coerceIn(0.0, 1.0) else 0.0
                            val expected = if (overlapMs == 0L) av + bv else av * cos(t * PI / 2) + bv * sin(t * PI / 2)
                            val actual = floats.float.toDouble()
                            maxError = max(maxError, abs(actual - expected)); compared++
                            if (frame >= start && frame < 480000 && overlapMs > 0) {
                                outgoingOnly = max(outgoingOnly, abs(actual - av))
                                incomingOnly = max(incomingOnly, abs(actual - bv))
                                buttJoint = max(buttJoint, abs(actual - av))
                            }
                        }
                    }
                    actualFrames += n / 8; position += n
                }
            }
            // Reverse seek after EOF must reconstruct the same actual native output, not restart B's head.
            val recorded = File(output, "$label.f32").readBytes()
            for (frame in listOf(9L * 48000, 8L * 48000, 10L * 48000, 1L * 48000)) {
                val n = stream.read(44 + frame * 8, bytes, 0, bytes.size)
                assertArrayEquals(recorded.copyOfRange((frame * 8).toInt(), (frame * 8).toInt() + n), bytes.copyOf(n))
            }
            assertEquals(-1, stream.read(stream.size, bytes, 0, bytes.size))
            assertEquals(0, stream.read(stream.size, bytes, 0, 0))
            val tiny = ByteArray(5); assertEquals(5, stream.read(45, tiny, 0, 5))
            assertArrayEquals(recorded.copyOfRange(1, 6), tiny)
        }
        File(output, "$label.json").writeText(buildJsonObject {
            put("actualFrames", actualFrames); put("expectedFrames", expectedFrames); put("comparedSamples", compared)
            put("maxAbsoluteError", maxError); put("tolerance", 0.00008)
            put("outgoingOnlyDifference", outgoingOnly); put("incomingOnlyDifference", incomingOnly); put("buttJointDifference", buttJoint)
        }.toString())
        assertTrue("$label every-sample overlap oracle max error=$maxError", maxError <= 0.00008)
        assertEquals("full output extent", expectedFrames, actualFrames)
        assertEquals(expectedFrames * 2, compared)
        if (overlapMs > 0) { assertTrue(outgoingOnly > .01); assertTrue(incomingOnly > .01); assertTrue(buttJoint > .01) }
    }
    @Test fun twoSourceActualJniEverySampleAndBackwardSeek() = render(false, 3000)
    @Test fun repeatedRecordingRetainsExactOccurrenceFileBinding() = render(true, 3000)
    @Test fun zeroRetainsSequentialSamplesAndExtent() = render(false, 0)
    @Test fun savedMixOverlapRemainsIdenticalEverySample() = render(false, 3000, true)
}
