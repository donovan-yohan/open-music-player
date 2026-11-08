package com.soundq.android.data

import com.soundq.android.data.discovery.*
import com.soundq.android.data.imports.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*

/** Source A recovery retires the captured admission of distinct selected job B. */
class DiscoveryRecoveryIdentityRepairTest {
    private val sourceJob = "123e4567-e89b-12d3-a456-426614174071"
    private val siblingJob = "123e4567-e89b-12d3-a456-426614174099"
    private val decisionId = "123e4567-e89b-12d3-a456-426614174020"
    private fun sibling() = """{"job_id":"$siblingJob","status":"complete","progress":100,"track_id":99,"source_type":"youtube","created_at":"2026-10-29T00:00:00Z"}"""

    @Test fun attachmentOnlyRecoveryRetiresSiblingCheckCapturedBeforeAdmission() = recoveryRace(open = false, published = false)
    @Test fun attachmentOnlyRecoveryRetiresSiblingLibraryOpenCapturedBeforeAdmission() = recoveryRace(open = true, published = false)
    @Test fun publishedRecoveryStillRetiresSiblingCheckAndReadsActualSourceJob() = recoveryRace(open = false, published = true)

    private fun recoveryRace(open: Boolean, published: Boolean) {
        HttpsFixture().use { f ->
            val session = playlistSession(f)
            val api = SoundQApi(session, f.client)
            val library = LibraryRepository(session, api::library, api::like)
            val imports = ImportRepository(session, api, library)
            val discovery = DiscoveryRepository(session, api)
            val route = discovery.open()!!
            val view = imports.open()!!
            discovery.edit(route, "海 & music")
            f.reply(DiscoveryBoundaryTest.search()); discovery.search(route, discovery.state.value.draft)
            val choice = discovery.inspect(route, discovery.state.value.results!!.rows.single())!!
            val post = imports.claimSource(view, choice)!!
            f.reply(DiscoveryOwnershipTest.decision(), 201); f.reply("{}", 500); imports.submit(post)
            assertEquals(SourceImportPhase.QueueUncertain, imports.state.value.sourceReceipt!!.phase)
            f.reply("""{"jobs":[${sibling()}]}"""); imports.recent(view)
            imports.select(view, imports.state.value.recent.single())
            assertEquals(siblingJob, imports.state.value.selected!!.id.value)
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            val pool = Executors.newSingleThreadExecutor()
            imports.beforeIdentityReadAdmission = { entered.countDown(); check(release.await(10, TimeUnit.SECONDS)) }
            try {
                val old = pool.submit<Boolean> { if (open) imports.openLibrary(view) else { imports.check(view); false } }
                assertTrue("Sibling job capture reached the pre-admission boundary", entered.await(3, TimeUnit.SECONDS))
                f.reply(DiscoveryOwnershipTest.decision(",\"downloadJobId\":\"$sourceJob\""))
                f.reply(if (published) DiscoveryPublicationRepairTest.job() else "{}", if (published) 200 else 404)
                imports.recoverSource(view, imports.state.value.sourceReceipt!!)
                assertNull(imports.state.value.selected)
                assertFalse(imports.state.value.loading)
                assertTrue(imports.state.value.consumed)
                assertEquals(decisionId, imports.state.value.sourceReceipt!!.decision!!.id)
                val before = f.server.requestCount
                assertEquals(6, before)
                // This reply is a trap: stale admission would consume it and restore job B.
                f.reply(if (open) """{"tracks":[{"id":99,"title":"Wrong sibling","is_liked":false}],"total":1,"limit":20,"offset":0}""" else sibling())
                release.countDown()
                assertFalse(old.get(5, TimeUnit.SECONDS))
                assertEquals("Recovery must permanently retire captured sibling admission", before, f.server.requestCount)
                assertNull(imports.state.value.selected)
                assertTrue(library.state.value.rows.isEmpty())
                assertFalse(library.state.value.loading)
                // Replace the unused trap without a network request before the intended continuation.
                f.server.dispatcher = object : mockwebserver3.Dispatcher() {
                    override fun dispatch(request: mockwebserver3.RecordedRequest): mockwebserver3.MockResponse {
                        val path = request.url.encodedPath
                        val body = when {
                            request.method == "POST" && path == "/api/v1/queue/items" -> """{"queue":{"items":[]},"downloadJobId":"$sourceJob","idempotent":true}"""
                            path == "/api/v1/downloads/$sourceJob" -> DiscoveryPublicationRepairTest.job()
                            path == "/api/v1/library" -> """{"tracks":[{"id":71,"title":"Recovered source","is_liked":false}],"total":1,"limit":20,"offset":0}"""
                            else -> error("Unexpected continuation: ${request.method} $path")
                        }
                        return mockwebserver3.MockResponse.Builder().body(body).build()
                    }
                }
                imports.beforeIdentityReadAdmission = null
                if (!published) {
                    assertNull(imports.state.value.acknowledgement)
                    assertEquals(SourceImportPhase.QueueRefused, imports.state.value.sourceReceipt!!.phase)
                    imports.another(view); assertTrue(imports.state.value.consumed)
                    imports.retrySource(view, imports.state.value.sourceReceipt!!)
                }
                imports.check(view)
                assertEquals(sourceJob, imports.state.value.selected!!.id.value)
                assertTrue(imports.openLibrary(view))
                assertEquals(listOf(TrackId(71)), library.state.value.rows.map { it.id })
                assertFalse(imports.state.value.loading)
                assertFalse(library.state.value.loading)
                imports.submit(post)
                val expectedCount = if (published) 8 else 9
                assertEquals(expectedCount, f.server.requestCount)
                val requests = (1..expectedCount).map { f.server.takeRequest(2, TimeUnit.SECONDS)!! }
                assertEquals(1, requests.count { it.method == "POST" && it.url.encodedPath == "/api/v1/source-selections" })
                assertEquals(if (published) 1 else 2, requests.count { it.method == "POST" && it.url.encodedPath == "/api/v1/queue/items" })
                assertFalse(requests.any { it.url.encodedPath == "/api/v1/downloads/$siblingJob" })
                assertEquals(1, requests.count { it.url.encodedPath == "/api/v1/library" })
            } finally {
                release.countDown(); imports.beforeIdentityReadAdmission = null
                pool.shutdownNow(); assertTrue(pool.awaitTermination(5, TimeUnit.SECONDS))
            }
        }
    }
}
