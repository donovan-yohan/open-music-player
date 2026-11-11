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

class PlaylistDetailOwnershipTest {
    @Test fun selectedReadRetiredBeforeIoCannotDispatch() {
        HttpsFixture().use { fixture ->
            val repository = PlaylistDetailRepository(SoundQApi(playlistSession(fixture), fixture.client))
            val selected = repository.select(PlaylistId(41))
            assertNotNull("selection must capture a route-owned request before IO", selected)
            val request = selected!!
            repository.retire()
            repository.load(request)
            assertEquals(0, fixture.server.requestCount)
            assertNull(repository.state.value.id)
        }
    }

    @Test fun playbackUsesAcceptedOrderedTracksAndTappedIdentity() {
        HttpsFixture().use { fixture ->
            val repository = PlaylistDetailRepository(SoundQApi(playlistSession(fixture), fixture.client))
            fixture.reply(playlistDetail()); repository.open(PlaylistId(41))
            val accepted = repository.capturePlayback()
            assertNotNull("loaded detail must expose a scoped playback capture", accepted)
            val capture = accepted!!
            var order = emptyList<TrackId>(); var index = -1
            assertTrue(repository.play(capture, TrackId(7)) { tracks, selected -> order = tracks.map { it.id }; index = selected })
            assertEquals(listOf(TrackId(9), TrackId(7)), order)
            assertEquals(1, index)
        }
    }

    @Test fun retainedPlaybackCannotReviveAfterSamePlaylistReopensOrAccountChanges() {
        HttpsFixture().use { fixture ->
            val session = playlistSession(fixture)
            val repository = PlaylistDetailRepository(SoundQApi(session, fixture.client))
            fixture.reply(playlistDetail()); repository.open(PlaylistId(41))
            val accepted = repository.capturePlayback()
            assertNotNull("loaded detail must expose a scoped playback capture", accepted)
            val old = accepted!!
            repository.retire()
            fixture.reply(playlistDetail()); repository.open(PlaylistId(41))
            var played = false
            assertFalse(repository.play(old, TrackId(9)) { _, _ -> played = true })
            val current = repository.capturePlayback()!!
            session.revoke()
            assertFalse(repository.play(current, TrackId(9)) { _, _ -> played = true })
            assertFalse(played)
        }
    }

    @Test fun heldOldDetailCannotReplaceNewSelection() {
        HttpsFixture().use { fixture ->
            val repository = PlaylistDetailRepository(SoundQApi(playlistSession(fixture), fixture.client))
            val entered = CountDownLatch(1); val release = CountDownLatch(1)
            fixture.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val id = request.url.encodedPath.substringAfterLast('/').toLong()
                    if (id == 41L) { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
                    return MockResponse.Builder().body(playlistDetail(id)).build()
                }
            }
            val pool = Executors.newSingleThreadExecutor()
            try {
                val old = pool.submit { repository.open(PlaylistId(41)) }
                assertTrue(entered.await(3, TimeUnit.SECONDS))
                repository.open(PlaylistId(42))
                val accepted = repository.state.value
                assertEquals(PlaylistId(42), accepted.detail!!.playlist.id)
                release.countDown(); old.get(5, TimeUnit.SECONDS)
                assertSame(accepted, repository.state.value)
                assertEquals(2, fixture.server.requestCount)
            } finally { release.countDown(); pool.shutdownNow(); assertTrue(pool.awaitTermination(5, TimeUnit.SECONDS)) }
        }
    }
}
