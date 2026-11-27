package com.soundq.android.data

import android.app.Application
import com.soundq.android.AppGraph
import com.soundq.android.data.originalimport.CommittedOriginal
import com.soundq.android.data.originalimport.OriginalImportCompositionTest
import com.soundq.android.data.originalimport.OriginalImportEntry
import com.soundq.android.data.originalimport.OriginalImportJournal
import com.soundq.android.data.originalimport.OriginalImportPhase
import com.soundq.android.data.originalimport.OriginalImportRepository
import kotlinx.coroutines.Job
import kotlinx.coroutines.job
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.RecordedRequest
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit.SECONDS
import java.util.concurrent.atomic.AtomicInteger

/** Exercise the real AppGraph callback after committed-import membership readback, not a copied plan. */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28], application = Application::class)
class LibraryOriginalImportRefreshTest {
    @Test fun heldImportReadIsReplacedAfterSameQueryLikeReadbackSettles() = Scenario().use { s ->
        val stale = s.beginImport()
        val like = s.like()
        try {
            assertTrue(like.readback.entered.await(5, SECONDS))
            val revision = s.library.state.value.pageRevision
            s.first.release.countDown()
            assertNull("retry must wait for the like readback", s.nextRequest(200))
            assertEquals(revision, s.library.state.value.pageRevision)
            assertEquals(listOf(TrackId(11)), s.ids)
            like.finish()
            s.join(stale)
            assertEquals("a bounded fresh read must restore the imported row", listOf(TrackId(77)), s.ids)
            assertEquals(s.query, s.library.state.value.query)
            assertEquals(MutationOutcome.ReadbackFailed, s.library.state.value.mutations[TrackId(11)])
            assertNull(s.library.state.value.error)
            s.assertReadCount(4)
        } finally { like.readback.release.countDown() }
    }

    @Test fun queryRoundTripRetiresHeldImportRead() = Scenario().use { s ->
        val stale = s.beginImport()
        s.library.refine(s.query.copy(text = "other"))
        s.takePage("other")
        s.library.refine(s.query)
        s.takePage(s.query.text)
        val accepted = s.library.state.value
        s.first.release.countDown()
        s.join(stale)
        assertSame(accepted, s.library.state.value)
        s.assertReadCount(4)
    }

    @Test fun accountRoundTripRetiresHeldImportRead() = Scenario().use { s ->
        val stale = s.beginImport()
        val foreign = s.fixture.signIn(s.graph, "2dc91581-2795-4d0a-b87d-25dbc35c8fc0")
        s.library.refine(s.query)
        s.takePage(s.query.text)
        assertEquals(foreign.epoch, s.library.projectionScope(s.library.state.value)?.epoch)
        val returned = s.fixture.signIn(s.graph)
        s.library.refine(s.query)
        s.takePage(s.query.text)
        val accepted = s.library.state.value
        s.first.release.countDown()
        s.join(stale)
        assertSame(accepted, s.library.state.value)
        assertEquals(returned.epoch, s.library.projectionScope(accepted)?.epoch)
        s.assertReadCount(4)
    }

    @Test fun secondSupersessionDoesNotStartAThirdImportRead() = Scenario(holdRetry = true).use { s ->
        val refresh = s.beginImport()
        s.like().finish()
        s.first.release.countDown()
        assertTrue("replacement GET was not admitted", s.retry.entered.await(4, SECONDS))
        s.takePage(s.query.text)
        s.reconcile()
        val accepted = s.library.state.value
        s.retry.release.countDown()
        s.join(refresh)
        assertSame(accepted, s.library.state.value)
        assertEquals(listOf(TrackId(11)), s.ids)
        assertEquals(s.query, s.library.state.value.query)
        s.assertReadCount(5)
    }

    @Test fun ordinaryPageFailureDoesNotRetryImportRead() = Scenario(firstStatus = 503).use { s ->
        val stale = s.beginImport()
        val accepted = s.library.state.value
        s.first.release.countDown()
        s.join(stale)
        assertSame(accepted, s.library.state.value)
        s.assertReadCount(2)
    }

    @Test fun unsupersededImportReadPublishesOnce() = Scenario().use { s ->
        val read = s.beginImport()
        s.first.release.countDown()
        s.join(read)
        assertEquals(listOf(TrackId(11), TrackId(77)), s.ids)
        assertEquals(s.query, s.library.state.value.query)
        s.assertReadCount(2)
    }

