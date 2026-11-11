package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger

/** Parent executes on its reserved runtime. Uses real mounted route and TLS fixture. */
class DiscoveryJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun searchInspectExplicitDecisionImportJobLibraryAndNoImplicitPlayback() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        val server=ProductTransportFixture.server;val original=server.dispatcher;val fixture=DiscoveryDispatcher(original);server.dispatcher=fixture
        try {
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("discover@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("fixture-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){app.graph.library.state.value.rows.isNotEmpty()}
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            val libraryRow=hasText("Fixture 1") and hasClickAction() and hasAnyDescendant(hasContentDescription("More for Fixture 1"))
            compose.onNode(libraryRow).performClick()
            compose.waitUntil(15000){model.playback.value.isPlaying}
            compose.onNodeWithContentDescription("Pause").performClick()
            compose.waitUntil(10000){!model.playback.value.isPlaying}
            val queue=model.playback.value.queue;val selected=model.playback.value.selectedOccurrence
            assertTrue(queue.isNotEmpty())
            compose.onAllNodesWithText("Discover").filterToOne(hasClickAction()).performClick()
            compose.onNodeWithContentDescription("Search sources").performTextInput("Source fixture")
            assertEquals(0,fixture.searches.get());assertEquals(0,fixture.decisions.get())
            compose.onNodeWithContentDescription("Search",useUnmergedTree=true).performScrollTo().performClick()
            compose.waitUntil(10000){compose.onAllNodesWithText("Found source fixture").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("Found source fixture").performScrollTo().performClick()
            compose.onNodeWithText("Source details").assertExists();assertEquals(0,fixture.decisions.get())
            compose.onNodeWithText("Import source").performScrollTo().performClick()
            compose.onNodeWithText("Import to Library").performScrollTo().performClick()
            assertTrue(fixture.entered.await(3,TimeUnit.SECONDS))
            assertEquals(1,fixture.decisions.get());assertEquals(0,fixture.queues.get())
            fixture.release.countDown()
            compose.waitUntil(10000){app.graph.imports.state.value.acknowledgement!=null}
            compose.onNodeWithContentDescription("Close Source details").performClick()
            compose.onNodeWithContentDescription("Imports",useUnmergedTree=true).performScrollTo().performClick()
            // At 2x text the source continuation fills the viewport; the job item is not composed.
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Check import"))
            compose.onNodeWithText("Check import").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.imports.state.value.selected?.track?.value==71L}
            compose.onNodeWithText("Open in Library").performScrollTo().performClick()
            compose.waitUntil(10000){compose.onAllNodesWithText("Discovered Library fixture").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("Discovered Library fixture").assertIsDisplayed()
            assertEquals(queue,model.playback.value.queue);assertEquals(selected,model.playback.value.selectedOccurrence);assertFalse(model.playback.value.isPlaying)
            assertEquals(1,fixture.searches.get());assertEquals(1,fixture.decisions.get());assertEquals(1,fixture.queues.get())
        }finally {fixture.release.countDown();server.dispatcher=original;app.graph.session.retire()}
    }
}
private class DiscoveryDispatcher(private val fallback:Dispatcher):Dispatcher() {
    val searches=AtomicInteger();val decisions=AtomicInteger();val queues=AtomicInteger();val entered=CountDownLatch(1);val release=CountDownLatch(1)
    private val session="123e4567-e89b-12d3-a456-426614174010";private val decision="123e4567-e89b-12d3-a456-426614174020";private val job="123e4567-e89b-12d3-a456-426614174071"
    private val candidate="""{"candidateId":"candidate-1","provider":"youtube","sourceUrl":"https://youtu.be/fixture","title":"Found source fixture","artist":"Synthetic artist","downloadable":true,"playable":false}"""
    override fun dispatch(request:RecordedRequest):MockResponse {
        val path=request.url.encodedPath
        if(path=="/api/v1/discovery/search"){searches.incrementAndGet();check(request.url.queryParameter("q")=="Source fixture");return reply("""{"query":"Source fixture","results":[$candidate],"providers":[{"provider":"youtube","status":"ok"}],"selectionRequired":true,"selectionSessionId":"$session","selectionExpiresAt":"2030-01-01T00:00:00Z"}""")}
        if(path=="/api/v1/source-selections"&&request.method=="POST"){decisions.incrementAndGet();entered.countDown();check(release.await(10,TimeUnit.SECONDS));return reply("""{"id":"$decision","sessionId":"$session","selectedCandidateId":"candidate-1","action":"selected","selectedCandidate":$candidate}""",201)}
        if(path=="/api/v1/queue/items"&&request.method=="POST"){queues.incrementAndGet();check(request.body!!.utf8()=="""{"sourceDecisionId":"$decision","position":"last"}""");return reply("""{"queue":{"items":[]},"downloadJobId":"$job","idempotent":false}""",202)}
        if(path=="/api/v1/downloads/$job")return reply("""{"job_id":"$job","status":"complete","progress":100,"track_id":71,"source_type":"youtube","created_at":"2026-10-29T00:00:00Z"}""")
        if(path=="/api/v1/library"&&queues.get()>0)return reply("""{"tracks":[{"id":71,"title":"Discovered Library fixture","is_liked":false}],"total":1,"limit":20,"offset":0}""")
        return fallback.dispatch(request)
    }
    private fun reply(body:String,code:Int=200)=MockResponse.Builder().code(code).body(body).build()
}
