package com.soundq.android.data

import com.soundq.android.data.discovery.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class DiscoveryBoundaryTest {
    @Test fun explicitSourceSearchUsesAuthenticatedTlsAndPreservesCapturedSelection() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            f.reply(search())
            val result=runCatching {SoundQApi(session,f.client).discoverySearch(session.capture()!!,"海 & music")}
            assertTrue("supported source search must reach TLS and return captured candidates",result.isSuccess)
            val page=result.getOrThrow()
            assertEquals("candidate-1",page.rows.single().id);assertEquals("123e4567-e89b-12d3-a456-426614174010",page.selection!!.id)
            val request=f.server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("GET",request.method);assertEquals("Bearer a",request.headers["Authorization"])
            assertEquals("海 & music",request.url.queryParameter("q"));assertEquals("youtube,soundcloud",request.url.queryParameter("providers"));assertEquals("12",request.url.queryParameter("limit"))
            assertEquals(1,f.server.requestCount)
        }
    }
    companion object {
        fun candidate()="""{"candidateId":"candidate-1","provider":"youtube","sourceId":"fixture","sourceUrl":"https://youtu.be/fixture","title":"Source fixture","artist":"Artist","durationMs":12000,"downloadable":true,"playable":false}"""
        fun search(query:String="海 & music",expires:String="2030-01-01T00:00:00Z")="""{"query":"$query","results":[${candidate()}],"providers":[{"provider":"youtube","status":"ok","resultCount":1,"elapsedMs":1},{"provider":"soundcloud","status":"disabled","resultCount":0,"elapsedMs":1}],"selectionRequired":true,"selectionSessionId":"123e4567-e89b-12d3-a456-426614174010","selectionExpiresAt":"$expires"}"""
    }
}
