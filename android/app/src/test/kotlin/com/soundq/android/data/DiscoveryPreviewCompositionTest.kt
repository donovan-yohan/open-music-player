package com.soundq.android.data

import com.soundq.android.data.catalog.RecordingMbid
import com.soundq.android.data.imports.ImportSource
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.RecordedRequest
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicBoolean

class DiscoveryPreviewCompositionTest {
    @Test fun overlappingPreviewGetAndPostJoinSearchSaveWithoutAdmittingAddOrResolve() = overlap(retire = false)
    @Test fun routeRetiredWhilePreviewGetAndPostAwaitSearchSaveNeverReopen() = overlap(retire = true)

    private fun overlap(retire: Boolean) = HttpsFixture().use { f ->
        val source = "https://www.youtube.com/watch?v=SQPreview01"
        val id = "123e4567-e89b-12d3-a456-426614174001"
        val recording = RecordingMbid(id)
        val recordingPath = "/api/v1/catalog/recordings/$id/source"
        val previewPath = "/api/v1/discovery/preview"
        val searchPath = "/api/v1/discovery/search"
        val exact = ConcurrentLinkedQueue<Pair<String,String>>()
        val entered = CountDownLatch(2)
        val first401 = CountDownLatch(1)
        val firstHeaders = CountDownLatch(2)
        val saveEntered = CountDownLatch(1)
        val releaseSave = CountDownLatch(1)
        val route = AtomicBoolean(true)
        val store = object:SessionStore {
            override fun load(endpoint:ApiEndpoint):SecretTokens? = null
            override fun clear() = Unit
            override fun save(endpoint:ApiEndpoint,tokens:SecretTokens) {
                if(tokens.access=="fresh") {saveEntered.countDown();check(releaseSave.await(10,TimeUnit.SECONDS))}
            }
        }
        f.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                val path=request.url.encodedPath
                val access=request.headers["Authorization"].orEmpty()
                exact.add(path to access)
                fun reply(body:String)=MockResponse.Builder().body(body).build()
                return when(path) {
                    "/api/v1/auth/refresh" -> reply(f.auth("A","fresh"))
                    searchPath -> if(access=="Bearer old") MockResponse.Builder().code(401).build()
                        else reply("""{"query":"held","results":[],"providers":[{"provider":"youtube","status":"ok"}]}""")
                    recordingPath,previewPath -> {
                        if(path==previewPath) {
                            check(request.method=="POST"&&request.body!!.utf8()=="""{"url":"$source"}""")
                        } else check(request.method=="GET")
                        if(access=="Bearer old") {
                            entered.countDown();check(first401.await(10,TimeUnit.SECONDS))
                            MockResponse.Builder().code(401).build()
                        } else if(path==recordingPath) reply("""{"recordingMbid":"$id","sourceUrl":"$source"}""")
                        else MockResponse.Builder().addHeader("Content-Type","audio/mpeg")
                            .addHeader("X-SoundQ-Preview-Sample-Rate","44100").addHeader("X-SoundQ-Preview-Frames","1").body("x").build()
                    }
                    else -> MockResponse.Builder().code(500).build()
                }
            }
        }
        val client=f.client.newBuilder().eventListener(object:okhttp3.EventListener() {
            override fun responseHeadersEnd(call:okhttp3.Call,response:okhttp3.Response) {
                if(response.code==401&&call.request().url.encodedPath in setOf(recordingPath,previewPath))firstHeaders.countDown()
            }
        }).build()
        val session=AccountSession(f.endpoint,store)
        assertTrue(session.accept(session.beginIntent(),SecretTokens("old","r-old","A")))
        val scope=checkNotNull(session.capture())
        val api=SoundQApi(session,client)
        val key=checkNotNull(ImportSource.parse(source))
        val input=api.discoveryPreview(scope,key,route::get)
        val pool=Executors.newFixedThreadPool(3)
        try {
            val lookup=pool.submit<Result<ImportSource?>> {runCatching {api.recordingPreviewSource(scope,recording,route::get)}}
            val media=pool.submit<Result<LongArray>> {try {runCatching {input.open()}}finally{input.close()}}
            assertTrue(entered.await(5,TimeUnit.SECONDS))
            val search=pool.submit<com.soundq.android.data.discovery.SourceResults> {api.discoverySearch(scope,"held",{true},provider=com.soundq.android.data.discovery.SourceProvider.YouTube)}
            assertTrue(saveEntered.await(5,TimeUnit.SECONDS))
            assertNull(session.capture());assertFalse(session.remoteCurrent(scope));assertTrue(session.previewOwnerCurrent(scope))
            first401.countDown()
            assertTrue(firstHeaders.await(5,TimeUnit.SECONDS))
            assertEquals(SafeFailure.Reason.Retired,(runCatching {api.recordingSource(scope,recording){true}}.exceptionOrNull() as SafeFailure).reason)
            assertEquals(SafeFailure.Reason.Retired,(runCatching {api.resolveSource(scope,key){true}}.exceptionOrNull() as SafeFailure).reason)
            assertEquals(4,exact.size)
            if(retire)route.set(false)
            releaseSave.countDown()
            assertEquals("held",search.get(5,TimeUnit.SECONDS).query)
            if(retire) {
                assertNotNull(lookup.get(5,TimeUnit.SECONDS).exceptionOrNull())
                assertNotNull(media.get(5,TimeUnit.SECONDS).exceptionOrNull())
            } else {
                assertEquals(source,lookup.get(5,TimeUnit.SECONDS).getOrThrow()?.url)
                assertArrayEquals(longArrayOf(1,44100,1),media.get(5,TimeUnit.SECONDS).getOrThrow())
            }
            assertEquals(1,exact.count {it.first=="/api/v1/auth/refresh"})
            for(path in listOf(recordingPath,previewPath))
                assertEquals(if(retire)listOf("Bearer old")else listOf("Bearer old","Bearer fresh"),exact.filter {it.first==path}.map {it.second})
        } finally {first401.countDown();releaseSave.countDown();input.cancel();pool.shutdownNow()}
    }
}
