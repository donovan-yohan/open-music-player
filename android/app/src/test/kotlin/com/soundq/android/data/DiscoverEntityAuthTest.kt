package com.soundq.android.data

import com.soundq.android.data.catalog.ArtistMbid
import com.soundq.android.data.catalog.ReleaseGroupMbid
import com.soundq.android.data.catalog.ReleaseMbid
import com.soundq.android.data.discovery.DiscoverBrowseJson
import com.soundq.android.data.discovery.DiscoverBrowsePage
import com.soundq.android.data.discovery.DiscoverBrowseSong
import com.soundq.android.data.discovery.DiscoverBrowseRoute
import com.soundq.android.data.discovery.DiscoveryCalls
import com.soundq.android.data.discovery.DiscoveryRepository
import com.soundq.android.data.discovery.SourceProvider
import com.soundq.android.product.discovery.EntityBrowseSlot
import com.soundq.android.product.discovery.EntityBrowseVisit
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit.SECONDS
import kotlinx.coroutines.*
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.RecordedRequest
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.Response
import org.junit.Assert.*
import org.junit.Test

class DiscoverEntityAuthTest {
    private val artist = ArtistMbid("821797e1-94c0-4e9c-88be-b49f971ada3b")
    private val group = ReleaseGroupMbid("b139f140-6a40-4dd5-af24-d7df33beb6a9")
    private val edition = ReleaseMbid("4d7b84cb-78e2-4c5d-9c00-29f7fe52cd21")

    @Test fun admittedDetailResponseSurvivesSiblingRefreshSaveWithoutReplay() = siblingRefresh(retireVisit = false)
    @Test fun exitingDetailDuringSiblingRefreshPermanentlyRetiresHeldRead() = siblingRefresh(retireVisit = true)

