package com.soundq.android.playback

import android.app.Application
import android.os.Bundle
import android.os.HandlerThread
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import com.soundq.android.AppGraph
import com.soundq.android.data.ApiEndpoint
import com.soundq.android.data.SecretTokens
import com.soundq.android.data.SessionStore
import com.soundq.android.data.TrackId
import com.soundq.android.playback.nativeengine.NativeCallbackCalls
import com.soundq.android.playback.nativeengine.NativeCallbackPlayer
import com.soundq.android.playback.nativeengine.NativeCallbackSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File
import java.time.Duration
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/** Real Media3 player, account/queue admission, readiness and native-owner custody. No HTTP or decoder. */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28], application = Application::class)
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class OrdinaryDeckReadinessTest {
    @Test fun foregroundReadinessDeadlinePublishesErrorAndRetiresDeck() = Fixture().use { f ->
        val selected = f.item(1)
        f.hw.held += selected.mediaId
        f.play(selected)
        val load = f.awaitPreparing(selected, 0)
        f.advance(14_700)
        assertEquals(Player.STATE_BUFFERING, f.player.playbackState)
        assertTrue(f.player.playWhenReady)
        assertNull(f.player.playerError)
        assertEquals(load.identity, f.hw.renderer.identity(0))
        assertTrue(load.file.isFile)

        f.advance(500)
        f.drain("foreground prepare settled") { f.player.preparationSettled }
        // Wait for the asynchronously admitted retirement (if there was one).
        if (f.player.playerError != null) f.drain("foreground deck and owned file retired") { f.retired(load) }
        assertEquals(listOf(PlaybackException.ERROR_CODE_IO_UNSPECIFIED, true),
            listOf(f.player.playerError?.errorCode, f.retired(load)))
        assertEquals("Audio source could not be prepared. Try again when the server is available.", f.player.playerError?.message)
        assertEquals(Player.STATE_IDLE, f.player.playbackState)
        assertFalse(f.player.playWhenReady)
        assertEquals(selected, f.player.currentMediaItem)
        assertEquals(listOf(selected.mediaId), f.hw.loads.map { it.occurrence })
        assertTrue(f.hw.renderer.played.isEmpty())
    }

    @Test fun successorReadinessDeadlineRetiresOnlySpareAndDoesNotRetry() = Fixture().use { f ->
        f.enableCrossfade()
        val selected = f.item(1)
        val next = f.item(2)
        f.hw.held += next.mediaId
        f.play(selected, next)
        val spare = f.awaitPreparing(next, 1)
        val outgoing = f.hw.loads.single { it.occurrence == selected.mediaId }
        f.assertPlaying(selected, outgoing)
        f.advance(14_700)
        assertEquals(spare.identity, f.hw.renderer.identity(1))
        assertTrue(spare.file.isFile)
        assertFalse(f.player.preparationSettled)

        f.advance(500)
        f.drain("successor prepare settled") { f.player.preparationSettled }
        f.advance(500) // subsequent ordinary polls must not dispatch another preload
        if (f.hw.renderer.identity(1) == 0L) f.drain("spare owned file retired") { !spare.file.exists() }
        f.assertPlaying(selected, outgoing)
        assertEquals(listOf(selected, next), (0 until f.player.mediaItemCount).map(f.player::getMediaItemAt))
        assertEquals(listOf(true, 1, 0), listOf(f.retired(spare), f.hw.loads.count { it.occurrence == next.mediaId }, f.hw.arms.size))

        f.player.pause()
        f.drain("ordinary paused") { !f.hw.renderer.isPlaying(0) && !f.player.isPlaying }
        f.player.play()
        f.drain("ordinary resumed") { f.player.isPlaying }
        f.advance(1_000)
        f.assertPlaying(selected, outgoing)
        assertEquals(listOf(selected.mediaId, next.mediaId), f.hw.loads.map { it.occurrence })
        assertTrue(f.hw.arms.isEmpty())
    }

    @Test fun replacingHeldForegroundCancelsWithoutAnErrorAndNewSelectionReadies() = Fixture().use { f ->
        val old = f.item(1)
        val replacement = f.item(2)
        f.hw.held += old.mediaId
        val errors = mutableListOf<PlaybackException>()
        f.player.addListener(object : Player.Listener {
            override fun onPlayerError(error: PlaybackException) { errors += error }
        })
        f.play(old)
        val retired = f.awaitPreparing(old, 0)
        f.play(replacement)
        f.drain("replacement ready and old file gone") { !retired.file.exists() && f.player.isPlaying }
        val active = f.hw.loads.single { it.occurrence == replacement.mediaId }
        assertNotEquals(retired.identity, active.identity)
        f.advance(16_000)
        f.assertPlaying(replacement, active)
        assertTrue(errors.isEmpty())
        assertEquals(listOf(old.mediaId, replacement.mediaId), f.hw.loads.map { it.occurrence })
    }

    @Test fun explicitSuccessorCancellationRetiresStaleAttemptAndFreshReadySuccessorArms() = Fixture().use { f ->
        f.enableCrossfade()
        val selected = f.item(1)
        val next = f.item(2)
        f.hw.held += next.mediaId
        f.play(selected, next)
        val retired = f.awaitPreparing(next, 1)
        val outgoing = f.hw.loads.first()
        f.player.repeatMode = Player.REPEAT_MODE_ONE
        f.drain("canceled successor retired") { f.player.preparationSettled && f.retired(retired) }
        f.assertPlaying(selected, outgoing)
        assertTrue(f.hw.arms.isEmpty())

        f.hw.held -= next.mediaId
        f.player.repeatMode = Player.REPEAT_MODE_OFF
        f.drain("fresh successor ready and armed") { f.player.preparationSettled && f.hw.arms.isNotEmpty() }
        val active = f.hw.loads.last()
        assertEquals(next.mediaId, active.occurrence)
        assertNotEquals(retired.identity, active.identity)
        f.advance(16_000)
        f.assertPlaying(selected, outgoing)
        assertTrue(active.file.isFile)
        assertEquals(active.identity, f.hw.renderer.identity(1))
        assertEquals(listOf(Hardware.Arm(outgoing.identity, active.identity, 2_000)), f.hw.arms)
        assertEquals(listOf(selected.mediaId, next.mediaId, next.mediaId), f.hw.loads.map { it.occurrence })
    }

    private class Fixture : AutoCloseable {
        private val graph = AppGraph(RuntimeEnvironment.getApplication(), ApiEndpoint.parse("https://fixture.invalid/api/v1"),
            store = object : SessionStore {
                override fun load(endpoint: ApiEndpoint): SecretTokens? = null
                override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) = Unit
                override fun clear() = Unit
            })
        private val scope = graph.session.run {
            check(accept(beginIntent(), SecretTokens("fixture-access", "fixture-refresh", "fixture")))
            checkNotNull(capture())
        }
        private val grants = ConcurrentHashMap<String, MediaGrant>()
        private val jobs = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val hw = Hardware(ProjectionPreviewHardware())
        val player = NativeCallbackPlayer(graph, grants, jobs, hw, NativeCallbackSource { item, current ->
            check(current())
            File.createTempFile("ordinary-deck", ".encoded", graph.directory).apply { writeText(item.mediaId) }
        })
        private val main = shadowOf(Looper.getMainLooper())
        private val control = run {
            val owner = NativeCallbackPlayer::class.java.getDeclaredField("owner").apply { isAccessible = true }.get(player)
            val thread = owner.javaClass.getDeclaredField("thread").apply { isAccessible = true }.get(owner) as HandlerThread
            shadowOf(thread.looper)
        }

        fun item(track: Long): MediaItem {
            val uri = "soundq://track/$track"
            grants[uri] = MediaGrant(scope, TrackId(track))
            return MediaItem.Builder().setMediaId("occurrence-$track").setUri(uri).setMediaMetadata(
                MediaMetadata.Builder().setExtras(Bundle().apply { putLong("trackId", track) }).build(),
            ).build()
        }

        fun enableCrossfade() = graph.crossfadePreferences.run {
            load()
            check(setSeconds(checkNotNull(capture()), 2) { true })
        }

        fun play(vararg items: MediaItem) {
            player.setMediaItems(items.toList(), 0, 0)
            player.play()
            player.prepare()
        }

        fun awaitPreparing(item: MediaItem, slot: Int): Hardware.Load {
            drain("native load accepted for ${item.mediaId}") { hw.loads.any { it.occurrence == item.mediaId } }
            val load = hw.loads.single { it.occurrence == item.mediaId }
            assertEquals(slot, load.deck)
            assertEquals(load.identity, hw.renderer.identity(slot))
            // An admitted, held decoder must be read by the readiness loop, not just assigned.
            val polls = hw.renderer.polls
            drain("held deck observed") { hw.renderer.polls >= polls + 4 }
            assertFalse(player.preparationSettled)
            return load
        }

        fun retired(load: Hardware.Load) = hw.renderer.identity(load.deck) == 0L && !load.file.exists()

        fun assertPlaying(item: MediaItem, load: Hardware.Load) {
            assertEquals(item, player.currentMediaItem)
            assertEquals(Player.STATE_READY, player.playbackState)
            assertTrue(player.isPlaying)
            assertTrue(player.playWhenReady)
            assertNull(player.playerError)
            assertEquals(load.identity, hw.renderer.identity(0))
            assertTrue(hw.renderer.isPlaying(0))
            assertTrue(load.file.isFile)
        }

        // The actual Android Main dispatcher uses Robolectric uptime for delay/timeout.
        // The owner still runs on its real HandlerThread, and acquisition still uses IO.
        fun advance(millis: Long) {
            control.idle()
            main.idleFor(Duration.ofMillis(millis))
            control.idle()
            main.idle()
        }

        fun drain(label: String, tick: () -> Unit = { advance(5) }, predicate: () -> Boolean) {
            val deadline = System.nanoTime() + 8_000_000_000L
            do {
                tick()
                if (predicate()) return
                Thread.sleep(2) // let real IO run without spending the readiness budget
            } while (System.nanoTime() < deadline)
            fail("$label: ${player.nativeDiagnostics()}")
        }

        override fun close() {
            try {
                player.release()
                // The owner may quit its Looper as soon as close completes.
                drain("native owner closed", tick = { main.idleFor(Duration.ofMillis(5)) }) { player.nativeReleased.isDone }
                assertTrue(player.nativeReleased.get())
            } finally {
                jobs.cancel()
                try { graph.close() } finally { hw.renderer.closeWorkers() }
            }
        }
    }

    private class Hardware(val renderer: ProjectionPreviewHardware) : NativeCallbackCalls by renderer {
        data class Load(val occurrence: String, val deck: Int, val identity: Long, val file: File)
        data class Arm(val outgoing: Long, val incoming: Long, val duration: Long)
        val held = ConcurrentHashMap.newKeySet<String>()
        val loads = CopyOnWriteArrayList<Load>()
        val arms = CopyOnWriteArrayList<Arm>()

        override fun load(handle: Long, deck: Int, path: String, identity: Long, generation: Long, positionMs: Long): Boolean {
            val file = File(path)
            val occurrence = file.readText()
            return renderer.load(handle, deck, path, identity, generation, positionMs).also { accepted ->
                if (accepted) loads += Load(occurrence, deck, identity, file)
            }
        }

        override fun state(handle: Long): String {
            val state = JSONObject(renderer.state(handle))
            val decks = state.getJSONArray("decks")
            for (slot in 0..1) {
                val deck = decks.getJSONObject(slot)
                val identity = deck.getLong("identity")
                if (identity != 0L && loads.any { it.identity == identity && it.occurrence in held }) {
                    deck.put("ready", false).put("preparing", true)
                }
            }
            return state.toString()
        }

        override fun crossfade(handle: Long, outgoing: Int, outgoingGeneration: Long, incoming: Int,
            incomingGeneration: Long, milliseconds: Long): Boolean {
            if (renderer.identity(outgoing) != outgoingGeneration || renderer.identity(incoming) != incomingGeneration) return false
            if (milliseconds > 0) arms += Arm(outgoingGeneration, incomingGeneration, milliseconds)
            return true
        }
    }
}
