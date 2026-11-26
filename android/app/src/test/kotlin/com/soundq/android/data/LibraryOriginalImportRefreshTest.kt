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
