package com.soundq.android.data

import com.soundq.android.data.playlists.*
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.RecordedRequest
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Next finite compiler cycle: real wire-boundary controls; not executed in the first lease. */
class PlaylistCreateBoundaryTest {
    @Test fun repeatedSubmitWhileActualPostIsHeldDispatchesOnce() {
        HttpsFixture().use { fixture ->
            val repository = PlaylistRepository(SoundQApi(playlistSession(fixture), fixture.client))
            val capture = repository.captureList()!!
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            fixture.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = if (request.method == "POST") {
                    entered.countDown()
                    if (!release.await(5, TimeUnit.SECONDS)) MockResponse.Builder().code(503).build()
                    else MockResponse.Builder().code(201).body(playlistSummary()).build()
                } else MockResponse.Builder().body(playlistPage()).build()
            }
            val pool = Executors.newSingleThreadExecutor()
            try {
                val draft = PlaylistDraft("海辺 — Étude", "Night listening")
                val task = pool.submit { repository.create(capture, draft) }
                assertTrue(entered.await(3, TimeUnit.SECONDS))
                repository.create(capture, draft)
                assertEquals(1, fixture.server.requestCount)
                release.countDown(); task.get(5, TimeUnit.SECONDS)
                assertEquals(MutationOutcome.Confirmed, repository.state.value.mutation?.outcome)
                assertEquals(2, fixture.server.requestCount)
            } finally { release.countDown(); pool.shutdownNow(); assertTrue(pool.awaitTermination(5, TimeUnit.SECONDS)) }
        }
    }

    @Test fun acknowledgedCreateWithFailedListReadbackKeepsIdentityAndDoesNotResubmit() {
        HttpsFixture().use { fixture ->
            val repository = PlaylistRepository(SoundQApi(playlistSession(fixture), fixture.client))
            fixture.reply(playlistSummary(), 201)
            fixture.reply("{}", 503)
            repository.create(repository.captureList()!!, PlaylistDraft("海辺 — Étude", "Night listening"))
            assertEquals(MutationOutcome.ReadbackFailed, repository.state.value.mutation?.outcome)
            assertEquals(PlaylistId(41), repository.state.value.created!!.id)
            fixture.reply(playlistPage()); repository.reload()
            assertEquals(repository.state.value.created, repository.state.value.rows.single())
            val requests = (1..fixture.server.requestCount).map { fixture.server.takeRequest(3, TimeUnit.SECONDS)!! }
            assertEquals(listOf("POST", "GET", "GET"), requests.map { it.method })
        }
    }

    @Test fun retiredRoutePredicateRefusesBeforeHttpDispatch() {
        HttpsFixture().use { fixture ->
            val session = playlistSession(fixture)
            val api = SoundQApi(session, fixture.client)
            val error = runCatching { api.createPlaylist(session.capture()!!, PlaylistDraft("Must not dispatch")) { false } }.exceptionOrNull()
            assertEquals(SafeFailure.Reason.Retired, (error as SafeFailure).reason)
            assertEquals(0, fixture.server.requestCount)
        }
    }

    @Test fun playlistWrite401NeverRefreshesOrReplays() {
        HttpsFixture().use { fixture ->
            val session = playlistSession(fixture)
            val repository = PlaylistRepository(SoundQApi(session, fixture.client))
            fixture.reply("{}", 401)
            repository.create(repository.captureList()!!, PlaylistDraft("Refused"))
            assertEquals(MutationOutcome.Refused, repository.state.value.mutation?.outcome)
            assertEquals(1, fixture.server.requestCount)
            assertEquals("/api/v1/playlists", fixture.server.takeRequest(3, TimeUnit.SECONDS)!!.url.encodedPath)
            assertTrue(session.current(session.capture()!!))
        }
    }
}
