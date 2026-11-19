package com.soundq.android.data

import com.soundq.android.data.discovery.*
import kotlinx.coroutines.*
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.RecordedRequest
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.lang.management.ManagementFactory
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit.SECONDS

class DiscoverySettlementRaceTest {
    @Test fun cancelSuccessWhileBlockedOnAccountMonitor() = cancelAtAccount(200)
    @Test fun cancelFailureWhileBlockedOnAccountMonitor() = cancelAtAccount(503)
    @Test fun cancelThenRevokeWhileSuccessIsBlockedOnAccountMonitor() = cancelAtAccount(200, revoke = true)
    @Test fun cancelThenRevokeWhileFailureIsBlockedOnAccountMonitor() = cancelAtAccount(503, revoke = true)
    @Test fun cancelHiddenReplyDoesNotConsumeNewerTabReservation() = cancelAtAccount(200, switchTab = true)

    private fun cancelAtAccount(code: Int, revoke: Boolean = false, switchTab: Boolean = false) = fixture(code, "discovery-cancel-fixture") { r, owner ->
        val request = r.reserve()
        val gate = Gate(request)
        val newer = if (switchTab) r.repo.selectType(r.view, DiscoveryResultType.Song)!! else null
        val states = r.observe(owner)
        val work = owner.async { r.repo.search(request) }
        try {
            val arrival = gate.decoded(code)
            synchronized(r.session) {
                gate.release.countDown()
                val bean = ManagementFactory.getThreadMXBean()
                val holder = Thread.currentThread().id
                until("worker BLOCKED on the actual account monitor inside settlement") {
                    val info = bean.getThreadInfo(arrival.thread.id, 32) ?: return@until false
                    info.threadState == Thread.State.BLOCKED && info.lockOwnerId == holder &&
                        info.lockInfo?.identityHashCode == System.identityHashCode(r.session) &&
                        info.stackTrace.any { it.methodName.contains("settleSearch") && it.className == DiscoveryRepository::class.java.name }
                }
                work.cancel()
                if (revoke) r.session.revoke() else assertTrue(r.session.remoteCurrent(r.scope))
            }
            work.finish()
            if (newer == null) assertEquals(listOf(DiscoveryPhase.Loading, DiscoveryPhase.Idle), states.map { it.state.phase })
            else {
                assertEquals(listOf(DiscoveryPhase.Loading), states.map { it.state.phase })
                assertSame(newer.draft, r.repo.state.value.draft)
                r.repo.searchBlocking(newer)
                val page = r.repo.state.value.results!!
                assertEquals("seed", page.query)
                assertNull(r.repo.selectType(r.view, DiscoveryResultType.Album))
                assertEquals("hidden canceled result must not survive tab return", DiscoveryPhase.Idle, r.repo.state.value.phase)
                assertNull(r.repo.state.value.results)
                assertNull(r.repo.selectType(r.view, DiscoveryResultType.Song))
                assertSame(page, r.repo.state.value.results)
            }
            assertTrue(states.all { it.state.error == null })
        } finally { gate.release.countDown() }
    }

    @Test fun revocationOrdersBeforeDecodedSuccessPublication() = revokeAtDecision(200)
    @Test fun revocationOrdersBeforeDecodedFailurePublication() = revokeAtDecision(503)

    private fun revokeAtDecision(code: Int) = fixture(code) { r, owner ->
        val request = r.reserve()
        val gate = Gate(request)
        val states = r.observe(owner)
        val work = owner.async { r.repo.search(request) }
        try {
            gate.decoded(code)
            val pending = r.repo.state.value
            r.session.revoke()
            assertFalse(r.session.remoteCurrent(r.scope))
            assertSame(pending, r.repo.state.value)
            gate.release.countDown()
            work.result()
            assertEquals("only retirement, never the decoded response", listOf(DiscoveryPhase.Loading to null,
                DiscoveryPhase.Failed to SafeFailure.Reason.Retired), states.map { it.state.phase to it.state.error })
            assertTrue(states.all { it.state.results == null })
            assertTrue(r.session.accept(r.session.beginIntent(), SecretTokens("replacement", "r2", "A")))
            r.fresh()
            assertEquals(2, r.f.server.requestCount)
        } finally { gate.release.countDown() }
    }

