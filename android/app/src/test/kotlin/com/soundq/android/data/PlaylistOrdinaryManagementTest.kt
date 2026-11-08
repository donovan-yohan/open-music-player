package com.soundq.android.data

import com.soundq.android.data.playlists.*
import org.junit.Assert.*
import org.junit.Test

class PlaylistOrdinaryManagementTest {
    @Test fun completeMetadataPutSupportsPublicVisibilityAndExactDraft() {
        HttpsFixture().use { f ->
            val api = SoundQApi(playlistSession(f), f.client)
            val draft = PlaylistDraft("海辺 edited", "A different description", "https://art.invalid/new", true)
            val summary = """{"id":41,"name":"海辺 edited","description":"A different description","coverUrl":"https://art.invalid/new","isPublic":true,"trackCount":2,"durationMs":24000}"""
            f.reply(summary)
            val result = api.renamePlaylist(api.session.capture()!!, PlaylistId(41), draft) { true }
            assertEquals(draft, result.draft)
            val request = f.server.takeRequest(2, java.util.concurrent.TimeUnit.SECONDS)!!
            assertEquals("PUT", request.method)
            assertEquals("/api/v1/playlists/41", request.url.encodedPath)
            assertEquals(draft, com.soundq.android.data.playlists.PlaylistJson.summary(kotlinx.serialization.json.Json.parseToJsonElement(summary) as kotlinx.serialization.json.JsonObject).draft)
            assertEquals("{\"name\":\"海辺 edited\",\"description\":\"A different description\",\"coverUrl\":\"https://art.invalid/new\",\"isPublic\":true}", request.body!!.utf8())
        }
    }
    @Test fun ownedPublicDetailAdmitsManagementOnlyWithServerPermission() {
        HttpsFixture().use { f ->
            val api = SoundQApi(playlistSession(f), f.client)
            val detail = PlaylistDetailRepository(api)
            val repository = PlaylistManagementRepository(api, detail)
            val actions = PlaylistManagementActions(repository) { it() }
            f.reply(managementDetail().replace("\"isPublic\":false", "\"isPublic\":true,\"canManage\":true"))
            detail.open(PlaylistId(41))
            assertNotNull("Explicit server permission admits owned public playlist", actions.capture())
            f.reply(managementDetail().replace("\"isPublic\":false", "\"isPublic\":true,\"canManage\":false"))
            detail.open(PlaylistId(41))
            assertNull(actions.capture())
            f.reply(managementDetail().replace("\"isPublic\":false", "\"isPublic\":true"))
            detail.open(PlaylistId(41))
            assertNull(actions.capture())
        }
    }
}
