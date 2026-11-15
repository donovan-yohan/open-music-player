package com.soundq.android

import android.view.KeyEvent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
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
import java.util.concurrent.*

/** Compiled real-root journeys. Runtime requires separately admitted device custody. */
class CatalogJourneyTest {
    @get:Rule val compose=createComposeRule()
    @Test fun normalCatalogArtistsGroupsAndConcreteAlbumPreservePausedListening()=journey(1f)
    @Test fun enlargedCatalogArtistsGroupsAndConcreteAlbumPreservePausedListening()=journey(2f)
    private fun journey(scale:Float) {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val io=Executors.newSingleThreadExecutor();val server=ProductTransportFixture.server;val requests=CopyOnWriteArrayList<String>()
        val client=app.fixtureClient
        val models=ViewModelStore();var graph:AppGraph?=null
        val a="123e4567-e89b-12d3-a456-426614174001";val g="123e4567-e89b-12d3-a456-426614174002";val r="123e4567-e89b-12d3-a456-426614174003"
        val longTitle="A long catalog edition title — 海辺の音楽 that remains available at enlarged text"
        try {
            val prepared=io.submit<AppGraph> {
                server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                    val path=request.url.encodedPath;requests.add(path)
                    fun reply(body:String)=MockResponse.Builder().body(body).build()
                    return when(path) {
                        "/api/v1/library"->reply("""{"tracks":[{"id":7,"title":"Persistent Library song","artist":"Library artist","is_liked":false}],"total":1,"limit":20,"offset":0}""")
                        "/api/v1/musicbrainz/search/artists"->reply("""{"results":[{"mbid":"$a","name":"Catalog artist","score":100}],"total":1,"limit":20,"offset":0}""")
                        "/api/v1/search/releases"->reply("""{"data":[{"id":8,"name":"$longTitle","mbReleaseId":"$r","trackCount":24},{"id":9,"name":"Local metadata only","trackCount":2}],"total":2,"limit":20,"offset":0}""")
                        "/api/v1/artists/$a"->reply("""{"id":"$a","name":"Catalog artist","releases":[{"id":"$g","title":"Artist release group"}]}""")
                        "/api/v1/albums/$r"->{
                            val tracks=(1..24).joinToString(",") {index->"""{"id":"123e4567-e89b-12d3-a456-${(426614174100L+index)}","title":"Catalog recording $index","position":$index,"inLibrary":false,"downloadable":false}"""}
                            reply("""{"id":"$r","title":"$longTitle","trackCount":24,"tracks":[$tracks]}""")
                        }
                        "/api/v1/playback/urls"->reply("""{"urls":[{"trackId":7,"url":"${server.url("/media/7.wav")}","expiresAt":"2030-01-01T00:00:00Z"}]}""")
                        "/media/7.wav"->{
                            check(request.headers["Authorization"]==null)
                            val samples=16000*12;val bytes=java.nio.ByteBuffer.allocate(44+samples*2).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                            bytes.put("RIFF".toByteArray()).putInt(36+samples*2).put("WAVEfmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(16000).putInt(32000).putShort(2).putShort(16).put("data".toByteArray()).putInt(samples*2)
                            repeat(samples){bytes.putShort(0)};MockResponse.Builder().addHeader("Content-Type","audio/wav").body(okio.Buffer().write(bytes.array())).build()
                        }
                        else->MockResponse.Builder().code(404).body("{}").build()
                    }
                }}
                // Keep the runner's trusted graph: its already-bound service owns this same lifetime.
                app.graph.also {it.session.accept(it.session.beginIntent(),SecretTokens("synthetic-a","synthetic-r","catalog-journey"))}
            }.get(10,TimeUnit.SECONDS)
            graph=prepared
            val model=compose.runOnIdle {ProductViewModel(app).also {models.put("catalog",it)}}
            compose.setContent {val density=LocalDensity.current;CompositionLocalProvider(LocalDensity provides Density(density.density,scale)){ProductApp(model)}}
            compose.waitUntil(10000){model.library.value.rows.isNotEmpty() && model.playback.value.connection==com.soundq.android.playback.PlaybackProjection.Connection.Connected}
            compose.onNodeWithText("Persistent Library song").performScrollTo().performClick()
            compose.waitUntil(15000){model.playback.value.isPlaying}
            compose.onNodeWithContentDescription("Pause").performClick()
            compose.waitUntil(5000){!model.playback.value.isPlaying}
            val settlement=compose.settledPausedPlayback(model)
            val paused=settlement.projection
            val queue=paused.queue;val selected=paused.selectedOccurrence
            compose.onNodeWithContentDescription("Settings").performClick()
            compose.onNodeWithText("Music tools").performScrollTo().performClick()
            compose.onNodeWithText("Catalog").performScrollTo().performClick()
            compose.onNodeWithContentDescription("Search catalog").performTextInput("artist")
            compose.onNodeWithContentDescription("Submit catalog search").performScrollTo().performClick()
            compose.waitUntil(10000){prepared.catalog.state.value.search!=null}
            compose.onNodeWithText("Catalog").performScrollTo()
            compose.onNode(hasScrollToNodeAction()).performScrollToNode(hasText("Catalog artist"))
            compose.onNodeWithText("Catalog artist").performClick()
            compose.waitUntil(10000){prepared.catalog.state.value.artist!=null}
            compose.onNodeWithText("Artist release group").performScrollTo().performClick()
            compose.onNodeWithText("Edition unavailable").performScrollTo().assertIsDisplayed()
            assertTrue(requests.none {it=="/api/v1/albums/$g"})
            compose.onNodeWithContentDescription("Back").performScrollTo().performClick()
            compose.waitUntil(5000){prepared.catalog.state.value.group==null}
            compose.onNodeWithContentDescription("Back").performScrollTo().performClick()
            compose.waitUntil(5000){prepared.catalog.state.value.artist==null}
            compose.onNodeWithText("Albums on server").performScrollTo().performClick()
            compose.onNodeWithContentDescription("Submit catalog search").performScrollTo().performClick()
            compose.waitUntil(10000){prepared.catalog.state.value.albums!=null}
            compose.onNodeWithText("Local metadata only").performScrollTo().assertIsNotEnabled()
            compose.onNodeWithText(longTitle).performScrollTo().performClick()
            compose.waitUntil(10000){prepared.catalog.state.value.album!=null}
            compose.onNode(hasScrollToNodeAction()).performScrollToNode(hasText("Catalog recording 24"))
            compose.onNodeWithText("Catalog recording 24").assertIsDisplayed().performClick()
            compose.onNodeWithText("Recording details").assertIsDisplayed()
            compose.onNodeWithText("Duration unavailable").assertExists()
            assertEquals(1,compose.onAllNodesWithContentDescription("Play").fetchSemanticsNodes().size) // Dock only.
            back();compose.onNodeWithText("Recording details").assertDoesNotExist()
            back();compose.waitUntil(5000){prepared.catalog.state.value.album==null}
            // Platform Back dispatch can finish before its posted callback changes the route.
            // Acknowledge each destination before sending the next event, within one 5s budget.
            val returnDeadline=android.os.SystemClock.uptimeMillis()+5000
            val heading=SemanticsMatcher.keyIsDefined(androidx.compose.ui.semantics.SemanticsProperties.Heading)
            compose.onNodeWithContentDescription("Back").performScrollTo().performClick()
            awaitReturnRoute(hasText("Music tools") and heading,returnDeadline)
            back();awaitReturnRoute(hasText("Settings") and heading,returnDeadline)
            back() // Catalog returns to Music tools, then Settings, then the opening Library.
            try {
                awaitReturnRoute(hasContentDescription("Library search query") and hasSetTextAction(),returnDeadline)
            compose.onNode(hasContentDescription("Library search query") and hasSetTextAction()).assertIsDisplayed()
            } catch(failure:Throwable) {
                // Failure-only evidence, never synchronization on the successful path.
                try {captureListeningStage("catalog-return-header-failure")} catch(capture:Throwable) {failure.addSuppressed(capture)}
                throw failure
            }
            assertEquals(queue,model.playback.value.queue);assertEquals(selected,model.playback.value.selectedOccurrence);assertFalse(model.playback.value.isPlaying)
            assertEquals(paused.positionMs,model.playback.value.positionMs)
            compose.runOnIdle {assertActualPausedUnchanged(settlement)}
            assertTrue(requests.none {it.contains("/downloads")||it.contains("source-selections")||it.contains("/queue/items")})
            assertEquals(1,requests.count {it=="/api/v1/playback/urls"})
            captureListeningStage("catalog-return-library")
        } finally {
            compose.runOnIdle {models.clear();graph?.close()}
            io.submit {server.close();client.connectionPool.evictAll();client.dispatcher.executorService.shutdown()}.get(5,TimeUnit.SECONDS)
            io.shutdownNow()
        }
    }
    private fun awaitReturnRoute(matcher:SemanticsMatcher,deadline:Long) {
        val remaining=deadline-android.os.SystemClock.uptimeMillis()
        check(remaining>0) {"Catalog return-route admission exceeded 5s"}
        compose.waitUntil(remaining) {compose.onAllNodes(matcher).fetchSemanticsNodes().size==1}
    }
    private fun back() {InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK);compose.waitForIdle()}
}
