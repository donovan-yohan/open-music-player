package com.soundq.android.data

import com.soundq.android.data.imports.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class ImportsTest {
    @Test fun rejectsUnsupportedCredentialedAndMalformedSourcesWithoutNormalizingBadIdentity() {
        val invalid=listOf("http://youtube.com/watch?v=x","https://youtube.com.evil.test/x","https://evilyoutube.com/x","https://x.youtu.be/x","https://user@youtube.com/x","https://@youtube.com/x","https://youtube.com/has space","https://youtube.com/"+"x".repeat(4096),"https://soundcloud.com\\@evil.test/x")
        invalid.forEach {assertNull(it,ImportSource.parse(it))}
        assertEquals("soundcloud",ImportSource.parse("https://m.soundcloud.com/fixture/song")!!.provider)
        assertEquals("youtube",ImportSource.parse("https://m.youtube.com/watch?v=x")!!.provider)
        assertNull(runCatching {ImportJobId("1-1-1-1-1")}.getOrNull())
        assertNull(runCatching {ImportJobId(" 123e4567-e89b-12d3-a456-426614174000")}.getOrNull())
        assertFalse(ImportSource.parse("https://youtu.be/x?secret=synthetic")!!.toString().contains("secret"))
    }
    @Test fun retiredReadRefusesBeforeDispatchAndDoesNotRefreshAfterHeldUnauthorizedReply() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val scope=session.capture()!!
            assertEquals(SafeFailure.Reason.Retired,(runCatching {api.recentImports(scope){false}}.exceptionOrNull() as SafeFailure).reason)
            assertEquals(0,f.server.requestCount)
            val entered=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1)
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {entered.countDown();release.await(3,TimeUnit.SECONDS);return mockwebserver3.MockResponse.Builder().code(401).build()}}
            val current=java.util.concurrent.atomic.AtomicBoolean(true);val pool=java.util.concurrent.Executors.newSingleThreadExecutor()
            try {
                val work=pool.submit<SafeFailure.Reason?> {try{api.recentImports(scope){current.get()};null}catch(e:SafeFailure){e.reason}}
                assertTrue(entered.await(2,TimeUnit.SECONDS));current.set(false);release.countDown()
                assertEquals(SafeFailure.Reason.Retired,work.get(3,TimeUnit.SECONDS));assertEquals(1,f.server.requestCount)
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun scalarTypesAndExactJobIdentityAreValidatedAndCreateIsNeverReplayed() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val scope=session.capture()!!;val source=ImportSource.parse("https://youtu.be/x")!!
            for((code,body) in listOf(200 to """{"job_id":"123e4567-e89b-12d3-a456-426614174000","status":"queued"}""",201 to """{"job_id":true,"status":"queued"}""",201 to """{"job_id":"1-1-1-1-1","status":"queued"}""",401 to "{}",503 to "{\"error\":\"secret\"}")) {
                f.reply(body,code);val error=runCatching {api.createImport(scope,source)}.exceptionOrNull() as SafeFailure
                assertFalse(error.toString().contains("secret"))
            }
            assertEquals(5,f.server.requestCount)
            val id=ImportJobId("123e4567-e89b-12d3-a456-426614174000")
            val base="""{"job_id":"${id.value}","status":"complete","progress":100,"track_id":71,"source_type":"youtube","created_at":"2026-10-28T00:00:00Z"}"""
            for(body in listOf(base.replace(id.value,"123e4567-e89b-12d3-a456-426614174001"),base.replace(":100",":\"100\""),base.replace(":71",":\"71\""),base.replace(":71",":true"),base.replace(":100",":101"),base.replace(":71",":0"),base.replace("\"complete\"","null"))) {
                f.reply(body);assertEquals(SafeFailure.Reason.InvalidResponse,(runCatching {api.importJob(scope,id)}.exceptionOrNull() as SafeFailure).reason)
            }
        }
    }

    @Test fun statusAndRecentReadActualCompletedTrackWithExactIdentityWithoutAnyPost() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","fixture"))
            val api=SoundQApi(session,f.client);val id=ImportJobId("123e4567-e89b-12d3-a456-426614174001")
            val body="""{"job_id":"${id.value}","status":"complete","progress":100,"track_id":71,"source_type":"soundcloud","url":"https://soundcloud.com/fixture/song?secret=not-presented","created_at":"2026-10-28T00:00:00Z"}"""
            f.reply(body)
            val result=runCatching {api.importJob(session.capture()!!,id)}
            assertTrue("status read must yield the real job",result.isSuccess)
            val job=result.getOrThrow()
            assertEquals(id,job.id);assertEquals(TrackId(71),job.track);assertEquals(ImportStatus.Complete,job.status)
            assertFalse(job.toString().contains("secret"))
            f.reply("""{"jobs":[$body]}""")
            assertEquals(job,api.recentImports(session.capture()!!).single())
            assertEquals(listOf("GET","GET"),(1..2).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!.method})
        }
    }

    @Test fun supportedLinkPostsOnceThroughAuthenticatedHttpsAndRequiresAcknowledgedJobIdentity() {
        HttpsFixture().use { f ->
            val session=AccountSession(f.endpoint,MemoryStore())
            session.accept(session.beginIntent(),SecretTokens("synthetic-a","synthetic-r","fixture"))
            val api=SoundQApi(session,f.client)
            val source=ImportSource.parse("https://www.youtube.com/watch?v=fixture#fragment")
            assertNotNull("supported HTTPS source must be admitted",source)
            f.reply("""{"job_id":"123e4567-e89b-12d3-a456-426614174000","status":"queued","sourceDecisionId":"123e4567-e89b-12d3-a456-426614174099"}""",201)
            val result=runCatching {api.createImport(session.capture()!!,source!!)}
            assertEquals(1,f.server.requestCount)
            assertTrue("201 receipt must become an acknowledged job, not a failure",result.isSuccess)
            val ack=result.getOrThrow()
            assertEquals("123e4567-e89b-12d3-a456-426614174000",ack.id.value)
            assertEquals(ImportStatus.Queued,ack.status)
            val request=f.server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("POST",request.method)
            assertEquals("/api/v1/downloads",request.url.encodedPath)
            assertEquals("Bearer synthetic-a",request.headers["Authorization"])
            val body=Json.parseToJsonElement(request.body!!.utf8()).jsonObject
            assertEquals("https://www.youtube.com/watch?v=fixture",body.getValue("url").jsonPrimitive.content)
            assertEquals("youtube",body.getValue("source_type").jsonPrimitive.content)
            assertEquals(1,f.server.requestCount)
        }
    }
}
