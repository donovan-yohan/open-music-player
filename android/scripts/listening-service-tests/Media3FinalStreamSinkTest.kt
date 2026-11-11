package com.soundq.android.playback.listening

import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.exoplayer.audio.AudioSink
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

/** Actual production sink construction + pinned processors + real bounded memory destination.
 * Synthetic decoder-shaped PCM isolates sink policy. No codec/device/audio acceptance claimed.
 */
@RunWith(RobolectricTestRunner::class)
@LooperMode(LooperMode.Mode.PAUSED)
@Config(manifest = Config.NONE, sdk = [30], application = android.app.Application::class)
class Media3FinalStreamSinkTest {
    private data class Result(val bytes: ByteArray, val sonicFrames: Long, val retries: Int, val endCalls: Int)

    @Test fun terminalPaddingIsRemovedBeforeSonicAcrossPartitions() {
        val reference = oracle(44100, 133632, 1105, 227)
        assertEquals(144000 * 8, reference.size)
        for (chunk in intArrayOf(1, 127, 997, 1152, 4096)) {
            val actual = runSink(44100, 133632, 1105, 227, chunk, 31)
            assertEquals("native input to Sonic chunk=$chunk", 132300L, actual.sonicFrames)
            assertArrayEquals("unshifted complete normalized samples chunk=$chunk", reference, actual.bytes)
            assertTrue("partial writes exercised", actual.retries > 0 || chunk == 1)
        }
    }

    @Test fun c2NativeDelayPolicyPreservesSourceOriginAndExtent() {
        // Android C2 emits raw decoder coordinates [529, N) followed by 529 zeros.
        // Media3 XingFrame converts LAME 576/756 into decoded-PCM trims 1105/227.
        // This tests that contract, not a fake codec or an alignment-fitted waveform.
        val result = runSink(44100, 133632, 1105, 227, 997, 31, "c2.android.mp3.decoder")
        assertEquals(132300L, result.sonicFrames)
        assertArrayEquals(oracle(44100, 133632, 1105, 227), result.bytes)
        val raw = Format.Builder().setSampleMimeType(MimeTypes.AUDIO_MPEG)
            .setEncoderDelay(1105).setEncoderPadding(227).build()
        assertSame(raw, mp3DecoderTrimFormat(raw, "other.mp3.decoder"))
        val untagged = raw.buildUpon().setEncoderDelay(0).setEncoderPadding(0).build()
        assertSame(untagged, mp3DecoderTrimFormat(untagged, "c2.android.mp3.decoder"))
    }

    @Test fun nativeRateSourceCoordinatesAndDelayAreExact() {
        for ((frames, delay, padding) in listOf(Triple(401, 37, 53), Triple(401, 0, 53),
            Triple(401, 37, 0), Triple(401, 0, 0), Triple(41, 0, 53), Triple(41, 53, 0))) {
            for (chunk in intArrayOf(1, 17, 1152)) {
                val result = runSink(48000, frames, delay, padding, chunk, 7)
                assertArrayEquals("exact source coordinates $frames/$delay/$padding chunk=$chunk",
                    oracle(48000, frames, delay, padding), result.bytes)
            }
        }
    }

    @Test fun terminalBackpressureCannotReplayOrDiscardAcceptedOutput() {
        val expected = oracle(44100, 8192, 113, 31)
        val result = runSink(44100, 8192, 113, 31, 8192, 7)
        assertTrue("terminal output actually needed repeated EOS", result.endCalls > 1)
        assertArrayEquals(expected, result.bytes)
    }

    @Test fun zeroPaddingDoesNotLoseOrDoubleTrimResampledInput() {
        val expected = oracle(44100, 8192, 113, 0)
        val result = runSink(44100, 8192, 113, 0, 997, 7)
        assertEquals(8079L, result.sonicFrames)
        assertArrayEquals(expected, result.bytes)
        assertTrue("input backpressure was exercised", result.retries > 0)
    }

    private fun pcm(start: Int, count: Int): ByteBuffer =
        ByteBuffer.allocateDirect(count * 4).order(ByteOrder.LITTLE_ENDIAN).apply {
            repeat(count) { i ->
                // Nonzero asymmetric source-coordinate samples expose shifts, deletion and double trim.
                putShort((((start + i) * 73 % 28001) - 14000).toShort())
                putShort((((start + i) * 139 % 26003) - 13000).toShort())
            }
            flip()
        }

