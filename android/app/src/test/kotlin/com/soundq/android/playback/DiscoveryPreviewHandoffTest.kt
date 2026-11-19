package com.soundq.android.playback

import android.os.HandlerThread
import android.os.Looper
import androidx.media3.common.*
import androidx.media3.session.MediaController
import androidx.media3.session.MediaSession
import com.soundq.android.*
import com.soundq.android.data.*
import com.soundq.android.data.imports.ImportSource
import com.soundq.android.playback.nativeengine.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
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
        fun drain(label: String, predicate: () -> Boolean) {
            val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(8)
            do {
                val owner = NativeCallbackPlayer::class.java.getDeclaredField("owner").apply { isAccessible = true }.get(player)
                val thread = owner.javaClass.getDeclaredField("thread").apply { isAccessible = true }.get(owner) as HandlerThread
                thread.looper?.let { Shadows.shadowOf(it).idleFor(Duration.ofMillis(25)) }
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
            f.drain("ordinary edit applied at the service and acknowledged by the controller/projection", ::agrees)
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
                            var eof: Long = 0, var paused: Boolean = false)
    private val decks = Array(4) { Deck() }
    private val io = Executors.newCachedThreadPool()
    val played = CopyOnWriteArrayList<Int>()
    val acceptedLoads = CopyOnWriteArrayList<OrdinaryLoad>()
    val ordinaryLoads get() = acceptedLoads.map { it.cursor }
    val previewOpened = ConcurrentHashMap.newKeySet<Int>()
    @Volatile var holdPreview = false
    @Volatile var holdPause = false
    @Volatile var refusePause = false
    @Volatile var pauseRequests = 0
    @Volatile var polls = 0
    private var coherent = true
    private var generationOffset = 0L
    override fun open() = 1L
    @Synchronized override fun load(handle: Long, deck: Int, path: String, identity: Long, generation: Long, positionMs: Long): Boolean {
        acceptedLoads += OrdinaryLoad(File(path).readText(), positionMs); decks[deck] = Deck(identity, positionMs); return true
    }
    @Synchronized override fun loadPreview(handle: Long, deck: Int, input: DiscoveryPreviewInput, generation: Long): Boolean {
        previewLoads += PreviewLoad(deck, generation, input)
        decks[deck] = Deck(generation); previewOpened.remove(deck)
        io.submit {
            try {
                input.open(); check(input.readEncoded(ByteArray(16)) > 0)
                synchronized(this) { if (decks[deck].id == generation) previewOpened.add(deck) }
            } finally { input.close() }
        }
        return true
    }
    @Synchronized override fun control(handle: Long, operation: Int, deck: Int, value: Double, eventNanos: Long): Boolean {
        val d = decks[deck]
        when (operation) {
            1 -> { d.playing = true; d.paused = false; played += deck }
            2, 11 -> {
                if (deck == 0 && d.id != 0L && d.playing) {
                    pauseRequests++
                    if (refusePause) return false
                    if (holdPause) return true
                }
                d.playing = false; d.paused = operation == 11
            }
            3 -> d.position = value.toLong()
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
    @Synchronized fun isPlaying(deck: Int) = decks[deck].playing
    @Synchronized fun empty() = decks.all { it.id == 0L }
    @Synchronized override fun state(handle: Long): String {
        polls++
        return JSONObject().put("error", 0).put("coherent", coherent).put("decks", JSONArray().apply {
            decks.forEachIndexed { slot, d ->
                val ready = d.id != 0L && (slot < 2 || slot in previewOpened && !holdPreview)
                put(JSONObject().put("identity", d.id).put("generation", d.id + if (slot == 0) generationOffset else 0).put("positionMs", d.position)
                    .put("durationMs", 6000).put("sourceRate", 44100).put("sourceFrames", 264600)
                    .put("ready", ready).put("preparing", d.id != 0L && !ready).put("playing", d.playing)
                    .put("handoffPaused", d.paused).put("eofCount", d.eof).put("error", 0).put("openDecoders", if (d.id == 0L) 0 else 1))
            }
        }).toString()
    }
    override fun close(handle: Long) = true
    fun closeWorkers() { io.shutdownNow(); check(io.awaitTermination(8, TimeUnit.SECONDS)) }
}
