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

    @Test fun songArtworkShowsTheExactProviderWithoutAddingAnotherAction() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val app=instrumentation.targetContext.applicationContext as SoundQApplication
        val server=ProductTransportFixture.server
        val fallback=server.dispatcher
        val releaseYouTube=CountDownLatch(1)
        val query="Badge fixture"
        server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath!="/api/v1/discovery/search")return fallback.dispatch(request)
                check(request.url.queryParameter("q")==query)
                val provider=checkNotNull(request.url.queryParameter("providers"))
                val (candidate,session)=when(provider) {
                    "soundcloud" -> """{"candidateId":"badge-cloud","provider":"soundcloud","sourceUrl":"https://soundcloud.com/fixture/badge","title":"Cloud song","artist":"Fixture Artist","downloadable":true,"durationMs":155000}""" to "123e4567-e89b-12d3-a456-426614174010"
                    "youtube" -> {
                        check(releaseYouTube.await(12,TimeUnit.SECONDS))
                        """{"candidateId":"badge-video","provider":"youtube","sourceUrl":"https://youtu.be/fixture","title":"Video song","artist":"Fixture Artist","downloadable":true,"durationMs":180000}""" to "123e4567-e89b-12d3-a456-426614174011"
                    }
                    else -> error("Unexpected search provider")
                }
                return MockResponse.Builder().body("""{"query":"$query","results":[$candidate],"providers":[{"provider":"$provider","status":"ok"}],"selectionSessionId":"$session","selectionExpiresAt":"2030-01-01T00:00:00Z"}""").build()
            }
        }
        fun assertBadge(title:String,provider:String,wire:String) {
            val mark=hasContentDescription("Source: $provider")
            compose.onNode(mark and hasAnyAncestor(hasTestTag("media-artwork")),useUnmergedTree=true)
                .assertIsDisplayed().assertHasNoClickAction()
            compose.onNode(hasText(title) and mark and hasClickAction()).assertIsDisplayed()
            compose.onNodeWithContentDescription("More for $title").assertIsDisplayed().assertIsEnabled().assertHasClickAction().performClick()
            compose.onNodeWithText("Source details").assertIsDisplayed()
            assertEquals(wire,app.graph.discovery.state.value.inspected!!.candidate.provider.wire)
            compose.onNodeWithContentDescription("Close Source details").performClick()
        }
        try {
            compose.signInThroughSettings("provider-badge@example.test","fixture-only-password"){app.graph.session.capture()!=null}
            compose.onAllNodesWithText("Discover").filterToOne(hasClickAction()).performClick()
            val editor=compose.onNodeWithContentDescription("Music search query")
            editor.performTextInput(query)
            editor.performImeAction()
            compose.waitUntil(8000){compose.onAllNodesWithText("Cloud song").fetchSemanticsNodes().isNotEmpty()}
            assertBadge("Cloud song","SoundCloud","soundcloud")
            releaseYouTube.countDown()
            compose.waitUntil(8000){compose.onAllNodesWithContentDescription("View YouTube results").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("View YouTube results").assertIsDisplayed().performClick()
            assertBadge("Video song","YouTube","youtube")
            if(InstrumentationRegistry.getArguments().getString("discoverCaptures")=="true") {
                val frame=checkNotNull(instrumentation.uiAutomation.takeScreenshot())
                try {
                    java.io.File(instrumentation.targetContext.filesDir,"discover-badges.png").outputStream().use {
                        check(frame.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it))
                    }
                } finally { frame.recycle() }
            }
        } finally { releaseYouTube.countDown();server.dispatcher=fallback;app.graph.session.retire() }
    }

    @Test fun typingShowsSkeletonThenOffersRetryOnlyAfterFailure() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val app=instrumentation.targetContext.applicationContext as SoundQApplication
        val server=ProductTransportFixture.server
        val fallback=server.dispatcher
        val searches=AtomicInteger()
        val release=CountDownLatch(1)
        val query="Automatic fixture"
        server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath!="/api/v1/discovery/search")return fallback.dispatch(request)
                check(request.url.queryParameter("q")==query)
                val provider=checkNotNull(request.url.queryParameter("providers"))
                if(searches.incrementAndGet()<=2) {
                    check(release.await(12,TimeUnit.SECONDS))
                    return MockResponse.Builder().code(503).build()
                }
                if(provider=="youtube")return MockResponse.Builder().body(emptyDiscoveryProvider(query,provider)).build()
                return MockResponse.Builder().body("""{"query":"$query","results":[{"candidateId":"fixture-auto","provider":"soundcloud","sourceUrl":"https://soundcloud.com/fixture/automatic","title":"Recovered source","downloadable":true}],"providers":[{"provider":"soundcloud","status":"ok"}],"selectionSessionId":"123e4567-e89b-12d3-a456-426614174010","selectionExpiresAt":"2030-01-01T00:00:00Z"}""").build()
            }
        }
        fun capture(name:String) {
            if(InstrumentationRegistry.getArguments().getString("discoverCaptures")!="true")return
            val frame=checkNotNull(instrumentation.uiAutomation.takeScreenshot())
            try {java.io.File(instrumentation.targetContext.filesDir,"discover-$name.png").outputStream().use {
                check(frame.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it))
            }} finally {frame.recycle()}
        }
        try {
            compose.signInThroughSettings("auto-discover@example.test","fixture-only-password"){app.graph.session.capture()!=null}
            compose.onAllNodesWithText("Discover").filterToOne(hasClickAction()).performClick()
            val editor=compose.onNodeWithContentDescription("Music search query")
            editor.performTextInput(query)
            val loading=compose.onNodeWithContentDescription("Loading search results")
            compose.waitUntil(8000){searches.get()==2&&compose.onAllNodesWithContentDescription("Loading search results").fetchSemanticsNodes().isNotEmpty()}
            loading.assertIsDisplayed().assertHasNoClickAction()
            compose.onNodeWithText("Searching").assertDoesNotExist()
            compose.onNodeWithContentDescription("Search music",useUnmergedTree=true).assertDoesNotExist()
            editor.performImeAction()
            assertEquals(2,searches.get())
            capture("loading")
            release.countDown()
            compose.waitUntil(8000){compose.onAllNodesWithText("Search unavailable").fetchSemanticsNodes().isNotEmpty()}
            loading.assertDoesNotExist()
            compose.onNodeWithText("Search again").performClick()
            compose.waitUntil(8000){compose.onAllNodesWithText("Recovered source").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("Recovered source").assertIsDisplayed()
            loading.assertDoesNotExist()
            compose.onNodeWithText("Search unavailable").assertDoesNotExist()
            assertEquals(4,searches.get())
            capture("results")
        } finally {release.countDown();server.dispatcher=fallback;app.graph.session.retire()}
    }

    @Test fun heldSoundCloudAppearsAfterAnActionableYouTubeRowWithoutClosingItsDetails() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        val server=ProductTransportFixture.server
        val fallback=server.dispatcher
        val release=CountDownLatch(1)
        val entered=CountDownLatch(2)
        val query="Held providers fixture"
        server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath!="/api/v1/discovery/search")return fallback.dispatch(request)
                check(request.url.queryParameter("q")==query)
                val provider=request.url.queryParameter("providers")!!
                check(provider in setOf("youtube","soundcloud"))
                entered.countDown()
                val slow=provider=="soundcloud"
                if(slow)check(release.await(12,TimeUnit.SECONDS))
                val url=if(slow)"https://soundcloud.com/fixture/held" else "https://youtu.be/fixture"
                val title=if(slow)"Late source fixture" else "First source fixture"
                val suffix=if(slow)"11" else "10"
                return MockResponse.Builder().body("""{"query":"$query","results":[{"candidateId":"same-id","provider":"$provider","sourceUrl":"$url","title":"$title","downloadable":true}],"providers":[{"provider":"$provider","status":"ok"}],"selectionSessionId":"123e4567-e89b-12d3-a456-4266141740$suffix","selectionExpiresAt":"2030-01-01T00:00:00Z"}""").build()
            }
        }
        try {
            compose.signInThroughSettings("held-discover@example.test","fixture-only-password"){app.graph.session.capture()!=null}
            compose.onAllNodesWithText("Discover").filterToOne(hasClickAction()).performClick()
            val editor=compose.onNodeWithContentDescription("Music search query")
            editor.performTextInput(query)
            editor.performImeAction()
            compose.waitUntil(8000){entered.count==0L&&compose.onAllNodesWithText("First source fixture").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Loading search results").assertDoesNotExist()
            compose.onNodeWithText("Late source fixture").assertDoesNotExist()
            compose.onNodeWithText("First source fixture").assertIsDisplayed().performClick()
            compose.onNodeWithText("Source details").assertIsDisplayed()
            val accepted=app.graph.discovery.state.value.inspected!!
            assertEquals("youtube",accepted.candidate.provider.wire)
            release.countDown()
            compose.waitUntil(8000){app.graph.discovery.state.value.results?.rows?.size==2}
            assertSame(accepted,app.graph.discovery.state.value.inspected)
            compose.onNodeWithContentDescription("Close Source details").performClick()
            compose.onNodeWithContentDescription("View SoundCloud results").assertIsDisplayed().performClick()
            compose.onNodeWithText("Late source fixture").assertIsDisplayed().performClick()
            compose.onNodeWithText("Source details").assertIsDisplayed()
            assertEquals("soundcloud",app.graph.discovery.state.value.inspected!!.candidate.provider.wire)
        } finally {release.countDown();server.dispatcher=fallback;app.graph.session.retire()}
    }

    @Test fun searchInspectExplicitDecisionImportJobLibraryAndNoImplicitPlayback() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        val server=ProductTransportFixture.server;val original=server.dispatcher;val fixture=DiscoveryDispatcher(original);server.dispatcher=fixture
        try {
            compose.signInThroughSettings("discover@example.test","fixture-only-password"){app.graph.session.capture()!=null}
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
            compose.onNodeWithContentDescription("Music search query").performTextInput("Source fixture")
            assertEquals(0,fixture.decisions.get())
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
            compose.onNodeWithContentDescription("Imports",useUnmergedTree=true).performClick()
            // At 2x text the source continuation fills the viewport; the job item is not composed.
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Check import"))
            compose.onNodeWithText("Check import").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.imports.state.value.selected?.track?.value==71L}
            compose.onNodeWithText("Open in Library").performScrollTo().performClick()
            compose.waitUntil(10000){compose.onAllNodesWithText("Discovered Library fixture").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("Discovered Library fixture").assertIsDisplayed()
            assertEquals(queue,model.playback.value.queue);assertEquals(selected,model.playback.value.selectedOccurrence);assertFalse(model.playback.value.isPlaying)
            assertEquals(2,fixture.searches.get());assertEquals(1,fixture.decisions.get());assertEquals(1,fixture.queues.get())
        }finally {fixture.release.countDown();server.dispatcher=original;app.graph.session.retire()}
    }
}
private class DiscoveryDispatcher(private val fallback:Dispatcher):Dispatcher() {
    val searches=AtomicInteger();val decisions=AtomicInteger();val queues=AtomicInteger();val entered=CountDownLatch(1);val release=CountDownLatch(1)
    private val session="123e4567-e89b-12d3-a456-426614174010";private val decision="123e4567-e89b-12d3-a456-426614174020";private val job="123e4567-e89b-12d3-a456-426614174071"
    private val candidate="""{"candidateId":"candidate-1","provider":"youtube","sourceUrl":"https://youtu.be/fixture","title":"Found source fixture","artist":"Synthetic artist","downloadable":true,"playable":false}"""
    override fun dispatch(request:RecordedRequest):MockResponse {
        val path=request.url.encodedPath
        if(path=="/api/v1/discovery/search"){searches.incrementAndGet();check(request.url.queryParameter("q")=="Source fixture");if(request.url.queryParameter("providers")=="soundcloud")return reply(emptyDiscoveryProvider("Source fixture","soundcloud"));return reply("""{"query":"Source fixture","results":[$candidate],"providers":[{"provider":"youtube","status":"ok"}],"selectionRequired":true,"selectionSessionId":"$session","selectionExpiresAt":"2030-01-01T00:00:00Z"}""")}
        if(path=="/api/v1/source-selections"&&request.method=="POST"){decisions.incrementAndGet();entered.countDown();check(release.await(10,TimeUnit.SECONDS));return reply("""{"id":"$decision","sessionId":"$session","selectedCandidateId":"candidate-1","action":"selected","selectedCandidate":$candidate}""",201)}
        if(path=="/api/v1/queue/items"&&request.method=="POST"){queues.incrementAndGet();check(request.body!!.utf8()=="""{"sourceDecisionId":"$decision","position":"last"}""");return reply("""{"queue":{"items":[]},"downloadJobId":"$job","idempotent":false}""",202)}
        if(path=="/api/v1/downloads/$job")return reply("""{"job_id":"$job","status":"complete","progress":100,"track_id":71,"source_type":"youtube","created_at":"2026-10-29T00:00:00Z"}""")
        if(path=="/api/v1/library"&&queues.get()>0)return reply("""{"tracks":[{"id":71,"title":"Discovered Library fixture","is_liked":false}],"total":1,"limit":20,"offset":0}""")
        return fallback.dispatch(request)
    }
    private fun reply(body:String,code:Int=200)=MockResponse.Builder().code(code).body(body).build()
}

internal fun emptyDiscoveryProvider(query:String,provider:String):String = org.json.JSONObject()
    .put("query",query).put("results",org.json.JSONArray()).put("providers",org.json.JSONArray().put(org.json.JSONObject().put("provider",provider).put("status","ok"))).toString()
