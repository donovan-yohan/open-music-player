package com.soundq.android.playback.listening

import android.content.ContextWrapper
import android.net.Uri
import android.os.Bundle
import android.os.FileObserver
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.PlayerMessage
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.AppGraph
import com.soundq.android.data.ApiEndpoint
import com.soundq.android.data.SecretTokens
import com.soundq.android.data.SessionStore
import com.soundq.android.data.TrackId
import com.soundq.android.playback.MediaGrant
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs

/** Actual create -> signed cache acquisition -> MP3 preparation -> progressive WAV -> sole Exo sink.
 * No install/wake/clock substitution, reconcile calls, sample dropping, or acoustic/performance claim.
 * Compilation is not Android execution. The parent owns the exclusive runtime qualification.
 */
@RunWith(AndroidJUnit4::class)
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class ListeningServicePlayerMp3Test {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun main(block: () -> Unit) {
        val failure = AtomicReference<Throwable>()
        instrumentation.runOnMainSync {
            try { block() } catch (error: Throwable) { failure.set(error) }
        }
        // A test assertion must fail its named method, not escape into the app main looper.
        failure.get()?.let { throw it }
    }

    private data class Seen(
        val occurrence: String?, val physical: String?, val local: Long, val global: Long,
        val logicalState: Int, val physicalState: Int, val rendered: Int
    )

    private inner class Fixture(names: List<String>, duplicate: Boolean = false) : AutoCloseable {
        val root = File(instrumentation.targetContext.cacheDir, "listening-player-mp3-${UUID.randomUUID()}").apply { check(mkdirs()) }
        private val context = object : ContextWrapper(instrumentation.targetContext) {
            override fun getNoBackupFilesDir() = root
        }
        private val store = object : SessionStore {
            override fun load(endpoint: ApiEndpoint): SecretTokens? = null
            override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) {}
            override fun clear() {}
        }
        val graph = AppGraph(context, ApiEndpoint.parse("https://fixture.invalid/api/v1"), store = store)
        val grants = ConcurrentHashMap<String, MediaGrant>()
        private val owner = SupervisorJob()
        // Main, not Main.immediate. Commands and publication use the actual application looper.
        private val jobs = CoroutineScope(owner + Dispatchers.Main)
        val items: List<MediaItem>
        lateinit var output: ExoPlayer
        lateinit var player: ListeningServicePlayer
        val completions = mutableListOf<String>()
        val transitions = mutableListOf<String>()
        val messages = mutableListOf<PlayerMessage>()

        init {
            try {
                assertTrue(graph.session.accept(graph.session.beginIntent(), SecretTokens("fixture-access", "fixture-refresh", "fixture-player")))
                val scope = requireNotNull(graph.session.capture())
                items = names.mapIndexed { i, name ->
                    val track = TrackId(if (duplicate) 1 else i + 1L)
                    if (!duplicate || i == 0) {
                        val bytes = instrumentation.context.assets.open("listening-mp3/$name").use { it.readBytes() }
                        val stage = requireNotNull(graph.temporaryAudio.begin(scope, track, bytes.size.toLong()))
                        stage.use { it.append(bytes, 0, bytes.size); assertTrue(it.finish()) }
                    }
                    val occurrence = "mp3-visit-$i"
                    val uri = Uri.parse("soundq://track/${track.value}/$occurrence")
                    grants[uri.toString()] = MediaGrant(scope, track, false)
                    // SoundQLibraryService.resolve's producer vocabulary, including occurrence identity.
                    val extras = Bundle().apply {
                        putLong("trackId", track.value); putString("occurrenceId", occurrence)
                        putBoolean("manual", i == 1); putBoolean("localOnly", false)
                        putLong("durationMs", 3000); putString("origin", if (i == 1) "Manual" else "Context")
                    }
                    MediaItem.Builder().setMediaId(occurrence).setUri(uri).setMimeType("audio/*")
                        .setMediaMetadata(MediaMetadata.Builder().setTitle("MP3 fixture $i").setArtist("Synthetic fixture")
                            .setIsPlayable(true).setIsBrowsable(false).setExtras(extras).build()).build()
                }
                main {
                    output = ExoPlayer.Builder(graph.applicationContext).setLooper(Looper.getMainLooper()).build()
                    player = ListeningServicePlayer.create(output, graph, grants, jobs, 1000)
                    assertSame(Looper.getMainLooper(), player.applicationLooper)
                    assertSame(output.applicationLooper, player.applicationLooper)
                    player.addCompletionListener { completions += it.mediaId }
                    player.addListener(object : Player.Listener {
                        override fun onMediaItemTransition(item: MediaItem?, reason: Int) {
                            item?.let { transitions += it.mediaId }
                        }
                    })
                }
            } catch (failure: Throwable) {
                if (::player.isInitialized) main { player.release() }
                else if (::output.isInitialized) main { output.release() }
                runBlocking { withTimeout(20000) { owner.cancelAndJoin() } }
                graph.close()
                throw failure
            }
        }

        fun seen(): Seen {
            val counters = output.audioDecoderCounters
            counters?.ensureUpdated()
            return Seen(player.currentMediaItem?.mediaId, output.currentMediaItem?.mediaId,
                player.currentPosition, output.currentPosition, player.playbackState,
                output.playbackState, counters?.renderedOutputBufferCount ?: 0)
        }

        /** A bounded main-looper observer. It issues no player commands or synthetic clock ticks. */
        fun await(label: String, predicate: () -> Boolean) {
            val handler = Handler(Looper.getMainLooper())
            val done = CountDownLatch(1)
            val failure = AtomicReference<Throwable>()
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(20)
            val poll = object : Runnable {
                override fun run() {
                    try {
                        check(player.playerError == null && output.playerError == null) { "Player failure: ${player.playerError?.errorCode}/${output.playerError?.errorCode}" }
                        if (predicate()) done.countDown()
                        else if (System.nanoTime() >= deadline) {
                            failure.set(AssertionError("$label: ${seen()}")); done.countDown()
                        } else handler.postDelayed(this, 10)
                    } catch (error: Throwable) { failure.set(error); done.countDown() }
                }
            }
            handler.post(poll)
            try {
                assertTrue("$label observer deadline", done.await(21, TimeUnit.SECONDS))
                failure.get()?.let { throw it }
                main { Log.i("ListeningPlayerMp3", "$label ${seen()}") }
            } finally { handler.removeCallbacks(poll) }
        }

        fun prepare() {
            main { player.setMediaItems(items, 0, 0); player.prepare() }
            ready()
            main {
                assertEquals(items.size, player.mediaItemCount)
                assertEquals(1, output.mediaItemCount)
                assertEquals("soundqlistening", output.currentMediaItem!!.localConfiguration!!.uri.scheme)
                assertTrue(output.currentMediaItem!!.mediaId.startsWith("render:"))
                assertEquals("audio/raw", output.audioFormat!!.sampleMimeType)
                assertEquals(48000, output.audioFormat!!.sampleRate)
                assertEquals(2, output.audioFormat!!.channelCount)
                assertEquals(if (items.size == 1) 3000L else 5000L, output.duration)
                assertEquals(items.size, privateCopies().size)
                items.forEachIndexed { i, item ->
                    assertEquals(item, player.getMediaItemAt(i))
                    assertEquals(3000L, player.currentTimeline.getWindow(i, Timeline.Window()).durationMs)
                }
                assertEquals(3000L, player.duration)
                assertFalse(player.playWhenReady)
                assertFalse(output.playWhenReady)
            }
        }

        fun ready() = await("actual ready") {
            player.preparationSettled && player.playbackState == Player.STATE_READY && output.playbackState == Player.STATE_READY
        }

        fun progress(occurrence: String, sourceStart: Long) {
            var before = 0L
            var buffers = 0
            main { before = output.currentPosition; buffers = seen().rendered; player.play() }
            await("positive physical renderer and source-local progress") {
                val s = seen()
                output.isPlaying && player.isPlaying && s.occurrence == occurrence &&
                    s.global > before + 80 && s.rendered > buffers && abs(s.local - (s.global - sourceStart)) <= 30
            }
        }

        /** Actual Exo position delivery. Assertions stay on the instrumentation thread. */
        fun at(position: Long, action: () -> Unit): () -> Unit {
            val done = CountDownLatch(1)
            val failure = AtomicReference<Throwable>()
            main {
                messages += output.createMessage { _, _ ->
                    try { action() } catch (error: Throwable) { failure.set(error) }
                    finally { done.countDown() }
                }.setLooper(output.applicationLooper).setPosition(0, position).send()
            }
            return {
                assertTrue("actual output message at $position", done.await(20, TimeUnit.SECONDS))
                failure.get()?.let { throw it }
            }
        }

        fun privateCopies(): List<File> = graph.directory.listFiles()?.filter { it.name.startsWith("listening-") } ?: emptyList()

        override fun close() {
            val changed = Object()
            @Suppress("DEPRECATION")
            val observer = object : FileObserver(graph.directory.absolutePath, DELETE or MOVED_FROM) {
                override fun onEvent(event: Int, path: String?) { synchronized(changed) { changed.notifyAll() } }
            }
            observer.startWatching()
            try {
                main { messages.forEach { it.cancel() }; player.release(); assertTrue(output.isReleased) }
                // A cancelled preparation can still own source IO. Join before graph/cache release.
                runBlocking { withTimeout(20000) { owner.cancelAndJoin() } }
                assertTrue("preparation worker retired", player.preparationSettled)
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(20)
                synchronized(changed) {
                    while (privateCopies().isNotEmpty()) {
                        val left = deadline - System.nanoTime()
                        assertTrue("private encoded copies retained after worker drain: ${privateCopies().map { it.name }}", left > 0)
                        TimeUnit.NANOSECONDS.timedWait(changed, left)
                    }
                }
                assertFalse(owner.isActive)
                assertTrue(owner.children.none())
                Log.i("ListeningPlayerMp3", "drained preparation=true privateCopies=0 outputReleased=true jobs=0")
                val cleared = graph.temporaryAudio.clear()
                assertEquals("no cache lease survives private-copy drain", 0, cleared.deferredFiles)
                assertEquals("owned cache cleanup succeeded", 0, cleared.failedFiles)
                graph.close()
                assertTrue("owned fixture directory cleanup", root.deleteRecursively())
            } finally { observer.stopWatching() }
        }
    }

    @Test fun actualMp3OutputMidpointSelectsIncomingButOnlySourceEofCompletes() {
        Fixture(listOf("stereo.mp3", "mono.mp3")).use { f ->
            f.prepare()
            val midpoint = f.at(2650) {
                f.player.pause()
                val s = f.seen()
                assertTrue("midpoint observation remains before outgoing EOF: $s", s.global in 2500 until 3000)
                assertEquals("mp3-visit-1", s.occurrence)
                assertTrue(abs(s.local - (s.global - 2000)) <= 30)
                assertEquals(3000L, f.player.duration)
                assertTrue(f.completions.isEmpty())
                assertTrue(f.transitions.contains("mp3-visit-1"))
                assertFalse(f.transitions.any { it.startsWith("render:") })
            }
            val outgoingEof = f.at(3150) {
                f.player.pause()
                assertEquals(listOf("mp3-visit-0"), f.completions)
                assertEquals("mp3-visit-1", f.player.currentMediaItem!!.mediaId)
                assertEquals(1, f.output.mediaItemCount)
            }
            f.progress("mp3-visit-0", 0)
            midpoint()
            main { f.player.play() }; outgoingEof()
            main { f.player.play() }
            f.await("actual full render EOF") { f.player.playbackState == Player.STATE_ENDED && f.output.playbackState == Player.STATE_ENDED }
            main {
                assertEquals(listOf("mp3-visit-0", "mp3-visit-1"), f.completions)
                assertEquals("mp3-visit-1", f.player.currentMediaItem!!.mediaId)
                assertEquals(3000L, f.player.currentPosition)
                assertEquals(5000L, f.output.duration)
                assertTrue("actual output reached its final boundary", f.output.currentPosition >= f.output.duration)
                assertEquals(3000L, f.player.duration)
                assertTrue(f.seen().rendered > 0)
            }
        }
    }

    @Test fun duplicateMp3SourceLocalSeeksBackwardReopenAndStopPrepareKeepBoundary() {
        Fixture(listOf("stereo.mp3", "stereo.mp3"), duplicate = true).use { f ->
            f.prepare(); f.progress("mp3-visit-0", 0)
            main {
                f.player.pause()
                // Explicit outgoing-tail selection is source-local even after the dominance midpoint.
                f.player.seekTo(0, 2900)
                assertEquals("mp3-visit-0", f.player.currentMediaItem!!.mediaId)
                assertEquals(2900L, f.player.currentPosition); assertEquals(2900L, f.output.currentPosition)
                assertTrue(f.completions.isEmpty())
            }
            f.ready()
            main {
                // Actual seek readiness and deferred notifications must preserve paused selection.
                assertEquals("mp3-visit-0", f.player.currentMediaItem!!.mediaId)
                assertEquals(2900L, f.player.currentPosition)
                assertEquals(2900L, f.output.currentPosition)
                assertTrue(f.completions.isEmpty())
                f.player.seekTo(1, 0)
                assertEquals("mp3-visit-1", f.player.currentMediaItem!!.mediaId)
                assertEquals(0L, f.player.currentPosition); assertEquals(2000L, f.output.currentPosition)
                assertTrue(f.completions.isEmpty())
            }
            f.ready()
            main { f.player.seekTo(0, 0) }
            f.ready(); f.progress("mp3-visit-0", 0)
            var saved = 0L
            var oldRender = ""
            main {
                f.player.pause(); saved = f.player.currentPosition
                oldRender = f.output.currentMediaItem!!.mediaId
                f.player.stop()
                assertEquals(Player.STATE_IDLE, f.player.playbackState)
                assertFalse(f.player.playWhenReady)
                assertEquals(saved, f.player.currentPosition)
                f.player.prepare()
            }
            f.ready()
            main {
                assertNotEquals(oldRender, f.output.currentMediaItem!!.mediaId)
                assertEquals("mp3-visit-0", f.player.currentMediaItem!!.mediaId)
                assertEquals(saved, f.player.currentPosition)
                assertFalse(f.output.playWhenReady)
            }
            f.progress("mp3-visit-0", 0)
            main {
                f.player.pause()
                val selected = f.player.currentMediaItem!!.mediaId
                val third = f.items.first().buildUpon().setMediaId("mp3-visit-third").build()
                try { f.player.setMediaItems(f.items + third, 0, 0); fail("three sources must be refused, not truncated") }
                catch (_: IllegalArgumentException) {}
                try { f.player.setMediaItems(f.items, 0, 3001); fail("source-local seek outside full source must be refused") }
                catch (_: IllegalArgumentException) {}
                assertEquals(2, f.player.mediaItemCount)
                assertEquals(selected, f.player.currentMediaItem!!.mediaId)
                assertFalse(f.player.playWhenReady); assertFalse(f.output.playWhenReady)
                assertEquals(listOf("mp3-visit-0", "mp3-visit-1"), (0 until 2).map { f.player.getMediaItemAt(it).mediaId })
                assertEquals(listOf(1L, 1L), (0 until 2).map { f.player.getMediaItemAt(it).mediaMetadata.extras!!.getLong("trackId") })
                assertEquals(1, f.output.mediaItemCount)
                assertTrue(f.completions.isEmpty())
            }
        }
    }

    @Test fun singleMp3RepeatAllReopensActualOutputAndRearmsOnlyNaturalEof() {
        Fixture(listOf("stereo.mp3")).use { f ->
            f.prepare()
            main {
                f.player.repeatMode = Player.REPEAT_MODE_ALL
                f.player.addCompletionListener { if (f.completions.size == 2) f.player.pause() }
                f.player.play()
            }
            f.await("first natural EOF and repeat-shaped backward reopen") {
                f.completions.size == 1 && f.output.currentPosition in 80 until 2200 && f.seen().rendered > 0 && f.output.isPlaying
            }
            main {
                assertEquals(listOf("mp3-visit-0"), f.completions)
                assertEquals(Player.REPEAT_MODE_OFF, f.output.repeatMode)
                assertEquals(Player.REPEAT_MODE_ALL, f.player.repeatMode)
                assertEquals("mp3-visit-0", f.player.currentMediaItem!!.mediaId)
                assertEquals(1, f.output.mediaItemCount)
            }
            f.await("second natural EOF pauses without a stale repeat restart") { f.completions.size == 2 && !f.output.playWhenReady }
            main {
                assertEquals(listOf("mp3-visit-0", "mp3-visit-0"), f.completions)
                assertFalse(f.player.playWhenReady)
                assertEquals(3000L, f.output.duration)
                assertTrue("actual repeated output reached its source boundary", f.output.currentPosition >= f.output.duration)
                assertEquals(3000L, f.player.currentPosition)
                assertEquals(3000L, f.player.duration)
            }
        }
    }

    @Test fun accountRevocationDuringPendingRealPreparationCannotInstallOrAutoplay() {
        Fixture(listOf("stereo.mp3")).use { f ->
            main {
                f.player.setMediaItems(f.items, 0, 0)
                assertEquals("mp3-visit-0", f.player.currentMediaItem!!.mediaId)
                f.player.prepare(); f.player.play()
                assertFalse("real preparation admitted before its main-dispatched continuation", f.player.preparationSettled)
                f.graph.session.revoke()
            }
            f.await("revoked pending preparation drains without publication") {
                f.player.preparationSettled && f.player.mediaItemCount == 0 && f.output.mediaItemCount == 0
            }
            main {
                assertFalse(f.player.playWhenReady); assertFalse(f.output.playWhenReady)
                assertEquals(Player.STATE_IDLE, f.player.playbackState)
                assertNull(f.player.currentMediaItem)
                assertTrue(f.completions.isEmpty())
            }
        }
    }
}
