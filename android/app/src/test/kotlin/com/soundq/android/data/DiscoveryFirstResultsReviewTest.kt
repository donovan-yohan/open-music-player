package com.soundq.android.data

import com.soundq.android.data.discovery.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.RecordedRequest
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.Response
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit.SECONDS

class DiscoveryFirstResultsReviewTest {
    @Test fun admittedSuccessSurvivesHeldRotationSave() = rotation(peerCode = 200)
    @Test fun overlappingUnauthorizedJoinsHeldRotationAndRetriesOnce() = rotation(peerCode = 401)
    @Test fun failedSaveDoesNotPublishAdmittedRows() = rotation(peerCode = 200, mode = "save failure")
    @Test fun localLockDuringSaveRetainsRotationButNotSearchAuthority() = rotation(peerCode = 200, mode = "lock")
    @Test fun signoutDuringSaveRetiresOldSearch() = rotation(peerCode = 200, mode = "signout")
    @Test fun sameIdReplacementDuringSaveCannotRebindOldSearch() = rotation(peerCode = 200, mode = "replacement")
    @Test fun cancelDuringSaveStillPersistsEnteredRotationWithoutRetry() = rotation(peerCode = 200, mode = "cancel")

    private fun rotation(peerCode: Int, mode: String = "success") = HttpsFixture().use { f ->
        val saveEntered = CountDownLatch(1)
        val releaseSave = CountDownLatch(1)
        val releasePeer = CountDownLatch(1)
        val peerResponseThreads = LinkedBlockingQueue<Thread>()
        val store = object : SessionStore {
            @Volatile var saved: SecretTokens? = null
            override fun load(endpoint: ApiEndpoint) = saved
            override fun clear() { saved = null }
            override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) {
                if (tokens.access == "rotated") {
                    saveEntered.countDown(); releaseSave.cross()
                    if (mode == "save failure") throw java.io.IOException()
                }
                saved = tokens
            }
        }
        val session = signedIn(f, store)
        val scope = session.capture()!!
        val client = f.client.newBuilder().eventListener(object : EventListener() {
            override fun responseHeadersEnd(call: Call, response: Response) {
                if (response.request.header("Authorization") == "Bearer a" &&
                    response.request.url.queryParameter("providers") == "soundcloud") peerResponseThreads.add(Thread.currentThread())
            }
        }).build()
        val api = SoundQApi(session, client)
        val repo = DiscoveryRepository(session, api)
        val view = repo.open()!!
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.url.encodedPath == "/api/v1/auth/refresh") return reply(f.auth("A", "rotated"))
                val p = checkNotNull(request.url.queryParameter("providers"))
                if (request.headers["Authorization"] == "Bearer a") {
                    if (p == "youtube") return reply("{}", 401)
                    releasePeer.cross()
                    return reply(batch("seed", p), peerCode)
                }
                check(request.headers["Authorization"] == "Bearer rotated")
                return reply(batch("seed", p))
            }
        }
        try {
            repo.edit(view, "seed")
            val work = owner.launch { repo.search(view, repo.state.value.draft) }
            saveEntered.cross()
            assertFalse(session.current(scope)); assertFalse(session.remoteCurrent(scope)); assertNull(session.capture())
            val firstRequests = List(3) { f.server.takeRequest(4, SECONDS)!! }
            assertEquals(setOf("youtube", "soundcloud"), firstRequests.filter { it.method == "GET" }.map { it.url.queryParameter("providers") }.toSet())
            assertEquals(1, firstRequests.count { it.url.encodedPath == "/api/v1/auth/refresh" })
            assertRetired { api.discoverySearch(scope, "not admitted") }
            assertRetired { api.like(scope, TrackId(7), true) }
            val replacement = when (mode) {
                "lock" -> { assertTrue(session.lockLocal()); null }
                "signout" -> session.revoke().let { retirement -> owner.launch { session.clearRetired(retirement) } }
                "replacement" -> session.beginIntent().let { intent -> owner.launch { assertTrue(session.accept(intent, SecretTokens("replacement", "r2", "A"))) } }
                else -> null
            }
            if (mode == "cancel") work.cancel() else {
                releasePeer.countDown()
                val peer = checkNotNull(peerResponseThreads.poll(4, SECONDS))
                // Either the peer joined the very save that is held, or it left the search worker.
                // In particular, releasing save immediately after server receipt would mask the bug.
                observeThread(peer) { stack -> stack.any { it.className == "java.util.concurrent.CompletableFuture" && it.methodName == "get" } ||
                    stack.none { it.className.startsWith("com.soundq.android.data.SoundQApi") || it.className.startsWith("com.soundq.android.data.discovery.DiscoveryRepository") } }
                assertNull("no rows while access is withdrawn", repo.state.value.results)
            }
            assertEquals("no GET retry or mutation while saving", 3, f.server.requestCount)
            releaseSave.countDown()
            work.finish(); replacement?.finish()
            if (mode == "success") {
                val results = repo.state.value.results!!
                assertEquals(DiscoveryPhase.Ready, repo.state.value.phase)
                assertFalse(repo.state.value.pendingProviders)
                assertEquals(setOf(SourceProvider.YouTube, SourceProvider.SoundCloud), results.rows.map { it.provider }.toSet())
                assertTrue(results.providers.all { it.status == "ok" })
                for (row in results.rows) assertEquals(id(row.provider.wire), repo.inspect(view, row)!!.selection.id)
                val retries = List(if (peerCode == 401) 2 else 1) { f.server.takeRequest(4, SECONDS)!! }
                assertEquals(if (peerCode == 401) setOf("youtube", "soundcloud") else setOf("youtube"), retries.map { it.url.queryParameter("providers") }.toSet())
                assertTrue(retries.all { it.headers["Authorization"] == "Bearer rotated" })
                assertEquals(3 + retries.size, f.server.requestCount)
            } else {
                assertTrue(repo.state.value.results?.rows.isNullOrEmpty())
                assertFalse(repo.state.value.pendingProviders)
                assertEquals(3, f.server.requestCount)
                when (mode) {
                    "lock", "cancel" -> assertEquals("rotated", store.saved?.access)
                    "replacement" -> assertEquals("replacement", store.saved?.access)
                    "signout" -> assertNull(store.saved)
                    "save failure" -> assertTrue(session.state.value is AuthState.SaveRequired)
                }
                if (mode != "cancel") assertFalse(session.remoteCurrent(scope))
            }
        } finally { releasePeer.countDown(); releaseSave.countDown(); owner.cancel() }
    }

    @Test fun queuedOldBearerIsRefusedAtActualNetworkAdmissionAfterRotation() = HttpsFixture().use { f ->
        val session = signedIn(f)
        val scope = session.capture()!!
        val atInterceptor = CountDownLatch(1)
        val release = CountDownLatch(1)
        val client = f.client.newBuilder().addInterceptor { chain ->
            if (chain.request().url.queryParameter("q") == "queued") {
                assertEquals("Bearer a", chain.request().header("Authorization"))
                atInterceptor.countDown(); release.cross()
            }
            chain.proceed(chain.request())
        }.build()
        val api = SoundQApi(session, client)
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when {
                request.url.encodedPath == "/api/v1/auth/refresh" -> reply(f.auth("A", "rotated"))
                request.url.queryParameter("q") == "queued" -> reply(batch("queued", "youtube"))
                request.headers["Authorization"] == "Bearer a" -> reply("{}", 401)
                else -> reply(batch("refresh", "youtube"))
            }
        }
        try {
            val queued = owner.async { runCatching { api.discoverySearch(scope, "queued", provider = SourceProvider.YouTube) } }
            atInterceptor.cross()
            assertEquals(1, api.discoverySearch(scope, "refresh", provider = SourceProvider.YouTube).rows.size)
            assertEquals("rotated", session.access(scope))
            release.countDown()
            val queuedResult = runBlocking { withTimeout(4000) { queued.await() } }
            assertEquals(SafeFailure.Reason.Retired, (queuedResult.exceptionOrNull() as? SafeFailure)?.reason)
            assertEquals("withdrawn bearer never reached TLS", 3, f.server.requestCount)
        } finally { release.countDown(); owner.cancel() }
    }

    @Test fun manualSaveRetryCannotReviveAReplyHeldAcrossFailedRotation() = HttpsFixture().use { f ->
        val store = MemoryStore()
        val session = signedIn(f, store)
        val scope = session.capture()!!
        val api = SoundQApi(session, f.client)
        val release = CountDownLatch(1)
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when {
                request.url.encodedPath == "/api/v1/auth/refresh" -> reply(f.auth("A", "rotated"))
                request.url.queryParameter("q") == "held" -> { release.cross(); reply(batch("held", "youtube")) }
                request.headers["Authorization"] == "Bearer a" -> reply("{}", 401)
                else -> reply(batch("fresh", "youtube"))
            }
        }
        try {
            val held = owner.async { runCatching { api.discoverySearch(scope, "held", provider = SourceProvider.YouTube) } }
            assertEquals("held", f.server.takeRequest(4, SECONDS)!!.url.queryParameter("q"))
            store.fail = true
            assertTrue(runCatching { api.discoverySearch(scope, "refresh", provider = SourceProvider.YouTube) }.isFailure)
            assertTrue(session.state.value is AuthState.SaveRequired)
            store.fail = false
            assertTrue(session.retrySave())
            assertEquals(scope.epoch, session.capture()!!.epoch)
            release.countDown()
            val result = runBlocking { withTimeout(4000) { held.await() } }
            assertEquals(SafeFailure.Reason.Retired, (result.exceptionOrNull() as? SafeFailure)?.reason)
            assertRetired { api.discoverySearch(scope, "old scope") }
            assertEquals(1, api.discoverySearch(session.capture()!!, "fresh", provider = SourceProvider.YouTube).rows.size)
            assertEquals(4, f.server.requestCount)
        } finally { release.countDown(); owner.cancel() }
    }

    @Test fun songPageReturnsWhileGroupedIsHeldAndPeerAppendsIndependently() = tabReturn(200)
    @Test fun failedGroupedPageDoesNotReplaceSongPageOrRetryOnTabReturn() = tabReturn(503)

    private fun tabReturn(groupedCode: Int) = HttpsFixture().use { f ->
        val session = signedIn(f)
        val repo = DiscoveryRepository(session, SoundQApi(session, f.client))
        val view = repo.open()!!
        val releaseGrouped = CountDownLatch(1)
        val releasePeer = CountDownLatch(1)
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (val p = request.url.queryParameter("providers")!!) {
                "youtube" -> reply(batch("seed", p))
                "soundcloud" -> { releasePeer.cross(); reply(batch("seed", p)) }
                else -> {
                    check(p == "youtube,soundcloud,musicbrainz")
                    releaseGrouped.cross(); reply(DiscoverCatalogContinuationTest.grouped(), groupedCode)
                }
            }
        }
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            repo.edit(view, "seed")
            val song = owner.launch { repo.search(view, repo.state.value.draft) }
            f.takeSongRequests()
            val page = runBlocking { withTimeout(4000) { repo.state.first { it.phase == DiscoveryPhase.Ready }.results!! } }
            val row = page.rows.single()
            val oldChoice = repo.inspect(view, row)!!

            val request = repo.selectType(view, DiscoveryResultType.Artist)!!
            val catalog = owner.launch { repo.search(request) }
            assertEquals("youtube,soundcloud,musicbrainz", f.server.takeRequest(4, SECONDS)!!.url.queryParameter("providers"))
            assertFalse(oldChoice.valid())
            assertNull(repo.selectType(view, DiscoveryResultType.Album))
            assertEquals(DiscoveryPhase.Loading, repo.state.value.phase)
            if (groupedCode != 200) {
                releaseGrouped.countDown(); catalog.finish()
                assertEquals(DiscoveryPhase.Failed, repo.state.value.phase)
            }
            assertNull(repo.selectType(view, DiscoveryResultType.Song))
            assertSame("Song must restore its own accepted page", page, repo.state.value.results)
            assertSame(row, repo.state.value.results!!.rows.single())
            assertFalse(oldChoice.valid())
            assertNull(repo.state.value.error)
            assertTrue(repo.state.value.pendingProviders)
            val choice = repo.inspect(view, row)!!
            assertSame(oldChoice.selection, choice.selection)
            assertEquals(Instant.parse("2030-01-01T00:00:00Z"), choice.selection.expires)
            assertTrue(repo.preview(view, choice) { assertEquals(row.source.url, it) })
            releasePeer.countDown(); song.finish()
            val appended = repo.state.value.results!!
            assertSame(page.identity, appended.identity)
            assertSame(row, appended.rows.first())
            assertEquals(listOf(SourceProvider.YouTube, SourceProvider.SoundCloud), appended.rows.map { it.provider })
            assertSame(choice, repo.state.value.inspected); assertTrue(choice.valid())
            releaseGrouped.countDown(); catalog.finish()
            assertSame(appended, repo.state.value.results)
            assertNull(repo.selectType(view, DiscoveryResultType.Artist))
            assertFalse(choice.valid())
            assertEquals(if (groupedCode == 200) DiscoveryPhase.Ready else DiscoveryPhase.Failed, repo.state.value.phase)
            if (groupedCode == 200) {
                val entity = repo.state.value.results!!.entities.first()
                val details = repo.details(view, entity)!!
                assertTrue(details.valid())
                assertNull(repo.selectType(view, DiscoveryResultType.Album))
                assertNull(repo.selectType(view, DiscoveryResultType.Artist))
                assertFalse(details.valid()); assertTrue(repo.details(view, entity)!!.valid())
            }
            assertNull(repo.selectType(view, DiscoveryResultType.Song))
            assertSame(appended, repo.state.value.results)
            assertEquals(listOf("seed"), repo.state.value.recent)
            assertEquals(3, f.server.requestCount)
        } finally { releasePeer.countDown(); releaseGrouped.countDown(); owner.cancel() }
    }

    @Test fun canceledDecodedSongSuccessCannotPublish() = cancelAtPublication("song", 200)
    @Test fun canceledSongFailureCannotSettle() = cancelAtPublication("song", 503)
    @Test fun canceledDecodedGroupedSuccessCannotPublish() = cancelAtPublication("grouped", 200)
    @Test fun canceledGroupedFailureCannotSettle() = cancelAtPublication("grouped", 503)
    @Test fun canceledDecodedResolveSuccessCannotPublish() = cancelAtPublication("resolve", 200)
    @Test fun canceledResolveFailureCannotSettle() = cancelAtPublication("resolve", 503)
    @Test fun canceledDecodedReplyCannotClearNewerSearch() = cancelAtPublication("grouped", 200, replace = true)

    private fun cancelAtPublication(family: String, code: Int, replace: Boolean = false) = HttpsFixture().use { f ->
        val session = signedIn(f)
        val repo = DiscoveryRepository(session, SoundQApi(session, f.client))
        val view = repo.open()!!
        val atPublication = LinkedBlockingQueue<Pair<Thread, Result<SourceResults>>>()
        val releasePublication = CountDownLatch(1)
        val releasePeer = CountDownLatch(1)
        val link = "https://youtu.be/fixture"
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val q = request.url.queryParameter("q")
                val p = request.url.queryParameter("providers")
                if (q == "fresh") return reply(DiscoveryBoundaryTest.search("fresh"))
                val body = when (family) {
                    "song" -> { if (p == "soundcloud") releasePeer.cross(); batch("seed", p!!) }
                    "grouped" -> DiscoveryGroupedJourneyTest.grouped()
                    else -> """{"candidate":${DiscoveryBoundaryTest.candidate()},"selectionRequired":true,"selectionSessionId":"${id("youtube")}","selectionExpiresAt":"2030-01-01T00:00:00Z"}"""
                }
                return reply(body, code)
            }
        }
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        // Unconfined observes publication inline rather than allowing finally's cleanup to conflate it.
        val phases = LinkedBlockingQueue<DiscoveryState>()
        val observer = owner.launch(Dispatchers.Unconfined) { repo.state.collect { phases.add(it) } }
        try {
            if (family == "grouped") repo.selectType(view, DiscoveryResultType.Artist)
            repo.edit(view, if (family == "resolve") link else "seed")
            val request = repo.claimSearch(view, repo.state.value.draft)!!
            request.beforePublication = { result -> atPublication.add(Thread.currentThread() to result); releasePublication.cross() }
            val work = owner.launch { repo.search(request) }
            val (worker, result) = checkNotNull(atPublication.poll(4, SECONDS))
            if (code == 200) assertEquals("youtube", result.getOrThrow().rows.single().provider.wire)
            else assertEquals(if (family == "resolve") SafeFailure.Reason.Uncertain else SafeFailure.Reason.Refused,
                (result.exceptionOrNull() as SafeFailure).reason)
            val fresh = synchronized(repo) {
                releasePublication.countDown()
                observeThread(worker) { stack -> worker.state == Thread.State.BLOCKED &&
                    stack.any { it.className.startsWith("com.soundq.android.data.discovery.DiscoveryRepository") } }
                work.cancel()
                if (replace) {
                    repo.edit(view, "fresh"); repo.claimSearch(view, repo.state.value.draft)!!
                } else null
            }
            work.finish()
            assertFalse("canceled worker published a reply before cleanup", phases.any { it.phase in setOf(DiscoveryPhase.Ready, DiscoveryPhase.Failed) || it.results != null })
            assertNull(repo.state.value.results)
            if (fresh == null) assertEquals(DiscoveryPhase.Idle, repo.state.value.phase)
            else {
                assertSame(fresh.draft, repo.state.value.draft)
                assertEquals(DiscoveryPhase.Loading, repo.state.value.phase)
                repo.searchBlocking(fresh)
                assertEquals("fresh", repo.state.value.results!!.query)
            }
        } finally { releasePublication.countDown(); releasePeer.countDown(); observer.cancel(); owner.cancel() }
    }

    private fun assertRetired(block: () -> Any) {
        assertEquals(SafeFailure.Reason.Retired, (runCatching(block).exceptionOrNull() as? SafeFailure)?.reason)
    }

    private fun signedIn(f: HttpsFixture, store: SessionStore = MemoryStore()) = AccountSession(f.endpoint, store).apply {
        check(accept(beginIntent(), SecretTokens("a", "r", "A")))
    }

    private fun CountDownLatch.cross() { check(await(8, SECONDS)) { "fixture barrier timed out" } }
    private fun Job.finish() = runBlocking { withTimeout(5000) { join() } }
    private fun observeThread(thread: Thread, predicate: (Array<StackTraceElement>) -> Boolean) {
        val until = System.nanoTime() + SECONDS.toNanos(4)
        do {
            if (predicate(thread.stackTrace)) return
            Thread.yield()
        } while (System.nanoTime() < until)
        fail("worker did not reach the expected boundary: ${thread.stackTrace.toList()}")
    }

    private fun id(provider: String) = "123e4567-e89b-12d3-a456-4266141740" + if (provider == "youtube") "10" else "11"
    private fun batch(query: String, provider: String): String {
        val url = if (provider == "youtube") "https://youtu.be/fixture" else "https://soundcloud.com/fixture/exact"
        return """{"query":"$query","results":[{"candidateId":"same-id","provider":"$provider","sourceUrl":"$url","title":"$provider","downloadable":true}],"providers":[{"provider":"$provider","status":"ok","resultCount":1}],"selectionSessionId":"${id(provider)}","selectionExpiresAt":"2030-01-01T00:00:00Z"}"""
    }
    private fun reply(body: String, code: Int = 200) = MockResponse.Builder().code(code).body(body).build()
}
