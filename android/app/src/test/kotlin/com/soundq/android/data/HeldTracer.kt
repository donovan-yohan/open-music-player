package com.soundq.android.data

import com.soundq.android.data.discovery.*
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.RecordedRequest
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*
import java.util.concurrent.TimeUnit.SECONDS

class HeldTracer {
    @Test fun eitherProviderCanPublishAnExactChoiceBeforePeerRelease() {
        for (first in SourceProvider.entries) HttpsFixture().use { fixture ->
            val session = AccountSession(fixture.endpoint, MemoryStore()).apply {
                accept(beginIntent(), SecretTokens("a", "r", "A"))
            }
            val repo = DiscoveryRepository(session, SoundQApi(session, fixture.client))
            val view = repo.open()!!
            val peer = SourceProvider.entries.single { it != first }
            val release = CountDownLatch(1)
            val executor = Executors.newSingleThreadExecutor()
            fixture.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val provider = request.url.queryParameter("providers")
                    if (provider != first.wire) check(release.await(8, SECONDS))
                    val payload = if (provider != peer.wire) first else peer
                    val url = if (payload == SourceProvider.YouTube) "https://youtu.be/fixture" else "https://soundcloud.com/fixture/held"
                    return MockResponse.Builder().body("""{"query":"held fixture","results":[{"candidateId":"same-id","provider":"${payload.wire}","sourceUrl":"$url","title":"${payload.label}","downloadable":true}],"providers":[{"provider":"${payload.wire}","status":"ok","resultCount":1}],"selectionSessionId":"123e4567-e89b-12d3-a456-42661417401${payload.ordinal}","selectionExpiresAt":"2030-01-01T00:00:00Z"}""").build()
                }
            }
            try {
                repo.edit(view, "held fixture")
                val task = executor.submit { kotlinx.coroutines.runBlocking { repo.search(view, repo.state.value.draft) } }
                val requests = List(2) { fixture.server.takeRequest(2, SECONDS) }
                assertEquals("both singleton requests must enter TLS before peer release", setOf(first.wire, peer.wire), requests.map { it?.url?.queryParameter("providers") }.toSet())
                requests.forEach { assertEquals("Bearer a", it!!.headers["Authorization"]) }
                val until = System.nanoTime() + SECONDS.toNanos(3)
                while (repo.state.value.results?.rows.isNullOrEmpty() && System.nanoTime() < until) Thread.sleep(5)
                val early = checkNotNull(repo.state.value.results).rows.single()
                val choice = checkNotNull(repo.inspect(view, early))
                assertTrue(choice.valid())
                assertEquals(first, early.provider)
                assertEquals(1L, release.count)
                assertFalse(task.isDone)
                release.countDown()
                task.get(3, SECONDS)
                val rows = repo.state.value.results!!.rows
                assertEquals(listOf(first, peer), rows.map { it.provider })
                assertSame(early, rows.first())
                assertSame(choice, repo.state.value.inspected)
                assertTrue(choice.valid())
                assertEquals("123e4567-e89b-12d3-a456-42661417401${first.ordinal}", choice.selection.id)
                val late = checkNotNull(repo.inspect(view, rows.last()))
                assertEquals("123e4567-e89b-12d3-a456-42661417401${peer.ordinal}", late.selection.id)
                assertFalse(choice.valid())
                assertTrue(late.valid())
            } finally {
                release.countDown()
                executor.shutdownNow()
            }
        }
    }
}
