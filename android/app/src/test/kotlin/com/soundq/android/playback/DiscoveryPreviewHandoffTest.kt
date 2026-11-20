package com.soundq.android.playback

import android.media.AudioManager
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.os.Looper
import android.os.Message
import android.os.MessageQueue
import androidx.media3.common.*
import androidx.media3.session.MediaController
import androidx.media3.session.MediaSession
import com.soundq.android.*
import com.soundq.android.data.*
import com.soundq.android.data.imports.ImportSource
import com.soundq.android.playback.nativeengine.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import mockwebserver3.*
import org.json.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.*
import org.robolectric.annotation.Config
import java.io.File
import java.time.Duration
import java.util.concurrent.*
import kotlin.coroutines.CoroutineContext

/** Real service, controller projection, account and HTTP; only encoded acquisition and renderer use facades. */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28], application = PreviewHandoffApplication::class)
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class DiscoveryPreviewHandoffTest {
    private class Fixture(holdAccountCollector: Boolean = false) : AutoCloseable {
        val app = RuntimeEnvironment.getApplication() as PreviewHandoffApplication
        val graph = app.graph
        val hw = app.hardware
        val lifecycle = Robolectric.buildService(SoundQLibraryService::class.java).also {
            if (holdAccountCollector) app.accountCollector = HeldAccountCollector()
        }.create()
        val service = lifecycle.get()
        fun field(name: String) = service.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(service)
        val player = field("player") as NativeCallbackPlayer
        val projection = ControllerProjection(app, (field("session") as MediaSession).token)
        val controller get() = ControllerProjection::class.java.getDeclaredField("controller").apply { isAccessible = true }
            .get(projection) as MediaController
        val jobs = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val completed = mutableListOf<String>()
        val scope = checkNotNull(graph.session.capture())
        init {
            player.addCompletionListener { completed += it.mediaId }
            drain("controller connected") { projection.state.value.connection == PlaybackProjection.Connection.Connected && field("account") != null }
        }
        val ownerLooper get() = (playerField("owner")!!.let { owner ->
            owner.javaClass.getDeclaredField("thread").apply { isAccessible = true }.get(owner)
        } as HandlerThread).looper
        fun drain(label: String, advanceOwner: Boolean = true, predicate: () -> Boolean) {
            val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(8)
            do {
                if (advanceOwner) {
                    ownerLooper?.let { Shadows.shadowOf(it).idleFor(Duration.ofMillis(25)) }
                }
                Shadows.shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(25))
                if (predicate()) return
                Thread.sleep(4)
            } while (System.nanoTime() < end)
            fail("$label: ${player.nativeDiagnostics()}")
        }
        fun crossAccountCollectorBarrier() {
            val subscriptions = (graph.session.scopeRevision as MutableStateFlow<Long>).subscriptionCount
            val before = subscriptions.value
            val continuations = checkNotNull(app.accountCollector).release()
            // The initial launch, both real combine source subscriptions, and their
            // consuming continuation(s) ran to quiescence on Main before this returns.
            assertTrue("account collector was not dispatched", continuations >= 3)
            assertEquals("account collector subscribed to the real epoch flow", before + 1, subscriptions.value)
            println("player account collector drained: $continuations continuations, auth=${graph.session.state.value}")
        }
        fun playerField(name: String): Any? = NativeCallbackPlayer::class.java.getDeclaredField(name)
            .apply { isAccessible = true }.get(player)
        val recoveryRevision get() = try { playerField("outputRecoveryRevision") as Long? }
            catch (_: NoSuchFieldException) { playerField("outputRecovery")?.let { batch ->
                batch.javaClass.getDeclaredField("revision").apply { isAccessible = true }.getLong(batch)
            } }
        val loaded get() = playerField("selectedLoaded") == true
        val revision get() = playerField("transportRevision") as Long
        val main get() = Shadows.shadowOf(Looper.getMainLooper())
        fun selectOrdinary() {
            val row = Track(TrackId(1), "Ordinary", "Fixture", durationMs = 6000)
            graph.rememberTracks(listOf(row))
            controller.setMediaItem(MediaItem.Builder().setMediaId(row.id.value.toString()).build())
            drain("ordinary occurrence installed") { player.mediaItemCount == 1 }
        }
        fun prepareOrdinary() { selectOrdinary(); player.prepare() }
        fun settled() {
            val polls = hw.polls
            drain("transport and four native polls settled") { player.preparationSettled && hw.polls >= polls + 4 }
        }
        fun pendingPreview(): Any? = NativeCallbackPlayer::class.java.getDeclaredField("previewPreparation")
            .apply { isAccessible = true }.get(player)
        fun topology() = OrdinaryTopology(
            (0 until player.mediaItemCount).map(player::getMediaItemAt), player.currentMediaItemIndex,
            player.currentPosition, player.repeatMode, player.shuffleModeEnabled, player.nativeTraversalForTest(),
            player.playWhenReady, player.isPlaying, player.playbackState, hw.identity(0),
        )
        fun ordinary(): List<MediaItem> {
            val rows = listOf(Track(TrackId(1), "Ordinary", "Fixture", durationMs = 6000), Track(TrackId(2), "Next", "Fixture", durationMs = 6000))
            graph.rememberTracks(rows)
            projection.playContext(rows, 1)
            drain("ordinary playing") { player.isPlaying && player.mediaItemCount == 2 && player.currentMediaItemIndex == 1 }
            player.repeatMode = Player.REPEAT_MODE_ALL
            player.shuffleModeEnabled = true
            hw.cursor(0, 321)
            drain("moving ordinary cursor") { player.currentPosition == 321L }
            return (0 until player.mediaItemCount).map(player::getMediaItemAt)
        }
        fun preview(name: String, current: () -> Boolean = { true }): Deferred<Boolean> {
            val command = projection.captureContextRead(preview = true)
            val source = checkNotNull(ImportSource.parse(previewUrl(name)))
            return jobs.async(start = CoroutineStart.UNDISPATCHED) {
                projection.startDiscoveryPreview(scope, source, name, "Fixture", wireValid = current) { command() && current() }
            }
        }
        fun await(result: Deferred<Boolean>): Boolean {
            drain("preview result settled") { result.isCompleted }
            return runBlocking { result.await() }
        }
        override fun close() {
            app.saveRelease.countDown()
            try {
                jobs.cancel(); projection.close(); lifecycle.destroy()
                app.accountCollector?.release()
                drain("native owner closed") { player.nativeReleased.isDone }
                assertTrue(player.nativeReleased.get())
            } finally {
                try { app.graph.close() } finally {
                    try { app.fixture.close() } finally { hw.closeWorkers() }
                }
            }
        }
    }

    private data class OrdinaryTopology(
        val rows: List<MediaItem>, val index: Int, val cursor: Long, val repeat: Int, val shuffle: Boolean,
        val traversal: List<Int>, val playIntent: Boolean, val playing: Boolean, val state: Int, val generation: Long,
    )

    @Test fun removedOccurrenceCannotReturnAfterAnotherPreview() = replayAfterEdit(QueueEdit.RemoveOther, 777)
    @Test fun movedOccurrenceKeepsNewIndexAndExactZeroAfterAnotherPreview() = replayAfterEdit(QueueEdit.Move, 0)
    @Test fun anotherPreviewWithoutEditKeepsTheSameParkedOccurrence() = replayAfterEdit(QueueEdit.None, 0)
    @Test fun removingSelectedOccurrenceRetiresItsLateCursor() = replayAfterEdit(QueueEdit.RemoveSelected, 777)

    private enum class QueueEdit { RemoveOther, Move, None, RemoveSelected }

    private fun replayAfterEdit(edit: QueueEdit, lateCursor: Long) {
        Fixture().use { f ->
            val (x, y) = f.ordinary()
            val initialLoads = f.hw.acceptedLoads.toList()
            assertEquals(listOf(y.mediaId), initialLoads.map { it.occurrence })
            val (rows, selectedIndex) = when (edit) {
                QueueEdit.RemoveOther -> listOf(y) to 0
                QueueEdit.Move -> listOf(y, x) to 0
                QueueEdit.RemoveSelected -> listOf(x) to 0
                QueueEdit.None -> listOf(x, y) to 1
            }
            val expectedIds = rows.map { it.mediaId }
            val selected = rows[selectedIndex]
            val cursor = if (edit == QueueEdit.RemoveSelected) 0L else lateCursor
            fun ids(player: Player) = (0 until player.mediaItemCount).map { player.getMediaItemAt(it).mediaId }
            fun agrees() = listOf(f.player, f.controller).all {
                ids(it) == expectedIds && it.currentMediaItemIndex == selectedIndex && it.currentMediaItem?.mediaId == selected.mediaId
            } && f.projection.state.value.let { it.queue.map { row -> row.occurrenceId } == expectedIds && it.selectedOccurrence == selected.mediaId }

            f.hw.holdPause = true
            val a = f.preview("A")
            f.drain("A installed with ordinary Pause held") { f.hw.pauseRequests > 0 && f.controller.mediaMetadata.title == "A" }
            f.controller.stop()
            f.drain("Stop admitted and ordinary published") {
                ids(f.player) == listOf(x.mediaId, y.mediaId) && ids(f.controller) == ids(f.player) && !f.player.playWhenReady
            }
            when (edit) {
                QueueEdit.RemoveOther -> f.projection.remove(x.mediaId)
                QueueEdit.Move -> f.projection.moveTo(y.mediaId, 0)
                QueueEdit.RemoveSelected -> f.projection.remove(y.mediaId)
                QueueEdit.None -> Unit
            }
            f.drain("ordinary edit applied at the service and acknowledged by the controller/projection", predicate = ::agrees)
            @Suppress("UNCHECKED_CAST")
            val grants = f.field("grants") as Map<String, MediaGrant>
            val removed = when (edit) { QueueEdit.RemoveOther -> x; QueueEdit.RemoveSelected -> y; else -> null }
            val removedUri = removed?.localConfiguration?.uri?.toString()
            removedUri?.let { assertFalse("removed URI must be pruned before B", grants.containsKey(it)) }
            assertEquals("Pause still held at the entry cursor after edit", if (edit == QueueEdit.RemoveSelected) 0L else 321L, f.player.currentPosition)
            assertNotEquals(0L, f.hw.identity(0))
            assertEquals(initialLoads, f.hw.acceptedLoads.toList())
            f.hw.applyHeldPause(lateCursor)
            f.drain("late Pause published only to its surviving occurrence and all decks drained") {
                a.isCompleted && f.hw.empty() && f.player.currentPosition == cursor && f.controller.currentPosition == cursor &&
                    f.projection.state.value.positionMs == cursor
            }
            assertTrue(agrees())

            // Read service-owned durable state separately from fake decoder receipts.
            val savedFile = if (edit == QueueEdit.None) null else {
                fun snapshots() = f.graph.directory.listFiles().orEmpty().filter { it.name.startsWith("queue-") && it.name.endsWith(".json") }
                f.drain("admitted edit persisted") {
                    snapshots().any {
                        QueueSnapshotStore(it).read(f.graph.endpoint.identity, f.scope.accountId) { true }?.let { snapshot ->
                            snapshot.items.map { row -> row.occurrence } == expectedIds && snapshot.selected == selectedIndex && snapshot.position == cursor
                        } == true
                    }
                }
                snapshots().single()
            }
            val saved = savedFile?.readBytes()
            println("before B: edit=$edit ids=${ids(f.player)} index=${f.player.currentMediaItemIndex} cursor=${f.player.currentPosition} removedGrant=${removedUri?.let(grants::containsKey)}")
            assertTrue(f.await(f.preview("B")))
            f.drain("B actually playing") { f.player.isPlaying && f.controller.mediaMetadata.title == "B" }
            f.controller.stop()
            f.drain("B stopped and retired") { f.hw.empty() && f.player.parkedQueue == null && f.projection.state.value.source == PlaybackSource.Queue }
            val restored = ids(f.player)
            val restoredIndex = f.player.currentMediaItemIndex
            val exactRestore = agrees()
            assertEquals(cursor, f.player.currentPosition)
            assertFalse(f.player.playWhenReady)
            assertEquals(initialLoads, f.hw.acceptedLoads.toList())
            assertTrue(f.completed.isEmpty())
            if (saved != null) assertArrayEquals("preview must not rewrite the admitted edit", saved, savedFile.readBytes())
            f.controller.prepare(); f.controller.play()
            f.drain("explicit replay accepted or refused") { f.player.isPlaying || f.player.playerError != null }
            val loads = f.hw.acceptedLoads.drop(initialLoads.size)
            println("after B: ids=$restored index=$restoredIndex cursor=$cursor; explicit replay=$loads error=${f.player.playerError?.message}")
            assertTrue("B must restore $expectedIds at index $selectedIndex, got $restored at $restoredIndex; replay error=${f.player.playerError?.message}", exactRestore)
            assertEquals(listOf(ProjectionPreviewHardware.OrdinaryLoad(selected.mediaId, cursor)), loads)
            assertNull(f.player.playerError)
            assertTrue(f.player.isPlaying)
        }
    }

    @Test fun heldHandoffPauseSurvivesImmediateStopAndPublishesExactCursor() {
        Fixture().use { f ->
            val rows = f.ordinary()
            f.hw.holdPause = true
            val a = f.preview("A")
            f.drain("handoff Pause entered") { f.hw.pauseRequests > 0 }
            f.player.stop()
            f.hw.applyHeldPause(777)
            f.drain("handoff resources retired") { a.isCompleted && f.hw.empty() }
            assertEquals("Stop must not restore the earlier moving poll", 777L, f.player.currentPosition)
            f.drain("matching restored controller cursor") { f.projection.state.value.positionMs == 777L }
            assertEquals(rows, (0 until f.player.mediaItemCount).map(f.player::getMediaItemAt))
            assertEquals(1, f.player.currentMediaItemIndex)
            assertEquals(Player.REPEAT_MODE_ALL, f.player.repeatMode)
            assertTrue(f.player.shuffleModeEnabled)
            assertFalse(f.player.playWhenReady)
            assertTrue(f.hw.played.none { it >= 2 })
            assertTrue(f.completed.isEmpty())
            f.player.prepare(); f.player.play()
            f.drain("first explicit replay") { f.player.isPlaying }
            assertEquals(777L, f.hw.ordinaryLoads.last())
        }
    }

    @Test fun refusedHandoffPauseCannotAuthorizePreviewPlayEvenAfterSuccessfulUnload() {
        Fixture().use { f ->
            f.ordinary(); f.hw.refusePause = true
            val result = f.preview("A")
            f.drain("handoff retired ordinary deck") { result.isCompleted && f.hw.pauseRequests > 0 && f.hw.identity(0) == 0L }
            assertTrue("unload is not a Pause receipt", f.hw.played.none { it >= 2 })
            f.drain("refusal settled") { f.player.playerError != null && f.hw.empty() }
            assertEquals(321L, f.player.currentPosition)
            assertFalse(f.player.playWhenReady)
        }
    }

    @Test fun olderNaturalEofCannotRetireEnteredNewerPreview() {
        Fixture().use { f ->
            f.ordinary()
            assertTrue(f.await(f.preview("A")))
            f.drain("A playing and published") { f.player.isPlaying && f.hw.played.contains(2) && f.projection.state.value.title == "A" }
            f.hw.holdPreview = true
            val b = f.preview("B")
            f.drain("B entered spare deck") { f.hw.identity(3) != 0L && f.hw.previewOpened.contains(3) }
            f.hw.eof(2)
            f.drain("A EOF drained and restored the ordinary controller selection") {
                f.hw.identity(2) == 0L && f.projection.state.value.title == "Next"
            }
            f.hw.holdPreview = false
            assertTrue("A EOF must not consume B's intent", f.await(b))
            f.drain("B playing") { f.player.isPlaying && f.player.mediaMetadata.title == "B" }
            assertEquals(listOf(0, 2, 3), f.hw.played.toList())
            assertTrue(f.completed.isEmpty())
        }
    }

    @Test fun pendingPreviewSurvivesSaveCollectorWithMovingQueue() = pendingPreviewSurvivesSaveCollector(moving = true)
    @Test fun pendingPreviewSurvivesSaveCollectorWithPausedQueue() = pendingPreviewSurvivesSaveCollector(moving = false)

    private fun pendingPreviewSurvivesSaveCollector(moving: Boolean) {
        Fixture(holdAccountCollector = true).use { f ->
            val rows = f.ordinary()
            if (!moving) {
                f.player.pause()
                f.drain("ordinary Pause acknowledged") { !f.player.isPlaying && !f.player.playWhenReady && !f.hw.isPlaying(0) }
            }
            val before = f.topology()
            assertEquals(rows, before.rows)
            assertEquals(1, before.index)
            assertEquals(321L, before.cursor)
            assertEquals(moving, before.playing)
            assertEquals(Player.STATE_READY, before.state)
            val ordinaryLoads = f.hw.acceptedLoads.toList()
            val session = f.graph.session
            f.app.rotate = true
            f.hw.holdPreview = true
            val work = f.preview("A")
            f.drain("401 rotation withdrew tokens and reached held secure save") { f.app.saveEntered.count == 0L }
            val pending = checkNotNull(f.pendingPreview())
            val load = f.hw.previewLoads.single()
            assertEquals(load.generation, f.hw.identity(load.deck))
            assertNull(f.player.parkedQueue)
            assertEquals(AuthState.SignedIn(f.scope.accountId), session.state.value)
            assertEquals(f.scope.epoch, session.version())
            assertTrue(session.discoveryReadState(f.scope) is DiscoveryReadState.Saving)
            assertTrue(session.previewOwnerCurrent(f.scope))
            assertNull(session.capture())
            assertFalse(session.current(f.scope))
            assertFalse(session.remoteCurrent(f.scope))
            assertFalse(session.discoveryCurrent(f.scope))
            assertFalse(session.discoveryDispatchCurrent(f.scope, "a"))
            assertEquals(SafeFailure.Reason.Retired, assertThrows(SafeFailure::class.java) {
                f.graph.api.descriptor(f.scope, TrackId(2))
            }.reason)
            assertEquals(SafeFailure.Reason.Retired, assertThrows(SafeFailure::class.java) {
                f.graph.api.like(f.scope, TrackId(2), true)
            }.reason)
            assertFalse(runBlocking {
                f.projection.startDiscoveryPreview(f.scope, checkNotNull(ImportSource.parse(previewUrl("B"))), "B", "Fixture") { true }
            })
            val otherEndpoint = AccountSession(ApiEndpoint.parse("https://other.fixture.invalid/api/v1"), MemoryStore())
            assertTrue(otherEndpoint.accept(otherEndpoint.beginIntent(), SecretTokens("x", "r-x", f.scope.accountId)))
            val foreignScope = checkNotNull(otherEndpoint.capture())
            assertEquals(f.scope.epoch, foreignScope.epoch)
            assertTrue(otherEndpoint.remoteCurrent(foreignScope))
            assertFalse(session.previewOwnerCurrent(foreignScope))
            assertFalse(runBlocking {
                f.projection.startDiscoveryPreview(foreignScope, checkNotNull(ImportSource.parse(previewUrl("B"))), "B", "Fixture") { true }
            })
            assertEquals(listOf(f.app.expectedPreview("A", "a")), f.app.previewRequests.toList())
            assertEquals(listOf("/api/v1/discovery/preview", "/api/v1/auth/refresh"), f.app.wirePaths.dropWhile { it == "/api/v1/library" })

            val polls = f.hw.polls
            f.drain("ordinary readiness observer crossed the held save before the account collector") { f.hw.polls >= polls + 4 }
            assertEquals(before, f.topology())
            assertFalse(load.input.canceled)
            f.crossAccountCollectorBarrier()
            assertEquals(1L, f.app.saveRelease.count)
            println("held save: moving=$moving canceled=${load.input.canceled} rows=${f.player.mediaItemCount}")
            assertEquals("account collector must preserve pending input and ordinary topology during save",
                false to before, load.input.canceled to f.topology())
            assertSame(pending, f.pendingPreview())
            assertEquals(load.generation, f.hw.identity(load.deck))
            assertFalse(work.isCompleted)
            assertEquals(ordinaryLoads, f.hw.acceptedLoads.toList())
            assertEquals(listOf(0), f.hw.played.toList())

            f.app.saveRelease.countDown()
            f.drain("same preview input reopened but is still held before native readiness") { load.deck in f.hw.previewOpened }
            assertTrue(session.remoteCurrent(f.scope))
            assertSame(pending, f.pendingPreview())
            assertEquals(listOf(load), f.hw.previewLoads.toList())
            assertEquals(load.generation, f.hw.identity(load.deck))
            assertEquals(before, f.topology())
            assertEquals(listOf(f.app.expectedPreview("A", "a"), f.app.expectedPreview("A", "b")), f.app.previewRequests.toList())
            assertEquals(listOf("/api/v1/discovery/preview", "/api/v1/auth/refresh", "/api/v1/discovery/preview"),
                f.app.wirePaths.dropWhile { it == "/api/v1/library" })
            f.hw.holdPreview = false
            assertTrue(f.await(work))
            f.drain("exact reopened preview active") { f.player.isPlaying && f.projection.state.value.title == "A" }
            assertEquals(load.generation, f.hw.identity(load.deck))
            assertEquals(f.player.currentMediaItem?.mediaId, f.controller.currentMediaItem?.mediaId)
            assertEquals(listOf(0, load.deck), f.hw.played.toList())
            f.controller.stop()
            f.drain("original ordinary occurrence and cursor restored paused") {
                f.hw.empty() && f.player.parkedQueue == null && f.projection.state.value.source == PlaybackSource.Queue
            }
            val restored = f.topology()
            assertEquals(before.copy(playIntent = false, playing = false, state = Player.STATE_IDLE,
                generation = 0L), restored)
            assertEquals(ordinaryLoads, f.hw.acceptedLoads.toList())
            assertTrue(f.completed.isEmpty())
        }
    }

    @Test fun incoherentAndWrongGenerationPauseCannotPublishBeforeExactZero() {
        Fixture().use { f ->
            f.ordinary(); f.hw.holdPause = true
            val a = f.preview("A")
            f.drain("handoff Pause entered") { f.hw.pauseRequests > 0 }
            f.player.stop()
            fun poll() {
                val before = f.hw.polls
                f.drain("candidate receipt polled") { f.hw.polls >= before + 3 }
                assertEquals(321L, f.player.currentPosition)
                assertNotEquals(0L, f.hw.identity(0))
            }
            f.hw.samplePause(906, false, 0); poll()
            f.hw.samplePause(907, true, 1); poll()
            f.hw.samplePause(0, true, 0)
            f.drain("exact zero restored and decoder drained") { a.isCompleted && f.hw.empty() }
            assertEquals(0L, f.player.currentPosition)
            f.player.prepare(); f.player.play()
            f.drain("first explicit replay from zero") { f.player.isPlaying }
            assertEquals(0L, f.hw.ordinaryLoads.last())
        }
    }

    @Test fun explicitStopRetiresEnteredB() = retireB("stop")
    @Test fun routeRetirementRetiresEnteredB() = retireB("route")
    @Test fun accountReplacementRetiresEnteredB() = retireB("account")
    @Test fun newerPreviewRetiresEnteredB() = retireB("C")

    private fun retireB(retirement: String) {
        Fixture().use { f ->
            f.ordinary()
            assertTrue(f.await(f.preview("A")))
            f.drain("A playing") { f.player.isPlaying }
            val route = java.util.concurrent.atomic.AtomicBoolean(true)
            f.hw.holdPreview = true
            val b = f.preview("B", route::get)
            f.drain("B entered") { f.hw.identity(3) != 0L && 3 in f.hw.previewOpened }
            val c = when (retirement) {
                "stop" -> { f.player.stop(); null }
                "route" -> { route.set(false); null }
                "account" -> { f.graph.session.beginIntent(); null }
                else -> f.preview("C")
            }
            f.drain("B permanently refused") { b.isCompleted && (c == null || f.app.previewRequests.size == 3) }
            assertFalse(f.await(b)); assertEquals(listOf(0, 2), f.hw.played.toList())
            if (c != null) {
                f.hw.holdPreview = false
                assertTrue(f.await(c))
                f.drain("C playing") { f.player.isPlaying && f.player.mediaMetadata.title == "C" }
            }
            assertTrue(f.completed.isEmpty())
        }
    }

    @Test fun playDuringOrdinaryPreparationDispatchesOnce() {
        Fixture().use { f ->
            val row = Track(TrackId(1), "Ordinary", "Fixture", durationMs = 6000)
            f.graph.rememberTracks(listOf(row))
            val gainEntered = CountDownLatch(1)
            val gainRelease = CountDownLatch(1)
            f.hw.beforeOrdinaryGain = {
                gainEntered.countDown()
                check(gainRelease.await(8, TimeUnit.SECONDS))
            }
            f.controller.setMediaItem(MediaItem.Builder().setMediaId(row.id.value.toString()).build())
            f.controller.prepare()
            try {
                f.drain("preparation reached its native gain operation", advanceOwner = false) { gainEntered.count == 0L }
                assertFalse(f.player.playWhenReady)
                f.controller.play()
                f.drain("explicit Play admitted while preparation is held", advanceOwner = false) { f.player.playWhenReady }
                assertTrue(f.hw.played.isEmpty())
            } finally {
                gainRelease.countDown()
            }
            val polls = f.hw.polls
            f.drain("preparation and native output settled") { f.player.preparationSettled && f.player.isPlaying && f.hw.polls >= polls + 4 }
            val identity = f.hw.identity(0)
            assertNotEquals(0L, identity)
            assertEquals(listOf(f.player.currentMediaItem?.mediaId), f.hw.acceptedLoads.map { it.occurrence })
            assertEquals(listOf(0), f.hw.played.toList())

            f.controller.pause()
            f.drain("ordinary Pause acknowledged") { !f.player.playWhenReady && !f.player.isPlaying && !f.hw.isPlaying(0) }
            f.controller.play()
            f.drain("fresh Play of the same assignment acknowledged") { f.player.isPlaying && f.hw.isPlaying(0) }
            assertEquals(identity, f.hw.identity(0))
            assertEquals(1, f.hw.acceptedLoads.size)
            assertEquals(listOf(0, 0), f.hw.played.toList())
        }
    }

    // Block the real repository's journal IO after native readiness, not the
    // player dispatcher. Run just the queued bind result before deferred transport.
    private class BindGate(private val f: Fixture) : AutoCloseable {
        private val repo = f.graph.phoneAudio
        private val serial = repo.javaClass.getDeclaredField("serial").apply { isAccessible = true }.get(repo) as Mutex
        private var held = false
        fun ready(): Long {
            repo.start()
            f.drain("listening store available") { repo.current(f.graph.session.version()) }
            f.hw.holdOrdinaryReady = true
            f.prepareOrdinary()
            f.drain("native load admitted before withholding journal IO") { f.hw.acceptedLoads.size == 1 }
            runBlocking { withTimeout(8000) { serial.lock() } }
            held = true
            f.hw.trackBindReadiness = true
            f.hw.holdOrdinaryReady = false
            // A healthy poll cannot prove awaitDeckReady took its own snapshot.
            // Do not inject the output fault until that snapshot has been sampled.
            f.drain("ready snapshot for bind while journal IO is held") { f.hw.bindReadinessSampled }
            assertFalse(f.loaded)
            assertFalse(f.player.preparationSettled)
            assertEquals(listOf(9), f.hw.transport.map { it.operation })
            return checkNotNull(f.hw.readyAssignment).generation
        }
        fun queueResult() {
            f.main.idle()
            val queue = Looper.getMainLooper().queue
            val head = MessageQueue::class.java.getDeclaredField("mMessages").apply { isAccessible = true }
            val next = Message::class.java.getDeclaredField("next").apply { isAccessible = true }
            fun queued(): List<Message> = synchronized(queue) {
                generateSequence(head.get(queue) as? Message) { next.get(it) as? Message }
                    .filter { it.`when` <= SystemClock.uptimeMillis() }.toList()
            }
            fun Message.isBind() = callback?.toString()?.contains("NativeListeningJournal.bind(") == true
            close()
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(8)
            while (System.nanoTime() < deadline) {
                val first = queued().firstOrNull()
                if (first == null) Thread.sleep(1)
                else if (first.isBind()) {
                    assertFalse(f.loaded)
                    println("queued Main journal continuation: ${first.callback}")
                    return
                } else f.main.runOneTask()
                assertFalse("journal completed before transport admission", f.loaded)
            }
            fail("final bind continuation did not reach the head of real Main")
        }
        override fun close() { if (held) { held = false; serial.unlock() } }
    }

    @Test fun preloadedFreshPlayRecoversFailedOutputOnSameAssignment() {
        Fixture().use { f ->
            val generation = BindGate(f).use { bind ->
                val generation = bind.ready()
                f.hw.breakOutput()
                f.drain("real failOutput publication before loaded") { f.player.playerError?.message?.startsWith("Audio output is unavailable") == true }
                assertFalse(f.player.playWhenReady)
                assertFalse(f.loaded)
                bind.queueResult()
                var loadedBeforeDeferred = false
                Handler.createAsync(Looper.getMainLooper()).post { loadedBeforeDeferred = f.loaded }
                val revision = f.revision
                // Public Player command runs on the service's actual Main, ahead of its yielded consumer.
                f.player.play()
                assertTrue(f.player.playWhenReady)
                assertTrue(f.revision > revision)
                assertFalse(f.loaded)
                f.main.idle()
                assertTrue("bind continuation ran before deferred Play", loadedBeforeDeferred)
                println("failed route published; explicit Play r=${f.revision} while unloaded; bind published first, generation=$generation")
                generation
            }
            f.settled()
            println("preloaded recovery: ${f.hw.transport}")
            assertEquals(listOf(9, 9, 1), f.hw.transport.map { it.operation }.filter { it != 7 })
            assertNull(f.player.playerError)
            assertTrue(f.player.isPlaying)
            assertEquals(generation, f.hw.identity(0))
            assertEquals(1, f.hw.acceptedLoads.size)
            assertTrue(f.hw.transport.filter { it.operation == 1 || it.operation == 9 && it.generation != 0L }.all { it.deck == 0 && it.identity == generation && it.generation == generation })
        }
    }

    @Test fun preloadedSeekBackToInitialCursorSubmitsRetainedPlayOnce() {
        Fixture().use { f ->
            val generation = BindGate(f).use { bind ->
                val generation = bind.ready()
                f.player.play()
                f.player.seekTo(900)
                f.drain("retained play and non-initial requested cursor") { f.player.playWhenReady && f.player.currentPosition == 900L }
                assertFalse(f.loaded)
                assertTrue(f.hw.played.isEmpty())
                bind.queueResult()
                var loadedBeforeDeferred = false
                Handler.createAsync(Looper.getMainLooper()).post { loadedBeforeDeferred = f.loaded }
                val revision = f.revision
                f.player.seekTo(0)
                assertEquals(0L, f.player.currentPosition)
                assertTrue(f.revision > revision)
                assertFalse(f.loaded)
                TransportGate().use { gain ->
                    f.hw.beforeOrdinaryGain = gain::hold
                    // Drain the deferred Seek without delivering the gain continuation.
                    f.main.idle()
                    assertTrue("bind continuation ran before deferred Seek transport", loadedBeforeDeferred)
                    assertTrue(gain.entered.await(8, TimeUnit.SECONDS))
                }
                println("explicit Seek-to-initial r=${f.revision} while unloaded; bind published first, generation=$generation")
                generation
            }
            f.settled()
            println("preloaded Seek: ${f.hw.transport}")
            assertEquals(listOf(9, 7, 1), f.hw.transport.map { it.operation })
            assertTrue(f.player.isPlaying)
            assertEquals(generation, f.hw.identity(0))
            assertEquals(1, f.hw.acceptedLoads.size)
            assertEquals(listOf(generation), f.hw.transport.filter { it.operation == 1 }.map { it.generation })
        }
    }

    private class TransportGate : AutoCloseable {
        val entered = CountDownLatch(1)
        private val release = CountDownLatch(1)
        fun hold() { entered.countDown(); check(release.await(8, TimeUnit.SECONDS)) }
        override fun close() { release.countDown() }
    }

    @Test fun seekDuringGainRetainsAcknowledgedCursorAndPlaysOnce() {
        Fixture().use { f ->
            TransportGate().use { gain ->
                f.hw.beforeOrdinaryGain = gain::hold
                f.prepareOrdinary()
                f.drain("ordinary gain held", advanceOwner = false) { gain.entered.count == 0L }
                assertTrue(f.loaded)
                f.player.play()
                f.player.seekTo(900)
                f.main.idle()
                assertEquals(900L, f.playerField("desiredSeek"))
                assertTrue(f.hw.played.isEmpty())
            }
            assertRetainedSeek(f, 900)
            println("Seek during gain: ${f.hw.transport}")
            assertEquals(listOf(9, 7, 3, 1), f.hw.transport.map { it.operation })
        }
    }

    @Test fun seekDuringQueuedFreshRecoveryUsesOnlyExplicitRecoveryAndAcknowledgedSeek() {
        Fixture().use { f ->
            val same = failedOrdinaryOutput(f)
            TransportGate().use { owner ->
                Handler(f.ownerLooper).post(owner::hold)
                assertTrue(owner.entered.await(8, TimeUnit.SECONDS))
                f.player.play()
                f.main.idle() // deferred Play queued op 9 on the held owner
                assertEquals(f.revision, f.recoveryRevision)
                assertEquals(listOf(9, 7, 2), f.hw.transport.map { it.operation })
                f.player.seekTo(900)
                f.main.idle()
                assertTrue(f.recoveryRevision != f.revision)
                assertEquals(900L, f.playerField("desiredSeek"))
                assertTrue(f.hw.played.isEmpty())
            }
            assertRetainedSeek(f, 900)
            println("Seek behind queued recovery: ${f.hw.transport}")
            assertEquals(listOf(9, 7, 2, 9, 3, 1), f.hw.transport.map { it.operation })
            assertEquals(same, f.hw.identity(0))
        }
    }

    private fun assertRetainedSeek(f: Fixture, target: Long) {
        f.drain("native Seek was acknowledged before resumed Play") {
            f.player.currentPosition == target && f.playerField("desiredSeek") == null && f.player.isPlaying
        }
        f.settled()
        assertEquals(1, f.hw.acceptedLoads.size)
        val active = checkNotNull(f.hw.readyAssignment)
        val seek = f.hw.transport.single { it.operation == 3 }
        val play = f.hw.transport.last { it.operation == 1 }
        assertEquals(target, play.position)
        assertFalse(play.playingBefore)
        assertTrue(listOf(seek, play).all { it.deck == active.deck && it.generation == active.generation && it.identity == active.identity })
    }

    private fun playingOrdinary(f: Fixture): ProjectionPreviewHardware.Transport {
        f.prepareOrdinary()
        f.drain("ordinary source ready paused") { f.player.preparationSettled && f.player.playbackState == Player.STATE_READY }
        f.controller.play()
        f.drain("published ordinary Play") { f.player.isPlaying && f.controller.isPlaying }
        f.settled()
        return f.hw.transport.last { it.operation == 1 }.also {
            assertEquals(1, f.hw.played.size)
            assertEquals(1, f.hw.acceptedLoads.size)
            assertNotEquals(0L, it.identity)
        }
    }

    @Test fun loadedPrepareRecoversBeforePollAndReplaysSameClaim() {
        Fixture().use { f ->
            val prior = playingOrdinary(f)
            val revision = f.revision
            val traversal = f.playerField("seekRevision")
            val failedSamples = f.hw.failedSamples
            val start = f.hw.transport.size
            f.hw.faultBeforeRecovery = true
            // Public SimpleBasePlayer.prepare on the service-owned Player, before
            // advancing the native poll clock. The fault becomes sticky at op9 entry.
            f.player.prepare()
            f.drain("public loaded Prepare entered op9", advanceOwner = false) { f.hw.routeResets == 1 }
            assertEquals(failedSamples, f.hw.failedSamples)
            assertNull(f.player.playerError)
            assertTrue(f.player.playWhenReady)
            assertEquals(revision, f.revision)
            assertEquals(traversal, f.playerField("seekRevision"))
            f.settled()
            val commands = f.hw.transport.drop(start)
            println("loaded Prepare revision=$revision traversal=$traversal: $commands")
            assertEquals(listOf(9, 1), commands.map { it.operation })
            assertTrue(commands.first().playingBefore)
            assertFalse(commands.last().playingBefore)
            assertTrue(commands.all { it.identity == prior.identity && it.generation == prior.generation && it.deck == prior.deck })
            assertTrue(f.hw.isPlaying(0))
            assertTrue(f.player.isPlaying)
            assertEquals(1, f.hw.acceptedLoads.size)
        }
    }

    @Test fun healthyLoadedPrepareDoesNotReplayOrdinaryPlay() {
        Fixture().use { f ->
            val prior = playingOrdinary(f)
            val revision = f.revision
            val traversal = f.playerField("seekRevision")
            val start = f.hw.transport.size
            // Verify the session path too: MediaController forwards Prepare even in READY.
            repeat(2) { f.controller.prepare(); f.settled() }
            val commands = f.hw.transport.drop(start)
            println("healthy loaded Prepare revision=$revision traversal=$traversal: $commands")
            assertEquals(listOf(9, 9), commands.map { it.operation })
            assertTrue(commands.all { it.identity == prior.identity && it.playingBefore && it.outputError == 0 })
            assertEquals(0, f.hw.routeResets)
            assertEquals(revision, f.revision)
            assertEquals(traversal, f.playerField("seekRevision"))
            assertTrue(f.hw.isPlaying(0))
            assertEquals(1, f.hw.acceptedLoads.size)
        }
    }

    @Test fun pauseDuringLoadedPrepareRecoveryPreventsReplayAndAllowsFreshPlay() {
        Fixture().use { f ->
            val prior = playingOrdinary(f)
            val revision = f.revision
            val traversal = f.playerField("seekRevision")
            val start = f.hw.transport.size
            f.hw.faultBeforeRecovery = true
            TransportGate().use { recovery ->
                f.hw.beforeRecovery = recovery::hold
                f.controller.prepare()
                f.drain("loaded Prepare entered recovery", advanceOwner = false) { recovery.entered.count == 0L }
                assertNull(f.player.playerError)
                assertEquals(revision, f.revision)
                assertTrue(f.player.playWhenReady)
                f.controller.pause()
                f.drain("Pause reached the service while recovery held", advanceOwner = false) { !f.player.playWhenReady }
                assertEquals(revision + 1, f.revision)
            }
            f.settled()
            assertEquals(1, f.hw.routeResets)
            assertNull(f.player.playerError)
            assertFalse(f.hw.isPlaying(0))
            assertFalse(f.player.playWhenReady)
            assertEquals(Player.STATE_READY, f.player.playbackState)
            assertEquals(listOf(9, 2), f.hw.transport.drop(start).map { it.operation })
            f.controller.play()
            f.drain("fresh explicit Play after loaded Prepare and Pause") { f.player.isPlaying }
            f.settled()
            val commands = f.hw.transport.drop(start)
            println("Pause during loaded Prepare revision=$revision traversal=$traversal: $commands")
            assertEquals(listOf(9, 2, 9, 1), commands.map { it.operation })
            assertTrue(commands.all { it.identity == prior.identity && it.generation == prior.generation && it.deck == prior.deck })
            assertEquals(traversal, f.playerField("seekRevision"))
            assertEquals(1, f.hw.acceptedLoads.size)
        }
    }

    @Test fun resetDoesNotDependOnMissingStateReceipt() = prepareWithUnreadableReceipt(null)

    @Test fun resetDoesNotDependOnInvalidStateReceipt() = prepareWithUnreadableReceipt("invalid")

    private fun prepareWithUnreadableReceipt(receipt: String?) {
        Fixture().use { f ->
            val prior = playingOrdinary(f)
            val start = f.hw.transport.size
            val revision = f.revision
            val failedSamples = f.hw.failedSamples
            val degradedState = if (receipt == null) """{"error":-10001,"decks":[]}"""
                else """{"outputRecoveryReceipt":"$receipt"}"""
            f.hw.nextPostResetState = degradedState
            f.hw.faultBeforeRecovery = true
            val beforeRecovery = f.hw.recoveryOutcomes.size
            val owner = Handler(f.ownerLooper)
            TransportGate().use { held ->
                assertTrue(owner.post(held::hold))
                assertTrue(held.entered.await(8, TimeUnit.SECONDS))
                f.player.prepare()
                f.main.idle()
            }
            awaitOwnerMarker(f)
            assertEquals(listOf(NativeOutputRecovery.Reset), f.hw.recoveryOutcomes.drop(beforeRecovery))
            assertEquals(1, f.hw.routeResets)
            assertEquals("Reset must arm degraded state without reading it before polling resumes",
                degradedState, f.hw.takeUnreadPostResetState())
            assertFalse(f.hw.isPlaying(prior.deck))
            assertEquals(failedSamples, f.hw.failedSamples)
            f.settled()
            assertEquals(listOf(9, 1), f.hw.transport.drop(start).map { it.operation })
            assertEquals(revision, f.revision)
            assertEquals(prior.identity, f.hw.identity(prior.deck))
            assertEquals(1, f.hw.acceptedLoads.size)
            assertTrue(f.player.isPlaying)
            assertNull(f.player.playerError)
        }
    }

    @Test fun failedPreviewAfterReopenLeavesOrdinaryPlayEligible() {
        Fixture().use { f ->
            val prior = playingOrdinary(f)
            val start = f.hw.transport.size
            val revision = f.revision
            val traversal = f.hw.traversal(prior.deck)
            val loads = f.hw.acceptedLoads.toList()
            val ordinary = f.player.currentMediaItem
            val failedSamples = f.hw.failedSamples
            val input = DiscoveryPreviewInput({ error("preview fixture does not open a network call") }, { false }, { true })
            f.hw.faultBeforeRecovery = true
            f.hw.failPreviewReadiness = true
            val preparation = f.jobs.async(start = CoroutineStart.UNDISPATCHED) {
                runCatching {
                    f.player.prepareDiscoveryPreview(MediaItem.fromUri("https://fixture.invalid/preview"), input, f.scope) { true }
                }
            }
            f.drain("preview decode failure and spare retirement", advanceOwner = false) { preparation.isCompleted }
            assertTrue(runBlocking { preparation.await() }.exceptionOrNull() is SafeFailure)
            assertEquals(failedSamples, f.hw.failedSamples)
            assertTrue(input.canceled)
            assertEquals(1, f.hw.routeResets)
            assertEquals(0L, f.hw.identity(f.hw.previewLoads.single().deck))
            assertFalse(f.hw.isPlaying(prior.deck))
            assertEquals(ordinary, f.player.currentMediaItem)
            assertNull(f.player.parkedQueue)
            assertTrue(f.loaded)
            assertTrue(f.player.playWhenReady)
            assertEquals(revision, f.revision)
            assertNull(f.player.playerError)
            f.player.prepare()
            f.settled()
            val commands = f.hw.transport.drop(start)
            assertEquals(listOf(9, 9, 1), commands.map { it.operation })
            assertTrue(commands.all { it.identity == prior.identity && it.generation == prior.generation })
            assertEquals(loads, f.hw.acceptedLoads.toList())
            assertEquals(traversal, f.hw.traversal(prior.deck))
            assertEquals(revision, f.revision)
            assertTrue(f.player.isPlaying)
            assertTrue(f.app.previewRequests.isEmpty())
        }
    }

    @Test fun settledResetSurvivesNewerPlaySkippedByPause() = resetBeforeNewerPlayAndPause(cancelEntered = false)

    @Test fun settledResetSurvivesCancellationAfterNativeEntry() = resetBeforeNewerPlayAndPause(cancelEntered = true)

    private fun resetBeforeNewerPlayAndPause(cancelEntered: Boolean) {
        Fixture().use { f ->
            val identity = failedOrdinaryOutput(f, singlePoll = true)
            val oldError = checkNotNull(f.player.playerError)
            val occurrence = f.player.currentMediaItem
            val nativeTraversal = f.hw.traversal(0)
            val traversal = f.playerField("seekRevision")
            val loads = f.hw.acceptedLoads.toList()
            val start = f.hw.transport.size
            val attempts = f.hw.recoveryOutcomes.size
            val failedSamples = f.hw.failedSamples
            val samples = f.hw.polls
            val revision = f.revision
            val owner = Handler(f.ownerLooper)
            val main = Handler.createAsync(Looper.getMainLooper())
            val ownerReturned = CountDownLatch(1)
            var mainSettledA = false
            lateinit var prepare: Job
            TransportGate().use { held ->
                assertTrue(owner.post(held::hold))
                assertTrue(held.entered.await(8, TimeUnit.SECONDS))
                prepare = admitLoadedPrepare(f)
                f.main.idle()
                assertTrue(owner.post {
                    main.post { mainSettledA = true }
                    ownerReturned.countDown()
                })
            }
            assertTrue(ownerReturned.await(8, TimeUnit.SECONDS))
            assertFalse(mainSettledA)
            assertEquals(listOf(NativeOutputRecovery.Reset), f.hw.recoveryOutcomes.drop(attempts))
            assertSame(oldError, f.player.playerError)
            if (cancelEntered) prepare.cancel()
            // Admit B and supersede it inline, without letting B's yield or A's result run.
            f.player.play()
            assertTrue(f.player.playWhenReady)
            assertEquals(revision + 1, f.revision)
            f.player.pause()
            assertFalse(f.player.playWhenReady)
            assertEquals(revision + 2, f.revision)
            assertFalse(mainSettledA)
            // The owner's marker already posted behind A's result. Drain due work
            // on Main and then the owner without ticking either queue's clock.
            crossOwner(f)
            assertTrue(mainSettledA)
            assertEquals(listOf(NativeOutputRecovery.Reset), f.hw.recoveryOutcomes.drop(attempts))
            assertEquals(failedSamples, f.hw.failedSamples)
            assertEquals(samples, f.hw.polls)
            assertNull("Reset must clear the latched error before another observation", f.playerField("error"))
            assertTrue(f.hw.transport.drop(start).none { it.operation == 1 || it.operation == 8 })
            assertFalse(f.hw.isPlaying(0))
            f.settled()
            println("Reset before skipped Play/Pause (entered cancellation=$cancelEntered): ${f.hw.transport.drop(start)}, state=${f.player.playbackState}, error=${f.player.playerError?.message}")
            assertNull(f.player.playerError)
            assertEquals(Player.STATE_READY, f.player.playbackState)
            assertFalse(f.player.playWhenReady)
            assertFalse(f.player.isPlaying)
            assertEquals(revision + 2, f.revision)
            assertEquals(occurrence, f.player.currentMediaItem)
            assertEquals(traversal, f.playerField("seekRevision"))
            assertEquals(nativeTraversal, f.hw.traversal(0))
            assertEquals(loads, f.hw.acceptedLoads.toList())
            assertTrue(f.hw.transport.drop(start).all { it.identity == identity && it.generation == identity })
            f.player.play()
            f.drain("fresh Play after paused recovery") { f.player.isPlaying }
            f.settled()
            assertEquals(listOf(NativeOutputRecovery.Reset, NativeOutputRecovery.Healthy), f.hw.recoveryOutcomes.drop(attempts))
            assertEquals(identity, f.hw.identity(0))
            assertEquals(loads, f.hw.acceptedLoads.toList())
            assertEquals(listOf(0), f.hw.played.toList())
        }
    }

    @Test fun previewResetSupersedesEarlierPrepareFailureWithoutPlaying() = previewAndLoadedPrepareCross(previewFirst = false)

    @Test fun previewResetCannotMaskLaterPrepareFailure() = previewAndLoadedPrepareCross(previewFirst = true)

    private fun previewAndLoadedPrepareCross(previewFirst: Boolean) {
        Fixture().use { f ->
            val prior = playingOrdinary(f)
            val occurrence = f.player.currentMediaItem
            val loads = f.hw.acceptedLoads.toList()
            val revision = f.revision
            val traversal = f.hw.traversal(prior.deck)
            val start = f.hw.transport.size
            val attempts = f.hw.recoveryOutcomes.size
            val failedSamples = f.hw.failedSamples
            val failedPolls = f.hw.failedPolls
            val owner = Handler(f.ownerLooper)
            val main = Handler.createAsync(Looper.getMainLooper())
            val ownerReturned = CountDownLatch(1)
            data class Settlement(val request: Int, val failedPolls: Int, val error: String?, val intent: Boolean)
            val settlements = mutableListOf<Settlement>()
            val input = DiscoveryPreviewInput({ error("preview fixture does not open a network call") }, { false }, { true })
            f.hw.reopenResults.addAll(listOf(previewFirst, !previewFirst))
            f.hw.faultBeforeRecovery = true
            f.hw.failPreviewReadiness = true
            lateinit var preview: Deferred<Result<Boolean>>
            TransportGate().use { held ->
                assertTrue(owner.post(held::hold))
                assertTrue(held.entered.await(8, TimeUnit.SECONDS))
                repeat(2) { request ->
                    if ((request == 0) == previewFirst) preview = f.jobs.async(start = CoroutineStart.UNDISPATCHED) {
                        runCatching { f.player.prepareDiscoveryPreview(MediaItem.fromUri("https://fixture.invalid/preview"), input, f.scope) { true } }
                    } else {
                        f.player.prepare()
                        f.main.idle()
                    }
                    assertTrue(owner.post {
                        main.post { settlements += Settlement(request, f.hw.failedPolls, f.player.playerError?.message, f.player.playWhenReady) }
                        if (request == 1) ownerReturned.countDown()
                    })
                }
            }
            assertTrue(ownerReturned.await(8, TimeUnit.SECONDS))
            assertTrue(settlements.isEmpty())
            assertTrue(f.hw.previewLoads.isEmpty())
            assertEquals(listOf(previewFirst, !previewFirst), f.hw.reopenAttempts.toList())
            assertEquals(listOf(NativeOutputRecovery.Failed, NativeOutputRecovery.Reset).let {
                if (previewFirst) it.reversed() else it
            }, f.hw.recoveryOutcomes.drop(attempts))
            assertEquals(failedSamples, f.hw.failedSamples)
            assertNull(f.player.playerError)
            assertTrue(f.player.playWhenReady)
            f.drain("Main crossed both recovery continuations", advanceOwner = false) { settlements.size == 2 }
            assertEquals(listOf(0, 1), settlements.map { it.request })
            val settled = settlements.last()
            assertEquals(failedPolls, settled.failedPolls)
            println("Both Main results (previewFirst=$previewFirst), before any failed poll: $settlements")
            f.drain("preview failure and spare drain", advanceOwner = false) { preview.isCompleted }
            assertTrue(runBlocking { preview.await() }.exceptionOrNull() is SafeFailure)
            assertTrue(input.canceled)
            assertEquals(0L, f.hw.identity(f.hw.previewLoads.single().deck))
            assertEquals(1, f.hw.routeResets)
            if (!previewFirst) assertEquals(failedSamples, f.hw.failedSamples)
            assertEquals(listOf(9, 9), f.hw.transport.drop(start).map { it.operation })
            assertEquals(occurrence, f.player.currentMediaItem)
            assertEquals(prior.identity, f.hw.identity(prior.deck))
            assertEquals(traversal, f.hw.traversal(prior.deck))
            assertEquals(loads, f.hw.acceptedLoads.toList())
            assertNull(f.player.parkedQueue)
            assertTrue(f.loaded)
            assertFalse(f.hw.isPlaying(prior.deck))
            assertTrue(f.app.previewRequests.isEmpty())
            println("Prepare/Preview (previewFirst=$previewFirst): ${f.hw.transport.drop(start)}, revision=${f.revision}, intent=${f.player.playWhenReady}, error=${f.player.playerError?.message}")
            if (previewFirst) {
                assertTrue(settled.error?.startsWith("Audio output is unavailable") == true)
                assertFalse(settled.intent)
                assertEquals(revision + 1, f.revision)
                assertFalse(f.player.playWhenReady)
                assertTrue(f.player.playerError?.message?.startsWith("Audio output is unavailable") == true)
            } else {
                assertEquals(revision, f.revision)
                assertTrue(settled.intent)
                assertNull(settled.error)
                assertTrue(f.player.playWhenReady)
                assertNull(f.player.playerError)
                f.player.prepare()
                f.drain("later explicit Prepare resumes the retained deck") { f.player.isPlaying }
                f.settled()
                assertEquals(listOf(9, 9, 9, 1), f.hw.transport.drop(start).map { it.operation })
                assertEquals(loads, f.hw.acceptedLoads.toList())
            }
        }
    }

    @Test fun overlappingPrepareFailureThenSuccessPreservesIntent() = overlappingReopens(listOf(false, true))
    @Test fun overlappingPrepareFailuresPublishLastFailure() = overlappingReopens(listOf(false, false))
    @Test fun overlappingPrepareSuccessCannotMaskLaterFailure() = overlappingReopens(listOf(true, false))
    @Test fun canceledSiblingCannotSwallowOnlyReopenFailure() = overlappingReopens(listOf(false), cancelSibling = true)

    private fun overlappingReopens(outcomes: List<Boolean>, cancelSibling: Boolean = false) {
        Fixture().use { f ->
            val prior = playingOrdinary(f)
            val start = f.hw.transport.size
            val revision = f.revision
            val failedSamples = f.hw.failedSamples
            val owner = Handler(f.ownerLooper)
            val main = Handler.createAsync(Looper.getMainLooper())
            val passed = CountDownLatch(1)
            val settled = mutableListOf<Int>()
            f.hw.reopenResults.addAll(outcomes)
            f.hw.faultBeforeRecovery = true
            TransportGate().use { hold ->
                assertTrue(owner.post(hold::hold))
                assertTrue(hold.entered.await(8, TimeUnit.SECONDS))
                repeat(2) { request ->
                    val admitted = admitLoadedPrepare(f)
                    f.main.idle()
                    assertEquals(revision, f.revision)
                    if (cancelSibling && request == 1) admitted.cancel()
                    assertTrue(owner.post {
                        main.post { settled += request }
                        if (request == 1) passed.countDown()
                    })
                }
            }
            assertTrue(passed.await(8, TimeUnit.SECONDS))
            assertTrue(settled.isEmpty())
            assertEquals(outcomes, f.hw.reopenAttempts.toList())
            assertEquals(List(outcomes.size) { 9 }, f.hw.transport.drop(start).map { it.operation })
            assertEquals(outcomes.count { it }, f.hw.routeResets)
            assertEquals(failedSamples, f.hw.failedSamples)
            assertTrue(f.player.playWhenReady)
            assertNull(f.player.playerError)
            f.drain("both Main markers ran", advanceOwner = false) { settled.size == 2 }
            assertEquals(listOf(0, 1), settled)
            // A sticky native fault must not let a later poll satisfy the failure oracle.
            if (outcomes.last()) {
                f.settled()
                assertEquals(List(outcomes.size) { 9 } + 1, f.hw.transport.drop(start).map { it.operation })
                assertTrue(f.player.playWhenReady)
                assertTrue(f.player.isPlaying)
                assertEquals(revision, f.revision)
                assertNull(f.player.playerError)
            } else {
                assertEquals(failedSamples, f.hw.failedSamples)
                assertEquals(List(outcomes.size) { 9 }, f.hw.transport.drop(start).map { it.operation })
                assertEquals(revision + 1, f.revision)
                assertFalse(f.player.playWhenReady)
                assertFalse(f.hw.isPlaying(prior.deck))
                assertTrue(f.player.playerError?.message?.startsWith("Audio output is unavailable") == true)
            }
            assertEquals(prior.identity, f.hw.identity(prior.deck))
            assertEquals(1, f.hw.acceptedLoads.size)
        }
    }

    private fun admitLoadedPrepare(f: Fixture): Job {
        fun pendingRecoveries(): Int = f.playerField("outputRecovery")?.let { batch ->
            batch.javaClass.getDeclaredField("pending").apply { isAccessible = true }.getInt(batch)
        } ?: 0
        val lifetime = f.playerField("lifetime") as CoroutineScope
        val jobs = lifetime.coroutineContext[Job]!!
        val pending = pendingRecoveries()
        val children = jobs.children.toSet()
        // Loaded Prepare admits recovery inline, then yields. Capture its job before
        // idling Main can deliver a queued poll and launch unrelated journal work.
        f.player.prepare()
        assertEquals("one loaded Prepare admitted", pending + 1, pendingRecoveries())
        return (jobs.children.toSet() - children).single()
    }

    @Test fun revokedLoadedPrepareIsRefusedBeforeNativeRecovery() {
        Fixture().use { f ->
            val prior = playingOrdinary(f)
            val start = f.hw.transport.size
            f.hw.faultBeforeRecovery = true
            val owner = Handler(f.ownerLooper)
            TransportGate().use { held ->
                assertTrue(owner.post(held::hold))
                assertTrue(held.entered.await(8, TimeUnit.SECONDS))
                f.player.prepare()
                f.main.idle() // request queued, owner has not checked the retained source yet
                f.player.clearMediaItems()
                assertEquals(0, f.player.mediaItemCount)
            }
            f.drain("revoked assignment drained") { f.hw.identity(prior.deck) == 0L }
            f.settled()
            assertTrue(f.hw.transport.drop(start).none { it.operation == 9 || it.operation == 1 })
            assertEquals(0, f.hw.routeResets)
            assertNull(f.player.playerError)
        }
    }

    private fun crossOwner(f: Fixture) {
        f.main.idle()
        awaitOwnerMarker(f)
    }

    private fun awaitOwnerMarker(f: Fixture) {
        val passed = CountDownLatch(1)
        assertTrue(Handler(f.ownerLooper).post { passed.countDown() })
        assertTrue(passed.await(8, TimeUnit.SECONDS))
    }

    @Test fun overlappingLoadedPreparesKeepLaterResetThroughMainSettlement() = overlappingPrepares(reset = 1)

    @Test fun overlappingLoadedPreparesKeepEarlierResetThroughMainSettlement() = overlappingPrepares(reset = 0)

    @Test fun overlappingHealthyLoadedPreparesDoNotReplayOrdinaryPlay() = overlappingPrepares(reset = null)

    @Test fun seekAfterOverlappingPrepareReceiptsFencesTheOldPlay() = overlappingPrepares(reset = 1, seek = true)

    @Test fun newerExplicitPlayOwnsTransportAfterOverlappingPrepareReceipts() = overlappingPrepares(reset = 1, newerPlay = true)

    private fun overlappingPrepares(reset: Int?, seek: Boolean = false, newerPlay: Boolean = false) {
        Fixture().use { f ->
            val prior = playingOrdinary(f)
            val revision = f.revision
            val traversal = f.playerField("seekRevision")
            val failedSamples = f.hw.failedSamples
            val start = f.hw.transport.size
            val acceptedLoads = f.hw.acceptedLoads.toList()
            val nativeTraversal = f.hw.traversal(prior.deck)
            assertNull(f.playerField("desiredSeek"))
            assertNull(f.playerField("successor"))
            val requests = f.hw.recoveryOutcomes.size
            if (reset == 0) f.hw.faultBeforeRecovery = true
            // A's actual healthy op9 arms the asynchronous fault for B's entry.
            if (reset == 1) f.hw.beforeRecovery = { f.hw.faultBeforeRecovery = true }
            val owner = Handler(f.ownerLooper)
            val main = Handler.createAsync(Looper.getMainLooper())
            val ownerPassedB = CountDownLatch(1)
            val settlements = mutableListOf<Int>()
            val recoveryRevisions = mutableListOf<Any?>()
            TransportGate().use { held ->
                assertTrue(owner.post(held::hold))
                assertTrue(held.entered.await(8, TimeUnit.SECONDS))
                repeat(2) { request ->
                    // The actual pinned service Player admits both commands while
                    // Main has not consumed either withContext completion.
                    f.player.prepare()
                    f.main.idle() // dispatch to the blocked serial native owner
                    assertEquals(revision, f.revision)
                    assertEquals(start, f.hw.transport.size)
                    assertTrue(owner.post {
                        // This owner marker follows the complete native call
                        // and the posting of its continuation back to Main.
                        main.post {
                            settlements += request
                            recoveryRevisions += f.recoveryRevision
                        }
                        if (request == 1) ownerPassedB.countDown()
                    })
                }
            }
            // Don't pump Main until both callbacks
            // are in its queue, in FIFO order around the two positive markers.
            assertTrue("native owner did not pass both recovery calls", ownerPassedB.await(8, TimeUnit.SECONDS))
            assertTrue(settlements.isEmpty())
            val outcomes = f.hw.recoveryOutcomes.drop(requests)
            assertEquals(List(2) { if (it == reset) NativeOutputRecovery.Reset else NativeOutputRecovery.Healthy }, outcomes)
            assertEquals(listOf(9, 9), f.hw.transport.drop(start).map { it.operation })
            assertEquals(listOf(0, 1).map { if (it == reset) -899 else 0 }, f.hw.transport.drop(start).map { it.outputError })
            assertEquals(if (reset == null) 0 else 1, f.hw.routeResets)
            assertEquals(reset == null, f.hw.isPlaying(prior.deck))
            assertEquals(failedSamples, f.hw.failedSamples)
            assertNull(f.player.playerError)
            assertTrue(f.player.playWhenReady)
            if (seek) {
                f.hw.holdSeek = true
                f.player.seekTo(900)
                assertEquals(revision + 1, f.revision)
                assertEquals(900L, f.playerField("desiredSeek"))
            } else if (newerPlay) {
                f.player.play()
                assertEquals(revision + 1, f.revision)
            }
            f.drain("Main crossed both completion markers", advanceOwner = false) { settlements.size == 2 }
            assertEquals(listOf(0, 1), settlements)
            if (seek) {
                f.drain("native observation while Seek ACK is held") { f.hw.heldSeekSamples.isNotEmpty() }
                crossOwner(f)
                f.main.idle()
                crossOwner(f)
                assertTrue(f.hw.heldSeekSamples.all { it == ProjectionPreviewHardware.SeekSample(prior.position, nativeTraversal) })
                assertEquals(900L, f.playerField("desiredSeek"))
                assertEquals(listOf(9, 9, 3), f.hw.transport.drop(start).map { it.operation })
                f.hw.acknowledgeHeldSeek()
                assertRetainedSeek(f, 900)
                assertEquals(nativeTraversal + 1, f.hw.traversal(prior.deck))
            } else f.settled()
            val commands = f.hw.transport.drop(start)
            println("overlapping Prepares reset=$reset seek=$seek newerPlay=$newerPlay r=$revision traversal=$traversal native=$nativeTraversal outcomes=$outcomes Main=$settlements recoveryRevisions=$recoveryRevisions commands=$commands nativePlaying=${f.hw.isPlaying(prior.deck)} intent=${f.player.playWhenReady} error=${f.player.playerError}")
            assertEquals(when {
                seek -> listOf(9, 9, 3, 1)
                newerPlay -> listOf(9, 9, 9, 1)
                reset != null -> listOf(9, 9, 1)
                else -> listOf(9, 9)
            }, commands.map { it.operation })
            if (reset != null) assertFalse(commands.last().playingBefore)
            assertTrue(commands.all { it.deck == prior.deck && it.identity == prior.identity && it.generation == prior.generation })
            if (!seek) {
                assertEquals(revision + if (newerPlay) 1 else 0, f.revision)
                assertEquals(traversal, f.playerField("seekRevision"))
                assertEquals(nativeTraversal, f.hw.traversal(prior.deck))
            }
            assertEquals(acceptedLoads, f.hw.acceptedLoads.toList())
            assertTrue(f.hw.isPlaying(prior.deck))
            assertTrue(f.player.isPlaying)
            assertNull(f.player.playerError)
        }
    }

    private fun failedOrdinaryOutput(f: Fixture, singlePoll: Boolean = false): Long {
        f.prepareOrdinary()
        f.drain("ordinary source ready paused") { f.player.preparationSettled && f.player.playbackState == Player.STATE_READY }
        f.settled()
        val same = f.hw.identity(0)
        assertNotEquals(0L, same)
        fun failurePublished() = f.player.playerError?.message?.startsWith("Audio output is unavailable") == true
        if (singlePoll) {
            // Drain any poll made due by setup while the route is still healthy.
            // Both loopers share the clock: idling Main *for* time after the first
            // failed poll can make its successor due before the recovery hold.
            awaitOwnerMarker(f)
            val failedSamples = f.hw.failedSamples
            val failedPolls = f.hw.failedPolls
            f.hw.breakOutput()
            Shadows.shadowOf(f.ownerLooper).runToNextTask()
            awaitOwnerMarker(f)
            f.main.idle()
            assertEquals(failedSamples + 1, f.hw.failedSamples)
            assertEquals(failedPolls + 1, f.hw.failedPolls)
            assertTrue("first route failure was not published", failurePublished())
        } else {
            f.hw.breakOutput()
            f.drain("route failure published", predicate = ::failurePublished)
        }
        assertFalse(f.player.playWhenReady)
        return same
    }

    @Test fun pauseDuringSuccessfulRecoveryRestoresSameAssignmentPausedThenFreshPlay() {
        Fixture().use { f ->
            val same = failedOrdinaryOutput(f)
            TransportGate().use { recovery ->
                f.hw.beforeRecovery = recovery::hold
                f.controller.play()
                f.drain("explicit native recovery entered", advanceOwner = false) { recovery.entered.count == 0L }
                f.controller.pause()
                f.drain("newer Pause reached the player", advanceOwner = false) { !f.player.playWhenReady }
            }
            f.drain("same source restored READY paused") { f.player.playerError == null && f.player.playbackState == Player.STATE_READY }
            f.settled()
            assertFalse(f.hw.isPlaying(0))
            assertTrue(f.hw.played.isEmpty())
            assertEquals(same, f.hw.identity(0))
            f.controller.play()
            f.drain("subsequent explicit Play reached the same decoder") { f.player.isPlaying }
            f.settled()
            assertEquals(listOf(9, 7, 2, 9, 9, 1), f.hw.transport.map { it.operation })
            assertEquals(same, f.hw.identity(0))
            assertEquals(1, f.hw.acceptedLoads.size)
        }
    }

    @Test fun focusDenialAndSeekOrHealthyPollCannotRecoverFailedOutput() {
        Fixture().use { f ->
            val same = failedOrdinaryOutput(f)
            f.hw.publishHealthyOutput()
            f.player.seekTo(900)
            f.settled()
            assertNotNull(f.player.playerError)
            assertEquals(listOf(9, 7, 2, 3), f.hw.transport.map { it.operation })
            val audio = Shadows.shadowOf(f.app.getSystemService(AudioManager::class.java))
            audio.setNextFocusRequestResponse(AudioManager.AUDIOFOCUS_REQUEST_FAILED)
            val revision = f.revision
            f.player.play()
            assertTrue(f.revision >= revision + 2) // the real service's focus listener supplied Pause
            assertFalse(f.player.playWhenReady)
            f.settled()
            assertNotNull(audio.lastAudioFocusRequest)
            assertNotNull(f.player.playerError)
            assertEquals(listOf(9, 7, 2, 3), f.hw.transport.map { it.operation })
            assertEquals(same, f.hw.identity(0))
        }
    }

    @Test fun enteredLoadedPrepareCannotReplayRetiredSource() = retireDuringLoadedPrepare(replaceAccount = false)

    @Test fun enteredLoadedPrepareCannotReplayRetiredAccount() = retireDuringLoadedPrepare(replaceAccount = true)

    private fun retireDuringLoadedPrepare(replaceAccount: Boolean) {
        Fixture().use { f ->
            val prior = playingOrdinary(f)
            val oldOccurrence = f.player.currentMediaItem!!.mediaId
            val start = f.hw.transport.size
            val revision = f.revision
            TransportGate().use { recovery ->
                f.hw.faultBeforeRecovery = true
                f.hw.beforeRecovery = recovery::hold
                f.player.prepare()
                f.drain("loaded Prepare entered sticky recovery", advanceOwner = false) { recovery.entered.count == 0L }
                assertEquals(revision, f.revision)
                if (replaceAccount) {
                    assertTrue(f.graph.session.accept(f.graph.session.beginIntent(), SecretTokens("c", "r-c", "other")))
                    f.drain("account observer retired the choice", advanceOwner = false) { f.player.mediaItemCount == 0 }
                } else {
                    f.player.clearMediaItems()
                    assertEquals(0, f.player.mediaItemCount)
                }
                assertFalse(f.loaded)
                assertNotEquals(oldOccurrence, f.player.currentMediaItem?.mediaId)
            }
            f.drain("old decoder retired") { f.hw.identity(prior.deck) == 0L }
            f.settled()
            val trace = f.hw.transport.drop(start)
            println("retirement account=$replaceAccount: $trace")
            assertEquals(1, f.hw.routeResets)
            assertEquals(listOf(9, 8), trace.filter { it.operation != 2 }.map { it.operation })
            assertTrue(trace.all { it.deck == prior.deck && it.identity == prior.identity && it.generation == prior.generation })
            assertEquals(1, f.hw.acceptedLoads.size)
            assertEquals(1, f.hw.played.size)
            assertNull(f.player.playerError)
        }
    }

    @Test fun naturalRepeatCanPlaySameAssignmentWithoutNewTransportRevision() {
        Fixture().use { f ->
            f.prepareOrdinary()
            f.settled()
            f.player.repeatMode = Player.REPEAT_MODE_ONE
            f.player.play()
            f.drain("first ordinary Play") { f.hw.played.size == 1 && f.player.isPlaying }
            val same = f.hw.identity(0)
            val revision = f.revision
            f.hw.cursor(0, 6000)
            f.hw.eof(0)
            f.drain("natural repeat Seek and fresh Play") { f.hw.played.size >= 2 && f.player.isPlaying }
            f.settled()
            assertEquals(revision, f.revision)
            assertEquals(same, f.hw.identity(0))
            assertEquals(listOf(9, 7, 2, 9, 1, 3, 1), f.hw.transport.map { it.operation })
            assertEquals(1, f.hw.acceptedLoads.size)
            println("same-revision repeat $revision: ${f.hw.transport}")
        }
    }

    @Test fun failedSaveDoesNotReopenAfter401() = refuseReopen("failed save")
    @Test fun localLockDoesNotReopenAfter401() = refuseReopen("lock")
    @Test fun signOutDoesNotReopenAfter401() = refuseReopen("sign-out")
    @Test fun differentAccountLockDoesNotReopenAfter401() = refuseReopen("different account lock")
    @Test fun routeRevocationDoesNotReopenAfter401() = refuseReopen("route")
    @Test fun localPauseIntentDoesNotReopenAfter401() = refuseReopen("pause")

    private fun refuseReopen(retirement: String) {
        Fixture().use { f ->
            f.ordinary()
            f.app.rotate = true
            val live = java.util.concurrent.atomic.AtomicBoolean(true)
            val a = f.preview("A", live::get)
            f.drain("entered secure save") { f.app.saveEntered.count == 0L }
            when (retirement) {
                "failed save" -> f.app.failSave = true
                "lock" -> {
                    assertTrue(f.graph.session.lockLocal())
                    assertEquals(AuthState.LocalLocked, f.graph.session.state.value)
                    assertNull(f.graph.session.capture())
                    assertFalse(f.graph.session.rotationCurrent(f.scope)) // adopted rotation already withdrew tokens
                    assertFalse(f.graph.session.previewOwnerCurrent(f.scope))
                }
                "sign-out" -> f.graph.session.revoke()
                "different account lock" -> {
                    val session = f.graph.session
                    val replacement = session.beginIntent()
                    // Complete the replacement after the previous secure-store holder exits.
                    val accept = f.jobs.async(Dispatchers.IO) { session.accept(replacement, SecretTokens("c", "r-c", "different")) }
                    f.app.saveRelease.countDown()
                    f.drain("replacement accepted") { accept.isCompleted }
                    assertTrue(f.await(accept))
                    assertEquals("different", session.capture()?.accountId)
                    assertTrue(session.lockLocal())
                    assertEquals(AuthState.LocalLocked, session.state.value)
                    assertFalse(session.previewOwnerCurrent(f.scope))
                }
                "route" -> live.set(false)
                "pause" -> f.projection.pause()
            }
            f.app.saveRelease.countDown()
            assertFalse(retirement, f.await(a))
            assertEquals(retirement, listOf(f.app.expectedPreview("A", "a")), f.app.previewRequests.toList())
            assertEquals(listOf(0), f.hw.played.toList())
        }
    }
}

