package com.soundq.android.data

import com.soundq.android.data.playlists.*
import kotlinx.serialization.json.*
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.RecordedRequest
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class PlaylistApiCandidateTest {
    @Test fun pagedListUsesDataEnvelopeAndServerTotalThroughExistingAuthenticatedApi() {
        HttpsFixture().use { fixture ->
            val session = playlistSession(fixture)
            fixture.reply(playlistPage(total = 51, offset = 20))
            val page = SoundQApi(session, fixture.client).playlists(session.capture()!!, 20)
            assertEquals(51, page.total)
            assertEquals(20, page.offset)
            assertEquals(20, page.limit)
            assertEquals("海辺 — Étude", page.rows.single().name)
            assertEquals(PlaylistId(41), page.rows.single().id)
            val request = fixture.server.takeRequest(3, TimeUnit.SECONDS)!!
            assertEquals("GET", request.method)
            assertEquals("/api/v1/playlists", request.url.encodedPath)
            assertEquals("20", request.url.queryParameter("offset"))
            assertEquals("20", request.url.queryParameter("limit"))
            assertEquals("Bearer playlist-test-a", request.headers["Authorization"])
        }
    }
    @Test fun absentServerTotalIsInvalidResponseNotAnInventedRowCount() {
        HttpsFixture().use { fixture ->
            val session = playlistSession(fixture)
            fixture.reply("""{"data":[],"limit":20,"offset":0}""")
            val error = runCatching { SoundQApi(session, fixture.client).playlists(session.capture()!!, 0) }.exceptionOrNull()
            assertTrue(error is SafeFailure)
            assertEquals(SafeFailure.Reason.InvalidResponse, (error as SafeFailure).reason)
            assertEquals(1, fixture.server.requestCount)
        }
    }
}

