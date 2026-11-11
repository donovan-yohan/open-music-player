package com.soundq.android.data

import com.soundq.android.data.playlists.*
import org.junit.Assert.*
import org.junit.Test

class PlaylistDetailResponseTest {
    @Test fun mismatchedPlaylistIdentityNeverPublishesOrAdmitsPlayback() {
        HttpsFixture().use { fixture ->
            val repository = PlaylistDetailRepository(SoundQApi(playlistSession(fixture), fixture.client))
            fixture.reply(playlistDetail(42)); repository.open(PlaylistId(41))
            assertEquals(SafeFailure.Reason.InvalidResponse, repository.state.value.error)
            assertNull(repository.state.value.detail)
            assertNull(repository.capturePlayback())
        }
    }
    @Test fun refusedDetailCanRetryWithoutInventingRowsOrPlayback() {
        HttpsFixture().use { fixture ->
            val repository = PlaylistDetailRepository(SoundQApi(playlistSession(fixture), fixture.client))
            fixture.reply("{}", 404); repository.open(PlaylistId(41))
            assertEquals(SafeFailure.Reason.Refused, repository.state.value.error)
            assertNull(repository.capturePlayback())
            fixture.reply(playlistDetail()); repository.open(PlaylistId(41))
            assertNull(repository.state.value.error)
            assertEquals(2, repository.state.value.detail!!.tracks.size)
            assertNotNull(repository.capturePlayback())
        }
    }
    @Test fun duplicateMembershipAndNegativeDurationAreInvalid() {
        HttpsFixture().use { fixture ->
            val repository = PlaylistDetailRepository(SoundQApi(playlistSession(fixture), fixture.client))
            for (body in listOf(playlistDetail().replace("\"id\":7", "\"id\":9"), playlistDetail().replace("123000", "-1"))) {
                fixture.reply(body); repository.open(PlaylistId(41))
                assertEquals(SafeFailure.Reason.InvalidResponse, repository.state.value.error)
                assertNull(repository.capturePlayback())
            }
        }
    }
    @Test fun emptyPlaylistIsValidButCannotPlayAMissingTrack() {
        HttpsFixture().use { fixture ->
            val repository = PlaylistDetailRepository(SoundQApi(playlistSession(fixture), fixture.client))
            fixture.reply("""{"id":41,"name":"Empty","isPublic":false,"trackCount":0,"durationMs":0,"tracks":[]}""")
            repository.open(PlaylistId(41))
            assertNull(repository.state.value.error)
            assertTrue(repository.state.value.detail!!.tracks.isEmpty())
            var invoked = false
            assertFalse(repository.play(repository.capturePlayback()!!, TrackId(9)) { _, _ -> invoked = true })
            assertFalse(invoked)
        }
    }
}