// Held only for the two collector regressions. The service and the player's native
// observation/lifetime run on their usual dispatchers; jobs is only the account collector.
internal class HeldAccountCollector : CoroutineDispatcher() {
    @Volatile private var initial: ArrayDeque<Runnable>? = ArrayDeque()
    override fun dispatch(context: CoroutineContext, block: Runnable) {
        val queue = initial
        if (queue != null) {
            check(Looper.myLooper() == Looper.getMainLooper())
            queue.addLast(block)
        } else Dispatchers.Main.dispatch(context, block)
    }
    fun release(): Int {
        val queue = initial ?: return 0
        check(Looper.myLooper() == Looper.getMainLooper())
        var continuations = 0
        while (queue.isNotEmpty()) {
            check(++continuations <= 32)
            queue.removeFirst().run()
        }
        initial = null
        return continuations
    }
}

private fun previewUrl(name: String) = "https://www.youtube.com/watch?v=SQPreview0$name"
internal data class PreviewRequest(val target: String, val method: String?, val body: String, val bearer: String?)

class PreviewHandoffApplication : SoundQApplication() {
    internal val fixture = HttpsFixture()
    internal val hardware = ProjectionPreviewHardware()
    internal val saveEntered = CountDownLatch(1)
    internal val saveRelease = CountDownLatch(1)
    internal var accountCollector: HeldAccountCollector? = null
    internal val previewRequests = CopyOnWriteArrayList<PreviewRequest>()
    internal val wirePaths = CopyOnWriteArrayList<String>()
    internal fun expectedPreview(name: String, generation: String) = PreviewRequest(
        fixture.server.url("/api/v1/discovery/preview").toString(), "POST", """{"url":"${previewUrl(name)}"}""", "Bearer $generation",
    )
    @Volatile internal var rotate = false
    @Volatile internal var failSave = false
    override fun onCreate() {
        graph = AppGraph(this, fixture.endpoint, fixture.client, store = object : SessionStore {
            override fun load(endpoint: ApiEndpoint): SecretTokens? = null
            override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) {
                if (tokens.access == "b") {
                    saveEntered.countDown(); check(saveRelease.await(8, TimeUnit.SECONDS)); check(!failSave)
                }
            }
            override fun clear() {}
        })
        check(graph.session.accept(graph.session.beginIntent(), SecretTokens("a", "r-a", "fixture")))
        fixture.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                wirePaths += request.url.encodedPath
                return when (request.url.encodedPath) {
                    "/api/v1/auth/refresh" -> MockResponse.Builder().body(fixture.auth(access = "b")).build()
                    "/api/v1/discovery/preview" -> {
                        check(request.method == "POST" && request.headers["Accept"] == "audio/mpeg")
                        val body = checkNotNull(request.body).utf8()
                        val bearer = request.headers["Authorization"]
                        previewRequests += PreviewRequest(request.url.toString(), request.method, body, bearer)
                        check(JSONObject(body).getString("url") in listOf("A", "B", "C").map(::previewUrl))
                        if (rotate && bearer == "Bearer a") MockResponse.Builder().code(401).build()
                        else MockResponse.Builder().addHeader("Content-Type", "audio/mpeg").addHeader("X-SoundQ-Preview-Sample-Rate", 44100)
                            .addHeader("X-SoundQ-Preview-Frames", 1000).body("fixture").build()
                    }
                    else -> MockResponse.Builder().code(404).build()
                }
            }
        }
    }
    override fun createCallbackLibraryPlayer(grants: ConcurrentHashMap<String, MediaGrant>, jobs: CoroutineScope): Player =
        NativeCallbackPlayer(graph, grants, accountCollector?.let { CoroutineScope(jobs.coroutineContext + it) } ?: jobs, hardware, NativeCallbackSource { item, current ->
            check(current()); File.createTempFile("preview-ordinary", ".encoded", graph.directory.apply { mkdirs() }).apply { writeText(item.mediaId) }
        })
}

