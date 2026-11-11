package com.soundq.android.data

import com.soundq.android.data.playlists.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

/** Real authenticated TLS + production owner: no database, device or provider writes. */
class PlaylistOrdinaryBrowseTest {
    @Test fun reloadReachesPlaylistBeyondFirstPageWithoutTruncatingTheCorpus() {
        HttpsFixture().use { f ->
            val owner = PlaylistRepository(SoundQApi(playlistSession(f), f.client))
            f.reply(page(1..20, 41, 0))
            f.reply(page(21..40, 41, 20))
            f.reply(page(41..41, 41, 40))
            owner.reload()
            assertEquals("Playlist #21+ must be reachable from the ordinary list", (1L..41L).toList(), owner.state.value.rows.map { it.id.value })
            assertEquals(41, owner.state.value.total)
            assertFalse(owner.state.value.loading)
            assertNull(owner.state.value.error)
            val requests = (1..f.server.requestCount).map { f.server.takeRequest(2, TimeUnit.SECONDS)!! }
            assertEquals(listOf("0", "20", "40"), requests.map { it.url.queryParameter("offset") })
            assertTrue(requests.all { it.method == "GET" && it.headers["Authorization"] == "Bearer playlist-test-a" })
        }
    }

    @Test fun failedLaterPageNeverPublishesAnIncompleteListAsComplete() {
        HttpsFixture().use { f ->
            val owner = PlaylistRepository(SoundQApi(playlistSession(f), f.client))
            f.reply(page(91..91, 1, 0)); owner.reload()
            val previous = owner.state.value.rows
            f.reply(page(1..20, 21, 0)); f.reply("{}", 503)
            owner.reload()
            assertNotNull("A failed continuation needs explicit read recovery", owner.state.value.error)
            assertSame(previous, owner.state.value.rows)
            assertFalse(owner.state.value.loading)
            f.reply(page(1..20, 21, 0)); f.reply(page(21..21, 21, 20))
            owner.reload()
            assertEquals((1L..21L).toList(), owner.state.value.rows.map { it.id.value })
            assertNull(owner.state.value.error)
        }
    }

    @Test fun duplicateOrEmptyContinuationIsAnErrorNotASilentTruncationOrLoop() {
        for (bad in listOf(page(1..1, 21, 20), page(IntRange.EMPTY, 21, 20))) {
            HttpsFixture().use { f ->
                val owner = PlaylistRepository(SoundQApi(playlistSession(f), f.client))
                f.reply(page(1..20, 21, 0)); f.reply(bad)
                owner.reload()
                assertNotNull(owner.state.value.error)
                assertTrue(owner.state.value.rows.isEmpty())
                assertEquals(2, f.server.requestCount)
            }
        }
    }

    @Test fun queuedReloadCannotAcquireReplacementDestinationAuthority() {
        HttpsFixture().use { f ->
            val owner = PlaylistRepository(SoundQApi(playlistSession(f), f.client))
            val jobs = mutableListOf<() -> Unit>()
            val old = PlaylistActions(owner) { jobs.add(it) }
            old.reload(); old.close()
            f.reply(page(91..91, 1, 0)); owner.reload()
            val replacement = owner.state.value
            jobs.single()()
            assertSame(replacement, owner.state.value)
            assertEquals(1, f.server.requestCount)
        }
    }

    @Test fun non201OrNonemptyCreateRepliesCannotConfirmCreation() {
        val replies = listOf(
            200 to playlistSummary(), 202 to playlistSummary(),
            201 to playlistSummary().replace("\"trackCount\":0", "\"trackCount\":1"),
            201 to playlistSummary().replace("\"durationMs\":0", "\"durationMs\":1"),
        )
        for ((status, body) in replies) HttpsFixture().use { f ->
            val owner = PlaylistRepository(SoundQApi(playlistSession(f), f.client))
            f.reply(body, status); f.reply(playlistPage())
            owner.create(owner.captureList()!!, PlaylistDraft("海辺 — Étude", "Night listening"))
            assertEquals(MutationOutcome.Uncertain, owner.state.value.mutation?.outcome)
            assertNull(owner.state.value.created)
            assertEquals(1, f.server.requestCount)
        }
    }

    @Test fun wrongCreateAcknowledgementCannotConfirmAnotherDraftOrIdentity() {
        HttpsFixture().use { f ->
            val owner = PlaylistRepository(SoundQApi(playlistSession(f), f.client))
            f.reply(playlistSummary(), 201); f.reply(playlistPage())
            owner.create(owner.captureList()!!, PlaylistDraft("The submitted draft", "Keep this exact description"))
            assertEquals(MutationOutcome.Uncertain, owner.state.value.mutation?.outcome)
            assertNull(owner.state.value.created)
            assertEquals("Invalid ACK must not grant a readback continuation", 1, f.server.requestCount)
        }
    }

    private fun page(ids: IntRange, total: Int, offset: Int) = """{"data":[${ids.joinToString(",") { """{"id":$it,"name":"Playlist $it","isPublic":false,"trackCount":0,"durationMs":0}""" }}],"total":$total,"limit":20,"offset":$offset}"""
}
