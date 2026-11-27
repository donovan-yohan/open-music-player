package com.soundq.android.product

import android.content.ComponentName
import androidx.activity.ComponentActivity
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.viewModelScope
import com.soundq.android.AppGraph
import com.soundq.android.SoundQApplication
import com.soundq.android.data.AccountScope
import com.soundq.android.data.LibraryQuery
import com.soundq.android.data.MemoryStore
import com.soundq.android.data.ApiEndpoint
import com.soundq.android.data.SecretTokens
import com.soundq.android.data.SessionStore
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.data.originalimport.*
import com.soundq.android.data.originalimport.OriginalImportCompositionTest.Fixture
import com.soundq.android.playback.SoundQLibraryService
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit.SECONDS
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.cancel
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.RecordedRequest
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** The actual ProductApp Library route, with an empty loopback Library and a real import journal. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = OriginalImportRecoveryApplication::class, qualifiers = "w412dp-h915dp")
class OriginalImportRecoveryTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun emptyLibraryCheckCanRetryLocalRefusalWithoutAnyWireSend() = withLibrary { f ->
        val choice = f.reject()
        f.mount()
        checkButton().assertIsDisplayed().assertIsEnabled()
        assertEquals(1, f.forces.get()) // rendering did not try local recovery
        assertEquals(0, f.statusReads.get())
        val wireBeforeCheck = f.peer.server.requestCount
        checkButton().performClick()
        waitForText("Couldn’t save import status. No new attempt will start until this is resolved.")
        checkButton().assertIsDisplayed().assertIsEnabled()
        assertTrue(f.repository.state.value.rejected)
        assertEquals(2, f.forces.get())
        f.beforeRefusalForce = {}
        checkButton().performClick()
        compose.waitUntil(5_000) { f.repository.state.value.entry(choice.intent.operation)?.phase == OriginalImportPhase.Refused }
        checkButton().assertDoesNotExist()
        assertEquals(3, f.forces.get())
        assertEquals(OriginalImportRepository.Action.Retired, f.repository.confirm(choice))
        assertEquals(OriginalImportPhase.Refused, OriginalImportJournal(f.disk).apply { load() }.state.value.entry(choice.intent.operation)?.phase)
        assertEquals(wireBeforeCheck, f.peer.server.requestCount)
        f.assertNoRecoveryWire()
    }

    @Test fun leavingLibraryWhileLocalCheckIsHeldCannotPublishTheRefusal() = withLibrary { f ->
        f.reject()
        f.mount()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        f.beforeRefusalForce = { entered.countDown(); check(release.await(8, SECONDS)) }
        try {
            checkButton().assertIsDisplayed().performClick()
            assertTrue(entered.await(5, SECONDS))
            compose.onNodeWithContentDescription("Settings").assertIsDisplayed().performClick()
            checkButton().assertDoesNotExist()
            compose.onNodeWithContentDescription("Back").assertIsDisplayed().performClick()
            checkButton().assertIsNotEnabled()
        } finally { release.countDown() }
        compose.waitUntil(5_000) { f.repository.work.value.isEmpty() }
        assertTrue(f.repository.state.value.rejected)
        assertEquals(2, f.forces.get())
        checkButton().assertIsDisplayed().assertIsEnabled()
        f.assertNoRecoveryWire()
    }

    @Test fun replacingTheLoginWhileLocalCheckIsHeldCannotPublishOrOfferTheOldRefusal() = withLibrary { f ->
        f.reject()
        f.mount()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        f.beforeRefusalForce = { entered.countDown(); check(release.await(8, SECONDS)) }
        try {
            checkButton().assertIsDisplayed().performClick()
            assertTrue(entered.await(5, SECONDS))
            compose.runOnIdle { f.peer.signIn(f.graph) } // Same account, new authorization lifetime.
        } finally { release.countDown() }
        compose.waitUntil(5_000) { f.repository.work.value.isEmpty() }
        checkButton().assertDoesNotExist()
        assertTrue(f.repository.state.value.rejected)
        assertEquals(2, f.forces.get())
        f.assertNoRecoveryWire()
    }

    @Test fun genericColdRejectionCannotOfferCheck() = withLibrary { f ->
        f.disk.writeText("not a journal")
        f.repository.load()
        assertTrue(f.repository.state.value.rejected)
        f.mount()
        checkButton().assertDoesNotExist()
        assertEquals(0, f.forces.get())
        f.assertNoRecoveryWire(uploads = 0)
    }

    @Test fun anotherAccountCannotSeeTheLiveRejectedRefusal() = withLibrary { f ->
        f.reject()
        f.peer.signIn(f.graph, UUID.randomUUID().toString())
        f.mount()
        checkButton().assertDoesNotExist()
        assertEquals(1, f.forces.get())
        f.assertNoRecoveryWire()
    }

    @Test fun durablePendingCheckStillSendsTheExactStatusGet() = withLibrary { f ->
        val choice = f.choose()
        assertEquals(OriginalImportRepository.Action.Unconfirmed, f.repository.confirm(choice))
        assertEquals(OriginalImportPhase.Unconfirmed, f.repository.state.value.entry(choice.intent.operation)?.phase)
        f.mount()
        checkButton().assertIsDisplayed().assertIsEnabled().performClick()
        compose.waitUntil(5_000) { f.repository.state.value.entry(choice.intent.operation)?.phase == OriginalImportPhase.Closed }
        checkButton().assertDoesNotExist()
        assertEquals(0, f.forces.get())
        assertEquals(1, f.uploads.get())
        assertEquals(1, f.statusReads.get())
        assertEquals(0, f.unexpected.get())
        f.assertIdlePlayback()
    }

    @Test fun visitRetirementAfterCandidateReadbackWinsBeforeCommit() = finalReadback(predecessor = false, replaceLogin = false)
    @Test fun visitRetirementAfterPredecessorRewriteWinsBeforeCommit() = finalReadback(predecessor = true, replaceLogin = false)
    @Test fun loginReplacementAfterCandidateReadbackWinsBeforeCommit() = finalReadback(predecessor = false, replaceLogin = true)
    @Test fun loginReplacementAfterPredecessorRewriteWinsBeforeCommit() = finalReadback(predecessor = true, replaceLogin = true)

    private fun finalReadback(predecessor: Boolean, replaceLogin: Boolean) = withLibrary { f ->
        val op = f.reject().intent.operation
        val exactCandidate = f.disk.readBytes()
        if (predecessor) f.disk.writeBytes(requireNotNull(f.predecessor))
        f.mount()
        val validated = CountDownLatch(1)
        val release = CountDownLatch(1)
        f.beforeRefusalForce = {}
        f.afterRefusalReadback = {
            assertFalse(Thread.holdsLock(f.graph.session))
            assertArrayEquals(exactCandidate, f.disk.readBytes())
            assertTrue(f.repository.state.value.rejected)
            validated.countDown()
            check(release.await(8, SECONDS))
        }
        try {
            checkButton().assertIsDisplayed().performClick()
            assertTrue(validated.await(5, SECONDS))
            if (replaceLogin) compose.runOnIdle { f.peer.signIn(f.graph) }
            else {
                compose.onNodeWithContentDescription("Settings").performClick()
                checkButton().assertDoesNotExist()
                compose.onNodeWithContentDescription("Back").performClick()
                checkButton().assertIsNotEnabled()
            }
        } finally { release.countDown() }
        compose.waitUntil(5_000) { f.repository.work.value.isEmpty() }
        assertTrue("retirement won before in-memory commit", f.repository.state.value.rejected)
        assertNull(f.repository.state.value.entry(op))
        assertArrayEquals(exactCandidate, f.disk.readBytes())
        if (replaceLogin) checkButton().assertDoesNotExist()
        else {
            f.afterRefusalReadback = {}
            checkButton().assertIsDisplayed().assertIsEnabled().performClick()
            compose.waitUntil(5_000) { f.repository.state.value.entry(op)?.phase == OriginalImportPhase.Refused }
            checkButton().assertDoesNotExist()
        }
        f.assertNoRecoveryWire()
    }

    @Test fun completedRefusalCommitSurvivesSubsequentVisitAndAccountRetirement() = withLibrary { f ->
        val op = f.reject().intent.operation
        f.disk.writeBytes(requireNotNull(f.predecessor))
        f.mount()
        f.beforeRefusalForce = {}
        val validated = AtomicBoolean()
        f.afterRefusalReadback = {
            assertFalse(Thread.holdsLock(f.graph.session))
            assertTrue(f.repository.state.value.rejected)
            validated.set(true)
        }
        checkButton().performClick()
        compose.waitUntil(5_000) { f.repository.state.value.entry(op)?.phase == OriginalImportPhase.Refused }
        assertTrue(validated.get())
        compose.onNodeWithContentDescription("Settings").performClick()
        compose.runOnIdle { f.peer.signIn(f.graph) }
        assertEquals(OriginalImportPhase.Refused, f.repository.state.value.entry(op)?.phase)
        f.assertNoRecoveryWire()
    }

    @Test fun returnToLibraryDuringCredentialSaveReoffersCheckWithoutAutoRecovery() = withLibrary { f ->
        val op = f.reject().intent.operation
        f.mount()
        checkButton().assertIsEnabled()
        compose.onNodeWithContentDescription("Settings").performClick()
        checkButton().assertDoesNotExist()
        val originalScope = requireNotNull(f.graph.session.capture())
        val signedIn = f.graph.session.state.value
        val saving = CountDownLatch(1)
        val release = CountDownLatch(1)
        f.store.beforeSave = {
            assertFalse(Thread.holdsLock(f.graph.session))
            saving.countDown()
            check(release.await(8, SECONDS))
        }
        f.refreshQuery.set(true)
        val refresh = FutureTask { f.graph.api.library(originalScope, LibraryQuery(text = "refresh-proof"), 0) }
        Thread(refresh, "test-library-refresh").start()
        var wiresHeld: Int
        try {
            assertTrue(saving.await(5, SECONDS))
            assertEquals(1, f.refreshPosts.get())
            assertEquals(1, f.refreshReads.get())
            assertNull(f.graph.session.capture())
            assertEquals(signedIn, f.graph.session.state.value)
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithContentDescription("Library, 0 tracks").assertExists()
            checkButton().assertDoesNotExist()
            assertEquals(1, f.forces.get())
            wiresHeld = f.peer.server.requestCount
        } finally { release.countDown() }
        assertEquals(0, refresh.get(6, SECONDS).total)
        assertEquals(originalScope.epoch, f.graph.session.capture()?.epoch)
        assertEquals(signedIn, f.graph.session.state.value)
        assertTrue(f.graph.session.remoteCurrent(originalScope))
        compose.waitUntil(5_000) { compose.onAllNodes(hasText("Check status") and hasClickAction()).fetchSemanticsNodes().size == 1 }
        checkButton().assertIsEnabled()
        assertEquals(1, f.forces.get())
        // Only the original ordinary read's authenticated retry followed the save.
        assertEquals(2, f.refreshReads.get())
        assertEquals(wiresHeld + 1, f.peer.server.requestCount)
        f.beforeRefusalForce = {}
        checkButton().performClick()
        compose.waitUntil(5_000) { f.repository.state.value.entry(op)?.phase == OriginalImportPhase.Refused }
        assertEquals(wiresHeld + 1, f.peer.server.requestCount)
        f.assertNoRecoveryWire()
    }

    @Test fun ordinaryRefineOpensOnceAndDismissesWithoutRecovering() = withLibrary { f ->
        f.reject()
        f.mount()
        val wire = f.peer.server.requestCount
        compose.onNodeWithContentDescription("Refine library").assertIsDisplayed().performClick()
        val close = compose.onNodeWithContentDescription("Close Refine library")
        close.assertIsDisplayed().performClick()
        close.assertDoesNotExist()
        checkButton().assertIsDisplayed().assertIsEnabled()
        assertTrue(f.repository.state.value.rejected)
        assertEquals(1, f.forces.get())
        assertEquals(wire, f.peer.server.requestCount)
        f.assertNoRecoveryWire()
    }

    @Test fun refineBeforeFinalAdmissionRetiresCheckAndDismissAllowsFreshCheck() = withLibrary { f ->
        val op = f.reject().intent.operation
        val exact = f.disk.readBytes()
        f.mount()
        val wire = f.peer.server.requestCount
        val validated = CountDownLatch(1)
        val release = CountDownLatch(1)
        f.beforeRefusalForce = {}
        f.afterRefusalReadback = {
            assertArrayEquals(exact, f.disk.readBytes())
            validated.countDown()
            check(release.await(8, SECONDS))
        }
        try {
            checkButton().assertIsDisplayed().performClick()
            assertTrue(validated.await(5, SECONDS))
            compose.onNodeWithContentDescription("Refine library").performClick()
            compose.onNodeWithContentDescription("Close Refine library").assertIsDisplayed().performClick()
            compose.onNodeWithContentDescription("Close Refine library").assertDoesNotExist()
        } finally { release.countDown() }
        compose.waitUntil(5_000) { f.repository.work.value.isEmpty() }
        assertTrue(f.repository.state.value.rejected)
        assertNull(f.repository.state.value.entry(op))
        assertArrayEquals(exact, f.disk.readBytes())
        f.afterRefusalReadback = {}
        checkButton().assertIsDisplayed().assertIsEnabled().performClick()
        compose.waitUntil(5_000) { f.repository.state.value.entry(op)?.phase == OriginalImportPhase.Refused }
        assertEquals(3, f.forces.get())
        assertEquals(wire, f.peer.server.requestCount)
        f.assertNoRecoveryWire()
    }

    private fun checkButton() = compose.onNode(hasText("Check status") and hasClickAction())

    private fun waitForText(text: String) = compose.waitUntil(5_000) {
        compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()
    }

    private fun withLibrary(block: (Library) -> Unit) = Fixture(seedReceipt = false).use { peer ->
        val app = RuntimeEnvironment.getApplication() as OriginalImportRecoveryApplication
        shadowOf(app).declareComponentUnbindable(ComponentName(app, SoundQLibraryService::class.java))
        val store = HeldStore()
        peer.graph(null, memory = store).use { graph ->
            app.graph = graph
            val fixture = Library(peer, graph, store)
            try { block(fixture) } finally { fixture.unmount() }
        }
    }

    private class HeldStore(private val backing: SessionStore = MemoryStore()) : SessionStore by backing {
        @Volatile var beforeSave: () -> Unit = {}
        override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) { beforeSave(); backing.save(endpoint, tokens) }
    }

    private inner class Library(val peer: Fixture, val graph: AppGraph, val store: HeldStore) {
        val disk = graph.directory.resolve("original-import.v1.json")
        val uploads = AtomicInteger()
        val statusReads = AtomicInteger()
        val unexpected = AtomicInteger()
        val forces = AtomicInteger()
        val refreshPosts = AtomicInteger()
        val refreshReads = AtomicInteger()
        val refreshQuery = AtomicBoolean()
        private val audio = byteArrayOf(31, 15, 8, 22)
        private val hash = MessageDigest.getInstance("SHA-256").digest(audio).joinToString("") { "%02x".format(it) }
        private val source = ContentOwner(HistoryKey.Device(DeviceFileId(UUID.randomUUID())), ContentRevision(hash, audio.size.toLong()), 1)
        private val scope: AccountScope = peer.signIn(graph)
        @Volatile private var refusal = false
        @Volatile private var operation: UUID? = null
        @Volatile var beforeRefusalForce: () -> Unit = { throw IOException("fixture directory force failed") }
        @Volatile var afterRefusalReadback: () -> Unit = {}
        var predecessor: ByteArray? = null
        private val mounted = mutableStateOf(true)
        private var model: ProductViewModel? = null
        val repository = OriginalImportRepository(graph.session, OriginalImportJournal(disk, beforeRefusalCommit = { afterRefusalReadback() }) {
            val id = operation
            if (id != null) when (OriginalImportJournal(disk).apply { load() }.state.value.entry(id)?.phase) {
                OriginalImportPhase.Unconfirmed -> predecessor = disk.readBytes()
                OriginalImportPhase.Refused -> { forces.incrementAndGet(); beforeRefusalForce() }
                else -> Unit
            }
        }, { _, current ->
            object : ImportOriginalRead {
                override val length = audio.size.toLong()
                override fun checkCurrent() { check(current()) }
                override fun readAt(position: Long, bytes: ByteArray, count: Int): Int {
                    audio.copyInto(bytes, 0, position.toInt(), position.toInt() + count)
                    return count
                }
                override fun close() = Unit
            }
        }, { it == source }).also { repo ->
            // Replace only this fixture graph's storage dependency to inject the real journal
            // force fault; ProductApp, route navigation, AccountSession and API are unchanged.
            AppGraph::class.java.getDeclaredField("originalImports").apply { isAccessible = true }.set(graph, repo)
            assertSame(repo, graph.originalImports)
            repo.installTransport(graph.api.originalImportTransport(true))
        }
        init {
            peer.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = when (request.method to request.url.encodedPath) {
                    "GET" to "/api/v1/library" -> if (request.url.queryParameter("q") == "refresh-proof") {
                        refreshReads.incrementAndGet()
                        if (refreshQuery.compareAndSet(true, false)) peer.reply(401, "{}") else peer.libraryPage(false, request)
                    } else peer.libraryPage(false, request)
                    "POST" to "/api/v1/auth/refresh" -> {
                        refreshPosts.incrementAndGet()
                        peer.reply(200, """{"accessToken":"rotated-fixture-access","refreshToken":"rotated-fixture-refresh","user":{"id":"${scope.accountId}"}}""")
                    }
                    "POST" to "/api/v1/library/uploads" -> {
                        check(request.headers["Idempotency-Key"] == operation.toString())
                        uploads.incrementAndGet()
                        if (refusal) MockResponse.Builder().code(401)
                            .body("""{"code":"UNAUTHORIZED","message":"invalid access token"}""" + "\n")
                            .setHeader("Content-Type", "text/plain; charset=utf-8")
                            .setHeader("X-Content-Type-Options", "nosniff").setHeader("Cache-Control", "private, no-store").build()
                        else peer.reply(503, "{}")
                    }
                    "GET" to "/api/v1/library/uploads/$operation" -> {
                        statusReads.incrementAndGet()
                        peer.reply(200, """{"account_id":"${scope.accountId}","operation_id":"$operation","status":"closed"}""")
                    }
                    else -> { unexpected.incrementAndGet(); peer.reply(500, "{}") }
                }
            }
        }
        fun choose(): OriginalImportRepository.Choice {
            repository.load()
            return requireNotNull(repository.choose(scope, source, ImportDisplay("Fixture audio", "", "")) { true }).also {
                operation = it.intent.operation
            }
        }
        fun reject(): OriginalImportRepository.Choice {
            refusal = true
            return choose().also {
                assertEquals(OriginalImportRepository.Action.StorageUnavailable, repository.confirm(it))
                assertTrue(repository.state.value.rejected)
                assertNull(repository.state.value.entry(it.intent.operation))
                assertTrue(repository.entries(scope).isEmpty())
                assertTrue(repository.associations(scope).isEmpty())
                assertEquals(1, forces.get())
            }
        }
        fun mount() {
            // Establish the same acknowledged empty page through the real Library loader before
            // measuring the control; the independent startup observer is not part of this race.
            graph.library.refine(LibraryQuery())
            assertEquals(0, graph.library.state.value.total)
            val app = RuntimeEnvironment.getApplication() as OriginalImportRecoveryApplication
            val owner = compose.runOnIdle { ProductViewModel(app) }.also { model = it }
            assertSame(graph, owner.graph)
            compose.setContent { if (mounted.value) ProductApp(owner) }
            try {
                compose.waitUntil(5_000) {
                    compose.onAllNodesWithContentDescription("Library, 0 tracks").fetchSemanticsNodes().size == 1
                }
            } catch (failure: Throwable) {
                throw AssertionError("Empty Library failed to mount (total=${graph.library.state.value.total}, " +
                    "loading=${graph.library.state.value.loading}):\n" + compose.onRoot().printToString(), failure)
            }
            compose.onNodeWithContentDescription("Library, 0 tracks").assertExists()
            assertEquals(0, graph.library.state.value.total)
            assertTrue(graph.library.state.value.rows.isEmpty())
        }
        fun unmount() {
            val owner = model ?: return
            compose.runOnIdle { mounted.value = false }
            compose.waitForIdle()
            owner.viewModelScope.cancel()
        }
        fun assertIdlePlayback() {
            val playback = graph.controller.state.value
            assertFalse(playback.isPlaying)
            assertTrue(playback.queue.isEmpty())
            assertNull(playback.selectedOccurrence)
        }
        fun assertNoRecoveryWire(uploads: Int = 1) {
            assertEquals(uploads, this.uploads.get())
            assertEquals(0, statusReads.get())
            assertEquals(0, unexpected.get())
            assertIdlePlayback()
        }
    }
}

/** Use the fixture graph without application startup or persistent playback services. */
class OriginalImportRecoveryApplication : SoundQApplication() {
    override fun onCreate() = Unit
}