internal class ProjectionPreviewHardware : NativeCallbackCalls {
    data class OrdinaryLoad(val occurrence: String, val cursor: Long)
    data class PreviewLoad(val deck: Int, val generation: Long, val input: DiscoveryPreviewInput)
    val previewLoads = CopyOnWriteArrayList<PreviewLoad>()
    private data class Deck(val id: Long = 0, var position: Long = 0, var playing: Boolean = false,
                            var eof: Long = 0, var paused: Boolean = false, var traversal: Long = 1)
    private val decks = Array(4) { Deck() }
    private val io = Executors.newCachedThreadPool()
    val played = CopyOnWriteArrayList<Int>()
    val acceptedLoads = CopyOnWriteArrayList<OrdinaryLoad>()
    val ordinaryLoads get() = acceptedLoads.map { it.cursor }
    val previewOpened = ConcurrentHashMap.newKeySet<Int>()
    @Volatile var beforeOrdinaryGain: (() -> Unit)? = null
    @Volatile var holdPreview = false
    @Volatile var holdPause = false
    @Volatile var refusePause = false
    @Volatile var pauseRequests = 0
    @Volatile var polls = 0
    data class Transport(val operation: Int, val deck: Int, val identity: Long, val generation: Long,
                         val position: Long, val playingBefore: Boolean, val outputError: Int)
    val transport = CopyOnWriteArrayList<Transport>()
    @Volatile var readyAssignment: Transport? = null
        private set
    private var outputError = 0
    @Volatile var faultBeforeRecovery = false
    @Volatile var failedSamples = 0
        private set
    @Volatile var failedPolls = 0
        private set
    private var outputRecoveryReceipt = 0L
    @Volatile var nextPostResetState: String? = null
    private var unreadPostResetState: String? = null
    @Synchronized fun takeUnreadPostResetState(): String? =
        unreadPostResetState.also { unreadPostResetState = null }
    val reopenResults = ConcurrentLinkedQueue<Boolean>()
    val reopenAttempts = CopyOnWriteArrayList<Boolean>()
    @Volatile var failPreviewReadiness = false
    @Volatile var holdSeek = false
    private var heldSeek: Pair<Int, Long>? = null
    data class SeekSample(val position: Long, val traversal: Long)
    val heldSeekSamples = CopyOnWriteArrayList<SeekSample>()
    @Synchronized fun acknowledgeHeldSeek() {
        val (slot, target) = checkNotNull(heldSeek)
        decks[slot].position = target; decks[slot].traversal++
        heldSeek = null
    }

