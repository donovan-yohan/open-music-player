package com.soundq.android.playback.listening

import android.net.Uri
import androidx.media3.datasource.AssetDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs

/** Actual Android MediaCodec lane past encoded admission to real EOS, with incremental evidence.
 * Independent ffmpeg frame contract is 960000 stereo 48k frames. No count repair or PCM preload.
 * Requires the separately owned sink gapless-policy repair for exact terminal extent acceptance.
 */
@RunWith(AndroidJUnit4::class)
class Media3LongMp3EosTest {
    @Test fun longMp3RecoversConsumedStorageAndDecodesToGenuineEos() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.context
        val uri = Uri.parse("asset:///listening-mp3/long-stereo.mp3")
        val encodedDigest = MessageDigest.getInstance("SHA-256")
        var encodedBytes = 0L
        context.assets.open("listening-mp3/long-stereo.mp3").use { input ->
            val block = ByteArray(8192)
            while (true) {
                val count = input.read(block)
                if (count == -1) break
                encodedBytes += count; encodedDigest.update(block, 0, count)
            }
        }
        fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
        assertEquals(802524L, encodedBytes)
        assertTrue(encodedBytes > 262144)
        assertEquals("0d31f55c74f6b45aada64540a0707520aab58facfef1d86397c0a319901b31ba", hex(encodedDigest.digest()))
        val valid = AtomicBoolean(true)
        val sourceBytes = AtomicLong()
        val factory = DataSource.Factory {
            val actual = AssetDataSource(context)
            object : DataSource by actual {
                override fun open(spec: DataSpec): Long {
                    check(valid.get()); assertEquals(uri, spec.uri)
                    return actual.open(spec)
                }
                override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                    check(valid.get())
                    val count = actual.read(buffer, offset, length)
                    if (count > 0) sourceBytes.addAndGet(count.toLong())
                    return count
                }
            }
        }
        val lane = Media3ListeningLane(instrumentation.targetContext, uri, factory, valid::get, 4096)
        val receipt = JSONObject().put("asset", uri.toString()).put("encodedBytes", encodedBytes)
            .put("expectedFrames", 960000).put("independentReferenceSha256", "39fbc6b5ab13d10669727331fb3363f71a1efa1451913a4e02b1c212f78bd5c1")
        val digest = MessageDigest.getInstance("SHA-256")
        var frames = 0L; var peak = 0f; var eos = false
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(60)
        try {
            while (true) {
                assertTrue("Finite long-source EOS deadline", System.nanoTime() < deadline)
                val window = lane.next(2048).get(15, TimeUnit.SECONDS)
                if (window == null) { eos = true; break }
                assertEquals("Source-local continuity", frames, window.startFrame)
                assertTrue(window.frameCount in 1..2048)
                val pcm = window.stereoFloatLE.duplicate().order(ByteOrder.LITTLE_ENDIAN)
                assertEquals(window.frameCount * 8, pcm.remaining())
                digest.update(pcm.duplicate())
                while (pcm.hasRemaining()) {
                    val value = pcm.float
                    assertTrue(value.isFinite()); peak = maxOf(peak, abs(value))
                }
                frames += window.frameCount
            }
            val evidence = lane.evidence().get(5, TimeUnit.SECONDS)
            receipt.put("inputRate", evidence.inputRate).put("inputChannels", evidence.inputChannels)
                .put("encoderDelay", evidence.encoderDelay).put("encoderPadding", evidence.encoderPadding)
                .put("decoderOutput", evidence.decoderOutput).put("normalizedFrames", evidence.normalizedFrames)
                .put("ringHighWaterFrames", evidence.ringHighWaterFrames)
                .put("encodedAllocatorHighWaterBytes", evidence.encodedAllocatorHighWaterBytes)
                .put("decoderPcmFrames", evidence.decoderPcmFrames).put("decoderOnlyFrames", evidence.decoderOnlyFrames)
                .put("sonicInputBytes", evidence.sonicInputBytes).put("sonicInputFrameCount", evidence.sonicInputFrameCount)
            assertTrue("Actually read past unchanged admission gate", sourceBytes.get() > 262144)
            assertEquals(44100, evidence.inputRate); assertEquals(2, evidence.inputChannels)
            assertTrue(evidence.ringHighWaterFrames <= 4096)
            assertEquals(frames, evidence.normalizedFrames)
            assertTrue("Non-silent decoded signal", peak > .01f)
            assertTrue(eos)
            assertNull("EOS remains terminal", lane.next(127).get(5, TimeUnit.SECONDS))
            // Literal independent generation contract, never inferred from duration or repaired at output.
            assertEquals(960000L, frames)
        } catch (failure: Throwable) {
            receipt.put("failure", failure.toString()); throw failure
        } finally {
            receipt.put("frames", frames).put("eos", eos).put("sourceBytesRead", sourceBytes.get())
                .put("pcmSha256", hex(digest.digest())).put("peak", peak.toDouble())
            valid.set(false)
            try {
                val drain = lane.retireAndDrain().get(15, TimeUnit.SECONDS)
                receipt.put("extractorReleases", drain.extractorReleases).put("openSources", drain.openSources)
                    .put("readsInFlight", drain.readsInFlight)
                assertEquals(1, drain.extractorReleases)
                assertEquals(0, drain.openSources); assertEquals(0, drain.readsInFlight)
                assertThrows(IllegalStateException::class.java) { lane.next(1) }
            } finally {
                val directory = File(instrumentation.targetContext.cacheDir, "media3-memory-lane").also { it.mkdirs() }
                File(directory, "long-stereo-eos.json").writeText(receipt.toString(2))
            }
        }
    }
}
