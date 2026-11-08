package com.soundq.android.data

import com.soundq.android.data.playlists.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class PlaylistQueryAdmissionTest {
    @Test fun replacementAccountGetsFreshQueryAndOldTicketCannotClearItsAcceptedRows() {
        HttpsFixture().use { f ->
            val session = playlistSession(f)
            val repository = PlaylistRepository(SoundQApi(session, f.client))
            val jobs = mutableListOf<() -> Unit>()
            val old = PlaylistActions(repository) { jobs.add(it) }
            old.refine(PlaylistQuery("private old query", PlaylistSort.Name, true))
            assertTrue(session.accept(session.beginIntent(), SecretTokens("replacement", "replacement-refresh", "replacement-account")))
            val replacement = PlaylistActions(repository) { jobs.add(it) }
            replacement.reload()
            assertEquals(2, jobs.size)
            assertEquals(PlaylistQuery(), repository.state.value.query)
            f.reply(playlistPage())
            jobs.removeAt(1)()
            val accepted = repository.state.value
            jobs.removeAt(0)()
            assertSame(accepted, repository.state.value)
            assertFalse(accepted.loading)
            assertEquals(1, f.server.requestCount)
            assertEquals("Bearer replacement", f.server.takeRequest(3, TimeUnit.SECONDS)!!.headers["Authorization"])
        }
    }

    @Test fun newerQueryOwnsEveryContinuationAndSupersededQueuedWorkCannotClearItsLoading() {
        HttpsFixture().use { f ->
            val repository = PlaylistRepository(SoundQApi(playlistSession(f), f.client))
            val jobs = mutableListOf<() -> Unit>()
            val actions = PlaylistActions(repository) { jobs.add(it) }
            actions.refine(PlaylistQuery("retired query", PlaylistSort.Name, true))
            val accepted = PlaylistQuery("海辺 & live/+", PlaylistSort.Tracks, false)
            actions.refine(accepted)
            jobs.removeAt(0)()
            assertEquals(0, f.server.requestCount)
            assertEquals(accepted, repository.state.value.query)
            assertTrue(repository.state.value.loading)
            for ((offset, ids) in listOf(0 to (1..20), 20 to (21..21))) {
                val rows = ids.joinToString(",") { """{"id":$it,"name":"Playlist $it","isPublic":false,"trackCount":0,"durationMs":0}""" }
                f.reply("""{"data":[$rows],"total":21,"limit":20,"offset":$offset}""")
            }
            jobs.removeAt(0)()
            assertEquals((1L..21L).toList(), repository.state.value.rows.map { it.id.value })
            assertEquals(accepted, repository.state.value.query)
            assertFalse(repository.state.value.loading)
            val reads = (1..2).map { f.server.takeRequest(3, TimeUnit.SECONDS)!! }
            assertEquals(listOf("0", "20"), reads.map { it.url.queryParameter("offset") })
            assertTrue(reads.all { it.url.queryParameter("q") == accepted.text && it.url.queryParameter("sort") == "track_count" && it.url.queryParameter("order") == "desc" })
        }
    }
}
