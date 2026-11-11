package com.soundq.android

import android.content.Intent
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

/** Real Android Intent and mounted native actions. Compiled here, execution requires runtime admission. */
class AcquisitionShareJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun shareThenSignInExplicitImportAcknowledgedLibraryAndPlaylistProgress() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val app=instrumentation.targetContext.applicationContext as SoundQApplication
        val activity=compose.activity
        val launchIntent=compose.runOnIdle {Intent(activity.intent)}
        val server=ProductTransportFixture.server;val original=server.dispatcher;val posts=AtomicInteger();val playlistPosts=AtomicInteger()
        val id="123e4567-e89b-12d3-a456-426614174071"
        server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            fun reply(body:String,code:Int=200)=MockResponse.Builder().code(code).body(body).build()
            val path=request.url.encodedPath
            if(path=="/api/v1/downloads"&&request.method=="POST"){posts.incrementAndGet();return reply("""{"job_id":"$id","status":"queued"}""",201)}
            if(path=="/api/v1/downloads/$id")return reply("""{"job_id":"$id","status":"complete","progress":100,"track_id":71,"source_type":"youtube","created_at":"2026-10-29T00:00:00Z"}""")
            if(path=="/api/v1/library"&&posts.get()>0)return reply("""{"tracks":[{"id":71,"title":"Shared fixture","artist":"Synthetic ensemble","is_liked":false}],"total":1,"limit":20,"offset":0}""")
            if(path=="/api/v1/queue")return reply("""{"items":[],"currentPosition":0,"updatedAt":"2026-10-29T00:00:00Z"}""")
            if(path=="/api/v1/playlist-imports"&&request.method=="POST")playlistPosts.incrementAndGet()
            if(path.startsWith("/api/v1/playlist-imports"))return reply("""{"id":"$id","playlistId":17,"status":"complete","totalItems":1,"importedItems":1,"queuedItems":0,"failedItems":0,"skippedItems":0,"items":[{"id":7,"title":"Playlist fixture","status":"imported","trackId":71}]}""",if(request.method=="POST")202 else 200)
            return original.dispatch(request)
        }}
        try {
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.runOnUiThread {compose.activity.startActivity(Intent(compose.activity,MainActivity::class.java).setAction(Intent.ACTION_SEND).setType("text/plain").addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP).putExtra(Intent.EXTRA_TEXT,"Fixture https://youtu.be/shared-fixture"))}
            compose.onNodeWithText("Shared music link retained. Sign in, then confirm the import.").assertExists()
            compose.runOnIdle {
                assertSame(activity,compose.activity)
                assertEquals(Intent.ACTION_MAIN,launchIntent.action)
                assertEquals(Intent.ACTION_SEND,activity.intent.action)
                assertEquals("text/plain",activity.intent.type)
                assertEquals("Fixture https://youtu.be/shared-fixture",activity.intent.getStringExtra(Intent.EXTRA_TEXT))
            }
            assertEquals(0,posts.get())
            compose.onNodeWithContentDescription("Email").performTextInput("share-fixture@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Review shared link").fetchSemanticsNodes().isNotEmpty()}
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            val queue=model.playback.value.queue;val selected=model.playback.value.selectedOccurrence
            compose.onNodeWithContentDescription("Review shared link").performClick()
            compose.onNodeWithText("Shared link").assertExists()
            compose.onNodeWithText("Review shared link").performClick()
            assertEquals(0,posts.get())
            compose.onNodeWithText("Import",useUnmergedTree=true).performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.imports.state.value.acknowledgement!=null}
            compose.onNodeWithText("Check import").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.imports.state.value.selected?.track?.value==71L}
            compose.onNodeWithText("Open in Library").performScrollTo().performClick()
            compose.waitUntil(10000){compose.onAllNodesWithText("Shared fixture").fetchSemanticsNodes().isNotEmpty()}
            assertEquals(queue,model.playback.value.queue);assertEquals(selected,model.playback.value.selectedOccurrence);assertFalse(model.playback.value.isPlaying)
            compose.onNode(hasScrollToIndexAction()).performScrollToIndex(0)
            compose.onNodeWithContentDescription("Account and settings").performClick()
            compose.onNodeWithText("Server import jobs and research").performClick()
            compose.onNodeWithText("YouTube playlist").performScrollTo().performClick().assertIsSelected()
            val playlistUrl=hasText("YouTube playlist URL") and hasSetTextAction()
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(playlistUrl)
            compose.onNode(playlistUrl).assertIsDisplayed().performTextInput("https://youtube.com/playlist?list=PLfixture")
            compose.onNode(playlistUrl).assertTextContains("https://youtube.com/playlist?list=PLfixture")
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Import playlist"))
            compose.onNodeWithText("Import playlist").assertIsEnabled().performClick()
            compose.waitUntil(10000){app.graph.acquisition.state.value.playlist?.playlistId==17L}
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Playlist fixture · imported"))
            compose.onNodeWithText("Playlist fixture · imported").assertIsDisplayed()
            assertEquals(queue,model.playback.value.queue);assertEquals(selected,model.playback.value.selectedOccurrence);assertFalse(model.playback.value.isPlaying);assertEquals(1,posts.get());assertEquals(1,playlistPosts.get())
            compose.runOnIdle {
                assertSame(activity,compose.activity)
                assertEquals(Intent.ACTION_SEND,activity.intent.action)
            }
            println("SERVICES_DIAGNOSTIC completed share-library-playlist playlist=17 imported=1 downloadPosts=${posts.get()} playlistPosts=${playlistPosts.get()} queueUnchanged=true selectionUnchanged=true playing=false")
        }finally {
            try {
                // AndroidX core 1.7.0 matches lifecycle events against the launch Intent.
                // Restore only after the real SEND journey, including on assertion failure.
                instrumentation.runOnMainSync { activity.intent=launchIntent }
                println("SHARE_LIFECYCLE restored launch intent for native rule teardown")
            }finally {server.dispatcher=original;app.graph.session.retire()}
        }
    }
}
