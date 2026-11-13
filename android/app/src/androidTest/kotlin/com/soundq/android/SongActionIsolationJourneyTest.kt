package com.soundq.android

import android.content.ComponentName
import android.content.ContentValues
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import androidx.media3.common.MediaItem
import androidx.media3.session.*
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.AuthState
import com.soundq.android.data.device.FileDeleteOutcome
import com.soundq.android.data.deviceaudio.HistoryKey
import com.soundq.android.playback.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.TimeUnit

/** CallbackFrontendFixtureRunner, generated originals only. Authored for parent execution.
 * Canonical MediaSession + provider/delete owner + real callback engine; no fake playback clock.
 * Existing SongActionsJourneyTest separately covers the mounted confirmation/cancel surface. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@androidx.test.filters.SdkSuppress(minSdkVersion=29)
class SongActionIsolationJourneyTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private val app get() = context.applicationContext as CallbackFrontendFixtureApplication
    private fun <T> main(block: () -> T): T {
        var result: Result<T>? = null
        instrumentation.runOnMainSync { result = runCatching(block) }
        return result!!.getOrThrow()
    }
    private fun await(message: String, ready: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(60)
        while (System.nanoTime() < deadline) { if (ready()) return; Thread.sleep(20) }
        assertTrue(message + "; native=" + runCatching {app.callbackPlayer.javaClass.getDeclaredMethod("nativeDiagnostics").apply {isAccessible=true}.invoke(app.callbackPlayer)}.getOrNull(), ready())
    }
    private fun wave(seconds: Int): ByteArray {
        val rate = 8000; val frames = rate * seconds; val salt = UUID.randomUUID().leastSignificantBits
        return ByteBuffer.allocate(44 + frames * 2).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()).putInt(36 + frames * 2).put("WAVEfmt ".toByteArray()).putInt(16)
            putShort(1).putShort(1).putInt(rate).putInt(rate * 2).putShort(2).putShort(16).put("data".toByteArray()).putInt(frames * 2)
            repeat(frames) { i -> putShort(if (frames - i <= 4) (salt ushr ((frames - i - 1) * 16)).toShort() else (kotlin.math.sin(i * 2 * Math.PI * 223 / rate) * 4000).toInt().toShort()) }
        }.array()
    }
    private inner class Fixture : AutoCloseable {
        val owned = mutableListOf<Uri>()
        val references = mutableMapOf<Uri, PlaybackRef.Device>()
        val future: com.google.common.util.concurrent.ListenableFuture<MediaController>
        val c: MediaController
        private val priorCrossfade: Int
        init {
            main { app.graph.session.retire() }
            await("Signed-out phone catalog") { app.graph.session.state.value is AuthState.SignedOut && app.graph.phoneAudio.state.value.ready }
            await("Crossfade preference ready") { app.graph.crossfadePreferences.state.value.ready }
            priorCrossfade = app.graph.crossfadePreferences.state.value.seconds
            future = main { MediaController.Builder(context, SessionToken(context, ComponentName(context, SoundQLibraryService::class.java))).buildAsync() }
            c = future.get(15, TimeUnit.SECONDS)
        }
        fun file(bytes: ByteArray): Pair<PlaybackRef.Device, Uri> {
            val r = context.contentResolver
            val uri = checkNotNull(r.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, "soundq-isolation-${UUID.randomUUID()}.wav")
                put(MediaStore.MediaColumns.MIME_TYPE, "audio/wav")
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/SoundQ menu isolation")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            })).also(owned::add)
            r.openOutputStream(uri, "w")!!.use { it.write(bytes) }
            assertEquals(1, r.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null))
            val ref = app.graph.phoneAudio.reference(app.graph.phoneAudio.awaitIndexed(uri))
            references[uri] = ref
            return ref to uri
        }
        fun crossfade(seconds: Int) = main {
            assertTrue(app.graph.crossfadePreferences.setSeconds(requireNotNull(app.graph.crossfadePreferences.capture()), seconds) { true })
        }
        fun request(ref: PlaybackRef.Device) = MediaItem.Builder().setMediaId("device:${ref.id}")
            .setRequestMetadata(MediaItem.RequestMetadata.Builder().setExtras(Bundle().apply { putString("playbackRef", ref.wire()) }).build()).build()
        fun play(vararg refs: PlaybackRef.Device) {
            main { c.setMediaItems(refs.map(::request), 0, 0); c.prepare(); c.play() }
            await("Playing native source") { main { c.isPlaying } && deck()?.getLong("positionMs")?.let { it > 200 } == true }
        }
        fun deck(): JSONObject? {
            val text = app.callbackPlayer.javaClass.getDeclaredMethod("nativeDiagnostics").apply { isAccessible = true }.invoke(app.callbackPlayer) as String
            val root = JSONObject(text)
            val decks = root.optJSONArray("decks") ?: return null
            val id = main { app.callbackPlayer.javaClass.getDeclaredField("ordinaryIdentity").apply { isAccessible = true }.getLong(app.callbackPlayer) }
            return (0 until decks.length()).map { decks.getJSONObject(it) }.singleOrNull { it.getLong("identity") == id && id > 0 }
        }
        fun command(action: String, ref: PlaybackRef.Device, speed: Double? = null): SessionResult {
            val future = main { c.sendCustomCommand(SessionCommand(action, Bundle.EMPTY), Bundle().apply {
                putString("target", ref.wire()); putLong("version", app.graph.session.version()); speed?.let { putDouble("speed", it) }
            }) }
            return future.get(30, TimeUnit.SECONDS)
        }
        fun delete(ref: PlaybackRef.Device): FileDeleteOutcome = runBlocking {
            val target = checkNotNull(app.graph.phoneFiles.capture(ref) { true })
            app.graph.phoneFiles.delete(target, { true }) { command(RETIRE_PHONE_FILE, ref).resultCode == SessionResult.RESULT_SUCCESS }
        }
        override fun close() {
            // Test-only custody barrier. A controller's optimistic clear is not native retirement.
            // use() preserves the workload exception and suppresses this aggregated cleanup error.
            var failure: Throwable? = null
            fun attempt(block: () -> Unit): Boolean = try { block(); true } catch (error: Throwable) {
                if (failure == null) failure = error else failure!!.addSuppressed(error)
                false
            }
            val retired = mutableSetOf<Uri>()
            owned.forEach { uri ->
                if (attempt {
                    references[uri]?.let { ref ->
                        assertEquals("Concrete retirement for $uri", SessionResult.RESULT_SUCCESS, command(RETIRE_PHONE_FILE, ref).resultCode)
                    }
                }) retired += uri
            }
            val empty = attempt {
                main { c.pause(); c.stop(); c.clearMediaItems() }
                await("Actual service player queue empty") { main { app.callbackPlayer.mediaItemCount == 0 } }
            }
            owned.forEach { uri ->
                attempt {
                    check(empty && uri in retired) { "Retaining original after refused retirement: $uri" }
                    await("Original descriptor custody drained for $uri") { app.graph.phoneAudio.originalDescriptorsDrained(references[uri]?.id) }
                    context.contentResolver.delete(uri, null, null)
                    assertFalse(context.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns._ID), null, null, null)?.use { it.moveToFirst() } ?: false)
                    android.util.Log.i("SoundQIsolationFixture", "retired/drained/deleted $uri")
                }
            }
            attempt { crossfade(priorCrossfade) }
            attempt { main { MediaController.releaseFuture(future) } }
            failure?.let { throw it }
        }
    }
    private fun deletionCase(queued: Boolean) = Fixture().use { f ->
        // A fits the native initial window, so its decoder seals the finite preload endpoint.
        val (a, _) = f.file(wave(if (queued) 2 else 20)); val (b, _) = f.file(wave(611))
        f.crossfade(if (queued) 2 else 0)
        if (queued) f.play(b, a) else f.play(b)
        if (queued) {
            // Test-only readiness: streaming originals do not advertise a sealed endpoint
            // until a real decoder window reaches EOS. Prime that endpoint while paused,
            // then return to the start before measuring deletion isolation.
            main { f.c.pause(); f.c.seekTo(608_000) }
            await("B decoded endpoint sealed before crossfade preload") { f.deck()?.getLong("sourceFrames")?.let { it > 0 } == true }
            main { f.c.seekTo(0); f.c.play() }
            await("B back at start and advancing") { f.deck()?.getLong("positionMs")?.let { it in 200..30_000 } == true && main { f.c.isPlaying } }
        }
        if (queued) await("A really preloaded before deletion") {
            main { app.callbackPlayer.javaClass.getDeclaredField("successor").apply { isAccessible = true }.get(app.callbackPlayer) != null } &&
                JSONObject(app.callbackPlayer.javaClass.getDeclaredMethod("nativeDiagnostics").apply { isAccessible = true }.invoke(app.callbackPlayer) as String)
                    .getJSONArray("decks").let { ds -> (0 until ds.length()).count { ds.getJSONObject(it).getBoolean("ready") } >= 2 }
        }
        val before = checkNotNull(f.deck()); val occurrence = main { f.c.currentMediaItem!!.mediaId }
        android.util.Log.i("SoundQIsolationFixture", "before delete queued=$queued B=$before native=" + app.callbackPlayer.javaClass.getDeclaredMethod("nativeDiagnostics").apply { isAccessible = true }.invoke(app.callbackPlayer))
        assertEquals(FileDeleteOutcome.Deleted, f.delete(a))
        await("Unrelated B still advances after deletion") { f.deck()?.let { it.getLong("identity") == before.getLong("identity") && it.getLong("positionMs") > before.getLong("positionMs") + 1200 } == true }
        assertEquals(occurrence, main { f.c.currentMediaItem!!.mediaId }); assertTrue(main { f.c.isPlaying })
        assertEquals(before.getLong("generation"), f.deck()!!.getLong("generation"))
        assertEquals(1, main { f.c.mediaItemCount })
        val key = HistoryKey.Device(com.soundq.android.data.deviceaudio.DeviceFileId(UUID.fromString(b.id)))
        await("B's existing journal retains checkpoint authority") { app.graph.phoneAudio.state.value.snapshot?.history?.singleOrNull { it.key == key }?.bookmark?.positionMs?.let { it > before.getLong("positionMs") } == true }
        // An explicit deep seek is not completion. Let the real callback consume the remaining source.
        main { f.c.seekTo(608_000) }
        await("Seek acknowledged") { f.deck()?.getLong("positionMs")?.let { it >= 607_900 } == true }
        await("Actual last-frame consumption retains natural-completion authority") {
            val row = app.graph.phoneAudio.state.value.snapshot?.history?.singleOrNull { it.key == key }
            main { f.c.playbackState == androidx.media3.common.Player.STATE_ENDED } && row != null && row.playedAtEpochMs != null && row.bookmark == null
        }
    }
    @Test fun deletingUnqueuedADoesNotInterruptBOrRetireItsJournal() = deletionCase(false)
    @Test fun deletingPreloadedADoesNotInterruptOutgoingBOrRetireItsJournal() = deletionCase(true)
    @Test fun editingIdenticalCopyASavesButDoesNotApplyToAudibleB() = Fixture().use { f ->
        val bytes = wave(30); val (a, _) = f.file(bytes); val (b, _) = f.file(bytes)
        assertNotEquals(a.id, b.id); assertEquals(ListeningSpeedKey.device(a), ListeningSpeedKey.device(b))
        f.crossfade(0); f.play(b)
        val before = f.deck()!!; val occurrence = main { f.c.currentMediaItem!!.mediaId }
        val result = f.command(SONG_SPEED, a, 1.5)
        assertEquals(SessionResult.RESULT_SUCCESS, result.resultCode)
        val reply = Json.decodeFromString<SongSpeedState>(result.extras.getString("songSpeed")!!)
        assertFalse(reply.current); assertTrue(reply.persisted)
        await("B advances after save-only edit") { f.deck()?.getLong("positionMs")?.let { it > before.getLong("positionMs") + 1200 } == true }
        assertEquals(before.getLong("identity"), f.deck()!!.getLong("identity")); assertEquals(1.0, f.deck()!!.getDouble("rate"), 0.0)
        assertEquals(occurrence, main { f.c.currentMediaItem!!.mediaId }); assertTrue(main { f.c.isPlaying })
        f.play(a)
        await("A starts with shared saved content preference") { f.deck()?.getDouble("rate") == 1.5 }
    }
}
