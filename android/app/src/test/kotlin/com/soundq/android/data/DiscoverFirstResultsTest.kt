package com.soundq.android.data

import com.soundq.android.data.discovery.*
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.RecordedRequest
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit.MILLISECONDS
import java.util.concurrent.TimeUnit.SECONDS

class DiscoverFirstResultsTest {
    @Test fun songUsesSourceOnlyWireAndPublishesAnExactSelection() {
        HttpsFixture().use { fixture ->
            val session = AccountSession(fixture.endpoint, MemoryStore()).apply {
                accept(beginIntent(), SecretTokens("a", "r", "A"))
            }
            val repo = DiscoveryRepository(session, SoundQApi(session, fixture.client))
            val route = repo.open()!!
            val soundcloud = """{"candidateId":"sc-exact","provider":"soundcloud","sourceUrl":"https://soundcloud.com/fixture/exact-remix","title":"Fixture exact remix","downloadable":true}"""
            fixture.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val provider = request.url.queryParameter("providers")!!
                    val body = """{"query":"fixture remix","results":[${DiscoveryBoundaryTest.candidate()},$soundcloud],"providers":[{"provider":"youtube","status":"ok"},{"provider":"soundcloud","status":"ok"}],"selectionSessionId":"123e4567-e89b-12d3-a456-426614174010","selectionExpiresAt":"2030-01-01T00:00:00Z"}"""
                    return MockResponse.Builder().body(singletonSongBody(body, provider)).headersDelay(140, MILLISECONDS).build()
                }
            }
            repo.edit(route, "fixture remix")
            val start = System.nanoTime()
            repo.searchBlocking(route, repo.state.value.draft)
            assertEquals(DiscoveryPhase.Ready, repo.state.value.phase)
            val rows = repo.state.value.results!!.rows
            assertEquals(SourceProvider.entries.toSet(), rows.map { it.provider }.toSet())
            val exact = rows.single {it.provider == SourceProvider.SoundCloud}
            val choice = repo.inspect(route, exact)!!
            val elapsedMs = (System.nanoTime() - start) / 1_000_000.0
            assertTrue(choice.valid())
            assertSame(exact, choice.candidate)
            assertEquals("sc-exact", choice.candidate.id)
            assertEquals("123e4567-e89b-12d3-a456-426614174079", choice.selection.id)
            val requests = fixture.takeSongRequests()
            println("both-settled fixture_ms=$elapsedMs")
            assertTrue(requests.all { it.url.encodedPath == "/api/v1/discovery/search" && it.headers["Authorization"] == "Bearer a" })
            assertEquals(2, fixture.server.requestCount)
        }
    }

    @Test fun hiddenSongFailureAndRetiredGroupedReplyCannotOverwriteTheVisibleQuery() {
        HttpsFixture().use { fixture ->
            val session = AccountSession(fixture.endpoint, MemoryStore()).apply {
                accept(beginIntent(), SecretTokens("a", "r", "A"))
            }
            val repo = DiscoveryRepository(session, SoundQApi(session, fixture.client))
            val route = repo.open()!!
            val releaseSource = CountDownLatch(1)
            val releaseGrouped = CountDownLatch(1)
            val threads = Executors.newFixedThreadPool(2)
            fixture.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = when (request.url.queryParameter("q")) {
                    "seed" -> if (request.url.queryParameter("providers") != "youtube,soundcloud,musicbrainz") {
                        check(releaseSource.await(5, SECONDS))
                        MockResponse.Builder().code(503).body("{}").build()
                    } else {
                        check(releaseGrouped.await(5, SECONDS))
                        MockResponse.Builder().body(DiscoveryGroupedJourneyTest.grouped()).build()
                    }
                    "empty fixture" -> MockResponse.Builder().body(singletonSongBody("""{"query":"empty fixture","results":[],"providers":[{"provider":"youtube","status":"ok"},{"provider":"soundcloud","status":"timeout"}]}""",request.url.queryParameter("providers")!!)).build()
                    else -> MockResponse.Builder().code(503).body("{}").build()
                }
            }
            try {
                repo.edit(route, "seed")
                val draft = repo.state.value.draft
                val source = repo.claimSearch(route, draft)!!
                val pendingSong = threads.submit { repo.searchBlocking(source) }
                fixture.takeSongRequests()
                val grouped = repo.selectType(route, DiscoveryResultType.Album)!!
                assertNull(repo.selectType(route, DiscoveryResultType.Artist))
                assertSame(draft, repo.state.value.draft)
                assertEquals(listOf("seed"), repo.state.value.recent)
                val pendingCatalog = threads.submit { repo.searchBlocking(grouped) }
                assertEquals("youtube,soundcloud,musicbrainz", fixture.server.takeRequest(2, SECONDS)!!.url.queryParameter("providers"))
                assertFalse(pendingSong.isDone)
                assertEquals(1L, releaseSource.count)
                releaseSource.countDown()
                pendingSong.get(3, SECONDS)
                assertEquals(DiscoveryPhase.Loading, repo.state.value.phase)
                assertNull(repo.state.value.error)

                assertNull(repo.selectType(route, DiscoveryResultType.Song))
                repo.edit(route, "empty fixture")
                repo.searchBlocking(route, repo.state.value.draft)
                assertEquals(DiscoveryPhase.Ready, repo.state.value.phase)
                val empty = repo.state.value.results!!
                assertTrue(empty.rows.isEmpty())
                assertTrue(empty.batches.all {it.selection==null})
                assertEquals(setOf("ok", "timeout"), empty.providers.map { it.status }.toSet())
                pendingCatalog.get(3, SECONDS)
                assertEquals(1L, releaseGrouped.count)
                releaseGrouped.countDown()
                assertSame(empty, repo.state.value.results)

                repo.edit(route, "failure fixture")
                repo.searchBlocking(route, repo.state.value.draft)
                assertEquals(DiscoveryPhase.Failed, repo.state.value.phase)
                assertNotNull(repo.state.value.error)
                assertTrue(repo.state.value.results!!.rows.isEmpty())
                assertTrue(repo.state.value.results!!.providers.all {it.status=="failed"})
                assertEquals(7, fixture.server.requestCount)
            } finally {
                releaseSource.countDown()
                releaseGrouped.countDown()
                threads.shutdownNow()
            }
        }
    }
}
