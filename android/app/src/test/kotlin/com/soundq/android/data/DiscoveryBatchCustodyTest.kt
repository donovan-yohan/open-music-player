package com.soundq.android.data

import com.soundq.android.data.discovery.*
import com.soundq.android.data.imports.ImportRepository
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import mockwebserver3.*
import okhttp3.Call
import okhttp3.EventListener
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.time.Instant
import java.util.concurrent.*
import java.util.concurrent.TimeUnit.SECONDS

class DiscoveryBatchCustodyTest {
    @Test fun consumingOneSessionDoesNotConsumeItsPeerAndExpiryDoesNotRetarget() {
        HttpsFixture().use { fixture ->
            val session = session(fixture)
            val api = SoundQApi(session, fixture.client)
            val intake = ImportRepository(session, api, LibraryRepository(session, api::library, api::like))
            val importView = intake.open()!!
            var now = Instant.parse("2028-01-01T00:00:00Z")
            val repo = DiscoveryRepository(session, api, now = { now })
            val view = repo.open()!!
            val posts = LinkedBlockingQueue<Pair<String, String>>()
            fixture.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val provider = request.url.queryParameter("providers")
                    if (request.url.encodedPath == "/api/v1/discovery/search" && provider != null) {
                        return reply(batch("exact", provider, if (provider == "youtube") "2029" else "2030"))
                    }
                    check(request.method == "POST" && request.url.encodedPath == "/api/v1/source-selections")
                    val body = Json.parseToJsonElement(request.body!!.utf8()).jsonObject
                    posts.add(body.getValue("sessionId").jsonPrimitive.content to body.getValue("candidateId").jsonPrimitive.content)
                    return MockResponse.Builder().code(400).build()
                }
            }
            repo.edit(view, "exact"); repo.searchBlocking(view, repo.state.value.draft)
            val (first, second) = repo.state.value.results!!.rows.sortedBy { it.provider.ordinal }
            assertEquals(SourceProvider.YouTube, first.provider)
            val choice = repo.inspect(view,first)!!
            val claimed = intake.claimSource(importView, choice)!!
            intake.submit(claimed)
            assertEquals(id("youtube") to "same-id", posts.poll(2, SECONDS))
            intake.another(importView)
            assertFalse(intake.prepareSource(importView, repo.inspect(view, first)!!))
            val peer = repo.inspect(view,second)!!
            now = Instant.parse("2029-06-01T00:00:00Z")
            assertNull(repo.inspect(view, first))
            assertSame(peer, repo.state.value.inspected)
            assertTrue(peer.valid())
            assertFalse(intake.sourceSessionConsumed(peer))
            assertTrue(intake.prepareSource(importView, peer))
            val next = intake.claimPlannedSource(importView, intake.state.value.sourcePlan!!)!!
            intake.submit(next)
            assertEquals(id("soundcloud") to "same-id", posts.poll(2, SECONDS))
            assertEquals(4, fixture.server.requestCount)
        }
    }

    @Test fun editCloseAndCallerCancellationAbortAlreadyDispatchedTlsCallsBeforeLateSuccess() {
        for (mode in listOf("edit", "close", "caller")) HttpsFixture().use { fixture ->
            val session = session(fixture)
            val canceled = LinkedBlockingQueue<String>()
            val client = fixture.client.newBuilder().eventListener(object : EventListener() {
                override fun callFailed(call: Call, ioe: IOException) {
                    if (call.isCanceled()) canceled.add(call.request().url.queryParameter("providers")!!)
                }
            }).build()
            val repo = DiscoveryRepository(session, SoundQApi(session, client))
            val view = repo.open()!!
            val release = CountDownLatch(1)
            fixture.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val q = request.url.queryParameter("q")!!
                    val provider = request.url.queryParameter("providers")!!
                    if (q == "obsolete") check(release.await(8, SECONDS))
                    return reply(batch(q, provider))
                }
            }
            val owner = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            try {
                repo.edit(view, "obsolete")
                val work = owner.launch { repo.search(view, repo.state.value.draft) }
                fixture.takeSongRequests()
                val replacement = when (mode) {
                    "edit" -> view.also { repo.edit(it, "fresh") }
                    "close" -> { repo.close(view); repo.open()!!.also {repo.edit(it,"fresh")} }
                    else -> view.also { work.cancel() }
                }
                val observed = List(2) { canceled.poll(3, SECONDS) }.toSet()
                assertEquals(mode, setOf("youtube", "soundcloud"), observed)
                runBlocking { withTimeout(3000) { work.join() } }
                assertEquals(1L, release.count)
                assertNull(repo.state.value.results)
                assertNull(repo.state.value.error)
                assertEquals(DiscoveryPhase.Idle, repo.state.value.phase)
                repo.edit(replacement, "fresh")
                repo.searchBlocking(replacement, repo.state.value.draft)
                val accepted = repo.state.value.results!!
                assertEquals("fresh", accepted.query)
                assertEquals(2, accepted.rows.size)
                release.countDown()
                assertSame(accepted, repo.state.value.results)
                assertEquals(4, fixture.server.requestCount)
            } finally { release.countDown(); owner.cancel() }
        }
    }

    @Test fun emptyAndFailedPeersDoNotInventRowsOrHideAPositiveBatch() {
        HttpsFixture().use { fixture ->
            val session = session(fixture)
            val repo = DiscoveryRepository(session, SoundQApi(session, fixture.client))
            val view = repo.open()!!
            fixture.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val q = request.url.queryParameter("q")!!
                    val p = request.url.queryParameter("providers")!!
                    return when (q) {
                        "empty" -> reply(empty(q,p,"ok"))
                        "partial-empty" -> reply(empty(q,p,if(p=="youtube") "ok" else "timeout"))
                        "no-provider" -> reply(empty(q,p,"timeout"))
                        "network-failure" -> MockResponse.Builder().code(503).build()
                        "wrong-provider" -> reply(if(p=="youtube") batch(q,"soundcloud") else empty(q,p,"ok"))
                        "shared-session" -> reply(batch(q,p).replace(id(p),id("youtube")))
                        else -> if(p=="youtube") reply(batch(q,p)) else MockResponse.Builder().code(503).build()
                    }
                }
            }
            for (q in listOf("empty","partial-empty","no-provider","network-failure","wrong-provider","partial-result","shared-session")) {
                repo.edit(view,q); repo.searchBlocking(view,repo.state.value.draft)
                val state = repo.state.value
                assertFalse(state.pendingProviders)
                val result = state.results!!
                assertEquals(q,result.query)
                assertEquals(2,result.providers.size)
                val expectedError = when(q) {
                    "no-provider" -> SafeFailure.Reason.ServiceUnavailable
                    "network-failure" -> SafeFailure.Reason.Refused
                    else -> null
                }
                assertEquals(q,expectedError,state.error)
                assertEquals(q,if(expectedError==null)DiscoveryPhase.Ready else DiscoveryPhase.Failed,state.phase)
                if(q in listOf("partial-result","shared-session")) {
                    val choice=repo.inspect(view,result.rows.single())!!
                    assertEquals(id("youtube"),choice.selection.id)
                    assertTrue(choice.valid())
                } else {
                    assertTrue(result.rows.isEmpty())
                    assertTrue(result.batches.all {it.selection==null})
                }
                assertEquals(q in listOf("wrong-provider","network-failure","partial-result","shared-session"),result.providers.any {it.status=="failed"})
            }
            assertEquals(14,fixture.server.requestCount)
        }
    }

    private fun session(fixture: HttpsFixture) = AccountSession(fixture.endpoint, MemoryStore()).apply {
        accept(beginIntent(), SecretTokens("a", "r", "A"))
    }
    private fun id(provider: String) = "123e4567-e89b-12d3-a456-4266141740" + if (provider == "youtube") "10" else "11"
    private fun batch(q: String, provider: String, year: String = "2030"): String {
        val url = if (provider == "youtube") "https://youtu.be/fixture" else "https://soundcloud.com/fixture/exact"
        return """{"query":"$q","results":[{"candidateId":"same-id","provider":"$provider","sourceUrl":"$url","title":"$provider","downloadable":true}],"providers":[{"provider":"$provider","status":"ok","resultCount":1}],"selectionSessionId":"${id(provider)}","selectionExpiresAt":"$year-01-01T00:00:00Z"}"""
    }
    private fun empty(q: String, p: String, status: String) = """{"query":"$q","results":[],"providers":[{"provider":"$p","status":"$status","resultCount":0}]}"""
    private fun reply(body: String) = MockResponse.Builder().body(body).build()
}
