package com.soundq.android.data.home

import com.soundq.android.data.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

/** Tracer through the existing trusted HTTPS/session/API path, not a second client. */
class HomeRepositoryTest {
    @Test fun topUsesThirtyDayContract() {
        HttpsFixture().use { f ->
            val s = AccountSession(f.endpoint, MemoryStore()); s.accept(s.beginIntent(), SecretTokens("a","r","fixture"))
            f.reply("""{"tracks":[{"id":7,"title":"Top","durationMs":123,"inLibrary":true}],"days":30,"limit":20}""")
            assertEquals("Top", SoundQApi(s,f.client).top(s.capture()!!).singleOrNull()?.track?.title)
            val request=f.server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("/api/v1/me/plays/top",request.url.encodedPath)
            assertEquals("30",request.url.queryParameter("days")); assertEquals("20",request.url.queryParameter("limit"))
        }
    }
    @Test fun historyKeepsRepeatedTrackEventsAndMetadataWithoutTotal() {
        HttpsFixture().use { f ->
            val s=AccountSession(f.endpoint,MemoryStore()); s.accept(s.beginIntent(),SecretTokens("a","r","fixture"))
            f.reply("""{"plays":[{"id":91,"track":{"id":7,"title":"Repeat","inLibrary":false},"playedAt":"2026-10-28T00:00:00Z","contextType":"playlist","contextId":"fixture-list","skipped":true},{"id":90,"track":{"id":7,"title":"Repeat"},"playedAt":"2026-10-27T00:00:00Z","skipped":false}],"limit":50,"offset":50}""")
            val rows=SoundQApi(s,f.client).history(s.capture()!!,50)
            assertEquals(listOf(91L,90L),rows.map {it.id})
            assertEquals(listOf(7L,7L),rows.map {it.entry.track.id.value})
            assertEquals("playlist",rows[0].contextType); assertEquals("fixture-list",rows[0].contextId)
            assertEquals(java.time.Instant.parse("2026-10-28T00:00:00Z"),rows[0].playedAt)
            assertTrue(rows[0].skipped); assertFalse(rows[0].entry.eligible); assertTrue(rows[1].entry.eligible)
            val request=f.server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("/api/v1/me/plays/history",request.url.encodedPath)
            assertEquals("50",request.url.queryParameter("limit"));assertEquals("50",request.url.queryParameter("offset"))
        }
    }
    @Test fun malformedExplicitEligibilityNeverGrantsPlayback() {
        HttpsFixture().use { fixture ->
            val session = AccountSession(fixture.endpoint, MemoryStore())
            session.accept(session.beginIntent(), SecretTokens("a", "r", "fixture"))
            val api = SoundQApi(session, fixture.client)
            fixture.reply("""{"tracks":[{"id":1,"title":"denied","inLibrary":false},{"id":2,"title":"legacy"},{"id":3,"title":"malformed","inLibrary":"true"},{"id":4,"title":"null","inLibrary":null},{"id":5,"title":"allowed","inLibrary":true}]}""")
            assertEquals(listOf(false, true, false, false, true), api.recent(session.capture()!!).map { it.eligible })
        }
    }
    @Test fun recentReadsAuthenticatedCamelCaseRowsThroughScopedRepository() {
        HttpsFixture().use { fixture ->
            val session = AccountSession(fixture.endpoint, MemoryStore())
            assertTrue(session.accept(session.beginIntent(), SecretTokens("synthetic-access", "synthetic-refresh", "home-fixture")))
            val api = SoundQApi(session, fixture.client)
            val repository = HomeRepository(session, api::recent)
            fixture.reply("""{"tracks":[{"id":7,"title":"海辺 — Étude","artist":"Fixture artist","album":"Fixture album","durationMs":182000,"artworkUrl":"https://media.invalid/cover","lastPlayedAt":"2026-10-28T00:10:00Z","inLibrary":true}],"limit":20,"offset":0}""")

            repository.refreshRecent()

            val state = repository.state.value
            assertEquals("the accepted recent GET must publish parsed rows", 1, state.rows.size)
            val row = state.rows.single()
            assertEquals(TrackId(7), row.track.id)
            assertEquals("海辺 — Étude", row.track.title)
            assertEquals("Fixture artist", row.track.artist)
            assertEquals("Fixture album", row.track.album)
            assertEquals(182000L, row.track.durationMs)
            assertEquals("https://media.invalid/cover", row.track.artwork)
            assertTrue(row.eligible)
            assertFalse(state.loading)
            assertNull(state.error)
            val request = fixture.server.takeRequest(2, TimeUnit.SECONDS)!!
            assertEquals("GET", request.method)
            assertEquals("/api/v1/me/plays/recent", request.url.encodedPath)
            assertEquals("20", request.url.queryParameter("limit"))
            assertEquals("Bearer synthetic-access", request.headers["Authorization"])
            assertEquals(1, fixture.server.requestCount)
        }
    }
}
