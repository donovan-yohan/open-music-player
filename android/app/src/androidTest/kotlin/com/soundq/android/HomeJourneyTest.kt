package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import com.soundq.android.product.*
import mockwebserver3.*
import okhttp3.OkHttpClient
import okhttp3.tls.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Run this class separately: mounted production shell, real synthetic HTTPS, no production account. */
class HomeJourneyTest {
    @get:Rule val compose=createComposeRule()
    @Test fun ordinaryLibraryHomeHistoryAndBackPreserveEligibilityAndRepeatedEvents() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        val io=Executors.newSingleThreadExecutor()
        val requests=CopyOnWriteArrayList<String>()
        val server=MockWebServer()
        val cert=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val trust=HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        val client=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
        val models=ViewModelStore()
        var graph:AppGraph?=null
        try {
            val prepared=io.submit<AppGraph> {
                server.useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory())
                server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                    val path=request.url.encodedPath;requests.add(path)
                    fun reply(body:String)=MockResponse.Builder().body(body).build()
                    val row="""{"id":7,"title":"Repeated history song","artist":"Synthetic artist","inLibrary":true}"""
                    return when(path) {
                        "/api/v1/library" -> reply("""{"tracks":[],"total":0,"limit":20,"offset":0}""")
                        "/api/v1/me/plays/recent" -> reply("""{"tracks":[{"id":8,"title":"Removed song","inLibrary":false},$row]}""")
                        "/api/v1/me/plays/top" -> reply("""{"tracks":[]}""")
                        "/api/v1/me/plays/history" -> reply("""{"plays":[{"id":2,"track":$row,"playedAt":"2026-10-28T00:00:00Z","skipped":false},{"id":1,"track":$row,"playedAt":"2026-10-27T00:00:00Z","skipped":true}],"limit":50,"offset":0}""")
                        "/api/v1/playback/urls" -> {
                            val id=Regex("\\\"trackIds\\\":\\s*\\[([0-9]+)").find(request.body!!.utf8())?.groupValues?.get(1) ?: "7"
                            reply("""{"urls":[{"trackId":$id,"url":"${server.url("/media/$id.wav")}","expiresAt":"2030-01-01T00:00:00Z"}]}""")
                        }
                        "/media/7.wav", "/media/9.wav" -> {
                            check(request.headers["Authorization"]==null)
                            val samples=16000*12
                            val bytes=java.nio.ByteBuffer.allocate(44+samples*2).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                            bytes.put("RIFF".toByteArray()).putInt(36+samples*2).put("WAVEfmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(16000).putInt(32000).putShort(2).putShort(16).put("data".toByteArray()).putInt(samples*2)
                            repeat(samples) {bytes.putShort(0)}
                            MockResponse.Builder().addHeader("Content-Type","audio/wav").body(okio.Buffer().write(bytes.array())).build()
                        }
                        else -> MockResponse.Builder().code(404).body("{}").build()
                    }
                }}
                server.start()
                AppGraph(app,ApiEndpoint.parse(server.url("/api/v1").toString()),client,object:SessionStore {
                    override fun load(endpoint:ApiEndpoint):SecretTokens?=null
                    override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){}
                    override fun clear(){}
                },client).also {it.session.accept(it.session.beginIntent(),SecretTokens("synthetic-a","synthetic-r","home-journey"))}
            }.get(10,TimeUnit.SECONDS)
            graph=prepared
            val model=compose.runOnIdle {app.graph.close();app.graph=prepared;ProductViewModel(app).also {models.put("home",it)}}
            compose.setContent {ProductApp(model)}
            compose.onNodeWithContentDescription("Search library").assertExists()
            compose.onNodeWithText("Home").performClick()
            compose.waitUntil(10000){requests.contains("/api/v1/me/plays/recent")&&model.home.recent.value.rows.size==2}
            compose.onNodeWithText("Removed song").assertIsNotEnabled()
            compose.waitUntil(10000){model.playback.value.connection==com.soundq.android.playback.PlaybackProjection.Connection.Connected}
            compose.onNodeWithText("Repeated history song").performClick()
            compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.queue.map {it.trackId}==listOf(7L)}
            compose.onNodeWithContentDescription("Pause").performClick()
            compose.waitUntil(10000){!model.playback.value.isPlaying}
            val paused=model.playback.value
            compose.onNodeWithText("Repeated history song").performTouchInput {
                down(androidx.compose.ui.geometry.Offset(width*0.9f,center.y));moveBy(androidx.compose.ui.geometry.Offset(-190*app.resources.displayMetrics.density,0f),delayMillis=300);up()
            }
            compose.waitUntil(10000){model.playback.value.queue.size==paused.queue.size+1}
            assertEquals(paused.selectedOccurrence,model.playback.value.selectedOccurrence);assertFalse(model.playback.value.isPlaying)
            compose.onNodeWithText("Your top tracks").performScrollTo()
            compose.onNodeWithText("No top tracks yet").assertExists()
            compose.onNodeWithContentDescription("Listening history").performClick()
            compose.waitUntil(10000){model.home.history.value.rows.size==2}
            compose.onNode(hasText("Repeated history song") and hasText("Skipped",substring=true)).assertExists().performClick()
            compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.queue.count {it.manual}==1&&model.playback.value.queue.size==2}
            compose.onNodeWithContentDescription("Pause").performClick()
            compose.waitUntil(10000){!model.playback.value.isPlaying}
            val historyPaused=model.playback.value
            compose.onNode(hasText("Repeated history song") and hasText("Skipped",substring=true)).performTouchInput {
                down(androidx.compose.ui.geometry.Offset(width*0.9f,center.y));moveBy(androidx.compose.ui.geometry.Offset(-190*app.resources.displayMetrics.density,0f),delayMillis=300);up()
            }
            compose.waitUntil(10000){model.playback.value.queue.size==historyPaused.queue.size+1}
            assertEquals(historyPaused.selectedOccurrence,model.playback.value.selectedOccurrence);assertFalse(model.playback.value.isPlaying)
            assertEquals(listOf(2L,1L),model.home.history.value.rows.map {it.id})
            compose.onNode(hasText("Library") and hasClickAction()).performClick()
            compose.onNodeWithContentDescription("Search library").assertExists()
            assertTrue(requests.none {it.contains("/plays/skip")||it=="/api/v1/me/plays"})
        } finally {
            compose.runOnIdle {models.clear();graph?.close()}
            io.submit {server.close();client.connectionPool.evictAll();client.dispatcher.executorService.shutdown()}.get(5,TimeUnit.SECONDS)
            io.shutdownNow()
        }
    }
}
