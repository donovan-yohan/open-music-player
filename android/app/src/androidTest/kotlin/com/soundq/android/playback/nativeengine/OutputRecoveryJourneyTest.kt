package com.soundq.android.playback.nativeengine

import android.content.ContextWrapper
import android.net.Uri
import android.os.Bundle
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import com.soundq.android.playback.MediaGrant
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Android player/control integration. Hardware disconnect and reopen are explicitly substituted. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class OutputRecoveryJourneyTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun main(block: () -> Unit) {
        val failure = AtomicReference<Throwable>()
        instrumentation.runOnMainSync { try { block() } catch (t: Throwable) { failure.set(t) } }
        failure.get()?.let { throw it }
    }

    private class Hardware : NativeCallbackCalls {
        @Volatile var outputError = 0
        @Volatile var recoveries = 0
        @Volatile var plays = 0
        @Volatile var position = 0L
        @Volatile var playing = false
        @Volatile var holdRecovery = false
        val recoveryEntered = CountDownLatch(1)
        val recoveryPermit = CountDownLatch(1)
        private var identity = 0L
        private var generation = 0L
        override fun open() = 1L
        override fun load(handle: Long, deck: Int, path: String, identity: Long, generation: Long, positionMs: Long): Boolean {
            this.identity = identity; this.generation = generation; position = positionMs; playing = false
            return outputError == 0
        }
        override fun control(handle: Long, operation: Int, deck: Int, value: Double, eventNanos: Long): Boolean {
            check(android.os.Looper.myLooper() != android.os.Looper.getMainLooper())
            if (operation == 9) {
                // Healthy native recovery is idempotent and does not reopen output.
                if (outputError == 0) return true
                recoveries++
                recoveryEntered.countDown()
                if (holdRecovery) check(recoveryPermit.await(10, TimeUnit.SECONDS))
                outputError = 0; playing = false
                return true
            }
            if (operation == 8) { identity = 0; playing = false; return true }
            if (outputError != 0) return false
            when (operation) {
                1 -> { plays++; playing = true }
                2 -> playing = false
                3 -> position = value.toLong()
            }
            return true
        }
        override fun state(handle: Long): String {
            val d = JSONObject().put("identity", identity).put("generation", generation)
                .put("positionMs", position).put("durationMs", 9000).put("sourceRate", 48000)
                .put("sourceFrames", 432000).put("ready", identity != 0L).put("preparing", false)
                .put("playing", playing && outputError == 0).put("eofCount", 0)
                .put("openDecoders", if (identity == 0L) 0 else 1).put("error", 0)
            return JSONObject().put("error", outputError).put("decks", JSONArray().put(d)).toString()
        }
        override fun close(handle: Long): Boolean { identity = 0; playing = false; return true }
    }

    private inner class Fixture : AutoCloseable {
        val root = File(instrumentation.targetContext.cacheDir, "output-recovery-${UUID.randomUUID()}").apply { mkdirs() }
        val graph = AppGraph(object : ContextWrapper(instrumentation.targetContext) { override fun getNoBackupFilesDir() = root },
            ApiEndpoint.parse("https://fixture.invalid/api/v1"), store = object : SessionStore {
                override fun load(endpoint: ApiEndpoint): SecretTokens? = null
                override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) {}
                override fun clear() {}
            })
        val hardware = Hardware()
        val grants = ConcurrentHashMap<String, MediaGrant>()
        val jobs = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        lateinit var player: NativeCallbackPlayer
        init {
            graph.session.accept(graph.session.beginIntent(), SecretTokens("synthetic-access", "synthetic-refresh", "synthetic-output"))
            main {
                player = NativeCallbackPlayer(graph, grants, jobs, hardware, NativeCallbackSource { _, current ->
                    check(current()); File(root, "source.encoded").apply { writeBytes(byteArrayOf(1, 2, 3)) }
                })
                val uri = Uri.parse("soundq://track/1/retained-occurrence")
                grants[uri.toString()] = MediaGrant(requireNotNull(graph.session.capture()), TrackId(1))
                val extras = Bundle().apply { putLong("trackId", 1); putLong("durationMs", 9000); putString("origin", "Context") }
                player.setMediaItem(MediaItem.Builder().setMediaId("retained-occurrence").setUri(uri)
                    .setMediaMetadata(MediaMetadata.Builder().setExtras(extras).build()).build())
                player.prepare(); player.play()
            }
            await { player.isPlaying }
            hardware.position = 2750
            await { player.currentPosition == 2750L }
        }
        fun await(predicate: () -> Boolean) {
            val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
            while (true) {
                var done = false
                main { done = predicate() }
                if (done) return
                check(System.nanoTime() < end) { "Output recovery observation deadline" }
                Thread.sleep(10)
            }
        }
        fun disconnect() {
            hardware.outputError = -899; hardware.playing = false
            await { player.playerError != null }
        }
        override fun close() {
            hardware.recoveryPermit.countDown()
            main { player.release() }
            assertTrue(player.nativeReleased.get(15, TimeUnit.SECONDS))
            jobs.cancel(); graph.close(); root.deleteRecursively()
        }
    }

    @Test fun disconnectedOutputPreservesCursorUntilExplicitPlayRecovers() {
        Fixture().use { f ->
            val plays = f.hardware.plays
            f.disconnect()
            main {
                assertEquals("retained-occurrence", f.player.currentMediaItem?.mediaId)
                assertEquals(2750L, f.player.currentPosition)
                assertFalse(f.player.playWhenReady)
                assertEquals(0, f.hardware.recoveries)
                assertEquals(plays, f.hardware.plays)
                f.player.prepare(); f.player.play()
            }
            f.await { f.hardware.recoveries == 1 && f.player.isPlaying }
            main {
                assertNull(f.player.playerError)
                assertEquals("retained-occurrence", f.player.currentMediaItem?.mediaId)
                assertEquals(2750L, f.player.currentPosition)
            }
            f.hardware.position = 3100
            f.await { f.player.currentPosition == 3100L }
        }
    }

    @Test fun pauseDuringExplicitRecoveryPreventsLateAutoplay() {
        Fixture().use { f ->
            f.disconnect(); f.hardware.holdRecovery = true
            main { f.player.prepare(); f.player.play() }
            assertTrue(f.hardware.recoveryEntered.await(5, TimeUnit.SECONDS))
            main { f.player.pause() }
            val plays = f.hardware.plays
            f.hardware.recoveryPermit.countDown()
            // Require completed recovery and settled preparation before the negative assertion.
            f.await { f.hardware.outputError == 0 && f.player.preparationSettled && f.player.playbackState == Player.STATE_READY }
            main { assertFalse(f.player.playWhenReady); assertFalse(f.player.isPlaying) }
            assertEquals(plays, f.hardware.plays)
            main { f.player.play() }
            f.await { f.player.isPlaying }
        }
    }
}
