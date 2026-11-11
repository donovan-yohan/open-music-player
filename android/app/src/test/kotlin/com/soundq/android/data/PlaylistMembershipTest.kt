package com.soundq.android.data

import com.soundq.android.data.playlists.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*

class PlaylistMembershipTest {
    @Test fun heldAddPublishesNoInventedMembershipThenExactAckAndAuthoritativeReads() {
        HttpsFixture().use { f ->
            val session = playlistSession(f)
            val api = SoundQApi(session, f.client)
            val library = LibraryRepository(session, api::library, api::like)
            f.reply(membershipLibrary()); library.refine(LibraryQuery(text = "海", liked = true))
            val before = library.state.value
            val repository = PlaylistMembershipRepository(api, library)
            val queue = ArrayDeque<() -> Unit>()
            val route = LibraryPlaylistActions(repository) { queue.add(it) }
            val picker = route.open(library.captureTrack(before.rows.single())!!)!!
            f.reply(playlistPage()); picker.reload(); queue.removeFirst().invoke()
            val submit = picker.select(repository.state.value.rows.single())!!
            val entered = CountDownLatch(1); val release = CountDownLatch(1)
            val requests = CopyOnWriteArrayList<String>()
            f.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    requests.add(request.method + " " + request.url.encodedPath)
                    return if (request.method == "POST") {
                        assertEquals("{\"trackIds\":[7]}", request.body!!.utf8())
                        entered.countDown(); check(release.await(5, TimeUnit.SECONDS))
                        MockResponse.Builder().body(membershipAck()).build()
                    } else MockResponse.Builder().body(if(request.url.encodedPath.endsWith("/41")) membershipDetail() else membershipPage()).build()
                }
            }
            val pool = Executors.newSingleThreadExecutor()
            try {
                picker.submit(submit); picker.submit(submit)
                assertEquals("Submit admission is synchronous", MutationOutcome.Pending, repository.state.value.outcome)
                assertEquals(1, queue.size)
                val task = pool.submit { queue.removeFirst().invoke() }
                assertTrue("Real HTTPS POST reached", entered.await(3, TimeUnit.SECONDS))
                assertNull(repository.state.value.ack)
                assertNull(repository.state.value.detail)
                assertEquals(0, repository.state.value.rows.single().trackCount)
                release.countDown(); task.get(5, TimeUnit.SECONDS)
                assertEquals("Exact acknowledgement", listOf(TrackId(7)), repository.state.value.ack?.added)
                assertEquals(emptyList<TrackId>(), repository.state.value.ack?.skipped)
                assertEquals(MutationOutcome.Confirmed, repository.state.value.outcome)
                assertEquals(listOf(TrackId(7)), repository.state.value.detail?.tracks?.map { it.id })
                assertEquals(1, repository.state.value.rows.single().trackCount)
                assertEquals(listOf("POST /api/v1/playlists/41/tracks", "GET /api/v1/playlists/41", "GET /api/v1/playlists"), requests)
                assertSame("No Library or Like mutation", before, library.state.value)
            } finally { release.countDown(); pool.shutdownNow(); assertTrue(pool.awaitTermination(5, TimeUnit.SECONDS)) }
        }
    }
}
internal fun membershipLibrary() = """{"tracks":[{"id":7,"title":"海辺 — Étude","artist":"Fixture","is_liked":true}],"total":1,"limit":20,"offset":0}"""
internal fun membershipSummary(id:Long = 41) = """{"id":$id,"name":"海辺 — Étude","isPublic":false,"trackCount":1,"durationMs":120000}"""
internal fun membershipAck(duplicate:Boolean = false, id:Long = 41) = """{"added":[${if(duplicate) "" else "7"}],"skipped":[${if(duplicate) "7" else ""}],"playlist":${membershipSummary(id)}}"""
internal fun membershipDetail(id:Long = 41) = membershipSummary(id).dropLast(1) + """, "tracks":[{"id":7,"title":"海辺 — Étude","durationMs":120000}]}"""
internal fun membershipPage() = """{"data":[${membershipSummary()}],"total":1,"limit":20,"offset":0}"""