    private fun runSink(rate: Int, frames: Int, delay: Int, padding: Int, chunk: Int, capacity: Int, codecName: String? = null): Result {
        val memory = ListeningMemoryOutput(capacity) { true }
        val sonic = SonicAudioProcessor().apply { setOutputSampleRateHz(48000); setSpeed(1f); setPitch(1f) }
        val sink: AudioSink = actualLaneSink(RuntimeEnvironment.getApplication(), memory, sonic)
        val format = Format.Builder().setSampleMimeType(MimeTypes.AUDIO_RAW).setPcmEncoding(C.ENCODING_PCM_16BIT)
            .setSampleRate(rate).setChannelCount(2).setEncoderDelay(delay).setEncoderPadding(padding).build()
        val bytes = ByteArrayOutputStream()
        var taken = 0L
        fun take() {
            val w = memory.take(capacity) ?: return
            assertEquals(taken, w.startFrame); taken += w.frameCount
            val b = w.stereoFloatLE; val block = ByteArray(b.remaining()); b.get(block); bytes.write(block)
        }
        var retries = 0
        var endCalls = 0
        try {
            sink.configure(AudioSink.AudioSinkConfig.Builder(mp3DecoderTrimFormat(
                format.buildUpon().setSampleMimeType(MimeTypes.AUDIO_MPEG).build(), codecName)
                .buildUpon().setSampleMimeType(MimeTypes.AUDIO_RAW).build()).build())
            sink.play()
            var offset = 0
            while (offset < frames) {
                val count = minOf(chunk, frames - offset)
                val b = if (codecName == "c2.android.mp3.decoder") {
                    val validCount = minOf(count, maxOf(0, frames - 529 - offset))
                    ByteBuffer.allocateDirect(count * 4).order(ByteOrder.LITTLE_ENDIAN).apply {
                        put(pcm(offset + 529, validCount))
                        repeat(count - validCount) { putInt(0) }; flip()
                    }
                } else pcm(offset, count)
                var turns = 0
                while (!sink.handleBuffer(b, offset.toLong() * 1000000 / rate, 1)) {
                    assertTrue("input bounded progress", ++turns < 100000)
                    retries++; take()
                }
                assertFalse(b.hasRemaining()); offset += count
                if (offset < frames) take()
            }
            do {
                assertTrue("EOS bounded progress", ++endCalls < 100000)
                sink.playToEndOfStream(); take()
            } while (!sink.isEnded)
            val accepted = memory.acceptedFrames
            val processed = if (rate == 48000) 0L else sonic.processedInputBytes
            repeat(3) { sink.playToEndOfStream(); take(); assertTrue(sink.isEnded) }
            assertEquals("repeated EOS cannot republish", accepted, memory.acceptedFrames)
            assertEquals("repeated EOS cannot refeed Sonic", processed, if (rate == 48000) 0L else sonic.processedInputBytes)
            assertEquals(accepted, taken)
            println("SINK_PROOF rate=$rate frames=$frames delay=$delay padding=$padding chunk=$chunk codec=$codecName output=$accepted sonic=${processed / 4} partialRetries=$retries eosCalls=$endCalls")
            return Result(bytes.toByteArray(), processed / 4, retries, endCalls)
        } finally { memory.retire(); sink.release() }
    }

    /** Independent extent selection in source coordinates, then the same pinned resampler algorithm.
     * No sink trim, metadata duration, offset fitting or normalized-output cuts in this oracle.
     */
    private fun oracle(rate: Int, frames: Int, delay: Int, padding: Int): ByteArray {
        val count = maxOf(0, frames - delay - padding)
        val source = pcm(minOf(delay, frames), count)
        val sonic = SonicAudioProcessor().apply { setOutputSampleRateHz(48000); setSpeed(1f); setPitch(1f) }
        sonic.configure(AudioProcessor.AudioFormat(rate, 2, C.ENCODING_PCM_16BIT))
        sonic.flush(AudioProcessor.StreamMetadata.DEFAULT)
        val output = ByteArrayOutputStream()
        fun collect(b: ByteBuffer) {
            b.order(ByteOrder.LITTLE_ENDIAN)
            val floats = ByteBuffer.allocate(b.remaining() * 2).order(ByteOrder.LITTLE_ENDIAN)
            while (b.hasRemaining()) {
                val sample = b.short.toInt()
                val frame = output.size() / 8 + floats.position() / 8
                // Pinned DefaultAudioSink applies a declared 20ms startup ramp AFTER processors.
                // This is the literal pinned integer ramp, not fitted gain or tolerance.
                // Complete output equality still exposes shifted or double-trimmed samples.
                val ramped = if (frame < 960) (((sample.toLong() shl 16) * frame / 960).toInt() shr 16) else sample
                floats.putFloat(ramped.toFloat() / 32768f)
            }
            output.write(floats.array())
        }
        if (sonic.isActive) {
            sonic.queueInput(source); collect(sonic.output); sonic.queueEndOfStream()
            var turns = 0
            while (!sonic.isEnded) { assertTrue(++turns < 1000); collect(sonic.output) }
        } else collect(source)
        sonic.reset()
        return output.toByteArray()
    }
}
