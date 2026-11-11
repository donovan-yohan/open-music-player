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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.random.Random

/** Real SimpleBasePlayer/Android looper. Only JNI hardware and encoded IO are substituted. */
@RunWith(AndroidJUnit4::class)
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class NativeCallbackJourneyTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun main(block: () -> Unit) {
        val failure = AtomicReference<Throwable>()
        instrumentation.runOnMainSync { try { block() } catch (t: Throwable) { failure.set(t) } }
        failure.get()?.let { throw it }
    }

    private class Hardware : NativeCallbackCalls {
        val threads = java.util.concurrent.CopyOnWriteArrayList<String>()
        val operations = java.util.concurrent.CopyOnWriteArrayList<Int>()
        @Volatile var allowUnload = true
        @Volatile var allowClose = true
        @Volatile var endedCount = 0L
        private var position = 0L
        private var identity = 0L
        private var generation = 0L
        private var playing = false
        private fun thread() { check(android.os.Looper.myLooper() != android.os.Looper.getMainLooper()); threads.add(Thread.currentThread().name) }
        override fun open(): Long { thread(); return 1 }
        override fun load(handle: Long, deck: Int, path: String, identity: Long, generation: Long, positionMs: Long): Boolean {
            thread(); this.identity = identity; this.generation = generation; position = positionMs; playing = false; return true
        }
        override fun control(handle: Long, operation: Int, deck: Int, value: Double, eventNanos: Long): Boolean {
            thread(); operations.add(operation)
            if (operation == 8 && !allowUnload) return false
            when (operation) { 1 -> playing = true; 2 -> playing = false; 3 -> position = value.toLong(); 8 -> { identity = 0; playing = false } }
            return true
        }
        override fun state(handle: Long): String {
            thread()
            val d = JSONObject().put("identity", identity).put("generation", generation).put("positionMs", position)
                .put("durationMs", 3000).put("sourceRate", 48000).put("sourceFrames", 144000)
                .put("ready", identity != 0L).put("preparing", false).put("playing", playing)
                .put("eofCount", endedCount).put("openDecoders", if (identity == 0L) 0 else 1).put("error", 0)
            return JSONObject().put("error", 0).put("decks", JSONArray().put(d)).toString()
        }
        override fun close(handle: Long): Boolean { thread(); if (!allowClose) return false; identity = 0; return true }
    }

    private inner class Fixture : AutoCloseable {
        val root = File(instrumentation.targetContext.cacheDir, "callback-test-${UUID.randomUUID()}").apply { mkdirs() }
        val graph = AppGraph(object : ContextWrapper(instrumentation.targetContext) { override fun getNoBackupFilesDir() = root },
            ApiEndpoint.parse("https://fixture.invalid/api/v1"), store = object : SessionStore {
                override fun load(endpoint: ApiEndpoint): SecretTokens? = null
                override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) {}
                override fun clear() {}
            })
        val grants = ConcurrentHashMap<String, MediaGrant>()
        val hardware = Hardware()
        val entered = CountDownLatch(1)
        val permit = CountDownLatch(1)
        val file = File(root, "source.encoded")
        val jobs = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        lateinit var player: NativeCallbackPlayer
        init {
            graph.session.accept(graph.session.beginIntent(), SecretTokens("fixture-access", "fixture-refresh", "callback"))
            main {
                player = NativeCallbackPlayer(graph, grants, jobs, hardware, NativeCallbackSource { _, current ->
                    entered.countDown(); check(permit.await(10, TimeUnit.SECONDS)); check(current())
                    file.writeBytes(byteArrayOf(1, 2, 3)); file
                }, Random(19))
            }
        }
        fun item(id: String, manual: Boolean = false, continuation: Boolean = false): MediaItem {
            val scope = requireNotNull(graph.session.capture())
            val uri = Uri.parse("soundq://track/1/$id")
            grants[uri.toString()] = MediaGrant(scope, TrackId(1))
            val extras = Bundle().apply { putLong("trackId", 1); putLong("durationMs", 9000); putBoolean("manual", manual); putString("origin", if (continuation) "Continuation" else if (manual) "Manual" else "Context") }
            return MediaItem.Builder().setMediaId(id).setUri(uri).setMediaMetadata(MediaMetadata.Builder().setExtras(extras).build()).build()
        }
        fun await(predicate: () -> Boolean) {
            val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
            while (true) {
                var done = false
                main { done = predicate() }
                if (done) return
                check(System.nanoTime() < end) { "Player observation deadline" }
                Thread.sleep(10)
            }
        }
        override fun close() {
            permit.countDown()
            main { player.release() }
            assertTrue(player.nativeReleased.get(15, TimeUnit.SECONDS))
            jobs.cancel(); graph.close(); root.deleteRecursively()
        }
    }

    @Test fun heldPreparationPauseRetainsLatestIntentAndReleasesFile() {
        Fixture().use { f ->
            main { f.player.setMediaItems(listOf(f.item("one"))); f.player.prepare(); f.player.play() }
            assertTrue(f.entered.await(5, TimeUnit.SECONDS))
            main { f.player.pause() }
            f.permit.countDown()
            f.await { f.player.playbackState == Player.STATE_READY }
            main { assertFalse(f.player.playWhenReady); assertFalse(f.player.isPlaying); assertEquals(3000L, f.player.duration) }
            assertFalse(f.hardware.operations.contains(1))
            assertTrue(f.file.exists())
            main { f.player.stop() }
            f.await { !f.file.exists() }
            assertEquals(1, f.hardware.threads.distinct().size)
        }
    }

    @Test fun canonicalContextShuffleManualPriorityAndMutationPreserveOccurrences() {
        Fixture().use { f -> main {
            val rows = (0..4).map { f.item("visit-$it") }
            f.player.setMediaItems(rows, 2, 600)
            f.player.shuffleModeEnabled = true
            val order = f.player.nativeTraversalForTest()
            assertEquals(2, order.first())
            f.player.addMediaItem(3, f.item("manual", manual = true))
            f.player.seekToNextMediaItem()
            assertEquals("manual", f.player.currentMediaItem!!.mediaId)
            f.player.addMediaItem(f.item("tail", continuation = true))
            f.player.moveMediaItem(0, 1)
            f.player.replaceMediaItem(0, f.item("replacement"))
            f.player.removeMediaItem(0)
            assertEquals("manual", f.player.currentMediaItem!!.mediaId)
            assertEquals(f.player.mediaItemCount, (0 until f.player.mediaItemCount).map { f.player.getMediaItemAt(it).mediaId }.distinct().size)
            f.player.setMediaItems(rows, 0, 0)
            assertEquals((0..4).toList(), f.player.nativeTraversalForTest())
            f.player.repeatMode = Player.REPEAT_MODE_ALL
            f.player.seekTo(4, 0); f.player.seekToNextMediaItem()
            assertEquals("visit-0", f.player.currentMediaItem!!.mediaId)
            assertFalse(f.player.playWhenReady)
        } }
    }

    @Test fun accountRetirementRejectsHeldSourceAndFreshQueueStillPrepares() {
        Fixture().use { f ->
            main { f.player.setMediaItems(listOf(f.item("old"))); f.player.prepare(); f.player.play() }
            assertTrue(f.entered.await(5, TimeUnit.SECONDS))
            main { f.graph.session.revoke(); f.player.stop(); f.player.clearMediaItems() }
            f.permit.countDown()
            f.await { f.player.preparationSettled }
            main {
                assertEquals(0, f.player.mediaItemCount)
                f.graph.session.accept(f.graph.session.beginIntent(), SecretTokens("next-access", "next-refresh", "callback-next"))
                f.player.setMediaItems(listOf(f.item("fresh"))); f.player.prepare()
            }
            f.await { f.player.playbackState == Player.STATE_READY }
            main { assertEquals("fresh", f.player.currentMediaItem!!.mediaId); assertFalse(f.player.playWhenReady) }
        }
    }

    @Test fun nativeEofIsTheOnlyCompletionAndRepeatOneSeeksWithoutReopening() {
        Fixture().use { f ->
            val completed = java.util.concurrent.CopyOnWriteArrayList<String>()
            f.permit.countDown()
            main {
                f.player.addCompletionListener { completed.add(it.mediaId) }
                f.player.setMediaItems(listOf(f.item("repeat")))
                f.player.repeatMode = Player.REPEAT_MODE_ONE
                f.player.prepare()
            }
            f.await { f.player.playbackState == Player.STATE_READY }
            assertTrue(completed.isEmpty())
            main { f.player.seekTo(2500) }
            f.await { f.player.currentPosition == 2500L }
            assertTrue(completed.isEmpty())
            f.hardware.endedCount = 1
            f.await { completed.size == 1 && f.player.currentPosition == 0L }
            assertEquals(listOf("repeat"), completed)
            assertEquals(1, f.hardware.threads.distinct().size)
            main {
                assertEquals("repeat", f.player.currentMediaItem!!.mediaId)
                assertFalse(f.player.playWhenReady)
            }
        }
    }

    @Test fun endpointSeekCompletionIsNotConsumedBySeekAcknowledgement() {
        Fixture().use { f ->
            val completed = java.util.concurrent.CopyOnWriteArrayList<String>()
            f.permit.countDown()
            main {
                f.player.addCompletionListener { completed.add(it.mediaId) }
                f.player.setMediaItems(listOf(f.item("endpoint")))
                f.player.prepare(); f.player.play()
            }
            f.await { f.player.isPlaying }
            main { f.player.seekTo(3000) }
            f.hardware.endedCount = 1
            f.await { f.player.playbackState == Player.STATE_ENDED }
            assertEquals(listOf("endpoint"), completed)
        }
    }

    @Test fun rejectedMixSetLeavesAcceptedQueueAndIntentUntouched() {
        Fixture().use { f -> main {
            val ordinary = f.item("accepted")
            f.player.setMediaItems(listOf(ordinary), 0, 700)
            val mix = MediaItem.Builder().setMediaId("mix").setUri("soundqmix://plan/refused").build()
            try { f.player.setMediaItem(mix); fail("Mix must be refused before mutation") }
            catch (_: IllegalArgumentException) { }
            assertEquals("accepted", f.player.currentMediaItem!!.mediaId)
            assertEquals(700L, f.player.currentPosition)
            assertFalse(f.player.playWhenReady)
            assertEquals(1L, f.entered.count)
        } }
    }
}