    @Test fun withdrawnBearerDefersDecodedSuccessUntilDurableSave() = saveAtDecision(200, Save.Success)
    @Test fun withdrawnBearerDefersDecodedFailureUntilDurableSave() = saveAtDecision(503, Save.Success)
    @Test fun revokeWhileSettlementAwaitsSaveRefusesDecodedRows() = saveAtDecision(200, Save.Revoke)
    @Test fun failedSaveAndManualRetryCannotReviveDecodedRows() = saveAtDecision(200, Save.FailThenRetry)
    @Test fun decodedResolveDoesNotWaitForGetCustodyOrReplayPost() = saveAtDecision(200, Save.Resolve)
    @Test fun hiddenPendingCatalogDoesNotLeakThroughTabSnapshotOrBack() = saveAtDecision(200, Save.Hidden)

    private enum class Save { Success, Revoke, FailThenRetry, Resolve, Hidden }

    private fun saveAtDecision(code: Int, mode: Save) = fixture(code) { r, owner ->
        val request = r.reserve(link = mode == Save.Resolve)
        val gate = Gate(request)
        val hidden = mode == Save.Hidden
        val song = if (hidden) {
            val next = r.repo.selectType(r.view, DiscoveryResultType.Song)!!
            r.repo.searchBlocking(next)
            r.repo.state.value.results!!
        } else null
        val states = r.observe(owner)
        val work = owner.async { r.repo.search(request) }
        try {
            val arrival = gate.decoded(code)
            val pending = r.repo.state.value
            if (hidden) assertSame(song, pending.results) else assertNull(pending.results)
            // Actual 401 → TLS refresh → bearer withdrawn → held SessionStore.save.
            val rotation = owner.async(Dispatchers.IO) { runCatching { r.api.discoverySearch(r.scope, "rotate", provider = SourceProvider.YouTube) } }
            r.store.entered.cross()
            assertNull(r.session.capture())
            assertEquals("a", r.store.saved!!.access)
            assertSame(pending, r.repo.state.value)
            if (mode == Save.FailThenRetry) {
                r.store.fail = true
                r.store.release.countDown()
                assertTrue(rotation.result().isFailure)
                assertTrue(r.session.state.value is AuthState.SaveRequired)
                r.store.fail = false
                assertTrue(r.session.retrySave())
                assertEquals(r.scope.epoch, r.session.capture()!!.epoch)
                assertFalse(r.session.discoveryCurrent(r.scope))
                assertSame(pending, r.repo.state.value)
            }
            gate.release.countDown()
            if (mode == Save.Resolve) {
                work.result() // Must finish before secure save is released.
                assertEquals(listOf(DiscoveryPhase.Loading to null, DiscoveryPhase.Failed to SafeFailure.Reason.Retired),
                    states.map { it.state.phase to it.state.error })
                assertTrue(states.all { it.state.results == null })
                assertEquals(listOf("POST /api/v1/discovery/resolve-url", "GET /api/v1/discovery/search", "POST /api/v1/auth/refresh"),
                    r.takeWire(3))
            } else if (mode != Save.FailThenRetry) {
                until("settlement wait or early completion") { work.isCompleted || arrival.thread.stackTrace.any {
                    it.className == "java.util.concurrent.CompletableFuture" && it.methodName == "get"
                } }
                assertFalse("decoded response settled while bearer was withdrawn: ${states.map { it.state.phase to it.state.error }}", work.isCompleted)
                // A different thread must acquire repository then session while the wait remains held.
                owner.async(Dispatchers.IO) {
                    synchronized(r.repo) {
                        synchronized(r.session) {
                            assertSame(pending, r.repo.state.value)
                            assertFalse(r.repo.current(r.view))
                            if (hidden) {
                                assertNull(r.repo.selectType(r.view, DiscoveryResultType.Artist))
                                assertFalse(r.repo.back(r.view))
                                assertNull(r.repo.refine(r.view, arrival.response.getOrThrow().entities.first()))
                                assertSame(song, r.repo.state.value.results)
                            }
                        }
                    }
                }.result()
                assertEquals(listOf(pending), states.map { it.state })
                if (mode == Save.Revoke) r.session.revoke()
            }
            r.store.release.countDown()
            val rotated = rotation.result()
            work.result()
            when (mode) {
                Save.Success -> {
                    assertEquals(listOf(DiscoveryPhase.Loading, if (code == 200) DiscoveryPhase.Ready else DiscoveryPhase.Failed), states.map { it.state.phase })
                    val last = states.last()
                    assertTrue("inline acceptance is inside account ordering", last.accountLocked)
                    assertTrue(last.repoLocked)
                    assertEquals("rotated", last.durableBearer)
                    assertEquals(if (code == 200) null else SafeFailure.Reason.Refused, last.state.error)
                    if (code == 200) assertEquals("seed", last.state.results!!.query) else assertNull(last.state.results)
                    assertEquals(4, r.f.server.requestCount)
                }
                Save.Hidden -> {
                    assertEquals(listOf(pending), states.map { it.state })
                    assertSame(song, r.repo.state.value.results)
                    assertNull(r.repo.selectType(r.view, DiscoveryResultType.Artist))
                    val page = r.repo.state.value.results!!
                    val entity = page.entities.first()
                    assertNotNull(r.repo.refine(r.view, entity))
                    assertTrue(r.repo.back(r.view))
                    assertSame(page, r.repo.state.value.results)
                    assertNull(r.repo.selectType(r.view, DiscoveryResultType.Song))
                    assertSame(song, r.repo.state.value.results)
                    assertEquals(6, r.f.server.requestCount)
                }
                Save.Revoke, Save.FailThenRetry -> {
                    assertTrue(rotated.isFailure)
                    assertEquals(listOf(DiscoveryPhase.Loading to null, DiscoveryPhase.Failed to SafeFailure.Reason.Retired),
                        states.map { it.state.phase to it.state.error })
                    assertTrue(states.all { it.state.results == null })
                    if (mode == Save.Revoke) assertTrue(r.session.accept(r.session.beginIntent(), SecretTokens("replacement", "r2", "A")))
                    r.fresh()
                    assertEquals(4, r.f.server.requestCount)
                }
                Save.Resolve -> {
                    assertEquals(4, r.f.server.requestCount) // only the competing GET retried
                    assertEquals(listOf("GET /api/v1/discovery/search"), r.takeWire(1))
                    assertEquals(DiscoveryPhase.Failed, r.repo.state.value.phase)
                }
            }
            if (mode in setOf(Save.Success, Save.Hidden, Save.Resolve)) {
                assertEquals("rotate", rotated.getOrThrow().query)
                assertEquals("rotated", r.session.access(r.scope))
            }
        } finally { gate.release.countDown(); r.store.release.countDown() }
    }

