package com.soundq.android.playback.listening

import android.content.ContextWrapper
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import com.soundq.android.data.timeline.TimelineSource
import com.soundq.android.playback.MediaGrant
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.*

/** Real signed acquisition (authorized local cache), preparation, MediaCodec, cursor and JNI.
 * Compiling this class is not execution. Parent owns device/runtime qualification.
 */
@RunWith(AndroidJUnit4::class)
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class PreparedListeningSourceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val output = Uri.parse("soundqlistening://instrumented-source")
    private fun readAll(source: DataSource, maximum: Int = 8191): ByteArray {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(maximum + 6) { 37 }
        var step = 0
        while (true) {
            val n = source.read(buffer, 3, if (step++ % 7 == 0) 3 else maximum)
            if (n < 0) break
            assertTrue(n > 0); assertEquals(37, buffer[2].toInt())
            out.write(buffer, 3, n)
        }
        return out.toByteArray()
    }
    private fun exercise(names: List<String>, overlap: Long) {
        val root = File(instrumentation.targetContext.cacheDir, "prepared-source-${java.util.UUID.randomUUID()}").apply { mkdirs() }
        val context = object : ContextWrapper(instrumentation.targetContext) { override fun getNoBackupFilesDir() = root }
        val store = object : SessionStore {
            override fun load(endpoint: ApiEndpoint): SecretTokens? = null
            override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) {}
            override fun clear() {}
        }
        val graph = AppGraph(context, ApiEndpoint.parse("https://fixture.invalid/api/v1"), store = store)
        assertTrue(graph.session.accept(graph.session.beginIntent(), SecretTokens("fixture-access", "fixture-refresh", "fixture-source")))
        val scope = graph.session.capture()!!
        val grants = ConcurrentHashMap<String, MediaGrant>()
        val items = names.mapIndexed { i, name ->
            val track = TrackId(i + 1L)
            val encoded = instrumentation.context.assets.open("listening-mp3/$name").use { it.readBytes() }
            val stage = requireNotNull(graph.temporaryAudio.begin(scope, track, encoded.size.toLong()))
            stage.append(encoded, 0, encoded.size); assertTrue(stage.finish())
            val uri = Uri.parse("soundq://track/${track.value}/prepared-$i")
            grants[uri.toString()] = MediaGrant(scope, track)
            MediaItem.Builder().setMediaId("prepared-$i").setUri(uri).build()
        }
        val schedule = ListeningSchedule.compile(names.indices.map { TimelineSource("prepared-$it", it + 1L, "Fixture $it", 3000, com.soundq.android.data.timeline.QueueSegment.Manual) }, overlap)
        fun valid() = graph.session.current(scope) && items.all { grants[it.localConfiguration!!.uri.toString()]?.scope === scope }
        val prepared = PreparedListening.prepare(graph, grants, items, schedule, ::valid)
        val source = prepared.acquire()
        try {
            assertEquals(44 + schedule.durationMs * 384, source.open(DataSpec(output)))
            val all = readAll(source)
            assertEquals(44 + schedule.durationMs * 384, all.size.toLong())
            source.close()
            // Independent actual decoder captures, not a fitted shift or a looser mix oracle.
            // The accepted decoder-vs-reference tolerance remains in Media3ListeningLaneTest.
            val references = names.map { name ->
                val lane = Media3ListeningLane(graph.applicationContext,
                    Uri.parse("asset:///listening-mp3/$name"),
                    DataSource.Factory { androidx.media3.datasource.AssetDataSource(instrumentation.context) }, ::valid)
                val capture = ByteArrayOutputStream()
                try {
                    while (true) {
                        val window = lane.next(997).get(15, java.util.concurrent.TimeUnit.SECONDS) ?: break
                        val data = window.stereoFloatLE
                        val chunk = ByteArray(data.remaining()); data.get(chunk); capture.write(chunk)
                        check(capture.size() <= 144000 * 8) { "Fixture exceeded catalog extent" }
                    }
                } finally {
                    val receipt = lane.retireAndDrain().get(15, java.util.concurrent.TimeUnit.SECONDS)
                    assertEquals(0, receipt.openSources); assertEquals(0, receipt.readsInFlight)
                }
                val bytes = capture.toByteArray(); assertEquals(144000 * 8, bytes.size)
                val floats = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
                FloatArray(floats.remaining()).also { floats.get(it) }
            }
            val actual = ByteBuffer.wrap(all, 44, all.size - 44).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
            var maxError = 0.0
            for (frame in 0 until schedule.durationMs * 48) repeat(2) { channel ->
                var expected = 0.0
                schedule.occurrences.forEachIndexed { i, c ->
                    val local = frame - c.startMs * 48
                    if (local in 0 until 144000L) {
                        val gain = when {
                            c.fadeInMs > 0 && local < c.fadeInMs * 48 -> sin(local.toDouble() / (c.fadeInMs * 48) * PI / 2)
                            c.fadeOutMs > 0 && 144000 - local < c.fadeOutMs * 48 -> sin((144000 - local).toDouble() / (c.fadeOutMs * 48) * PI / 2)
                            else -> 1.0
                        }
                        expected += references[i][local.toInt() * 2 + channel] * gain
                    }
                }
                maxError = maxOf(maxError, abs(actual.get() - expected))
            }
            assertTrue("Unshifted every-sample max error $maxError", maxError <= .000001)
            for (at in listOf(0L, 45L, 44 + 120000L * 8 + 3, all.size - 1L, all.size.toLong(), 44L)) {
                source.open(DataSpec.Builder().setUri(output).setPosition(at).setLength(23).build())
                assertArrayEquals(all.copyOfRange(at.toInt(), minOf(all.size, at.toInt() + 23)), readAll(source, 5))
                source.close()
            }
            source.open(DataSpec(output))
            graph.session.revoke()
            val untouched = ByteArray(9) { 37 }
            try { source.read(untouched, 0, 9); fail("Revoked account cannot publish") } catch (_: IllegalStateException) {}
            assertTrue(untouched.all { it == 37.toByte() })
        } finally {
            source.close(); prepared.close(); graph.close()
        }
        val deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(15)
        while (graph.directory.listFiles()?.any { it.name.startsWith("listening-") } == true && System.nanoTime() < deadline) Thread.sleep(5)
        assertFalse(graph.directory.listFiles()?.any { it.name.startsWith("listening-") } == true)
    }
    @Test fun realMp3PreparationPartialBytesBackwardForwardAndAccountRetirement() = exercise(listOf("stereo.mp3"), 0)
    @Test fun realMp3StereoMonoOverlapRetainsOriginalFadeAnchors() = exercise(listOf("stereo.mp3", "mono.mp3"), 1000)
    @Test fun duplicateRecordingOccurrencesDecodeIndependently() = exercise(listOf("stereo.mp3", "stereo.mp3"), 1000)
}
