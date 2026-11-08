package com.soundq.android.data

import com.soundq.android.data.playlists.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class PlaylistLaterCorpusTest {
    @Test fun ordinaryBrowseContinuesPastBoth200And500WithoutLosingPlaylist541() {
        HttpsFixture().use { f ->
            val owner = PlaylistRepository(SoundQApi(playlistSession(f), f.client))
            for (offset in 0 until 541 step 20) {
                val ids = (offset + 1)..minOf(offset + 20, 541)
                val rows = ids.joinToString(",") { """{"id":$it,"name":"Playlist $it","isPublic":false,"trackCount":0,"durationMs":0}""" }
                f.reply("""{"data":[$rows],"total":541,"limit":20,"offset":$offset}""")
            }
            owner.reload()
            assertEquals((1L..541L).toList(), owner.state.value.rows.map { it.id.value })
            assertEquals(541, owner.state.value.total)
            assertNull(owner.state.value.error)
            assertEquals(28, f.server.requestCount)
            val reads = (1..28).map { f.server.takeRequest(3, TimeUnit.SECONDS)!! }
            assertEquals((0 until 541 step 20).map(Int::toString), reads.map { it.url.queryParameter("offset") })
            assertTrue(reads.all { it.method == "GET" })
        }
    }
}