    private fun siblingRefresh(retireVisit: Boolean) = HttpsFixture().use { fixture ->
        val saveEntered = CountDownLatch(1)
        val releaseSave = CountDownLatch(1)
        val releaseDetail = CountDownLatch(1)
        val responseThread = CompletableFuture<Thread>()
        val store = object : SessionStore {
            override fun load(endpoint: ApiEndpoint): SecretTokens? = null
            override fun clear() = Unit
            override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) {
                if (tokens.access == "rotated") {
                    saveEntered.countDown()
                    check(releaseSave.await(8, SECONDS))
                }
            }
        }
        val session = AccountSession(fixture.endpoint, store)
        assertTrue(session.accept(session.beginIntent(), SecretTokens("fixture-access", "fixture-refresh", "fixture-account")))
        val scope = checkNotNull(session.capture())
        val route = DiscoverBrowseRoute.TopTracks(artist)
        val path = "/api/v1" + route.path(fixture.endpoint.base)
        val client = fixture.client.newBuilder().eventListener(object : EventListener() {
            override fun responseHeadersEnd(call: Call, response: Response) {
                if (response.request.url.encodedPath == path) responseThread.complete(Thread.currentThread())
            }
        }).build()
        val api = SoundQApi(session, client)
        val repo = DiscoveryRepository(session, api, unifiedSearch = true)
        val view = checkNotNull(repo.open())
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        fixture.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = MockResponse.Builder().apply {
                val q = request.url.queryParameter("q")
                val p = request.url.queryParameter("providers")
                when (request.url.encodedPath) {
                    path -> {
                        check(releaseDetail.await(8, SECONDS))
                        body("""{"results":[{"recordingMbid":"7c50feaa-cd49-4887-9904-309e67c27870","title":"Held track","listenCount":41}]}""")
                    }
                    "/api/v1/auth/refresh" -> body(fixture.auth("fixture-account", "rotated"))
                    "/api/v1/discovery/catalog" -> body(if (request.url.queryParameter("kind") == "artist")
                        """{"results":[{"kind":"artist","id":"${artist.value}","title":"Fixture artist"}],"hasMore":false}"""
                        else """{"results":[],"hasMore":false}""")
                    "/api/v1/discovery/search" -> if (q == "sibling" && request.headers["Authorization"] == "Bearer fixture-access") {
                        code(401)
                    } else body("""{"query":"$q","results":[],"providers":[{"provider":"$p","status":"ok"}]}""")
                    else -> code(404)
                }
            }.build()
        }
        try {
            repo.edit(view, "Fixture artist")
            repo.searchBlocking(view, repo.state.value.draft)
            repeat(4) { checkNotNull(fixture.server.takeRequest(4, SECONDS)) }
            val details = checkNotNull(repo.details(view, repo.state.value.results!!.entities.single()))
            val visit = EntityBrowseVisit(details.valid)
            val slot = EntityBrowseSlot { song: DiscoverBrowseSong -> song.recording }
            val detail = owner.async {
                slot.load(visit, debounce = false, fetch = { _, calls, valid ->
                    val songs = DiscoverBrowseJson.topTracks(api.discoverBrowseBody(details.scope, route, calls, valid))
                    DiscoverBrowsePage(songs, null, false)
                }, onAccepted = { _, _ -> })
            }
            val admitted = checkNotNull(fixture.server.takeRequest(4, SECONDS))
            assertEquals(path, admitted.url.encodedPath)
            assertEquals("GET", admitted.method)
            assertEquals("Bearer fixture-access", admitted.headers["Authorization"])
            val sibling = owner.async { api.discoverySearch(scope, "sibling", provider = SourceProvider.YouTube) }
            assertTrue("rotation did not enter secure save", saveEntered.await(4, SECONDS))
            assertFalse(session.remoteCurrent(scope))
            assertEquals("sibling", fixture.server.takeRequest(4, SECONDS)!!.url.queryParameter("q"))
            val refresh = checkNotNull(fixture.server.takeRequest(4, SECONDS))
            assertEquals("POST", refresh.method)
            assertEquals("/api/v1/auth/refresh", refresh.url.encodedPath)
            releaseDetail.countDown()
            val reader = responseThread.get(4, SECONDS)
            // Witness the response consumer while persistence is still held; server receipt alone
            // would let a prematurely released save hide the ordinary-auth rejection.
            val deadline = System.nanoTime() + SECONDS.toNanos(4)
            fun joinedSave() = reader.stackTrace.any { it.className == AccountSession::class.java.name && it.methodName.substringBefore('$') == "awaitDiscoveryRead" }
            while (!joinedSave() && !detail.isCompleted && System.nanoTime() < deadline) Thread.sleep(5)
            assertTrue("admitted detail did not join the held save", joinedSave())
            assertTrue(visit.current())
            assertFalse(slot.accepted)
            assertEquals(7, fixture.server.requestCount)
            if (retireVisit) {
                visit.retire()
                runBlocking { withTimeout(1000) { detail.join() } }
                assertTrue(detail.isCancelled)
            }
            releaseSave.countDown()
            runBlocking { withTimeout(4000) { if (!retireVisit) detail.await(); sibling.await() } }
            assertEquals(!retireVisit, slot.accepted)
            assertEquals(if (retireVisit) emptyList() else listOf("Held track"), slot.rows.map { it.title })
            assertEquals(retireVisit, slot.waiting)
            assertFalse(slot.failed)
            assertEquals(!retireVisit, visit.current())
            val retry = checkNotNull(fixture.server.takeRequest(4, SECONDS))
            assertEquals("sibling", retry.url.queryParameter("q"))
            assertEquals("Bearer rotated", retry.headers["Authorization"])
            assertEquals(8, fixture.server.requestCount)
        } finally {
            releaseDetail.countDown(); releaseSave.countDown(); owner.cancel()
        }
    }

    @Test fun unavailableBrowseDoesNotReplayEvenWhenServerAsksForImmediateRetry() {
        HttpsFixture().use { fixture ->
            val session = AccountSession(fixture.endpoint, MemoryStore())
            assertTrue(session.accept(session.beginIntent(), SecretTokens("fixture-access", "fixture-refresh", "fixture-account")))
            val scope = checkNotNull(session.capture())
            val api = SoundQApi(session, fixture.client)
            fixture.server.enqueue(MockResponse.Builder().code(503).addHeader("Retry-After", "0").build())
            fixture.reply("""{"results":[]}""")
            val route = DiscoverBrowseRoute.TopTracks(artist)
            assertThrows(SafeFailure::class.java) { api.discoverBrowseBody(scope, route, DiscoveryCalls()) { true } }
            assertEquals(1, fixture.server.requestCount)
            assertEquals("/api/v1/artists/${artist.value}/top-tracks", checkNotNull(fixture.server.takeRequest(3, SECONDS)).url.encodedPath)
            assertTrue(DiscoverBrowseJson.topTracks(api.discoverBrowseBody(scope, route, DiscoveryCalls()) { true }).isEmpty())
            assertEquals(2, fixture.server.requestCount)
        }
    }

    @Test fun authenticatedArtistAndEditionUseTheirOwnTypedPaths() {
        HttpsFixture().use { fixture ->
            val session = AccountSession(fixture.endpoint, MemoryStore())
            assertTrue(session.accept(session.beginIntent(), SecretTokens("fixture-access", "fixture-refresh", "fixture-account")))
            val scope = checkNotNull(session.capture())
            val api = SoundQApi(session, fixture.client)
            val groupBody = """{"releaseGroupMbid":"${group.value}","title":"A+B & #","artistCredits":[{"mbid":"${artist.value}","name":"Matched artist"}],"coverArtUrl":""}"""
            fixture.reply("""{"results":[$groupBody],"limit":20,"offset":0,"total":1,"hasMore":false}""")
            val search = DiscoverBrowseRoute.ArtistSearch(artist, DiscoverBrowseRoute.SearchKind.Albums, "A+B & #", 0)
            val scoped = DiscoverBrowseJson.albums(api.discoverBrowseBody(scope, search, DiscoveryCalls()) { true }, search)
            assertEquals(group, scoped.rows.single().id)
            val searchRequest = checkNotNull(fixture.server.takeRequest(3, SECONDS))
            assertEquals("GET", searchRequest.method)
            assertEquals("Bearer fixture-access", searchRequest.headers["Authorization"])
            assertEquals("/api/v1/artists/${artist.value}/search", searchRequest.url.encodedPath)
            assertEquals("A+B & #", searchRequest.url.queryParameter("q"))
            assertEquals("album", searchRequest.url.queryParameter("kind"))

            val fields = """
                "releaseMbid":"${edition.value}","releaseGroupMbid":"${scoped.rows.single().id.value}",
                "title":"Selected","discCount":1,"coverArtUrl":""
            """.trim()
            fixture.reply("""{"results":[{$fields}],"limit":20,"offset":0,"total":1,"hasMore":false}""")
            val editions = DiscoverBrowseRoute.Editions(scoped.rows.single().id, 0)
            val selected = DiscoverBrowseJson.editions(api.discoverBrowseBody(scope, editions, DiscoveryCalls()) { true }, editions).rows.single()
            assertEquals("/api/v1/release-groups/${group.value}/editions", checkNotNull(fixture.server.takeRequest(3, SECONDS)).url.encodedPath)

            fixture.reply("""{$fields,"trackCount":0,"tracks":[]}""")
            val tracklist = DiscoverBrowseRoute.Tracklist(selected.group, selected.id)
            assertEquals(edition, DiscoverBrowseJson.tracklist(api.discoverBrowseBody(scope, tracklist, DiscoveryCalls()) { true }, tracklist).edition.id)
            val request = checkNotNull(fixture.server.takeRequest(3, SECONDS))
            assertEquals("GET", request.method)
            assertEquals("/api/v1/albums/${edition.value}/tracklist", request.url.encodedPath)
            assertEquals("Bearer fixture-access", request.headers["Authorization"])
            assertThrows(SafeFailure::class.java) { api.discoverBrowseBody(scope, tracklist, DiscoveryCalls()) { false } }
            assertEquals(3, fixture.server.requestCount)
        }
    }
}
