package com.soundq.android.data

import com.soundq.android.data.playlists.*
import org.junit.Assert.*
import org.junit.Test

class PlaylistCapacityTest {
    @Test fun full501MembershipLaunchesCompleteContextAtTheExactLaterSelection() {
        HttpsFixture().use { fixture ->
            val repository = PlaylistDetailRepository(SoundQApi(playlistSession(fixture), fixture.client))
            val tracks = (1..501).joinToString(",") { """{"id":$it,"title":"Track $it","durationMs":12000}""" }
            fixture.reply("""{"id":41,"name":"Full membership","isPublic":false,"trackCount":501,"durationMs":6012000,"tracks":[$tracks]}""")
            repository.open(PlaylistId(41))
            assertEquals((1L..501L).toList(), repository.state.value.detail!!.tracks.map { it.id.value })
            val capture = repository.capturePlayback()!!
            var consumed:List<Track>? = null
            var selected=-1
            assertTrue(repository.play(capture, TrackId(501)) { rows, index -> consumed=rows;selected=index })
            assertEquals((1L..501L).toList(),consumed!!.map {it.id.value})
            assertEquals(500,selected)
            assertEquals(501, repository.state.value.detail!!.tracks.size)
        }
    }
}
