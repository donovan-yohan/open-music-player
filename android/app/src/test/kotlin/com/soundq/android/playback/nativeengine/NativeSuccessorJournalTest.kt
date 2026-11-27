package com.soundq.android.playback.nativeengine

import android.app.Application
import android.content.ContextWrapper
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.os.HandlerThread
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import com.soundq.android.AppGraph
import com.soundq.android.data.ApiEndpoint
import com.soundq.android.data.SecretTokens
import com.soundq.android.data.SessionStore
import com.soundq.android.data.TrackId
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.playback.MediaGrant
import java.io.File
import java.nio.ByteBuffer
import java.nio.file.Files
import java.time.Duration
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadows.ShadowEnvironment

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [30], application = Application::class, shadows = [NativeSuccessorJournalTest.StoragePermission::class])
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class NativeSuccessorJournalTest {
    @Implements(Environment::class)
    class StoragePermission : ShadowEnvironment() {
        companion object {
            @JvmStatic @Implementation(minSdk = 30) fun isExternalStorageManager() = false
        }
    }

    @Test fun naturalPromotionRetainsExactlyOneLateBorrowedJournal() = Fixture().use { f ->
        f.start()
        f.holdJournal().use {
            f.readyAndArmed()
            val outgoing = checkNotNull(f.hardware.assignment(0))
            val incoming = checkNotNull(f.hardware.assignment(1))
            f.hardware.eof(0, startIncoming = true)
            f.drain("EOF promotion and outgoing decoder ACK while binding is held") {
                f.player.currentMediaItem?.mediaId == f.items[1].mediaId && f.readers[0].closed
            }
            assertEquals(listOf(f.items[0].mediaId), f.completed)
            assertEquals(incoming, f.hardware.assignment(1))
            assertEquals(listOf(0 to outgoing, 1 to incoming), f.hardware.loads)
            assertEquals(listOf(0), f.hardware.plays)
            assertTrue(f.player.isPlaying)
            // The retired outgoing grant is no longer authority for this decoder or its journal.
            f.grants.remove(f.uris[0])
            f.hardware.advance(1, 2_000)
            f.drain("consumed incoming cursor while binding is held") { f.player.currentPosition == 2_000L }
            assertEquals(-1L, f.journal.stamp(1))
            assertEquals(0, f.readers[1].binds.get())
            assertNull(f.history(1))
        }
        f.drain("borrowed successor preparation settled") { f.player.preparationSettled }
        assertTrue("promoted assignment lost its journal binding", f.journal.stamp(1) >= 0)
        assertEquals(1, f.readers[1].binds.get())
        f.drainJournalPoll()
        // The completion callback was delivered, but the outgoing grant was
        // revoked before its queued durable EOF could be accepted.
        assertEquals(6_000L, f.history(0)?.bookmark)
        assertNull("binding plus a stationary playing cursor is not durable evidence", f.history(1))
        f.hardware.advance(1, 8_000)
        f.drain("incoming consumed samples became a checkpoint") { f.history(1)?.bookmark == 8_000L }
        f.hardware.eof(1)
        f.drain("incoming qualified end cleared its own checkpoint") {
            f.completed.size == 2 && f.history(1)?.bookmark == null
        }
        assertEquals(f.items.map { it.mediaId }, f.completed)
        assertEquals(1, f.readers[1].binds.get())
        assertEquals(2, f.hardware.loads.size)
        assertNull(f.player.playerError)
    }

    @Test fun cancellingAnUnselectedHeldBindingCannotAttachOrRetireOutgoingPlayback() = Fixture().use { f ->
        f.start()
        f.holdJournal().use {
            f.readyAndArmed()
            f.player.repeatMode = androidx.media3.common.Player.REPEAT_MODE_ONE
            f.drain("cancelled incoming decoder ACK before journal IO release") { f.readers[1].closed }
            assertEquals(f.items[0].mediaId, f.player.currentMediaItem?.mediaId)
            assertTrue(f.player.isPlaying)
        }
        f.hardware.advance(0, 12_000)
        f.drain("outgoing checkpoint after cancelled optional source") { f.history(0)?.bookmark == 12_000L }
        assertEquals(-1L, f.journal.stamp(1))
        assertNull(f.history(1))
        assertEquals(0, f.readers[1].binds.get())
        assertEquals(listOf(0), f.hardware.plays)
        assertTrue(f.completed.isEmpty())
    }

    @Test fun revokedHeldPromotedSourceCannotAttachToTheRetiredAssignment() = Fixture().use { f ->
        f.start()
        f.holdJournal().use {
            f.readyAndArmed()
            f.hardware.eof(0, startIncoming = true)
            f.drain("incoming selection while binding is held") { f.player.currentMediaItem?.mediaId == f.items[1].mediaId }
            f.grants.remove(f.uris[1])
            f.drain("promoted source authority revoked while journal IO is held") { !f.player.playWhenReady }
            assertEquals(-1L, f.journal.stamp(1))
        }
        f.drain("revoked promoted source decoder ACK and settled preparation") { f.readers[1].closed && f.player.preparationSettled }
        assertFalse(f.player.isPlaying)
        assertEquals(-1L, f.journal.stamp(1))
        assertEquals(0, f.readers[1].binds.get())
        assertNull(f.history(1))
    }

    private class Reader(private val current: () -> Boolean) : NativePcmReader {
        val binds = AtomicInteger()
        @Volatile var closed = false
        private var revoked = false
        override fun open() = 48_000
        override fun read(first: Long, count: Int, destination: ByteBuffer): Int {
            check(current() && !revoked && !closed)
            destination.putShort(42)
            return count
        }
        override fun endFrames() = DURATION * 48
        // For this finite long source, the real journal invokes it exactly once per bind.
        override fun longFormConfirmed(): Boolean { binds.incrementAndGet(); return true }
        override fun revoke() { revoked = true }
        override fun closeReader(): Boolean { closed = true; return true }
    }

    /** Only the JNI boundary is modeled; Player, handler owner, wire parser and journal are real. */
    private class Hardware : NativeCallbackCalls {
        private data class Deck(val id: Long, val reader: NativePcmReader, var position: Long = 0, var playing: Boolean = false, var eof: Long = 0)
        private val decks = arrayOfNulls<Deck>(2)
        @Volatile var incomingReady = false
        @Volatile var sawIncomingReadySnapshot = false
        @Volatile var armed = false
        val loads = CopyOnWriteArrayList<Pair<Int, Long>>()
        val plays = CopyOnWriteArrayList<Int>()
        override fun open() = 1L
        override fun recoverOutput(handle: Long) = NativeOutputRecovery.Healthy
        override fun load(handle: Long, deck: Int, path: String, identity: Long, generation: Long, positionMs: Long) = error("Expected a borrowed original")
        @Synchronized override fun loadReader(handle: Long, deck: Int, reader: NativePcmReader, identity: Long, generation: Long, positionMs: Long, speed: Double): Boolean {
            check(identity == generation && decks[deck] == null && reader.open() == 48_000)
            decks[deck] = Deck(identity, reader, positionMs)
            loads += deck to identity
            return true
        }
        @Synchronized override fun control(handle: Long, operation: Int, deck: Int, value: Double, eventNanos: Long): Boolean {
            when (operation) {
                1 -> { decks[deck]!!.playing = true; plays += deck }
                2 -> decks.forEach { it?.playing = false }
                8 -> decks[deck] = null
            }
            return true
        }
        @Synchronized override fun crossfade(handle: Long, outgoing: Int, outgoingGeneration: Long, incoming: Int, incomingGeneration: Long, milliseconds: Long): Boolean {
            check(decks[outgoing]?.id == outgoingGeneration && decks[incoming]?.id == incomingGeneration)
            if (milliseconds > 0) armed = true
            return true
        }
        @Synchronized fun assignment(deck: Int) = decks[deck]?.id
        @Synchronized fun advance(deck: Int, position: Long) {
            val d = checkNotNull(decks[deck]); check(d.playing)
            val buffer = ByteBuffer.allocate(2)
            check(d.reader.read(position * 48, 1, buffer) == 1 && buffer.getShort(0) == 42.toShort())
            d.position = position
        }
        @Synchronized fun eof(deck: Int, startIncoming: Boolean = false) {
            advance(deck, DURATION)
            decks[deck]!!.apply { eof++; playing = false }
            if (startIncoming) {
                check(armed)
                decks[1]!!.playing = true
                advance(1, 1_000)
            }
        }
        @Synchronized override fun state(handle: Long): String {
            // Distinguish the real readiness snapshot from periodic owner polls.
            if (incomingReady && decks[1] != null && Thread.currentThread().stackTrace.any {
                it.className.startsWith(NativeCallbackOwner::class.java.name + "\$snapshot\$")
            }) sawIncomingReadySnapshot = true
            return JSONObject().put("error", 0).put("sampleRate", 48_000).put("coherent", true)
                .put("naturalEndVersion", 1).put("decks", JSONArray().apply { decks.forEachIndexed { slot, d ->
                    val id = d?.id ?: 0L
                    put(JSONObject().put("identity", id).put("generation", id).put("positionMs", d?.position ?: 0)
                        .put("durationMs", DURATION).put("sourceRate", 48_000).put("sourceFrames", DURATION * 48)
                        .put("ready", d != null && (slot == 0 || incomingReady)).put("preparing", false)
                        .put("playing", d?.playing == true).put("rate", 1.0).put("eofCount", d?.eof ?: 0)
                        .put("error", 0).put("openDecoders", if (d == null) 0 else 1).put("traversalRevision", 1)
                        .put("naturalEndCount", d?.eof ?: 0).put("naturalEndIdentity", id)
                        .put("naturalEndGeneration", id).put("naturalEndTraversalRevision", 1))
                } }).toString()
        }
        @Synchronized override fun close(handle: Long): Boolean { decks.fill(null); return true }
    }

    private class Fixture : AutoCloseable {
        private val root = Files.createTempDirectory("native-successor-journal-").toFile()
        private val store = DeviceListeningStore(File(root, "listening.json"))
        private val jobs = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        private val graph = AppGraph(object : ContextWrapper(RuntimeEnvironment.getApplication()) {
            override fun getNoBackupFilesDir() = root
        }, ApiEndpoint.parse("https://fixture.invalid/api/v1"), store = object : SessionStore {
            override fun load(endpoint: ApiEndpoint): SecretTokens? = null
            override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) {}
            override fun clear() {}
        }, openPhoneAudioStore = { store })
        val hardware = Hardware()
        val grants = ConcurrentHashMap<String, MediaGrant>()
        val uris = listOf("soundq://track/1/outgoing", "soundq://track/2/incoming")
        val items = uris.mapIndexed { i, uri ->
            MediaItem.Builder().setMediaId(UUID(0, i + 1L).toString()).setUri(Uri.parse(uri))
                .setMediaMetadata(MediaMetadata.Builder().setExtras(Bundle().apply { putLong("trackId", i + 1L) }).build()).build()
        }
        val readers = CopyOnWriteArrayList<Reader>()
        val completed = mutableListOf<String>()
        private val admissions: List<com.soundq.android.data.device.PhoneSourceAdmission>
        val player: NativeCallbackPlayer
        val journal: NativeListeningJournal
        private val ownerThread: HandlerThread

        init {
            val seedAccess = store.unlock()
            val scan = ScanGrant(ScanGrantId(UUID(1, 1)), GrantKind.INDEXED, "fixture", ProviderLocator("fixture", "index"), true)
            check(store.putGrant(seedAccess, scan) != Mutation.REFUSED)
            check(store.publishScan(checkNotNull(store.beginScan(seedAccess, scan.id)), items.mapIndexed { i, _ ->
                DiscoveredAudio(ProviderObjectId("fixture", "source-$i"), ProviderLocator("fixture", "content://fixture/$i"),
                    ContentRevision((i + 1).toString().repeat(64), 64), OriginalMetadata("source-$i.mp3"), DURATION)
            }) != Mutation.REFUSED)
            check(graph.session.accept(graph.session.beginIntent(), SecretTokens("fixture", "fixture", "fixture")))
            graph.phoneAudio.start()
            admissions = runBlocking {
                withTimeout(4_000) {
                    while (!graph.phoneAudio.current(graph.session.version()) || graph.phoneAudio.state.value.snapshot == null) delay(10)
                    val rows = graph.phoneAudio.state.value.snapshot!!.files.sortedBy { it.objectId.objectId }
                    rows.map { checkNotNull(graph.phoneAudio.admit(it)) }.also { check(it.size == 2) }
                }
            }
            graph.crossfadePreferences.load()
            check(graph.crossfadePreferences.setSeconds(checkNotNull(graph.crossfadePreferences.capture()), 2) { true })
            uris.forEachIndexed { i, uri -> grants[uri] = MediaGrant(checkNotNull(graph.session.capture()), TrackId(i + 1L)) }
            player = NativeCallbackPlayer(graph, grants, jobs, hardware, object : NativeCallbackSource {
                override fun prepare(item: MediaItem, current: () -> Boolean): File = error("Expected typed acquisition")
                override fun acquire(item: MediaItem, current: () -> Boolean): NativePlaybackSource {
                    val i = items.indexOfFirst { it.mediaId == item.mediaId }
                    checkNotNull(grants[uris[i]]).phoneAdmission = admissions[i]
                    val reader = Reader(current).also { readers += it }
                    return NativePlaybackSource.BorrowedOriginal(reader, 0, DURATION, admissions[i].row.canonicalId, current)
                }
            })
            journal = field(player, "journal") as NativeListeningJournal
            ownerThread = field(field(player, "owner"), "thread") as HandlerThread
            player.setMediaItems(items)
            player.addCompletionListener { completed += it.mediaId }
        }

        fun start() {
            player.prepare()
            player.play()
            drain("outgoing playing and incoming assigned but not ready") { player.isPlaying && hardware.assignment(1) != null }
            hardware.advance(0, 6_000)
            drain("outgoing durable checkpoint before the hold") { history(0)?.bookmark == 6_000L }
        }
        fun readyAndArmed() {
            hardware.incomingReady = true
            drain("both decks ready and the owner acknowledged the native arm") {
                hardware.sawIncomingReadySnapshot && hardware.armed && (field(player, "successor")?.let { field(it, "armed") } == true)
            }
            assertEquals(-1L, journal.stamp(1))
            assertEquals(0, readers[1].binds.get())
            assertNull(history(1))
        }
        fun holdJournal(): AutoCloseable {
            val mutex = field(graph.phoneAudio, "serial") as Mutex
            val token = Any()
            runBlocking(Dispatchers.IO) { withTimeout(2_000) { mutex.lock(token) } }
            return AutoCloseable { mutex.unlock(token) }
        }
        fun history(slot: Int): History? {
            val source = admissions[slot].source
            val entry = store.snapshot(source.access)?.history?.singleOrNull { it.key == source.owner.key } ?: return null
            return History(entry.bookmark?.positionMs)
        }
        fun drainJournalPoll() {
            val before = field(journal, "tail")
            var next: Job? = null
            drain("fresh native journal observation") {
                next = (field(journal, "tail") as Job?)?.takeUnless { it === before }
                next != null
            }
            drain("fresh journal observation completed") { checkNotNull(next).isCompleted }
        }
        fun drain(stage: String, predicate: () -> Boolean) {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(4)
            do {
                shadowOf(ownerThread.looper).idleFor(Duration.ofMillis(50))
                shadowOf(Looper.getMainLooper()).idle()
                if (predicate()) return
                Thread.sleep(5) // real repository IO is not a shadow looper
            } while (System.nanoTime() < deadline)
            fail("$stage; completions=$completed loads=${hardware.loads} binds=${readers.map { it.binds.get() }} stamp=${journal.stamp(1)}")
        }
        override fun close() {
            try {
                player.release()
                drain("player owner close") { player.nativeReleased.isDone }
                assertTrue(player.nativeReleased.get())
                assertTrue(readers.all { it.closed })
            } finally {
                jobs.cancel()
                graph.close()
                root.deleteRecursively()
            }
        }
    }

    private data class History(val bookmark: Long?)
    private companion object {
        const val DURATION = 720_000L
        fun field(owner: Any?, name: String): Any? = checkNotNull(owner).javaClass.getDeclaredField(name).apply { isAccessible = true }.get(owner)
    }
}
