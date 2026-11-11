package com.soundq.android.playback.nativeengine

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.concurrent.CancellationException

/** Platform-compatible real decoder tests. Requires Android execution; host compilation is not a pass. */
@RunWith(AndroidJUnit4::class)
class PhonePlatformStageTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun digest(file: File) = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).toList()
    private fun wav(seconds: Int): File {
        val rate = 8000; val bytes = seconds * rate * 2
        val file = File.createTempFile("synthetic-", ".wav", context.cacheDir)
        RandomAccessFile(file, "rw").use { out ->
            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
                .put("RIFF".toByteArray()).putInt(36 + bytes).put("WAVEfmt ".toByteArray())
                .putInt(16).putShort(1).putShort(1).putInt(rate).putInt(rate * 2).putShort(2).putShort(16)
                .put("data".toByteArray()).putInt(bytes).array()
            out.write(header)
            val page = ByteBuffer.allocate(rate * 2).order(ByteOrder.LITTLE_ENDIAN)
            repeat(rate) { frame -> page.putShort(if (frame % 16 < 8) 8192 else -8192) }
            repeat(seconds) { out.write(page.array()) }
        }
        return file
    }
    private fun frames(file: File): Pair<Int, Long> = RandomAccessFile(file, "r").use {
        val raw = ByteArray(32); it.readFully(raw)
        val h = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals("SQP1", raw.copyOfRange(0, 4).toString(Charsets.US_ASCII))
        val rate = h.getInt(8); val frames = h.getLong(16)
        assertEquals(32 + frames * 8, it.length())
        rate to frames
    }
    @Test fun decodedExtentQualifiesStrictThresholdAndPreservesOriginal() {
        for (seconds in listOf(600, 601)) {
            val source = wav(seconds); val before = digest(source)
            var decoded: File? = null
            try {
                decoded = AndroidPlatformAudioStage.decode(source, context.cacheDir) { true }
                val (rate, count) = frames(decoded)
                assertEquals(seconds * rate.toLong(), count)
                assertEquals(seconds > 600, count > rate.toLong() * 600)
                assertEquals(before, digest(source))
            } finally { decoded?.delete(); source.delete() }
        }
    }
    @Test fun m4aAacAndFlacActuallyDecodeToFiniteNonzeroPcm() {
        val testContext = InstrumentationRegistry.getInstrumentation().context
        for (name in listOf("tone.m4a", "tone.flac")) {
            val source = File.createTempFile("synthetic-", name, context.cacheDir)
            testContext.assets.open("local-audio/$name").use { input -> source.outputStream().use { input.copyTo(it) } }
            val before = digest(source); var decoded: File? = null
            try {
                decoded = AndroidPlatformAudioStage.decode(source, context.cacheDir) { true }
                val (rate, count) = frames(decoded)
                assertTrue(count in rate.toLong()..rate.toLong() * 3)
                RandomAccessFile(decoded, "r").use {
                    it.seek(32); val page = ByteArray(4096); it.readFully(page)
                    val samples = ByteBuffer.wrap(page).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
                    var nonzero = false
                    while (samples.hasRemaining()) { val v = samples.get(); assertTrue(v.isFinite()); nonzero = nonzero || kotlin.math.abs(v) > .001f }
                    assertTrue(nonzero)
                }
                assertEquals(before, digest(source))
            } finally { decoded?.delete(); source.delete() }
        }
    }
    @Test fun cancellationClosesCodecAndRemovesOnlyOwnedStages() {
        val source = wav(3); val before = digest(source)
        val initial = context.cacheDir.listFiles()!!.map { it.name }.toSet()
        var calls = 0
        try {
            AndroidPlatformAudioStage.decode(source, context.cacheDir) { ++calls < 3 }
            fail("Expected source cancellation")
        } catch (_: CancellationException) {
            assertEquals(initial, context.cacheDir.listFiles()!!.map { it.name }.toSet())
            assertEquals(before, digest(source))
        } finally { source.delete() }
    }
}