    @Test fun importReadDeniedBeforeHeadersResumesAfterTheSave() = importReadAtRotation("saving")

    @Test fun importReadDeniedBeforeHeadersResumesEvenIfSaveFinishedBeforeCatch() = importReadAtRotation("already-saved")

    @Test fun failedSaveOrRetiredQueryOrScopeCannotResumeTheUnsentImportRead() {
        importReadAtRotation("save-failed")
        importReadAtRotation("query-retired")
        importReadAtRotation("scope-retired")
    }

    @Test fun importReadThatEnteredHeadersIsNotResentAfterTheSave() = importReadAtRotation("entered")

    private fun importReadAtRotation(end: String) = OriginalImportCompositionTest.Fixture(seedReceipt = false).use { fixture ->
        val saving = Barrier()
        val beforeHeaders = Barrier()
        val terminalCall = Barrier()
        val enteredGet = Barrier()
        val arm = java.util.concurrent.atomic.AtomicBoolean()
        val firstCall = java.util.concurrent.atomic.AtomicReference<okhttp3.Call>()
        val headers = AtomicInteger()
        val reads = AtomicInteger()
        val savedGet = AtomicInteger()
        val entered = end == "entered"
        val failSave = java.util.concurrent.atomic.AtomicBoolean(end == "save-failed")
        val store = object : SessionStore by MemoryStore() {
            override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) {
                if (tokens.access != "rotated-access") return
                saving.await()
                if (failSave.get()) throw java.io.IOException("fixture save failed")
            }
        }
        val listener = object : okhttp3.EventListener() {
            override fun connectionAcquired(call: okhttp3.Call, connection: okhttp3.Connection) {
                if (arm.get() && call.request().url.queryParameter("q") == "matches" && firstCall.compareAndSet(null,call) && !entered)
                    beforeHeaders.await() // TLS is connected; SoundQ's real header guard has not run.
            }
            override fun requestHeadersStart(call: okhttp3.Call) {
                if (arm.get() && call.request().url.queryParameter("q") == "matches") headers.incrementAndGet()
            }
            override fun callFailed(call: okhttp3.Call, ioe: java.io.IOException) {
                if (!entered && call === firstCall.get()) terminalCall.await()
            }
        }
        fixture.graph("fixture",memory=store,listener=listener).use { graph ->
            val scope = fixture.signIn(graph)
            val query = LibraryQuery(text="matches")
            val library = graph.library
            val intent = fixture.intent
            OriginalImportJournal(File(graph.directory,"original-import.v1.json")).put(
                OriginalImportEntry(intent,OriginalImportPhase.ReadbackRequired,CommittedOriginal(fixture.track,intent.original.revision)),null) { true }
            fun page(id: Int) = fixture.reply(200,"""{"tracks":[{"id":$id,"title":"Track $id"}],"total":1,"offset":0,"limit":20}""")
            fixture.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = when (request.method to request.url.encodedPath) {
                    "GET" to fixture.memberPath -> fixture.member()
                    "POST" to "/api/v1/auth/refresh" -> fixture.reply(200,
                        """{"accessToken":"rotated-access","refreshToken":"rotated-refresh","user":{"id":"${scope.accountId}"}}""")
                    "GET" to "/api/v1/library" -> when (request.url.queryParameter("q")) {
                        "rotate" -> if (request.headers["Authorization"] == "Bearer rotated-access") page(33) else fixture.reply(401,"{}")
                        "matches" -> if (reads.incrementAndGet() == 1) page(11) else if (entered) {
                            enteredGet.await(); fixture.reply(503,"{}")
                        } else if (request.headers["Authorization"] == "Bearer rotated-access") {
                            savedGet.incrementAndGet(); page(77)
                        } else fixture.reply(500,"{}")
                        else -> fixture.reply(500,"{}")
                    }
                    else -> fixture.reply(500,"{}")
                }
            }
            val executor = Executors.newSingleThreadExecutor()
            try {
                library.refine(query)
                val accepted = library.state.value
                assertEquals(listOf(TrackId(11)),accepted.rows.map(Track::id))
                arm.set(true)
                val earlierJobs = graph.io.coroutineContext.job.children.toSet()
                assertEquals(OriginalImportRepository.Action.Added,graph.originalImports.check(scope,intent.operation) { true })
                assertTrue((if (entered) enteredGet else beforeHeaders).entered.await(5,SECONDS))
                val job = (graph.io.coroutineContext.job.children.toSet()-earlierJobs).single()
                val rotate = executor.submit<Boolean> { runCatching { graph.api.library(scope,LibraryQuery(text="rotate"),0) }.isSuccess }
                assertTrue(saving.entered.await(5,SECONDS))
                assertFalse(graph.session.remoteCurrent(scope))
                assertSame(accepted,library.state.value)
                if (entered) {
                    assertEquals(1,headers.get())
                    enteredGet.release.countDown()
                    runBlocking { withTimeout(5000) { job.join() } } // Entered failure is terminal, even while saving.
                } else {
                    beforeHeaders.release.countDown()
                    assertTrue(terminalCall.entered.await(5,SECONDS))
                    assertEquals("the original import GET did not send headers",0,headers.get())
                    assertEquals(1,reads.get())
                }
                if (end == "already-saved" || end == "save-failed") {
                    saving.release.countDown()
                    assertEquals(end != "save-failed",rotate.get(5,SECONDS))
                    if (end == "save-failed") {
                        failSave.set(false)
                        assertTrue(graph.session.retrySave()) // Later readiness cannot turn the failed flight into success.
                    }
                    assertTrue(graph.session.remoteCurrent(scope))
                }
                terminalCall.release.countDown()
                if (end == "query-retired") {
                    library.retire()
                    runBlocking { withTimeout(5000) { job.join() } }
                }
                if (end == "scope-retired") {
                    graph.session.beginIntent()
                    runBlocking { withTimeout(5000) { job.join() } }
                }
                saving.release.countDown()
                val rotated = end !in setOf("save-failed","scope-retired")
                assertEquals(rotated,rotate.get(5,SECONDS))
                runBlocking { withTimeout(5000) { job.join() } }
                assertFalse(job.isCancelled)
                val shouldResume = end in setOf("saving","already-saved")
                assertEquals("only the owed unsent read may use the newly saved credentials",if (shouldResume) 1 else 0,savedGet.get())
                assertEquals(if (shouldResume || entered) 1 else 0,headers.get())
                assertEquals(if (shouldResume || entered) 2 else 1,reads.get())
                assertEquals(4 + (if (rotated) 1 else 0) + (if (shouldResume || entered) 1 else 0),fixture.server.requestCount)
                if (shouldResume) {
                    assertEquals(query,library.state.value.query)
                    assertEquals(listOf(TrackId(77)),library.state.value.rows.map(Track::id))
                } else if (end != "query-retired") assertSame(accepted,library.state.value)
            } finally {
                listOf(saving,beforeHeaders,terminalCall,enteredGet).forEach { it.release.countDown() }
                executor.shutdownNow()
                assertTrue(executor.awaitTermination(5,SECONDS))
            }
        }
    }

    @Test fun collectionReadyBeforeImportCallbackRetainsRowsUntilExplicitPlay() = CollectionScenario().use { s ->
        val play = s.claim()
        s.readCollection(play)
        val refresh = s.importCallback()
        s.assertWaiting(refresh, play)
        s.playOnce(play)
        s.finishRefresh(refresh)
    }

    @Test fun collectionClaimDuringImportGetDefersTheBoundedReplacementUntilExplicitPlay() = CollectionScenario().use { s ->
        val refresh = s.importCallback()
        val first = s.takeImportPage(66)
        val play = s.claim()
        s.readCollection(play)
        first.release.countDown()
        s.assertWaiting(refresh, play)
        s.playOnce(play)
        s.finishRefresh(refresh)
    }

    @Test fun equalCollectionAdmissionRoundTripDoesNotRevalidateAnEnteredImportGet() = CollectionScenario().use { s ->
        val refresh = s.importCallback()
        val first = s.takeImportPage(66)
        val before = s.library.state.value
        val play = s.claim()
        s.readCollection(play)
        s.playOnce(play)
        assertEquals(before, s.library.state.value)
        assertNotSame(before, s.library.state.value)
        first.release.countDown()
        s.finishRefresh(refresh)
    }

    @Test fun collectionFinishedBeforeImportAdmissionNeedsNoReplacement() = CollectionScenario().use { s ->
        val play = s.claim()
        s.readCollection(play)
        s.playOnce(play)
        s.finishRefresh(s.importCallback())
    }

    @Test fun abandonBeforeCollectionReadReleasesWaitingImportWithoutPlaying() = CollectionScenario().use { s ->
        val play = s.claim()
        val refresh = s.importCallback()
        s.assertWaiting(refresh, play)
        s.library.abandonCollection(play)
        s.assertCannotPlay(play)
        s.finishRefresh(refresh, playCount = 0)
    }

    @Test fun failedCollectionReadReleasesWaitingImportWithoutPlaying() = CollectionScenario().use { s ->
        val play = s.claim()
        val refresh = s.importCallback()
        s.assertWaiting(refresh, play)
        s.readCollection(play, status = 503)
        assertNotNull(s.library.state.value.collectionError)
        s.assertCannotPlay(play)
        s.finishRefresh(refresh, playCount = 0)
    }

    @Test fun failedImportGetIsNotRetriedEvenIfCollectionClaimOverlapped() = CollectionScenario().use { s ->
        val refresh = s.importCallback()
        val first = s.takeImportPage(66, status = 503)
        val play = s.claim()
        s.readCollection(play)
        first.release.countDown()
        s.join(refresh)
        s.playOnce(play)
        s.assertIdle(listOf(TrackId(11)), playCount = 1)
    }

    @Test fun secondCollectionSupersessionDoesNotAdmitAThirdImportGet() = CollectionScenario().use { s ->
        val refresh = s.importCallback()
        val first = s.takeImportPage(66)
        val play = s.claim()
        s.readCollection(play)
        first.release.countDown()
        s.assertWaiting(refresh, play)
        s.playOnce(play)
        val second = s.takeImportPage(77)
        val successor = s.claim()
        // Cleanup for the previous claim must not release the matching successor.
        s.library.abandonCollection(play)
        s.readCollection(successor)
        second.release.countDown()
        s.join(refresh)
        s.playOnce(successor)
        s.assertIdle(listOf(TrackId(11)), playCount = 2)
    }

    /** The original-import membership GET reaches AppGraph's real callback. Play uses the
     * repository's actual canonical-start callback, with a recorder at the queue boundary. */
    private class CollectionScenario : AutoCloseable {
        private val fixture = OriginalImportCompositionTest.Fixture(seedReceipt = false)
        private val graph = fixture.graph("fixture")
        private val scope = fixture.signIn(graph)
        val library = graph.library
        private val query = LibraryQuery(text = "mix", liked = true, sort = LibrarySort.Title, ascending = true)
        private val responses = java.util.concurrent.LinkedBlockingQueue<Step>()
        private val executor = Executors.newSingleThreadExecutor()
        private val starts = mutableListOf<Pair<List<TrackId>, Int>>()
        private val barriers = mutableListOf<Barrier>()
        private var requestCount = 0

        private class Step(val barrier: Barrier, val response: MockResponse)

        init {
            val intent = fixture.intent
            OriginalImportJournal(File(fixture.directory, "original-import.v1.json")).put(
                OriginalImportEntry(intent, OriginalImportPhase.ReadbackRequired, CommittedOriginal(fixture.track, intent.original.revision)), null) { true }
            fixture.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = when (request.method to request.url.encodedPath) {
                    "GET" to fixture.memberPath -> fixture.member()
                    "GET" to "/api/v1/library" -> {
                        val step = responses.poll(6, SECONDS) ?: returnFailure()
                        step.barrier.await()
                        step.response
                    }
                    else -> fixture.reply(500, "{}")
                }
            }
            page(11).release.countDown()
            library.refine(query)
            takePage()
        }

        private fun returnFailure(): Step = Step(Barrier().also { it.release.countDown() }, fixture.reply(500, "{}"))

        private fun page(vararg ids: Int, status: Int = 200): Barrier {
            val rows = ids.joinToString(",") { """{"id":$it,"title":"mix $it","is_liked":true}""" }
            val body = if (status == 200) """{"tracks":[$rows],"total":${ids.size},"limit":20,"offset":0}""" else "{}"
            val barrier = Barrier().also { barriers += it }
            responses.add(Step(barrier, fixture.reply(status, body)))
            return barrier
        }

        private fun takePage(text: String = query.text) {
            val req = fixture.next("/api/v1/library").also { requestCount++ }
            assertEquals("GET", req.method)
            assertEquals("0", req.url.queryParameter("offset"))
            assertEquals(text, req.url.queryParameter("q"))
            assertEquals("true", req.url.queryParameter("liked"))
            assertEquals("title", req.url.queryParameter("sort"))
            assertEquals("asc", req.url.queryParameter("order"))
        }

        fun importCallback(): Job {
            val previous = graph.io.coroutineContext.job.children.toSet()
            assertEquals(OriginalImportRepository.Action.Added, graph.originalImports.check(scope, fixture.intent.operation) { true })
            assertEquals("GET", fixture.next(fixture.memberPath).method)
            requestCount++
            return (graph.io.coroutineContext.job.children.toSet() - previous).single()
        }

        fun claim() = checkNotNull(library.claimCollectionPlay(library.state.value, selected = TrackId(11)) { true })

        fun readCollection(play: LibraryRepository.CollectionRequest, status: Int = 200) {
            page(9, 11, status = status).release.countDown()
            executor.submit { library.readCollection(play) }.get(5, SECONDS)
            takePage()
        }

        fun assertWaiting(refresh: Job, play: LibraryRepository.CollectionRequest) {
            assertNull("import GET must wait for the matching collection release", fixture.server.takeRequest(300, java.util.concurrent.TimeUnit.MILLISECONDS))
            assertFalse(refresh.isCompleted)
            assertSame(play.expected.rows, library.state.value.rows)
            assertTrue(library.state.value.collectionLoading)
        }

        fun playOnce(play: LibraryRepository.CollectionRequest) {
            val before = starts.size
            library.startCollection(play) { tracks, index ->
                assertTrue(library.collectionPlaybackCurrent(play))
                assertSame(play.expected.rows, library.state.value.rows)
                starts += tracks.map(Track::id) to index
                null
            }
            assertEquals("explicit collection Play must reach canonical start", before + 1, starts.size)
            assertEquals(listOf(TrackId(9), TrackId(11)) to 1, starts.last())
            assertCannotPlay(play)
        }

        fun assertCannotPlay(play: LibraryRepository.CollectionRequest) {
            library.startCollection(play) { _, _ -> throw AssertionError("retired claim must not send Play") }
        }

        fun takeImportPage(id: Int, status: Int = 200): Barrier = page(id, status = status).also {
            takePage()
            assertTrue(it.entered.await(5, SECONDS))
        }

        fun finishRefresh(refresh: Job, playCount: Int = 1) {
            takeImportPage(77).release.countDown()
            join(refresh)
            assertIdle(listOf(TrackId(77)), playCount)
        }

        fun join(job: Job) = runBlocking { withTimeout(5000) { job.join() }; assertFalse(job.isCancelled) }

        fun assertIdle(ids: List<TrackId>, playCount: Int) {
            assertEquals(ids, library.state.value.rows.map(Track::id))
            assertEquals(query, library.state.value.query)
            assertEquals(playCount, starts.size)
            assertFalse(library.state.value.collectionLoading)
            assertEquals(requestCount, fixture.server.requestCount)
        }

        override fun close() {
            barriers.forEach { it.release.countDown() }
            executor.shutdownNow()
            try { graph.close() } finally { fixture.close() }
        }
    }

    private class Barrier {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        fun await() { entered.countDown(); check(release.await(10, SECONDS)) }
    }

    private class Scenario(firstStatus: Int = 200, holdRetry: Boolean = false) : AutoCloseable {
        val fixture = OriginalImportCompositionTest.Fixture(seedReceipt = false)
        val graph = fixture.graph("fixture")
        private val scope = fixture.signIn(graph)
        val library = graph.library
        val query = LibraryQuery(text = "mix", liked = true, sort = LibrarySort.Title, ascending = true)
        val ids get() = library.state.value.rows.map(Track::id)
        val first = Barrier()
        val retry = Barrier()
        private val readback = Barrier()
        private val reads = AtomicInteger()
        private val unlikeCount = AtomicInteger()
        private val membershipCount = AtomicInteger()
        private val executor = Executors.newSingleThreadExecutor()
        private var requestsConsumed = 0
        @Volatile private var unlike = false

        init {
            val intent = fixture.intent
            OriginalImportJournal(File(fixture.directory, "original-import.v1.json")).put(
                OriginalImportEntry(intent, OriginalImportPhase.ReadbackRequired, CommittedOriginal(fixture.track, intent.original.revision)), null) { true }
            fixture.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = when (request.method to request.url.encodedPath) {
                    "GET" to fixture.memberPath -> { membershipCount.incrementAndGet(); fixture.member() }
                    "DELETE" to "/api/v1/library/tracks/11/like" -> {
                        unlike = true
                        unlikeCount.incrementAndGet()
                        fixture.reply(200, "{}")
                    }
                    "GET" to "/api/v1/library" -> when (reads.incrementAndGet()) {
                        1 -> page(11)
                        2 -> { first.await(); if (firstStatus == 200) page(11, 77) else fixture.reply(firstStatus, "{}") }
                        3 -> if (unlike) { readback.await(); fixture.reply(503, "{}") } else page(22)
                        4 -> if (unlike) { if (holdRetry) retry.await(); page(77) } else page(33)
                        5 -> if (holdRetry) page(11, liked = false) else fixture.reply(500, "{}")
                        else -> fixture.reply(500, "{}")
                    }
                    else -> fixture.reply(500, "{}")
                }
            }
            library.refine(query)
            assertEquals(listOf(TrackId(11)), ids)
            assertPage(fixture.next("/api/v1/library").also { requestsConsumed++ })
        }

        private fun page(vararg ids: Int, liked: Boolean = true): MockResponse {
            val rows = ids.joinToString(",") { """{"id":$it,"title":"mix $it","is_liked":$liked}""" }
            return fixture.reply(200, """{"tracks":[$rows],"total":${ids.size},"limit":20,"offset":0}""")
        }

        fun beginImport(): Job {
            val existing = graph.io.coroutineContext.job.children.toSet()
            assertEquals(OriginalImportRepository.Action.Added, graph.originalImports.check(scope, fixture.intent.operation) { true })
            assertEquals("GET", fixture.next(fixture.memberPath).method)
            requestsConsumed++
            assertTrue(first.entered.await(5, SECONDS))
            assertPage(fixture.next("/api/v1/library").also { requestsConsumed++ })
            return (graph.io.coroutineContext.job.children.toSet() - existing).single()
        }

        fun nextRequest(timeoutMs: Long) = fixture.server.takeRequest(timeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS)
        fun takePage(text: String) = assertPage(fixture.next("/api/v1/library").also { requestsConsumed++ }, text)
        fun reconcile() {
            library.reconcileLike(scope, TrackId(11))
            val request = fixture.next("/api/v1/library")
            requestsConsumed++
            assertEquals("GET", request.method)
            assertNull(request.url.queryParameter("q"))
            assertNull(request.url.queryParameter("liked"))
            assertEquals(false, library.state.value.rows.single().liked)
        }
        fun like(): LikeWork {
            val row = library.state.value.rows.single()
            val result = executor.submit { library.like(row) }
            assertEquals("DELETE", fixture.next("/api/v1/library/tracks/11/like").method)
            requestsConsumed++
            assertPage(fixture.next("/api/v1/library").also { requestsConsumed++ })
            return LikeWork(readback) { result.get(5, SECONDS) }
        }

        class LikeWork(val readback: Barrier, private val settled: () -> Unit) {
            fun finish() { readback.release.countDown(); settled() }
        }

        fun join(job: Job) = runBlocking { withTimeout(5000) { job.join() }; assertFalse(job.isCancelled) }

        private fun assertPage(req: RecordedRequest, text: String = query.text) {
            assertEquals("GET", req.method)
            assertEquals("0", req.url.queryParameter("offset"))
            assertEquals(text, req.url.queryParameter("q"))
            assertEquals("true", req.url.queryParameter("liked"))
            assertEquals("title", req.url.queryParameter("sort"))
            assertEquals("asc", req.url.queryParameter("order"))
        }

        fun assertReadCount(total: Int) {
            assertEquals(total, reads.get())
            assertEquals(1, membershipCount.get())
            assertEquals(if (unlike) 1 else 0, unlikeCount.get())
            while (requestsConsumed < total + 1 + unlikeCount.get()) {
                val request = fixture.next("/api/v1/library")
                assertPage(request)
                requestsConsumed++
            }
            // All callback work joined; no upload replay, play/descriptor request, or other wire side effect.
            assertEquals(requestsConsumed, fixture.server.requestCount)
        }

        override fun close() {
            first.release.countDown()
            retry.release.countDown()
            readback.release.countDown()
            executor.shutdown()
            try {
                check(executor.awaitTermination(5, SECONDS))
                graph.close()
            } finally { fixture.close() }
        }
    }
}
