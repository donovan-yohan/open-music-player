package com.soundq.android.data

import com.soundq.android.data.discovery.*
import com.soundq.android.data.catalog.RecordingMbid
import com.soundq.android.data.imports.ImportSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class DiscoveryBoundaryTest {
    @Test fun providerWaitCanOutlastOrdinaryReadTimeoutWithoutRelaxingOtherRoutes() {
        HttpsFixture().use { f ->
            val session=AccountSession(f.endpoint,MemoryStore())
            session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val scope=session.capture()!!
            val api=SoundQApi(session,f.client.newBuilder().readTimeout(1,TimeUnit.SECONDS).build())
            f.server.enqueue(mockwebserver3.MockResponse.Builder().headersDelay(2,TimeUnit.SECONDS).body(search()).build())
            assertEquals("candidate-1",api.discoverySearch(scope,"海 & music").rows.single().id)
            f.server.enqueue(mockwebserver3.MockResponse.Builder().headersDelay(2,TimeUnit.SECONDS).body("{}").build())
            val failure=runCatching {api.releaseRadar(scope){true}}.exceptionOrNull() as? SafeFailure
            assertEquals(SafeFailure.Reason.Network,failure?.reason)
            assertEquals(2,f.server.requestCount)
        }
    }
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
    private fun readPreview(input: DiscoveryPreviewInput): ByteArray = try {
        val metadata = input.open()
        val result = java.io.ByteArrayOutputStream()
        val chunk = ByteArray(5)
        while (true) {
            val count = input.readEncoded(chunk)
            if (count == -1) break
            result.write(chunk, 0, count)
        }
        assertEquals(metadata[0], result.size().toLong())
        result.toByteArray()
    } finally { input.close() }

    @Test fun previewUsesOnlyAuthenticatedMediaRouteAndCreatesNoIntakeReceipt() = runBlocking {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore())
            session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val scope=session.capture()!!
            val api=SoundQApi(session,f.client)
            val source=ImportSource.parse("https://soundcloud.com/fixture/a-song")!!
            val media="fixture media bytes"
            f.server.enqueue(mockwebserver3.MockResponse.Builder().addHeader("Content-Type","audio/mpeg").addHeader("X-SoundQ-Preview-Sample-Rate",44100).addHeader("X-SoundQ-Preview-Frames",132300).body(media).build())
            assertArrayEquals(media.toByteArray(),readPreview(api.discoveryPreview(scope,source)))
            val request=f.server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("POST",request.method)
            assertEquals("/api/v1/discovery/preview",request.url.encodedPath)
            assertEquals("Bearer a",request.headers["Authorization"])
            assertEquals("audio/mpeg",request.headers["Accept"])
            assertEquals("""{"url":"https://soundcloud.com/fixture/a-song"}""",request.body?.utf8())
            assertTrue(api.intakeReceipts.entries(f.endpoint.identity,scope.accountId).isEmpty())
            assertEquals(1,f.server.requestCount)
        }
    }
    @Test fun previewRefusesRedirectWrongMediaAndOversize() = runBlocking {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore())
            session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val scope=session.capture()!!
            val api=SoundQApi(session,f.client)
            val source=ImportSource.parse("https://soundcloud.com/fixture/a-song")!!
            fun failure(reply:mockwebserver3.MockResponse,reason:SafeFailure.Reason)=reply to reason
            val cases=listOf(
                failure(mockwebserver3.MockResponse.Builder().code(404).build(),SafeFailure.Reason.AudioUnavailable),
                failure(mockwebserver3.MockResponse.Builder().addHeader("Content-Type","audio/mpeg").body("missing clocks").build(),SafeFailure.Reason.InvalidResponse),
                failure(mockwebserver3.MockResponse.Builder().addHeader("Content-Type","audio/mpeg").addHeader("Content-Encoding","gzip").addHeader("X-SoundQ-Preview-Sample-Rate",48000).addHeader("X-SoundQ-Preview-Frames",1).body("x").build(),SafeFailure.Reason.InvalidResponse),
                failure(mockwebserver3.MockResponse.Builder().code(302).addHeader("Location","/api/v1/downloads").build(),SafeFailure.Reason.Endpoint),
                failure(mockwebserver3.MockResponse.Builder().addHeader("Content-Type","application/json").body("{}").build(),SafeFailure.Reason.InvalidResponse),
                failure(mockwebserver3.MockResponse.Builder().addHeader("Content-Type","audio/mpeg").addHeader("X-SoundQ-Preview-Sample-Rate",44100).addHeader("X-SoundQ-Preview-Frames",132300).body("x".repeat(2_097_153)).build(),SafeFailure.Reason.InvalidResponse)
            )
            for((reply,reason) in cases) {
                f.server.enqueue(reply)
                assertEquals(reason,(runCatching {readPreview(api.discoveryPreview(scope,source))}.exceptionOrNull() as? SafeFailure)?.reason)
            }
            assertEquals(cases.size,f.server.requestCount)
        }
    }
    @Test fun previewCannotPublishHeldAudioAfterItsIntentRetires() = runBlocking {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore())
            session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val scope=session.capture()!!
            val api=SoundQApi(session,f.client)
            val source=ImportSource.parse("https://soundcloud.com/fixture/a-song")!!
            val entered=CountDownLatch(1)
            val release=CountDownLatch(1)
            val input=api.discoveryPreview(scope,source)
            f.server.dispatcher=object:mockwebserver3.Dispatcher() {
                override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                    entered.countDown()
                    check(release.await(5,TimeUnit.SECONDS))
                    return mockwebserver3.MockResponse.Builder().addHeader("Content-Type","audio/mpeg").addHeader("X-SoundQ-Preview-Sample-Rate",44100).addHeader("X-SoundQ-Preview-Frames",132300).body("fixture").build()
                }
            }
            try {
                val held=async(Dispatchers.IO) {runCatching {readPreview(input)}}
                assertTrue(entered.await(3,TimeUnit.SECONDS))
                input.cancel()
                assertEquals(SafeFailure.Reason.Retired,(held.await().exceptionOrNull() as? SafeFailure)?.reason)
                release.countDown()
                assertArrayEquals("fixture".toByteArray(),readPreview(api.discoveryPreview(scope,source)))
                assertEquals(2,f.server.requestCount)
            } finally {release.countDown()}
        }
    }
    @Test fun recordingSourceRefusesMismatchedOrUntrustedSourceAndAllowsExactNoMatch() {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore())
            session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val scope=session.capture()!!
            val api=SoundQApi(session,f.client)
            val id=RecordingMbid("123e4567-e89b-12d3-a456-426614174010")
            val link="https://soundcloud.com/fixture/a-song"
            f.reply("""{"recordingMbid":"${id.value}","sourceUrl":"$link"}""")
            assertEquals(link,api.recordingSource(scope,id){true}?.url)
            assertEquals("/api/v1/catalog/recordings/${id.value}/source",f.server.takeRequest(2,TimeUnit.SECONDS)!!.url.encodedPath)
            f.reply("""{"recordingMbid":"${id.value}","sourceUrl":null}""")
            assertNull(api.recordingSource(scope,id){true})
            for((wrongId,badUrl) in listOf("123e4567-e89b-12d3-a456-426614174011" to link,id.value to "https://fixture.invalid/a-song")) {
                f.reply("""{"recordingMbid":"$wrongId","sourceUrl":"$badUrl"}""")
                assertEquals(SafeFailure.Reason.InvalidResponse,(runCatching {api.recordingSource(scope,id){true}}.exceptionOrNull() as? SafeFailure)?.reason)
            }
            assertEquals(4,f.server.requestCount)
        }
    }

    @Test fun searchPreviewKeyIsOptionalCanonicalProviderBoundAndNeverBorrowedFromAdd() {
        val original=kotlinx.serialization.json.Json.parseToJsonElement(candidate()) as kotlinx.serialization.json.JsonObject
        val exact="https://www.youtube.com/watch?v=SQPreview01"
        assertNull(DiscoveryJson.candidate(original).previewSource)
        for(value in listOf(exact,"https://youtu.be/SQPreview01","https://soundcloud.com/fixture/wrong","$exact&list=other")) {
            val row=DiscoveryJson.candidate(kotlinx.serialization.json.JsonObject(original+ ("previewSourceUrl" to kotlinx.serialization.json.JsonPrimitive(value))))
            assertEquals("https://youtu.be/fixture",row.source.url)
            assertEquals(value.takeIf {it==exact},row.previewSource?.url)
        }
        val cloud=kotlinx.serialization.json.Json.parseToJsonElement(candidate().replace("youtube","soundcloud").replace("https://youtu.be/fixture","https://soundcloud.com/fixture/original")) as kotlinx.serialization.json.JsonObject
        for(key in listOf("https://soundcloud.com/fixture/exact","https://api.soundcloud.com/tracks/42","https://soundcloud.com/fixture/likes","https://soundcloud.com/settings/exact")) {
            val row=DiscoveryJson.candidate(kotlinx.serialization.json.JsonObject(cloud+ ("previewSourceUrl" to kotlinx.serialization.json.JsonPrimitive(key))))
            assertEquals(key.takeUnless {it.endsWith("/likes")||it.contains("/settings/")},row.previewSource?.url)
            assertEquals("https://soundcloud.com/fixture/original",row.source.url)
        }
    }

    @Test fun previewRefreshesOnlyOneExplicit401AndDoesNotReplayAfterRetirementOrAdmission() = runBlocking {
        for(mode in listOf("success","repeat401","cancelRotation","truncatedBody")) HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore())
            session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val scope=session.capture()!!
            val api=SoundQApi(session,f.client)
            val source=ImportSource.parse("https://www.youtube.com/watch?v=SQPreview01")!!
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            val paths=java.util.concurrent.CopyOnWriteArrayList<Pair<String,String?>>()
            fun audio()=mockwebserver3.MockResponse.Builder().addHeader("Content-Type","audio/mpeg")
                .addHeader("X-SoundQ-Preview-Sample-Rate",44100).addHeader("X-SoundQ-Preview-Frames",1000).body("fixture")
            f.server.dispatcher=object:mockwebserver3.Dispatcher() {
                override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                    val path=request.url.encodedPath;val auth=request.headers["Authorization"]
                    paths.add(path to auth)
                    if(path=="/api/v1/auth/refresh") {
                        check(request.method=="POST"&&request.body!!.utf8()=="""{"refreshToken":"r"}""")
                        if(mode=="cancelRotation"){entered.countDown();check(release.await(5,TimeUnit.SECONDS))}
                        return mockwebserver3.MockResponse.Builder().body("""{"accessToken":"b","refreshToken":"new-r","user":{"id":"A"}}""").build()
                    }
                    check(path=="/api/v1/discovery/preview"&&request.method=="POST"&&request.body!!.utf8()=="""{"url":"${source.url}"}""")
                    if(mode=="truncatedBody")return audio().setHeader("Content-Length",20).build()
                    return if(auth=="Bearer a"||mode=="repeat401")mockwebserver3.MockResponse.Builder().code(401).build() else audio().build()
                }
            }
            val input=api.discoveryPreview(scope,source)
            try {
                val work=async(Dispatchers.IO){runCatching {readPreview(input)}}
                if(mode=="cancelRotation") {assertTrue(entered.await(3,TimeUnit.SECONDS));input.cancel();release.countDown()}
                val result=work.await()
                if(mode=="success")assertArrayEquals("fixture".toByteArray(),result.getOrThrow())
                else assertNotNull(mode,result.exceptionOrNull())
                val preview="/api/v1/discovery/preview";val rotation="/api/v1/auth/refresh"
                assertEquals(mode,when(mode) {
                    "truncatedBody"->listOf(preview to "Bearer a")
                    "cancelRotation"->listOf(preview to "Bearer a",rotation to null)
                    else->listOf(preview to "Bearer a",rotation to null,preview to "Bearer b")
                },paths.toList())
                if(mode=="cancelRotation") {
                    assertEquals("b",session.access(scope)) // entered rotation still settles, not a replay
                    assertEquals(SafeFailure.Reason.Retired,(result.exceptionOrNull() as SafeFailure).reason)
                }
                assertTrue(api.intakeReceipts.entries(f.endpoint.identity,scope.accountId).isEmpty())
            } finally {release.countDown();input.cancel()}
        }
    }

    companion object {
        fun candidate()="""{"candidateId":"candidate-1","provider":"youtube","sourceId":"fixture","sourceUrl":"https://youtu.be/fixture","title":"Source fixture","artist":"Artist","durationMs":12000,"downloadable":true,"playable":false}"""
        fun search(query:String="海 & music",expires:String="2030-01-01T00:00:00Z")="""{"query":"$query","results":[${candidate()}],"providers":[{"provider":"youtube","status":"ok","resultCount":1,"elapsedMs":1},{"provider":"soundcloud","status":"disabled","resultCount":0,"elapsedMs":1}],"selectionRequired":true,"selectionSessionId":"123e4567-e89b-12d3-a456-426614174010","selectionExpiresAt":"$expires"}"""
    }
}
