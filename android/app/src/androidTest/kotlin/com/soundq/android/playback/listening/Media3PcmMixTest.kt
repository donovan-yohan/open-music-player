package com.soundq.android.playback.listening

import android.net.Uri
import androidx.media3.datasource.AssetDataSource
import androidx.media3.datasource.DataSource
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.playback.mix.NativeMix
import java.io.File
import java.nio.ByteOrder
import java.nio.ByteBuffer
import java.util.concurrent.TimeUnit
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Finite synthetic fixture only. Real codec, memory sink and JNI DSP; no audio output. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@RunWith(AndroidJUnit4::class)
class Media3PcmMixTest {
    @Test fun decodedMp3WindowsReachExistingMixerWithExactSourceAndFadeCoordinates() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.context
        val directory = File(instrumentation.targetContext.cacheDir, "media3-pcm-mix").also { it.mkdirs() }
        val sourceFrames = 144000
        fun decode(name: String): FloatArray {
            val lane = Media3ListeningLane(instrumentation.targetContext,
                Uri.parse("asset:///listening-mp3/$name"),
                DataSource.Factory { AssetDataSource(context) }, { true }, 4096)
            val samples = FloatArray(sourceFrames * 2)
            var frames = 0
            try {
                while (true) {
                    val window = lane.next(997).get(15, TimeUnit.SECONDS) ?: break
                    assertEquals(frames.toLong(), window.startFrame)
                    assertTrue(window.frameCount in 1..997)
                    // Refuse an unexpected extent. Never cut or pad decoder output to fit the fixture.
                    check(window.frameCount <= sourceFrames - frames)
                    val data = window.stereoFloatLE.order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
                    assertEquals(window.frameCount * 2, data.remaining())
                    data.get(samples, frames * 2, window.frameCount * 2)
                    frames += window.frameCount
                }
                assertEquals(sourceFrames, frames)
                val evidence = lane.evidence().get(5, TimeUnit.SECONDS)
                assertEquals(44100, evidence.inputRate)
                assertEquals(if (name == "mono.mp3") 1 else 2, evidence.inputChannels)
                assertEquals(sourceFrames.toLong(), evidence.normalizedFrames)
                assertTrue(evidence.ringHighWaterFrames <= 4096)
                assertTrue(samples.all { it.isFinite() })
                return samples
            } finally {
                val drain = lane.retireAndDrain().get(15, TimeUnit.SECONDS)
                assertEquals(1, drain.extractorReleases)
                assertEquals(0, drain.openSources)
                assertEquals(0, drain.readsInFlight)
            }
        }
        // Full captures exist only for these three-second instrumentation fixtures.
        val outgoing = decode("stereo.mp3")
        val incoming = decode("mono.mp3")
        val incomingStart = 96000
        val overlap = 48000
        val totalFrames = incomingStart + sourceFrames
        var maximumError = 0.0
        var comparedSamples = 0L
        var overlapSamples = 0L
        for (origin in 0 until totalFrames step 997) {
            val count = minOf(997, totalFrames - origin)
            val fields = mutableListOf<Long>()
            val windows = mutableListOf<FloatArray>()
            for (index in 0..1) {
                val start = if (index == 0) 0 else incomingStart
                val end = start + sourceFrames
                if (end <= origin || start >= origin + count) continue
                val local = maxOf(origin, start) - start
                val stop = minOf(origin + count, end) - start
                fields.addAll(listOf(index + 11L, start.toLong(), end.toLong(), 0L,
                    sourceFrames.toLong(), if (index == 0) 0L else overlap.toLong(),
                    if (index == 0) overlap.toLong() else 0L, local.toLong()))
                windows += (if (index == 0) outgoing else incoming).copyOfRange(local * 2, stop * 2)
            }
            val output = ByteArray(count * 8 + 16) { 37 }
            NativeMix.renderPcmBlock(origin.toLong(), count, fields.toLongArray(),
                windows.toTypedArray(), FloatArray(windows.size) { 1f }, output)
            assertTrue(output.copyOfRange(count * 8, output.size).all { it == 37.toByte() })
            val actual = ByteBuffer.wrap(output, 0, count * 8).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
            repeat(count) { offset ->
                val frame = origin + offset
                val progress = ((frame - incomingStart) / overlap.toDouble()).coerceIn(0.0, 1.0)
                repeat(2) { channel ->
                    val expected = (if (frame < sourceFrames) outgoing[frame * 2 + channel] * cos(progress * PI / 2) else 0.0) +
                        (if (frame >= incomingStart) incoming[(frame - incomingStart) * 2 + channel] * sin(progress * PI / 2) else 0.0)
                    val sample = actual.get().toDouble()
                    assertTrue(sample.isFinite())
                    maximumError = maxOf(maximumError, abs(sample - expected))
                    comparedSamples++
                    if (frame in incomingStart until sourceFrames) overlapSamples++
                }
            }
        }
        File(directory, "RESULT.json").writeText(JSONObject()
            .put("comparedSamples", comparedSamples).put("overlapSamples", overlapSamples)
            .put("sourceFrames", sourceFrames).put("renderFrames", totalFrames)
            .put("maximumAbsoluteError", maximumError).put("tolerance", .000001)
            .put("blockFrames", 997).put("actualCodecAndJni", true)
            .put("scope", "Finite synthetic MP3 decode-to-existing-DSP path. No audible output or ordinary service activation.")
            .toString(2))
        assertEquals(totalFrames.toLong() * 2, comparedSamples)
        assertEquals(overlap.toLong() * 2, overlapSamples)
        assertTrue("Every-sample source/envelope error $maximumError", maximumError <= .000001)
    }
}
