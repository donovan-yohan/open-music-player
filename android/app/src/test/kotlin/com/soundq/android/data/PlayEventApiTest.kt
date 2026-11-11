package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class PlayEventApiTest {
    @Test fun exactCreatedTypedAcknowledgementAndSingleWriteNoBlindReplay() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val scope=session.capture()!!
            f.reply("""{"trackId":7,"played":true}""",201);api.recordPlay(scope,TrackId(7))
            val request=f.server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("POST",request.method);assertEquals("/api/v1/me/plays",request.url.encodedPath)
            assertEquals("{\"trackId\":7}",request.body!!.utf8())
            for((code,body) in listOf(200 to """{"trackId":7,"played":true}""",201 to """{"trackId":8,"played":true}""",201 to """{"trackId":"7","played":true}""",201 to """{"trackId":7,"played":"true"}""",201 to """{"trackId":7,"played":false}""",500 to "{}",401 to "{}")) {
                val before=f.server.requestCount;f.reply(body,code)
                assertTrue(runCatching {api.recordPlay(scope,TrackId(7))}.exceptionOrNull() is SafeFailure)
                assertEquals(before+1,f.server.requestCount)
            }
            val before=f.server.requestCount
            assertTrue(runCatching {api.recordPlay(scope,TrackId(7)){false}}.exceptionOrNull() is SafeFailure)
            session.revoke();assertTrue(runCatching {api.recordPlay(scope,TrackId(7))}.exceptionOrNull() is SafeFailure)
            assertEquals(before,f.server.requestCount)
        }
    }
    @Test fun deviceOnlyDoesNotDispatch() {
        HttpsFixture().use {f ->
            val store=MemoryStore().apply {tokens=SecretTokens("a","r","A")};val session=AccountSession(f.endpoint,store)
            assertTrue(session.useDeviceDownloads());val api=SoundQApi(session,f.client)
            assertTrue(runCatching {api.recordPlay(session.capture()!!,TrackId(7))}.exceptionOrNull() is SafeFailure)
            assertEquals(0,f.server.requestCount)
        }
    }
}