    private class HeldStore : SessionStore {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        @Volatile var fail = false
        @Volatile var saved: SecretTokens? = null
        override fun load(endpoint: ApiEndpoint) = saved
        override fun clear() { saved = null }
        override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) {
            if (tokens.access == "rotated") { entered.countDown(); release.cross(); if (fail) throw IOException() }
            saved = tokens
        }
    }

    private data class Emission(val state: DiscoveryState, val repoLocked: Boolean, val accountLocked: Boolean, val durableBearer: String?)

    private class Rig(val f: HttpsFixture, code: Int) {
        val store = HeldStore()
        val session = AccountSession(f.endpoint, store).apply { check(accept(beginIntent(), SecretTokens("a", "r", "A"))) }
        val scope = session.capture()!!
        val api = SoundQApi(session, f.client)
        val repo = DiscoveryRepository(session, api)
        val view = repo.open()!!
        init {
            f.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val q = request.url.queryParameter("q")
                    val providers = request.url.queryParameter("providers")
                    return when {
                        request.url.encodedPath == "/api/v1/auth/refresh" -> reply(f.auth("A", "rotated"))
                        request.url.encodedPath == "/api/v1/discovery/resolve-url" -> reply("""{"candidate":${DiscoveryBoundaryTest.candidate()},"selectionRequired":true,"selectionSessionId":"123e4567-e89b-12d3-a456-426614174010","selectionExpiresAt":"2030-01-01T00:00:00Z"}""")
                        q == "rotate" && request.headers["Authorization"] == "Bearer a" -> reply("{}", 401)
                        q == "rotate" -> reply(singletonSongBody(DiscoveryBoundaryTest.search(q), "youtube"))
                        providers == "youtube,soundcloud,musicbrainz" -> if (q == "fresh") reply(DiscoverCatalogContinuationTest.grouped().replace("\"seed\"", "\"fresh\""))
                            else if (code == 200) reply(DiscoverCatalogContinuationTest.grouped()) else reply("{}", code)
                        else -> reply(singletonSongBody(DiscoveryBoundaryTest.search(q!!), providers!!))
                    }
                }
            }
        }
        fun reserve(link: Boolean = false): DiscoverySearchRequest {
            repo.selectType(view, DiscoveryResultType.Artist)
            repo.edit(view, if (link) "https://youtu.be/fixture" else "seed")
            return repo.claimSearch(view, repo.state.value.draft)!!
        }
        fun observe(owner: CoroutineScope) = LinkedBlockingQueue<Emission>().also { emissions ->
            // Inline, read-only recorder: capture every transition before finally or the next action can conflate it.
            owner.launch(Dispatchers.Unconfined, start = CoroutineStart.UNDISPATCHED) {
                repo.state.collect { emissions.add(Emission(it, Thread.holdsLock(repo), Thread.holdsLock(session), store.saved?.access)) }
            }
        }
        fun takeWire(count: Int) = List(count) { checkNotNull(f.server.takeRequest(5, SECONDS)).let { "${it.method} ${it.url.encodedPath}" } }
        fun fresh() {
            val freshView = repo.open()!!
            repo.selectType(freshView, DiscoveryResultType.Artist)
            repo.edit(freshView, "fresh")
            repo.searchBlocking(freshView, repo.state.value.draft)
            assertEquals(DiscoveryPhase.Ready, repo.state.value.phase)
            assertEquals("fresh", repo.state.value.results!!.query)
        }
    }

    private data class Arrival(val thread: Thread, val response: Result<SourceResults>)

    private class Gate(request: DiscoverySearchRequest) {
        private val arrivals = LinkedBlockingQueue<Arrival>(1)
        val release = CountDownLatch(1)
        init {
            request.beforePublication = { response ->
                check(arrivals.offer(Arrival(Thread.currentThread(), response)))
                release.cross()
            }
        }
        fun decoded(code: Int): Arrival = checkNotNull(arrivals.poll(6, SECONDS)) { "decoded response not reached" }.also {
            if (code == 200) assertTrue("decoded success required: ${it.response.exceptionOrNull()}", it.response.getOrThrow().rows.isNotEmpty())
            else assertEquals(SafeFailure.Reason.Refused, (it.response.exceptionOrNull() as SafeFailure).reason)
        }
    }

    private fun fixture(code: Int, name: String = "discovery-after-decision-fixture", exercise: (Rig, CoroutineScope) -> Unit) = HttpsFixture().use { f ->
        // The private predecessor-only overlay relocates the existing observation
        // for this named worker to the unlocked post-lookup gap. Cancel cases keep
        // the production hook location because they witness actual monitor contention.

        Executors.newSingleThreadExecutor { work -> Thread(work, name).apply { isDaemon = true } }.asCoroutineDispatcher().use { dispatcher ->
            val root = SupervisorJob()
            try { exercise(Rig(f, code), CoroutineScope(root + dispatcher)) }
            finally { root.cancel(); root.finish() }
        }
    }

    companion object {
        private fun reply(body: String, code: Int = 200) = MockResponse.Builder().code(code).body(body).build()
        private fun CountDownLatch.cross() = check(await(12, SECONDS)) { "fixture gate timed out" }
        private fun Job.finish() = runBlocking { withTimeout(6000) { join() } }
        private fun <T> Deferred<T>.result(): T = runBlocking { withTimeout(6000) { await() } }
        private fun until(stage: String, condition: () -> Boolean) {
            val deadline = System.nanoTime() + SECONDS.toNanos(5)
            do { if (condition()) return; Thread.yield() } while (System.nanoTime() < deadline)
            fail("fixture did not reach $stage")
        }
    }
}