    @Volatile var routeResets = 0
        private set
    @Synchronized fun latchRouteFault() { outputError = -899 }
    @Volatile var holdOrdinaryReady = false
    @Volatile var trackBindReadiness = false
    @Volatile var bindReadinessSampled = false
        private set
    @Volatile var beforeRecovery: (() -> Unit)? = null
    @Synchronized fun publishHealthyOutput() { outputError = 0 }
    @Synchronized fun breakOutput() { outputError = 1; decks[0].playing = false }
    private var coherent = true
    private var generationOffset = 0L
    override fun open() = 1L
    @Synchronized override fun load(handle: Long, deck: Int, path: String, identity: Long, generation: Long, positionMs: Long): Boolean {
        acceptedLoads += OrdinaryLoad(File(path).readText(), positionMs); decks[deck] = Deck(identity, positionMs); return true
    }
    @Synchronized override fun loadPreview(handle: Long, deck: Int, input: DiscoveryPreviewInput, generation: Long): Boolean {
        previewLoads += PreviewLoad(deck, generation, input)
        decks[deck] = Deck(generation); previewOpened.remove(deck)
        if (failPreviewReadiness) return true
        io.submit {
            try {
                input.open(); check(input.readEncoded(ByteArray(16)) > 0)
                synchronized(this) { if (decks[deck].id == generation) previewOpened.add(deck) }
            } finally { input.close() }
        }
        return true
    }
    val recoveryOutcomes = CopyOnWriteArrayList<NativeOutputRecovery>()
    @Synchronized override fun recoverOutput(handle: Long): NativeOutputRecovery {
        control(handle, 9, 0, 0.0, 0L)
        return recoveryOutcomes.last()
    }
    @Synchronized override fun control(handle: Long, operation: Int, deck: Int, value: Double, eventNanos: Long): Boolean {
        if (operation == 7 && deck == 0) beforeOrdinaryGain?.let {
            beforeOrdinaryGain = null
            it()
        }
        if (operation == 9 && faultBeforeRecovery) {
            faultBeforeRecovery = false
            latchRouteFault()
        }
        val d = decks[deck]
        if (deck == 0 && (operation == 9 || d.id != 0L && operation in listOf(1, 2, 3, 7, 8))) {
            transport += Transport(operation, deck, d.id, d.id + generationOffset, d.position, d.playing, outputError)
        }
        if (outputError != 0 && operation in listOf(1, 2, 3)) return false
        when (operation) {
            9 -> {
                beforeRecovery?.let { beforeRecovery = null; it() }
                if (outputError != 0) {
                    // callback_host.cpp quiesces only a failed/recovering route;
                    // it pauses all rendered assignments without seeking them.
                    decks.forEach { it.playing = false; it.paused = false }
                    val reopened = reopenResults.poll()?.also { reopenAttempts += it } ?: true
                    if (!reopened) {
                        recoveryOutcomes += NativeOutputRecovery.Failed
                        return false
                    }
                    if (reopenResults.isNotEmpty()) faultBeforeRecovery = true
                    outputError = 0
                    outputRecoveryReceipt = eventNanos
                    // Only a real Reset arms the next read, even with the typed path's zero stamp.
                    unreadPostResetState = nextPostResetState
                    nextPostResetState = null
                    routeResets++
                    recoveryOutcomes += NativeOutputRecovery.Reset
                } else recoveryOutcomes += NativeOutputRecovery.Healthy
            }
            1 -> { d.playing = true; d.paused = false; played += deck }
            2, 11 -> {
                if (deck == 0 && d.id != 0L && d.playing) {
                    pauseRequests++
                    if (refusePause) return false
                    if (holdPause) return true
                }
                d.playing = false; d.paused = operation == 11
            }
            3 -> {
                if (holdSeek) { check(heldSeek == null); heldSeek = deck to value.toLong() }
                else { d.position = value.toLong(); d.traversal++ }
            }
            8 -> decks[deck] = Deck()
        }
        return true
    }
    @Synchronized fun cursor(deck: Int, position: Long) { decks[deck].position = position }
    @Synchronized fun eof(deck: Int) { decks[deck].playing = false; decks[deck].eof++ }
    @Synchronized fun applyHeldPause(position: Long) { decks[0].position = position; decks[0].playing = false; decks[0].paused = true }
    @Synchronized fun samplePause(position: Long, coherent: Boolean, generationOffset: Long) {
        applyHeldPause(position); this.coherent = coherent; this.generationOffset = generationOffset
    }
    @Synchronized fun identity(deck: Int) = decks[deck].id
    @Synchronized fun traversal(deck: Int) = decks[deck].traversal
    @Synchronized fun isPlaying(deck: Int) = decks[deck].playing
    @Synchronized fun empty() = decks.all { it.id == 0L }
    @Synchronized override fun state(handle: Long): String {
        polls++
        heldSeek?.let { (slot, _) -> heldSeekSamples += SeekSample(decks[slot].position, decks[slot].traversal) }
        // A test takes the unread value at its owner barrier before advancing polling.
        takeUnreadPostResetState()?.let { return it }
        if (outputError != 0) {
            failedSamples++
            if (Thread.currentThread().stackTrace.any { it.className.startsWith(NativeCallbackOwner::class.java.name + "\$poll\$") }) failedPolls++
        }
        return JSONObject().put("error", outputError).put("outputRecoveryReceipt", outputRecoveryReceipt).put("coherent", coherent).put("decks", JSONArray().apply {
            decks.forEachIndexed { slot, d ->
                val ready = d.id != 0L && (slot < 2 && !holdOrdinaryReady || slot in previewOpened && !holdPreview)
                if (slot == 0 && ready && readyAssignment == null) readyAssignment =
                    Transport(0, slot, d.id, d.id + generationOffset, d.position, d.playing, outputError)
                if (slot == 0 && ready && outputError == 0 && trackBindReadiness && !bindReadinessSampled) {
                    bindReadinessSampled = Thread.currentThread().stackTrace.any {
                        it.className.startsWith(NativeCallbackOwner::class.java.name + "\$snapshot\$")
                    }
                }
                put(JSONObject().put("traversalRevision", d.traversal).put("identity", d.id).put("generation", d.id + if (slot == 0) generationOffset else 0).put("positionMs", d.position)
                    .put("durationMs", 6000).put("sourceRate", 44100).put("sourceFrames", 264600)
                    .put("ready", ready).put("preparing", d.id != 0L && !ready).put("playing", d.playing)
                    .put("handoffPaused", d.paused).put("eofCount", d.eof).put("error", if (slot >= 2 && d.id != 0L && failPreviewReadiness) -1 else 0).put("openDecoders", if (d.id == 0L) 0 else 1))
            }
        }).toString()
    }
    override fun close(handle: Long) = true
    fun closeWorkers() { io.shutdownNow(); check(io.awaitTermination(8, TimeUnit.SECONDS)) }
}
