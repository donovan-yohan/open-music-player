package com.soundq.android.data

import com.soundq.android.data.playlists.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class PlaylistDetailTest {
    @Test fun openPublishesOwnedPlaylistAndOrderedCamelCaseTracksThroughAuthenticatedGet() {
        HttpsFixture().use { fixture ->
            val session = playlistSession(fixture)
            val repository = PlaylistDetailRepository(SoundQApi(session, fixture.client))
            fixture.reply(playlistDetail())
            repository.open(PlaylistId(41))
            val state = repository.state.value
            assertEquals("the selected playlist must publish its authoritative detail", PlaylistId(41), state.detail?.playlist?.id)
            assertEquals(listOf(9L, 7L), state.detail!!.tracks.map { it.id.value })
            assertEquals("海辺 — Étude", state.detail!!.tracks.first().title)
            assertEquals(123000L, state.detail!!.tracks.first().durationMs)
            assertEquals("Night listening", state.detail!!.playlist.draft.description)
            assertFalse(state.loading)
            assertNull(state.error)
            val request = fixture.server.takeRequest(2, TimeUnit.SECONDS)!!
            assertEquals("GET", request.method)
            assertEquals("/api/v1/playlists/41", request.url.encodedPath)
            assertEquals("Bearer playlist-test-a", request.headers["Authorization"])
            assertEquals(1, fixture.server.requestCount)
        }
    }
}

internal fun playlistDetail(id: Long = 41): String = """{"id":$id,"name":"Night route","description":"Night listening","coverUrl":"","isPublic":false,"trackCount":2,"durationMs":243000,"tracks":[{"id":9,"title":"海辺 — Étude","artist":"Fixture artist","album":"Fixture album","durationMs":123000},{"id":7,"title":"Second","artist":"Fixture artist","durationMs":120000}]}"""
