package com.soundq.android.data

import com.soundq.android.data.discovery.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class DiscoverSourceContinuityTest {
    @Test fun absentArtistDoesNotBecomeUploaderMetadata() {
        val wire=DiscoveryBoundaryTest.candidate().replace("\"artist\":\"Artist\",", "\"uploader\":\"Channel, not artist\",")
        val row=DiscoveryJson.candidate(Json.parseToJsonElement(wire).jsonObject)
        assertEquals("",row.artist)
        assertEquals("Channel, not artist",row.uploader)
    }
    @Test fun exactSourceFactsRemainAvailableWithoutGrantingAppPlayback() {
        val wire=DiscoveryBoundaryTest.candidate().replace("\"playable\":false", "\"playable\":true,\"thumbnailUrl\":\"https://images.example.test/live.jpg\",\"explicit\":false,\"metadata\":{\"album\":\"Live 2026 edition\"}")
        val row=DiscoveryJson.candidate(Json.parseToJsonElement(wire).jsonObject)
        assertEquals("fixture",row.sourceId);assertEquals("https://images.example.test/live.jpg",row.thumbnailUrl)
        assertEquals("Live 2026 edition",row.album);assertEquals(12000L,row.durationMs)
        assertTrue(row.playable);assertTrue(row.downloadable);assertEquals(false,row.explicit)
        assertEquals("https://youtu.be/fixture",row.source.url)
    }
    @Test fun externalPreviewRefusesNonProviderPortWithoutLosingTheInspectedSelection() {
        HttpsFixture().use { f ->
            val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
            val repo=DiscoveryRepository(session,SoundQApi(session,f.client));val view=repo.open()!!
            f.reply(DiscoveryBoundaryTest.search("seed").replace("https://youtu.be/fixture","https://youtu.be:8443/fixture"))
            repo.edit(view,"seed");repo.search(view,repo.state.value.draft)
            val accepted=repo.state.value.results!!;val choice=repo.inspect(view,accepted.rows.single())!!
            var launched=false
            assertFalse(repo.preview(view,choice){launched=true})
            assertFalse(launched);assertSame(accepted,repo.state.value.results);assertSame(choice,repo.state.value.inspected)
            assertEquals("seed",repo.state.value.draft.text);assertEquals(1,f.server.requestCount)
        }
    }
}
