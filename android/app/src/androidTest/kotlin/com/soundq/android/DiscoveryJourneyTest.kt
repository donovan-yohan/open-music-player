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

    private fun callbackFixtureApp(): CallbackFrontendFixtureApplication {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext
        check(app is CallbackFrontendFixtureApplication) {
            "Select registered CallbackFrontendFixtureRunner, not ProductFixtureRunner"
        }
        return app
    }

    @Test fun mountedRowKeepsSpinnerThroughSameAccountSaveAndReopensOnlyExactPreview() {
        val app=callbackFixtureApp()
        val server=ProductTransportFixture.server
        val fallback=server.dispatcher
        val enteredSave=CountDownLatch(1);val releaseSave=CountDownLatch(1)
        val calls=CopyOnWriteArrayList<String>();val refreshes=AtomicInteger();val writes=AtomicInteger()
        val key="https://www.youtube.com/watch?v=SQPreview01"
        val title="Held save source";val query="Same account fixture"
        val fresh="rotated-preview-fixture-access"
        val tail=HeldPreviewTail();val bytes=previewFixtureBytes()
        app.beforeFixtureSessionSave={tokens->
            if(tokens.access==fresh) {check(android.os.Looper.myLooper()!=android.os.Looper.getMainLooper());enteredSave.countDown();check(releaseSave.await(15,TimeUnit.SECONDS))}
        }
        server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                val path=request.url.encodedPath
                val bearer=request.headers["Authorization"]
                when(path) {
                    "/api/v1/discovery/search" -> {
                        check(request.url.queryParameter("q")==query)
                        val provider=checkNotNull(request.url.queryParameter("providers"))
                        return MockResponse.Builder().body(if(provider=="soundcloud")emptyDiscoveryProvider(query,provider) else
                            """{"query":"$query","results":[{"candidateId":"held-save","title":"$title","provider":"youtube","sourceUrl":"https://youtu.be/fixture","previewSourceUrl":"$key","downloadable":true}],"providers":[{"provider":"youtube","status":"ok"}],"selectionSessionId":"123e4567-e89b-12d3-a456-426614174010","selectionExpiresAt":"2030-01-01T00:00:00Z"}""").build()
                    }
                    "/api/v1/discovery/preview" -> {
                        check(request.method=="POST"&&org.json.JSONObject(request.body!!.utf8()).getString("url")==key)
                        calls.add(checkNotNull(bearer))
                        return when(bearer) {
                            "Bearer synthetic-fixture-access" -> MockResponse.Builder().code(401).build()
                            "Bearer $fresh" -> previewFixtureResponse(bytes,tail)
                            else -> error("Unexpected synthetic bearer")
                        }
                    }
                    "/api/v1/auth/refresh" -> {
                        refreshes.incrementAndGet()
                        return MockResponse.Builder().body("""{"accessToken":"$fresh","refreshToken":"rotated-preview-fixture-refresh","user":{"id":"fixture-account"}}""").build()
                    }
                }
                if(request.method=="POST"&&path in setOf("/api/v1/downloads","/api/v1/source-selections","/api/v1/queue/items","/api/v1/me/plays"))writes.incrementAndGet()
                return fallback.dispatch(request)
            }
        }
        try {
            compose.signInThroughSettings("held-preview-save@example.test","fixture-only-password"){app.graph.session.capture()!=null}
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            compose.onAllNodesWithText("Discover").filterToOne(hasClickAction()).performClick()
            compose.onNodeWithContentDescription("Music search query").performTextInput(query)
            compose.waitUntil(8000){app.graph.discovery.state.value.results?.batches?.size==2}
            val before=model.playback.value
            val scope=checkNotNull(app.graph.session.capture())
            compose.onNode(hasText(title) and hasClickAction()).performClick()
            val spinner=hasContentDescription("Loading preview for $title")
            compose.waitUntil(8000){enteredSave.count==0L&&compose.onAllNodes(spinner,useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty()}
            compose.onNode(spinner,useUnmergedTree=true).assertIsDisplayed().assertHasNoClickAction()
            compose.onNodeWithText("Source details").assertDoesNotExist()
            // Pump the mounted watcher through the save gap, not just a pre-save snapshot.
            repeat(4) { compose.mainClock.advanceTimeBy(60);compose.waitForIdle();compose.onNode(spinner,useUnmergedTree=true).assertIsDisplayed() }
            assertNull(app.graph.session.capture());assertTrue(app.graph.session.previewOwnerCurrent(scope))
            assertEquals(before.selectedOccurrence,model.playback.value.selectedOccurrence)
            assertEquals(listOf("Bearer synthetic-fixture-access"),calls.toList());assertEquals(1L,releaseSave.count)
            releaseSave.countDown()
            compose.waitUntil(8000){tail.prefixSent.count==0L&&model.playback.value.let {it.title==title&&it.isPlaying&&it.positionMs>0}}
            compose.onNode(spinner,useUnmergedTree=true).assertDoesNotExist()
            assertEquals(listOf("Bearer synthetic-fixture-access","Bearer $fresh"),calls.toList());assertEquals(1,refreshes.get())
            assertEquals(0,writes.get());assertNull(app.graph.imports.state.value.acknowledgement)
        } finally {
            releaseSave.countDown();tail.release.countDown();app.beforeFixtureSessionSave=null
            server.dispatcher=fallback;app.graph.session.retire()
        }
    }

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
            compose.onNodeWithContentDescription("Add to Library: $title").assertIsDisplayed().assertIsEnabled().assertHasClickAction().performClick()
            compose.onNodeWithText("Import source").assertIsDisplayed()
            assertEquals(wire,app.graph.imports.state.value.sourcePlan!!.choice.candidate.provider.wire)
            compose.onNodeWithContentDescription("Close Import source").performClick()
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
            compose.waitUntil(8000){app.graph.discovery.state.value.results?.rows?.size==2}
            compose.onNodeWithTag("discover-list").performScrollToNode(hasText("Video song") and hasClickAction())
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

    @Test fun heldSoundCloudAppendsWithoutChangingEarlyPreviewOrExactAddChoice() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        val server=ProductTransportFixture.server
        val fallback=server.dispatcher
        val release=CountDownLatch(1)
        val entered=CountDownLatch(2)
        val first=HeldPreviewTail(3)
        val previewUrls=java.util.concurrent.CopyOnWriteArrayList<String>()
        val audio=previewFixtureBytes()
        val query="Held providers fixture"
        server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                val path=request.url.encodedPath
                if(path=="/api/v1/discovery/preview") {
                    check(request.method=="POST"&&request.headers["Authorization"]=="Bearer synthetic-fixture-access")
                    val exact=org.json.JSONObject(request.body!!.utf8()).getString("url")
                    previewUrls.add(exact)
                    return when(exact) {
                        "https://www.youtube.com/watch?v=SQPreview01"->previewFixtureResponse(audio,first)
                        "https://soundcloud.com/fixture/held"->previewFixtureResponse(audio)
                        else->error("Wrong exact preview key")
                    }
                }
                check(request.method!="POST"||path !in setOf("/api/v1/downloads","/api/v1/source-selections","/api/v1/queue/items"))
                if(path!="/api/v1/discovery/search")return fallback.dispatch(request)
                check(request.url.queryParameter("q")==query)
                val provider=request.url.queryParameter("providers")!!
                check(provider in setOf("youtube","soundcloud"))
                entered.countDown()
                val slow=provider=="soundcloud"
                if(slow)check(release.await(12,TimeUnit.SECONDS))
                val url=if(slow)"https://soundcloud.com/fixture/held" else "https://youtu.be/fixture"
                val previewKey=if(slow)url else "https://www.youtube.com/watch?v=SQPreview01"
                val title=if(slow)"Late source fixture" else "First source fixture"
                val suffix=if(slow)"11" else "10"
                return MockResponse.Builder().body("""{"query":"$query","results":[{"candidateId":"same-id","provider":"$provider","sourceUrl":"$url","previewSourceUrl":"$previewKey","title":"$title","downloadable":true}],"providers":[{"provider":"$provider","status":"ok"}],"selectionSessionId":"123e4567-e89b-12d3-a456-4266141740$suffix","selectionExpiresAt":"2030-01-01T00:00:00Z"}""").build()
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
            val spinner=hasContentDescription("Loading preview for First source fixture")
            compose.waitUntil(8000){first.prefixSent.count==0L&&compose.onAllNodes(spinner,useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Add to Library: First source fixture").performClick()
            val plan=app.graph.imports.state.value.sourcePlan!!
            assertEquals("youtube",plan.choice.candidate.provider.wire)
            assertEquals("https://youtu.be/fixture",plan.choice.candidate.source.url)
            assertEquals("123e4567-e89b-12d3-a456-426614174010",plan.choice.selection.id)
            val page=app.graph.discovery.state.value.results!!
            release.countDown()
            compose.waitUntil(8000){app.graph.discovery.state.value.results?.rows?.size==2}
            val appended=app.graph.discovery.state.value.results!!
            assertSame(page.identity,appended.identity)
            assertSame(page.batches.single(),appended.batches.first())
            assertSame(plan,app.graph.imports.state.value.sourcePlan)
            assertTrue(plan.choice.valid())
            assertEquals(listOf("https://www.youtube.com/watch?v=SQPreview01"),previewUrls.toList())
            compose.onNodeWithContentDescription("Close Import source").performClick()
            compose.onNode(spinner,useUnmergedTree=true).assertIsDisplayed()
            compose.onNodeWithTag("discover-list").performScrollToNode(hasText("Late source fixture") and hasClickAction())
            compose.onNodeWithText("Late source fixture").assertIsDisplayed().performClick()
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            compose.waitUntil(8000){model.playback.value.let {it.title=="Late source fixture"&&it.isPlaying&&it.positionMs>0}}
            first.release.countDown()
            compose.onNode(spinner,useUnmergedTree=true).assertDoesNotExist()
            assertEquals("Late source fixture",model.playback.value.title)
            assertEquals(listOf("https://www.youtube.com/watch?v=SQPreview01","https://soundcloud.com/fixture/held"),previewUrls.toList())
        } finally {release.countDown();first.release.countDown();server.dispatcher=fallback;app.graph.session.retire()}
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
            val loading=hasContentDescription("Loading preview for Found source fixture")
            compose.waitUntil(10000){fixture.previews.get()==1&&compose.onAllNodes(loading,useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty()}
            compose.onNode(loading,useUnmergedTree=true).assertIsDisplayed().assertHasNoClickAction()
            compose.onNodeWithContentDescription("Play preview for Found source fixture",useUnmergedTree=true).assertDoesNotExist()
            compose.onNodeWithText("Source details").assertDoesNotExist()
            assertEquals(0,fixture.decisions.get());assertEquals(queue,model.playback.value.queue)
            compose.onNodeWithContentDescription("Add to Library: Found source fixture").assertIsEnabled().performClick()
            compose.onNodeWithText("Import to Library").performScrollTo().performClick()
            compose.waitUntil(10000){fixture.entered.count==0L}
            assertEquals(1,fixture.previews.get())
            assertEquals(1,fixture.decisions.get());assertEquals(0,fixture.queues.get())
            fixture.release.countDown()
            compose.waitUntil(10000){app.graph.imports.state.value.acknowledgement!=null}
            compose.onNodeWithContentDescription("Imports",useUnmergedTree=true).performClick()
            fixture.releasePreview.countDown()
            // At 2x text the source continuation fills the viewport; the job item is not composed.
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Check import"))
            compose.onNodeWithText("Check import").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.imports.state.value.selected?.track?.value==71L}
            compose.onNodeWithText("Open in Library").performScrollTo().performClick()
            compose.waitUntil(10000){compose.onAllNodesWithText("Discovered Library fixture").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("Discovered Library fixture").assertIsDisplayed()
            assertEquals(queue,model.playback.value.queue);assertEquals(selected,model.playback.value.selectedOccurrence);assertFalse(model.playback.value.isPlaying)
            assertEquals(2,fixture.searches.get());assertEquals(1,fixture.decisions.get());assertEquals(1,fixture.queues.get())
        }finally {fixture.release.countDown();fixture.releasePreview.countDown();server.dispatcher=original;app.graph.session.retire()}
    }

    /** Run with CallbackFrontendFixtureRunner to exercise the shipping playback engine. */
    @Test fun onlyNewestPendingSearchPreviewCanTakeOverPlayingAudio() {
        val app=callbackFixtureApp()
        val server=ProductTransportFixture.server;val fallback=server.dispatcher
        val audio=previewFixtureBytes()
        val first=HeldPreviewTail(3);val second=CountDownLatch(1);val releaseSecond=CountDownLatch(1)
        val calls=java.util.concurrent.CopyOnWriteArrayList<String>()
        val query="Competing previews"
        server.dispatcher=object:Dispatcher() {override fun dispatch(request:RecordedRequest):MockResponse {
            val path=request.url.encodedPath
            if(path=="/api/v1/discovery/search") {
                check(request.url.queryParameter("q")==query)
                val provider=request.url.queryParameter("providers")
                if(provider=="soundcloud")return MockResponse.Builder().body(emptyDiscoveryProvider(query,provider)).build()
                check(provider=="youtube")
                val rows=listOf("alpha","bravo").joinToString(",") {name->
                    val key=if(name=="alpha")"SQPreview01" else "SQPreview02"
                    """{"candidateId":"$name","title":"Preview $name","provider":"youtube","sourceUrl":"https://youtu.be/$name","previewSourceUrl":"https://www.youtube.com/watch?v=$key","downloadable":true}"""
                }
                return MockResponse.Builder().body("""{"query":"$query","results":[$rows],"providers":[{"provider":"youtube","status":"ok"}],"selectionSessionId":"123e4567-e89b-12d3-a456-426614174010","selectionExpiresAt":"2030-01-01T00:00:00Z"}""").build()
            }
            if(path=="/api/v1/discovery/preview") {
                check(request.method=="POST"&&request.headers["Authorization"]=="Bearer synthetic-fixture-access")
                val url=org.json.JSONObject(request.body!!.utf8()).getString("url");calls.add(url)
                when(url) {
                    "https://www.youtube.com/watch?v=SQPreview01"->return previewFixtureResponse(audio,first)
                    "https://www.youtube.com/watch?v=SQPreview02"->{second.countDown();check(releaseSecond.await(15,TimeUnit.SECONDS))}
                    else->error("Unexpected preview target")
                }
                return previewFixtureResponse(audio)
            }
            check(request.method!="POST"||path !in setOf("/api/v1/downloads","/api/v1/source-selections","/api/v1/queue/items"))
            return fallback.dispatch(request)
        }}
        try {
            compose.signInThroughSettings("preview-latest@example.test","fixture-only-password"){app.graph.session.capture()!=null}
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            compose.waitUntil(10000){model.library.value.rows.isNotEmpty()}
            compose.onNode(hasText("Fixture 1") and hasClickAction() and hasAnyDescendant(hasContentDescription("More for Fixture 1"))).performClick()
            compose.waitUntil(10000){model.playback.value.let {it.isPlaying&&it.positionMs>0}}
            val playing=model.playback.value
            compose.onAllNodesWithText("Discover").filterToOne(hasClickAction()).performClick()
            compose.onNodeWithContentDescription("Music search query").performTextInput(query)
            compose.waitUntil(10000){app.graph.discovery.state.value.results?.query==query}
            fun tap(name:String)=compose.onNodeWithText("Preview $name").performScrollTo().performClick()
            fun loading(name:String)=compose.onNodeWithContentDescription("Loading preview for Preview $name",useUnmergedTree=true)
            tap("alpha")
            compose.waitUntil(10000){first.prefixSent.count==0L && model.playback.value.positionMs>playing.positionMs}
            loading("alpha").assertIsDisplayed()
            compose.onNodeWithContentDescription("Play preview for Preview alpha",useUnmergedTree=true).assertDoesNotExist()
            tap("bravo")
            compose.waitUntil(10000){second.count==0L}
            loading("alpha").assertDoesNotExist();loading("bravo").assertIsDisplayed()
            assertEquals(playing.queue,model.playback.value.queue)
            assertEquals(playing.selectedOccurrence,model.playback.value.selectedOccurrence)
            assertTrue(model.playback.value.isPlaying)
            releaseSecond.countDown()
            compose.waitUntil(10000){model.playback.value.let {it.source==com.soundq.android.playback.PlaybackSource.DiscoveryPreview&&it.isPlaying&&it.title=="Preview bravo"&&it.positionMs>0}}
            first.release.countDown()
            compose.waitForIdle()
            assertEquals("Preview bravo",model.playback.value.title)
            assertEquals(listOf("https://www.youtube.com/watch?v=SQPreview01","https://www.youtube.com/watch?v=SQPreview02"),calls.toList())
            loading("bravo").assertDoesNotExist()
            assertNull(app.graph.imports.state.value.acknowledgement)
        } finally {first.release.countDown();releaseSecond.countDown();server.dispatcher=fallback;app.graph.session.retire()}
    }
}
private class DiscoveryDispatcher(private val fallback:Dispatcher):Dispatcher() {
    val searches=AtomicInteger();val decisions=AtomicInteger();val queues=AtomicInteger();val entered=CountDownLatch(1);val release=CountDownLatch(1)
    val previews=AtomicInteger();val releasePreview=CountDownLatch(1)
    private val session="123e4567-e89b-12d3-a456-426614174010";private val decision="123e4567-e89b-12d3-a456-426614174020";private val job="123e4567-e89b-12d3-a456-426614174071"
    private val candidate="""{"candidateId":"candidate-1","provider":"youtube","sourceUrl":"https://youtu.be/fixture","previewSourceUrl":"https://www.youtube.com/watch?v=SQPreview01","title":"Found source fixture","artist":"Synthetic artist","downloadable":true,"playable":false}"""
    override fun dispatch(request:RecordedRequest):MockResponse {
        val path=request.url.encodedPath
        if(path=="/api/v1/discovery/search"){searches.incrementAndGet();check(request.url.queryParameter("q")=="Source fixture");if(request.url.queryParameter("providers")=="soundcloud")return reply(emptyDiscoveryProvider("Source fixture","soundcloud"));return reply("""{"query":"Source fixture","results":[$candidate],"providers":[{"provider":"youtube","status":"ok"}],"selectionRequired":true,"selectionSessionId":"$session","selectionExpiresAt":"2030-01-01T00:00:00Z"}""")}
        if(path=="/api/v1/discovery/preview") {
            check(request.method=="POST"&&org.json.JSONObject(request.body!!.utf8()).getString("url")=="https://www.youtube.com/watch?v=SQPreview01")
            previews.incrementAndGet();check(releasePreview.await(15,TimeUnit.SECONDS))
            return previewFixtureResponse(previewFixtureBytes())
        }
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