class PlaylistRepositoryCandidateTest {
    @Test fun privateCreateStaysPendingUntilAcknowledgedThenPublishesServerIdentityAndReadback() {
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
                val task = pool.submit { repository.create(capture, PlaylistDraft("海辺 — Étude", "Night listening")) }
                assertTrue("Private create did not reach the real HTTPS fixture", entered.await(3, TimeUnit.SECONDS))
                val pending = repository.state.value
                assertEquals(MutationOutcome.Pending, pending.mutation?.outcome)
                assertNull(pending.created)
                assertTrue(pending.rows.isEmpty())
                val write = fixture.server.takeRequest(3, TimeUnit.SECONDS)!!
                assertEquals("POST", write.method)
                assertEquals("/api/v1/playlists", write.url.encodedPath)
                assertEquals("Bearer playlist-test-a", write.headers["Authorization"])
                val body = Json.parseToJsonElement(write.body!!.utf8()).jsonObject
                assertEquals(setOf("name", "description", "coverUrl", "isPublic"), body.keys)
                assertEquals("海辺 — Étude", body.getValue("name").jsonPrimitive.content)
                assertEquals("Night listening", body.getValue("description").jsonPrimitive.content)
                assertEquals("", body.getValue("coverUrl").jsonPrimitive.content)
                assertFalse(body.getValue("isPublic").jsonPrimitive.boolean)
                release.countDown()
                task.get(5, TimeUnit.SECONDS)
                val accepted = repository.state.value
                assertEquals(MutationOutcome.Confirmed, accepted.mutation?.outcome)
                val created = accepted.created!!
                assertEquals(PlaylistId(41), created.id)
                assertEquals(created, accepted.rows.single())
                val readback = fixture.server.takeRequest(3, TimeUnit.SECONDS)!!
                assertEquals("GET", readback.method)
                assertEquals("/api/v1/playlists", readback.url.encodedPath)
                assertEquals(2, fixture.server.requestCount)
            } finally {
                release.countDown(); pool.shutdownNow()
                assertTrue(pool.awaitTermination(5, TimeUnit.SECONDS))
            }
        }
    }

    @Test fun uncertainCreateReloadsWithoutReplayingPostOrClaimingAConfirmedCreation() {
        HttpsFixture().use { fixture ->
            val repository = PlaylistRepository(SoundQApi(playlistSession(fixture), fixture.client))
            val capture = repository.captureList()!!
            fixture.reply("""{"message":"synthetic-server-text-must-not-be-shown"}""", 503)
            fixture.reply(playlistPage())
            repository.create(capture, PlaylistDraft("海辺 — Étude"))
            assertEquals(MutationOutcome.Uncertain, repository.state.value.mutation?.outcome)
            assertNull(repository.state.value.created)
            repository.reload()
            assertEquals(1, repository.state.value.rows.size)
            assertNull(repository.state.value.created)
            assertNotEquals(MutationOutcome.Confirmed, repository.state.value.mutation?.outcome)
            val requests = (1..fixture.server.requestCount).map { fixture.server.takeRequest(3, TimeUnit.SECONDS)!! }
            assertEquals(listOf("POST", "GET"), requests.map { it.method })
        }
    }

    @Test fun retainedCreateCannotCrossListRetirementEvenWhenSameAccountAndRowsReturn() {
        HttpsFixture().use { fixture ->
            val repository = PlaylistRepository(SoundQApi(playlistSession(fixture), fixture.client))
            val oldCapture = repository.captureList()!!
            repository.retire()
            fixture.reply(playlistPage())
            repository.reload()
            val before = fixture.server.requestCount
            repository.create(oldCapture, PlaylistDraft("Must not dispatch"))
            assertEquals(before, fixture.server.requestCount)
            assertNull(repository.state.value.created)
        }
    }

    @Test fun heldCreateAcknowledgementCannotPublishAfterReplacementAccountOpensItsOwnList() {
        HttpsFixture().use { fixture ->
            val session = playlistSession(fixture)
            val repository = PlaylistRepository(SoundQApi(session, fixture.client))
            val oldCapture = repository.captureList()!!
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            fixture.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = if (request.method == "POST") {
                    entered.countDown()
                    if (!release.await(5, TimeUnit.SECONDS)) MockResponse.Builder().code(503).build()
                    else MockResponse.Builder().code(201).body(playlistSummary()).build()
                } else MockResponse.Builder().body(playlistPage(empty = true)).build()
            }
            val pool = Executors.newSingleThreadExecutor()
            try {
                val task = pool.submit { repository.create(oldCapture, PlaylistDraft("Old account")) }
                assertTrue(entered.await(3, TimeUnit.SECONDS))
                assertTrue(session.accept(session.beginIntent(), SecretTokens("playlist-test-b", "playlist-refresh-b", "playlist-account-b")))
                repository.retire(); repository.reload()
                val replacement = repository.state.value
                assertTrue(replacement.rows.isEmpty())
                release.countDown(); task.get(5, TimeUnit.SECONDS)
                assertEquals(replacement, repository.state.value)
                val requests = (1..fixture.server.requestCount).map { fixture.server.takeRequest(3, TimeUnit.SECONDS)!! }
                assertEquals(listOf("POST", "GET"), requests.map { it.method })
                assertEquals(listOf("Bearer playlist-test-a", "Bearer playlist-test-b"), requests.map { it.headers["Authorization"] })
            } finally {
                release.countDown(); pool.shutdownNow()
                assertTrue(pool.awaitTermination(5, TimeUnit.SECONDS))
            }
        }
    }
}

internal fun playlistSession(fixture: HttpsFixture): AccountSession =
    AccountSession(fixture.endpoint, MemoryStore()).also {
        check(it.accept(it.beginIntent(), SecretTokens("playlist-test-a", "playlist-refresh-a", "playlist-account-a")))
    }
internal fun playlistSummary(): String = """{"id":41,"name":"海辺 — Étude","description":"Night listening","isPublic":false,"trackCount":0,"durationMs":0,"createdAt":"2026-10-28T04:00:00Z","updatedAt":"2026-10-28T04:00:00Z"}"""
internal fun playlistPage(total: Int = 1, offset: Int = 0, empty: Boolean = false): String =
    """{"data":[${if (empty) "" else playlistSummary()}],"total":${if (empty) 0 else total},"limit":20,"offset":$offset}"""
