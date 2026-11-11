package com.soundq.android.playback.nativeengine

import android.content.ContextWrapper
import android.net.Uri
import android.os.Bundle
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import com.soundq.android.playback.MediaGrant
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.random.Random

/** Real SimpleBasePlayer/Android looper; only JNI hardware and encoded IO are substituted.
 * A stored listening speed must apply even when the native capability report arrives
 * after the first deck load (which can then only start at 1.0x). */
@RunWith(AndroidJUnit4::class)
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class NativeCallbackSpeedTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun main(block: () -> Unit) {
        val failure = AtomicReference<Throwable>()
        instrumentation.runOnMainSync { try { block() } catch (t: Throwable) { failure.set(t) } }
        failure.get()?.let { throw it }
    }

    private class Hardware(@Volatile var bounds: Boolean) : NativeCallbackCalls {
        val loads = CopyOnWriteArrayList<Double>()
        val speedControls = CopyOnWriteArrayList<Double>()
        @Volatile var speed = 1.0
        private var identity = 0L
        private var generation = 0L
        override fun open(): Long = 1
        override fun load(handle: Long, deck: Int, path: String, identity: Long, generation: Long, positionMs: Long): Boolean {
            loads.add(1.0); speed = 1.0; this.identity = identity; this.generation = generation; return true
        }
        override fun loadSpeed(handle: Long, deck: Int, path: String, identity: Long, generation: Long, positionMs: Long, speed: Double): Boolean {
            if (!bounds) return false
            loads.add(speed); this.speed = speed; this.identity = identity; this.generation = generation; return true
        }
        override fun control(handle: Long, operation: Int, deck: Int, value: Double, eventNanos: Long): Boolean {
            if (operation == 10) { if (!bounds) return false; speedControls.add(value); speed = value }
            if (operation == 8) identity = 0
            return true
        }
        override fun state(handle: Long): String {
            val d = JSONObject().put("identity", identity).put("generation", generation).put("positionMs", 0)
                .put("durationMs", 3000).put("sourceRate", 48000).put("sourceFrames", 144000)
                .put("ready", identity != 0L).put("preparing", false).put("playing", false)
                .put("eofCount", 0).put("openDecoders", if (identity == 0L) 0 else 1).put("error", 0)
                .put("speed", speed).put("rate", speed)
            val root = JSONObject().put("error", 0).put("decks", JSONArray().put(d))
            if (bounds) root.put("speedMin", 0.5).put("speedMax", 2.0)
            return root.toString()
        }
        override fun close(handle: Long): Boolean { identity = 0; return true }
    }

    private inner class Fixture(boundsAtOpen: Boolean) : AutoCloseable {
        val root = File(instrumentation.targetContext.cacheDir, "speed-test-${UUID.randomUUID()}").apply { mkdirs() }
        val graph = AppGraph(object : ContextWrapper(instrumentation.targetContext) { override fun getNoBackupFilesDir() = root },
            ApiEndpoint.parse("https://fixture.invalid/api/v1"), store = object : SessionStore {
                override fun load(endpoint: ApiEndpoint): SecretTokens? = null
                override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) {}
                override fun clear() {}
            })
        val grants = ConcurrentHashMap<String, MediaGrant>()
        val hardware = Hardware(boundsAtOpen)
        val file = File(root, "source.encoded")
        val jobs = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        lateinit var player: NativeCallbackPlayer
        init {
            graph.session.accept(graph.session.beginIntent(), SecretTokens("fixture-access", "fixture-refresh", "callback"))
            main {
                player = NativeCallbackPlayer(graph, grants, jobs, hardware, NativeCallbackSource { _, _ ->
                    file.writeBytes(byteArrayOf(1, 2, 3)); file
                }, Random(23))
            }
        }
        fun item(id: String): MediaItem {
            val scope = requireNotNull(graph.session.capture())
            val uri = Uri.parse("soundq://track/1/$id")
            grants[uri.toString()] = MediaGrant(scope, TrackId(1))
            val extras = Bundle().apply { putLong("trackId", 1); putLong("durationMs", 3000); putString("origin", "Context") }
            return MediaItem.Builder().setMediaId(id).setUri(uri).setMediaMetadata(MediaMetadata.Builder().setExtras(extras).build()).build()
        }
        fun await(message: String, predicate: () -> Boolean) {
            val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
            while (true) {
                var done = false
                main { done = predicate() }
                if (done) return
                check(System.nanoTime() < end) { message }
                Thread.sleep(10)
            }
        }
        override fun close() {
            main { player.release() }
            assertTrue(player.nativeReleased.get(15, TimeUnit.SECONDS))
            jobs.cancel(); graph.close(); root.deleteRecursively()
        }
    }

    @Test fun storedSpeedAppliesWhenCapabilityArrivesAfterFirstLoad() {
        Fixture(boundsAtOpen = false).use { f ->
            main { f.player.speedFor = { 1.5 }; f.player.setMediaItems(listOf(f.item("one"))); f.player.prepare() }
            f.await("Loaded before the capability report") { f.player.playbackState == Player.STATE_READY }
            assertEquals("only normal speed is admissible before the capability", listOf(1.0), f.hardware.loads.toList())
            f.hardware.bounds = true
            f.await("Stored 1.5x re-applied to the loaded deck") { f.player.listeningSpeed()?.accepted == 1.5 }
            assertEquals(listOf(1.5), f.hardware.speedControls.toList())
            assertEquals(1.5, f.hardware.speed, 0.0)
        }
    }

    @Test fun knownCapabilityLoadsAtStoredSpeedWithoutAReconcileRequest() {
        Fixture(boundsAtOpen = true).use { f ->
            // Let the first capability observation land before any load.
            f.await("Capability observed") { f.player.listeningSpeed() == null }
            Thread.sleep(200)
            main { f.player.speedFor = { 1.5 }; f.player.setMediaItems(listOf(f.item("one"))); f.player.prepare() }
            f.await("Loaded at the stored speed") { f.player.listeningSpeed()?.accepted == 1.5 }
            Thread.sleep(300)
            assertEquals(listOf(1.5), f.hardware.loads.toList())
            assertTrue("no redundant speed control", f.hardware.speedControls.isEmpty())
        }
    }
}
