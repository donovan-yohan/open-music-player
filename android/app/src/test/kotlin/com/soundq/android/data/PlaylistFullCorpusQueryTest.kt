package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class PlaylistFullCorpusQueryTest {
    @Test fun serverRefinementAndSortAreEncodedBeforePaginationNotAppliedToFirst20Rows() {
        HttpsFixture().use { f ->
            val session = playlistSession(f)
            val api = SoundQApi(session, f.client)
            f.reply(playlistPage(empty = true))
            // The old consuming list call is retained as the predecessor control for the new overload.
            val browse = api.javaClass.methods.firstOrNull { it.name == "browsePlaylists" }
            if (browse == null) api.playlists(session.capture()!!, 0)
            else browse.invoke(api, session.capture()!!, 0, "海辺 & live/+", "name", "asc", { true })
            val request = f.server.takeRequest(3, TimeUnit.SECONDS)!!
            assertEquals("海辺 & live/+", request.url.queryParameter("q"))
            assertEquals("name", request.url.queryParameter("sort"))
            assertEquals("asc", request.url.queryParameter("order"))
            assertEquals("20", request.url.queryParameter("limit"))
            assertEquals("0", request.url.queryParameter("offset"))
            assertEquals(1, f.server.requestCount)
        }
    }
}
