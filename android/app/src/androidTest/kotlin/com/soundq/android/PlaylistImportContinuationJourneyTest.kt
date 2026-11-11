package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import kotlinx.serialization.json.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** Mounted acceptance selector. Parent owns SDK/device execution; no real server is contacted. */
class PlaylistImportContinuationJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun descriptionProgressPartialOpenBackAndReceiptRestoreNeverPlay() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        app.graph.session.retire()
        val server=ProductTransportFixture.server;val fallback=server.dispatcher
        val posts=AtomicInteger();val phase=AtomicReference("importing");val payload=AtomicReference<JsonObject>()
        val job="123e4567-e89b-12d3-a456-426614174091"
        fun progress():String {
            val active=phase.get()=="importing"
            return """{"id":"$job","playlistId":17,"sourceTitle":"Source night route","status":"${phase.get()}","totalItems":2,"importedItems":1,"queuedItems":${if(active)1 else 0},"failedItems":${if(active)0 else 1},"skippedItems":0,"items":[{"id":1,"title":"Ready entry","status":"imported","trackId":71},{"id":2,"title":"Unavailable entry","status":"${if(active)"queued" else "failed"}"${if(active)"" else ",\"error\":\"private video\""}}]}"""
        }
        server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            val path=request.url.encodedPath
            fun reply(body:String,code:Int=200)=MockResponse.Builder().code(code).body(body).build()
            if(path=="/api/v1/queue")return reply("""{"items":[],"currentPosition":0,"updatedAt":"2026-10-29T00:00:00Z"}""")
            if(path=="/api/v1/playlist-imports"&&request.method=="POST") {
                posts.incrementAndGet();payload.set(Json.parseToJsonElement(request.body!!.utf8()).jsonObject)
                return reply(progress(),202)
            }
            if(path=="/api/v1/playlist-imports/$job")return reply(progress())
            if(path=="/api/v1/playlists/17")return reply("""{"id":17,"name":"Imported night route","description":"Evening set","isPublic":false,"trackCount":1,"durationMs":12000,"tracks":[{"id":71,"title":"Ready entry","artist":"Synthetic ensemble","durationMs":12000}]}""")
            return fallback.dispatch(request)
        }}
        try {
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("playlist-import@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){app.graph.library.state.value.rows.isNotEmpty()}
            val model=compose.runOnIdle{ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            val before=model.playback.value
            compose.onAllNodesWithText("Discover").filterToOne(hasClickAction()).performClick()
            compose.onNodeWithContentDescription("Discover options").performClick()
            compose.onNodeWithText("Server tools").assertIsDisplayed().performClick()
            compose.onNodeWithText("YouTube playlist").performScrollTo().performClick()
            fun scroll(matcher:SemanticsMatcher){compose.onNodeWithTag("acquisition-list").performScrollToNode(matcher)}
            fun fill(label:String,value:String){val match=hasText(label) and hasSetTextAction();scroll(match);compose.onNode(match).performTextReplacement(value)}
            fill("YouTube playlist URL","https://youtube.com/playlist?list=PLfixture")
            fill("New playlist name (optional)","Evening")
            fill("Playlist description (optional)","Evening set")
            fill("Maximum items (1–1000)","42")
            scroll(hasText("Import playlist"));compose.onNodeWithText("Import playlist").performClick()
            compose.waitUntil(10000){app.graph.acquisition.state.value.playlist?.status=="importing"}
            assertEquals("Evening set",payload.get()["description"]!!.jsonPrimitive.content)
            assertEquals(42,payload.get()["maxItems"]!!.jsonPrimitive.int)
            scroll(hasText("Importing entries"));compose.onNodeWithText("Source night route").assertIsDisplayed()
            phase.set("partial_failure")
            scroll(hasContentDescription("Check playlist progress"));compose.onNodeWithContentDescription("Check playlist progress").performClick()
            compose.waitUntil(10000){app.graph.acquisition.state.value.playlist?.status=="partial_failure"&&!app.graph.acquisition.state.value.busy}
            scroll(hasText("Private video"));compose.onNodeWithText("Private video").assertIsDisplayed()
            captureListeningStage("playlist-import-partial")
            scroll(hasText("Open playlist"));compose.onNodeWithText("Open playlist").performClick()
            compose.waitUntil(10000){app.graph.playlistDetail.state.value.detail?.playlist?.id?.value==17L}
            compose.onNodeWithText("Imported night route").assertExists()
            captureListeningStage("playlist-import-opened")
            compose.onNodeWithContentDescription("Back to playlists").performClick()
            compose.waitUntil(10000){compose.onAllNodesWithTag("acquisition-list").fetchSemanticsNodes().isNotEmpty()&&!app.graph.acquisition.state.value.busy}
            scroll(hasText("Playlist description (optional)") and hasSetTextAction())
            compose.onNode(hasText("Playlist description (optional)") and hasSetTextAction()).assertTextContains("Evening set")
            scroll(hasText("YouTube playlist"));compose.onNodeWithText("Jobs").performClick()
            scroll(hasText("Check playlist import"));compose.onNodeWithText("Check playlist import").performClick()
            compose.waitUntil(10000){app.graph.acquisition.state.value.playlist?.id?.value==job&&!app.graph.acquisition.state.value.busy}
            scroll(hasText("Open playlist"));compose.onNodeWithText("Open playlist").performClick()
            compose.waitUntil(10000){app.graph.playlistDetail.state.value.detail?.playlist?.id?.value==17L}
            assertEquals(1,posts.get());assertEquals(before.queue,model.playback.value.queue)
            assertEquals(before.selectedOccurrence,model.playback.value.selectedOccurrence);assertFalse(model.playback.value.isPlaying)
        } finally {server.dispatcher=fallback;app.graph.session.retire()}
    }
}
