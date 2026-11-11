package com.soundq.android.playback.listening

import android.net.Uri
import androidx.media3.datasource.AssetDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs
import kotlin.math.sqrt

/** Actual MediaCodec + progressive source + DefaultAudioSink. No ExoPlayer, AudioTrack or codec fake.
 * Full capture exists only here for these finite three-second synthetic assets.
 */
@RunWith(AndroidJUnit4::class)
class Media3ListeningLaneTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.context
    private val receipts get() = File(instrumentation.targetContext.cacheDir, "media3-memory-lane").also { it.mkdirs() }
    private fun factory() = DataSource.Factory { AssetDataSource(context) }
    private fun lane(name: String, valid: () -> Boolean = { true }, factory: DataSource.Factory = factory()) =
        Media3ListeningLane(instrumentation.targetContext, Uri.parse("asset:///listening-mp3/$name"), factory, valid, 4096)

    private fun capture(name: String, block: Int, label: String): ByteArray {
        val lane = lane(name)
        val bytes = ByteArrayOutputStream()
        var frames = 0L
        val receipt = JSONObject().put("asset", name).put("block", block)
        try {
            while (true) {
                val w = lane.next(block).get(15, TimeUnit.SECONDS) ?: break
                assertEquals(frames, w.startFrame)
                assertTrue(w.frameCount in 1..block)
                frames += w.frameCount
                // Finite fixture safety ceiling, not an extent repair or production source preload.
                check(frames <= 160000) { "Fixture produced excessive PCM" }
                val b = w.stereoFloatLE
                val chunk = ByteArray(b.remaining()); b.get(chunk); bytes.write(chunk)
            }
            val e = lane.evidence().get(5, TimeUnit.SECONDS)
            receipt.put("inputRate", e.inputRate).put("inputChannels", e.inputChannels)
                .put("encoderDelay", e.encoderDelay).put("encoderPadding", e.encoderPadding)
                .put("decoderOutput", e.decoderOutput).put("sonicInputBytes", e.sonicInputBytes)
                .put("normalizedFrames", e.normalizedFrames).put("ringHighWaterFrames", e.ringHighWaterFrames)
                .put("encodedAllocatorHighWaterBytes", e.encodedAllocatorHighWaterBytes)
                .put("decoderPcmFrames", e.decoderPcmFrames).put("decoderOnlyFrames", e.decoderOnlyFrames)
                .put("sonicInputFrameCount", e.sonicInputFrameCount)
            File(receipts, "$label.f32le").writeBytes(bytes.toByteArray())
            assertEquals(44100, e.inputRate)
            assertTrue(e.inputChannels in 1..2)
            assertTrue(e.ringHighWaterFrames <= 4096)
            assertEquals(frames, e.normalizedFrames)
            // Independent fixture contract. NEVER cut, pad or calculate decoder success from metadata.
            assertEquals(144000L, frames)
            return bytes.toByteArray()
        } catch (failure: Throwable) {
            receipt.put("failure", failure.toString()); throw failure
        } finally {
            try {
                val d = lane.retireAndDrain().get(15, TimeUnit.SECONDS)
                receipt.put("extractorReleases", d.extractorReleases).put("openSources", d.openSources)
                    .put("readsInFlight", d.readsInFlight)
                assertEquals(1, d.extractorReleases); assertEquals(0, d.openSources); assertEquals(0, d.readsInFlight)
            } finally { File(receipts, "$label.json").writeText(receipt.toString(2)) }
        }
    }

    @Test fun syntheticStereoAndMonoMp3DecodeSequentially() {
        for (name in listOf("stereo.mp3", "mono.mp3")) {
            val a = capture(name, 2048, "$name-2048")
            val b = capture(name, 127, "$name-127")
            assertArrayEquals("Chunk partition must not change samples", a, b)
            val reference = context.assets.open("listening-mp3/$name.48k-stereo.f32").use { it.readBytes() }
            assertEquals(reference.size, a.size)
            val actual = ByteBuffer.wrap(a).order(ByteOrder.LITTLE_ENDIAN)
            val expected = ByteBuffer.wrap(reference).order(ByteOrder.LITTLE_ENDIAN)
            var squared = 0.0; var peakError = 0.0; var peak = 0.0
            var headError = 0.0; var tailError = 0.0
            val samples = a.size / 4
            repeat(samples) { i ->
                val x = actual.float.toDouble(); val y = expected.float.toDouble()
                assertTrue(x.isFinite())
                val error = abs(x - y); squared += error * error
                peakError = maxOf(peakError, error); peak = maxOf(peak, abs(x))
                if (i < 4096) headError += error * error
                if (i >= samples - 4096) tailError += error * error
            }
            val rms = sqrt(squared / samples)
            File(receipts, "$name-reference.json").writeText(JSONObject().put("rmsError", rms)
                .put("peakError", peakError).put("headRmsError", sqrt(headError / 4096))
                .put("tailRmsError", sqrt(tailError / 4096)).put("comparisonShiftFrames", 0)
                .put("monoPolicy", "Media3 constant-power 1-to-2 then PCM16 Sonic 48k").toString(2))
            // Initial deliberately explicit codec/resampler tolerance, zero fitted shift.
            assertTrue("Non-silent signal", peak > .01)
            assertTrue("Reference rms $rms", rms < .03)
            assertTrue("Reference peak error $peakError", peakError < .15)
            assertTrue(sqrt(headError / 4096) < .03); assertTrue(sqrt(tailError / 4096) < .03)
        }
    }

    @Test fun retireDuringRealAssetReadWaitsForExtractorAndRefusesOldPublication() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val closed = AtomicBoolean(false); val valid = AtomicBoolean(true)
        val actualFactory = factory()
        val heldFactory = DataSource.Factory {
            val actual = actualFactory.createDataSource()
            object : DataSource by actual {
                private var first = true
                override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                    if (first) {
                        first = false; entered.countDown()
                        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
                        while (release.count != 0L) {
                            check(System.nanoTime() < deadline) { "Held asset read deadline" }
                            try { release.await(20, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { }
                        }
                    }
                    return actual.read(buffer, offset, length)
                }
                override fun close() { actual.close(); closed.set(true) }
            }
        }
        val lane = lane("stereo.mp3", valid::get, heldFactory)
        try {
            val read = lane.next()
            assertTrue(entered.await(10, TimeUnit.SECONDS))
            valid.set(false)
            val drain = lane.retireAndDrain()
            assertFalse(drain.isDone); assertFalse(closed.get())
            assertThrows(IllegalStateException::class.java) { lane.next() }
            release.countDown()
            assertThrows(java.util.concurrent.ExecutionException::class.java) { read.get(10, TimeUnit.SECONDS) }
            val receipt = drain.get(15, TimeUnit.SECONDS)
            assertEquals(0, receipt.openSources); assertEquals(0, receipt.readsInFlight)
            assertEquals(1, receipt.extractorReleases); assertTrue(closed.get())
        } finally {
            release.countDown(); lane.retireAndDrain().get(15, TimeUnit.SECONDS)
        }
    }
}
