package com.soundq.android.playback.listening

import android.net.Uri
import android.os.Handler
import androidx.media3.common.C
import androidx.media3.datasource.FileDataSource
import androidx.media3.decoder.DecoderInputBuffer
import androidx.media3.exoplayer.FormatHolder
import androidx.media3.exoplayer.audio.MediaCodecAudioRenderer
import androidx.media3.exoplayer.source.SampleStream
import androidx.media3.exoplayer.upstream.DefaultAllocator
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

/** Direct encoded consumer of the real lane-selected progressive period/SampleQueue.
 * Deliberately bypasses MediaCodec render: this proves allocation recovery and encoded EOS,
 * not Android PCM success. Private reflection exposes existing ownership, not a fake period.
 */
@RunWith(RobolectricTestRunner::class)
@LooperMode(LooperMode.Mode.PAUSED)
@Config(manifest = Config.NONE, sdk = [28], application = android.app.Application::class)
class Media3EncodedRetentionTest {
    @Test fun consumedSamplesRecoverAdmissionAndReachEncodedEosWithoutLosingUnreadPackets() {
        val file = File(checkNotNull(System.getProperty("soundq.listening.longMp3")))
        assertEquals(802524L, file.length())
        assertTrue(file.length() > 262144)
        val lane = Media3ListeningLane(RuntimeEnvironment.getApplication(), Uri.fromFile(file),
            androidx.media3.datasource.DataSource.Factory { FileDataSource() }, { true }, 8)
        fun field(name: String) = Media3ListeningLane::class.java.getDeclaredField(name).apply { isAccessible = true }
        val handler = field("handler").get(lane) as Handler
        fun <T> onWorker(body: () -> T): T {
            val done = CompletableFuture<T>()
            handler.post { try { done.complete(body()) } catch (failure: Throwable) { done.completeExceptionally(failure) } }
            return done.get(5, TimeUnit.SECONDS)
        }
        val loading = Media3ListeningLane::class.java.getDeclaredMethod("continueLoading").apply { isAccessible = true }
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
        fun await(label: String, condition: () -> Boolean) {
            while (!onWorker(condition)) {
                assertTrue(label, System.nanoTime() < deadline)
                Thread.sleep(5)
            }
        }
        try {
            await("Actual progressive period prepared") { field("ready").getBoolean(lane) }
            val allocator = field("allocator").get(lane) as DefaultAllocator
            val renderer = field("renderer").get(lane) as MediaCodecAudioRenderer
            val stream = onWorker { checkNotNull(renderer.stream) }
            await("Unchanged 262144-byte admission gate reached before consumption") {
                loading.invoke(lane)
                allocator.totalBytesAllocated >= 262144
            }
            val gateBytes = onWorker { allocator.totalBytesAllocated }
            val holder = FormatHolder()
            val input = DecoderInputBuffer(DecoderInputBuffer.BUFFER_REPLACEMENT_MODE_NORMAL)
            val digest = MessageDigest.getInstance("SHA-256")
            var samples = 0; var eos = false; var recovered = false; var peekChecked = false
            var minimumAfterGate = gateBytes
            while (!eos && System.nanoTime() < deadline) {
                onWorker {
                    assertSame("Exact selected stream remains installed", stream, renderer.stream)
                    if (!peekChecked) {
                        input.clear()
                        val first = stream.readData(holder, input, SampleStream.FLAG_PEEK)
                        if (first == C.RESULT_BUFFER_READ && !input.isEndOfStream) {
                            val pts = input.timeUs
                            val peek = ByteArray(input.data!!.position())
                            input.flip(); input.data!!.get(peek)
                            input.clear()
                            assertEquals(C.RESULT_BUFFER_READ, stream.readData(holder, input, SampleStream.FLAG_PEEK))
                            assertEquals(pts, input.timeUs)
                            val repeated = ByteArray(input.data!!.position())
                            input.flip(); input.data!!.get(repeated)
                            assertArrayEquals(peek, repeated)
                            loading.invoke(lane)
                            assertEquals("Peeks must not retire consumed allocations", gateBytes, allocator.totalBytesAllocated)
                            peekChecked = true
                        }
                    }
                    if (!peekChecked) return@onWorker // A format read must not fall through to consumption.
                    // Drain available real encoded samples before asking the unchanged gate to reopen.
                    repeat(1024) {
                        if (!eos) {
                            input.clear()
                            when (stream.readData(holder, input, 0)) {
                                C.RESULT_BUFFER_READ -> if (input.isEndOfStream) eos = true else {
                                    input.flip(); digest.update(input.data!!); samples++
                                }
                                C.RESULT_FORMAT_READ -> assertEquals("audio/mpeg", holder.format!!.sampleMimeType)
                            }
                        }
                    }
                    loading.invoke(lane)
                    minimumAfterGate = minOf(minimumAfterGate, allocator.totalBytesAllocated)
                    recovered = recovered || allocator.totalBytesAllocated < 262144
                }
                if (!eos) Thread.sleep(5)
            }
            println("encoded retention gateBytes=$gateBytes minimumAfterGate=$minimumAfterGate recovered=$recovered samples=$samples eos=$eos")
            assertTrue("Consumed allocations must recover below unchanged gate and permit encoded EOS", recovered && eos)
            assertTrue(peekChecked)
            assertEquals("Independent ffprobe packet count", 767, samples)
            assertEquals("Independent ffprobe ordered packet digest", "c25a7ae3b6050ab56e2d17e8f61418d043d10c35974e53cf1bfe849f72dfac51",
                digest.digest().joinToString("") { "%02x".format(it) })
        } finally {
            val drain = lane.retireAndDrain().get(15, TimeUnit.SECONDS)
            assertEquals(1, drain.extractorReleases)
            assertEquals(0, drain.openSources); assertEquals(0, drain.readsInFlight)
        }
    }
}
