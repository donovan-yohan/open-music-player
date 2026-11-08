package com.soundq.android.data

import com.soundq.android.data.discovery.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class DirectSourceResolutionTest {
    @Test fun pastedUrlUsesResolverBeforeExplicitSourceDecision() {
        HttpsFixture().use { f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val repo=DiscoveryRepository(session,api);val view=repo.open()!!
            val url="https://youtu.be/fixture"
            repo.edit(view,url)
            f.reply("""{"candidate":{"candidateId":"youtube:fixture","provider":"youtube","sourceUrl":"$url","title":"Fixture","downloadable":true,"playable":false},"selectionRequired":true,"selectionSessionId":"123e4567-e89b-12d3-a456-426614174000","selectionExpiresAt":"2099-01-01T00:00:00Z"}""")
            repo.search(view,repo.state.value.draft)
            val request=f.server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("POST",request.method)
            assertEquals("/api/v1/discovery/resolve-url",request.url.encodedPath)
            assertEquals(DiscoveryPhase.Ready,repo.state.value.phase)
            assertNotNull(repo.inspect(view,repo.state.value.results!!.rows.single()))
            assertEquals(1,f.server.requestCount)
        }
    }
}
