package com.soundq.android


import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import com.soundq.android.data.discovery.DiscoveryResultType
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

/** Mounted ordinary typing/refinement and preview failure. */
class DiscoveryTypedJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun ordinaryTypingMixedRefinementBackAndPreviewLeaveImportAndPlaybackUntouched() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val app=instrumentation.targetContext.applicationContext as SoundQApplication
        val server=ProductTransportFixture.server;val old=server.dispatcher
        val reads=AtomicInteger();val writes=AtomicInteger();val previews=AtomicInteger()
        val artistId="123e4567-e89b-12d3-a456-426614174001"
        val groupId="123e4567-e89b-12d3-a456-426614174002"
        val releaseId="123e4567-e89b-12d3-a456-426614174003"
        val recordingId="123e4567-e89b-12d3-a456-426614174004"
        val trackId="123e4567-e89b-12d3-a456-426614174005"
        val catalogReads=java.util.concurrent.CopyOnWriteArrayList<String>()
        val metadataReads=java.util.concurrent.CopyOnWriteArrayList<Pair<String,String>>()
        val credits=""""artist":"Exact Artist","artistCredits":[{"mbid":"$artistId","name":"Exact Artist"}]"""
        val group="""{"releaseGroupMbid":"$groupId","title":"Exact Album","primaryType":"Album",$credits}"""
        val release=""""releaseMbid":"$releaseId","releaseGroupMbid":"$groupId","title":"Concrete 2026 edition","discCount":1,"date":"2026-01-02","status":"Official",$credits"""
        fun page(vararg rows:String)="""{"results":[${rows.joinToString()}],"limit":20,"offset":0,"total":${rows.size},"hasMore":false}"""

        server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath=="/api/v1/discovery/search") {
                    reads.incrementAndGet()
                    val q=request.url.queryParameter("q")!!
                    val c="""{"candidateId":"typed-source","provider":"youtube","sourceUrl":"https://youtu.be/fixture","previewSourceUrl":"https://www.youtube.com/watch?v=SQPreview01","title":"Typed source","artist":"Artist","uploader":"Uploader","durationMs":123000,"downloadable":true,"playable":false}"""
                    when(request.url.queryParameter("providers")) {
                        "youtube"->Unit
                        "soundcloud"->return MockResponse.Builder().body(emptyDiscoveryProvider(q,"soundcloud")).build()
                        else->error("Unexpected search scope")
                    }
                    return MockResponse.Builder().code(200).body("""{"query":"$q","results":[$c],"providers":[{"provider":"youtube","status":"ok","resultCount":1}],"selectionSessionId":"123e4567-e89b-12d3-a456-426614174010","selectionExpiresAt":"2030-01-01T00:00:00Z"}""").build()
                }
                val path=request.url.encodedPath
                if(path=="/api/v1/discovery/catalog") {
                    check(request.method=="GET"&&request.url.queryParameter("offset")=="0")
                    val q=checkNotNull(request.url.queryParameter("q"))
                    val kind=checkNotNull(request.url.queryParameter("kind"))
                    metadataReads.add(q to kind)
                    val row=when(kind) {
                        "artist"->"""{"kind":"artist","id":"$artistId","title":"Exact Artist","subtitle":"Group"}"""
                        "album"->"""{"kind":"album","id":"$groupId","title":"Exact Album","artist":"Artist"}"""
                        else->error("Unexpected metadata kind")
                    }
                    return MockResponse.Builder().body("""{"results":[$row],"hasMore":false}""").build()
                }
                if(path=="/api/v1/discovery/preview") {
                    check(request.method=="POST"&&org.json.JSONObject(request.body!!.utf8()).getString("url")=="https://www.youtube.com/watch?v=SQPreview01")
                    previews.incrementAndGet()
                    return MockResponse.Builder().code(503).build()
                }
                val body=when(path) {
                    "/api/v1/artists/$artistId/discography"->when(request.url.queryParameter("type")) {
                        "album"->page(group)
                        "single","ep"->page()
                        else->error("Unexpected discography scope")
                    }
                    "/api/v1/artists/$artistId/top-tracks"->"""{"results":[]}"""
                    "/api/v1/artists/$artistId/search"->{
                        check(request.url.queryParameter("q")=="Exact Album")
                        when(request.url.queryParameter("kind")) {
                            "album"->page(group)
                            "song"->page()
                            else->error("Unexpected artist search scope")
                        }
                    }
                    "/api/v1/release-groups/$groupId/editions"->page("{$release}")
                    "/api/v1/albums/$releaseId/tracklist"->"""{$release,"trackCount":1,"tracks":[{"trackMbid":"$trackId","recordingMbid":"$recordingId","title":"Exact recording","discPosition":1,"trackPosition":1,"kind":"track"}]}"""
                    else->null
                }
                if(body!=null){check(request.method=="GET");catalogReads.add(path);return MockResponse.Builder().code(200).body(body).build()}
                if(request.url.encodedPath in setOf("/api/v1/source-selections","/api/v1/queue/items","/api/v1/research-jobs","/api/v1/discovery/assist"))writes.incrementAndGet()
                return old.dispatch(request)
            }
        }
        try {
            compose.signInThroughSettings("typed@example.test","fixture-only-password"){app.graph.session.state.value is com.soundq.android.data.AuthState.SignedIn}
            compose.waitUntil(10000){app.graph.library.state.value.rows.isNotEmpty()}
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            val queue=model.playback.value.queue;val selected=model.playback.value.selectedOccurrence
            compose.onAllNodesWithText("Discover").filterToOne(hasClickAction()).performClick()
            compose.onNodeWithContentDescription("Music search query").performTextInput("seed")
            try {
                compose.waitUntil(10000){app.graph.discovery.state.value.let {it.results?.query=="seed"&&!it.searchActive}}
            } catch(original:Throwable) {
                fun observation():String {
                    val s=app.graph.discovery.state.value
                    val matches=s.draft.text=="seed"
                    return "phase=${s.phase}, draftMatches=$matches, error=${s.error}, reads=${reads.get()}, clock=${compose.mainClock.currentTime}"
                }
                val before=observation()
                captureListeningStage("discover-query-failure")
                compose.mainClock.advanceTimeBy(400)
                compose.waitForIdle()
                runCatching {compose.waitUntil(5000){app.graph.discovery.state.value.let {it.results?.query=="seed"&&!it.searchActive}}}
                captureListeningStage("discover-query-clock-control")
                throw AssertionError("Ordinary query failed before=$before; after explicit clock advance=${observation()}",original)
            }
            fun checkOptions(label:String) {
                val accepted=app.graph.discovery.state.value.results
                val count=reads.get()
                compose.onNodeWithContentDescription("Discover options").assertIsDisplayed().performClick()
                compose.onNodeWithText("Server tools").assertIsDisplayed()
                compose.onNodeWithText("Settings").assertIsDisplayed()
                captureListeningStage(label)
                instrumentation.sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
                compose.waitForIdle()
                compose.onNodeWithText("Server tools").assertDoesNotExist()
                assertSame(accepted,app.graph.discovery.state.value.results)
                assertEquals(count,reads.get())
            }
            compose.waitForIdle()
            assertEquals(DiscoveryResultType.All,app.graph.discovery.state.value.resultType)
            assertEquals(setOf(DiscoveryResultType.Song,DiscoveryResultType.Artist,DiscoveryResultType.Album),app.graph.discovery.state.value.items.map {it.type}.toSet())
            assertEquals(2,reads.get());assertEquals(setOf("seed" to "artist","seed" to "album"),metadataReads.toSet())
            captureListeningStage("discover-mixed-all")
            checkOptions("discover-options-song")
            fun tab(label:String)=compose.onNode(hasText(label) and SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.Role,androidx.compose.ui.semantics.Role.Tab))
            fun waitFor(matcher:SemanticsMatcher)=compose.waitUntil(10000) {compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty()}
            fun tracklist() {
                waitFor(hasText("1 track"))
                compose.onNodeWithTag("discover-album-list").performScrollToNode(hasText("Exact recording"))
                compose.onNodeWithText("Exact recording").assertIsDisplayed()
            }
            tab("Artists").performClick()
            compose.waitUntil(10000){app.graph.discovery.state.value.results?.entities?.isNotEmpty()==true}
            compose.onNodeWithContentDescription("More for Exact Artist").performScrollTo().performClick()
            compose.onNodeWithText("Refine search").performClick()
            compose.waitUntil(10000){app.graph.discovery.state.value.let {it.results?.query=="Exact Artist"&&!it.searchActive}}
            compose.waitForIdle()
            captureListeningStage("discover-refined-artist")
            checkOptions("discover-options-artist")
            assertEquals("Artist",app.graph.discovery.state.value.resultType.label)
            compose.onNodeWithContentDescription("Back to previous search").performClick()
            compose.waitUntil(10000){app.graph.discovery.state.value.let {it.results?.query=="seed"&&!it.pendingProviders}}
            tab("Albums").performClick()
            val acceptedAlbumSearch=app.graph.discovery.state.value.results
            compose.onNodeWithText("Exact Album").assertIsDisplayed().performClick()
            tracklist()
            compose.onNodeWithContentDescription("Back").performClick()
            tab("Albums").assertIsDisplayed().assertIsSelected()
            assertSame(acceptedAlbumSearch,app.graph.discovery.state.value.results)
            tab("Songs").performClick()
            compose.onNode(hasContentDescription("Source: YouTube") and !hasClickAction(),useUnmergedTree=true).assertExists()
            compose.onNode(hasText("2:03") and !hasClickAction(),useUnmergedTree=true).assertExists()
            compose.onNodeWithText("Typed source").performScrollTo().performClick()
            compose.waitUntil(5000){previews.get()==1&&compose.onAllNodesWithContentDescription("Play preview for Typed source").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("Source details").assertDoesNotExist()
            compose.onNodeWithContentDescription("Add to Library: Typed source").assertIsEnabled()
            captureListeningStage("discover-song-preview-actions")
            assertEquals("seed",app.graph.discovery.state.value.results!!.query)
            assertEquals(0,writes.get());assertEquals(queue,model.playback.value.queue)
            assertEquals(selected,model.playback.value.selectedOccurrence);assertFalse(model.playback.value.isPlaying)
            assertEquals(4,reads.get())
            val acceptedSong=app.graph.discovery.state.value.results
            val editor=compose.onNodeWithContentDescription("Music search query")
            fun imeVisible()=compose.runOnUiThread {
                ViewCompat.getRootWindowInsets(compose.activity.window.decorView)?.isVisible(WindowInsetsCompat.Type.ime())==true
            }
            // After preview refusal the editor need not own Back. Start the
            // keyboard-dismissal leg with a real focused editor and visible IME.
            editor.performTouchInput {click()}
            compose.waitUntil(5000){imeVisible()}
            editor.assertIsFocused()
            try {
                instrumentation.sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
                compose.waitUntil(5000){!imeVisible()}
                editor.assertIsDisplayed().assertIsNotFocused()
                compose.onNodeWithContentDescription("Clear search").assertIsDisplayed()
                assertEquals("seed",app.graph.discovery.state.value.draft.text)
                assertSame(acceptedSong,app.graph.discovery.state.value.results)
                assertEquals(4,reads.get());assertEquals(0,writes.get());assertEquals(1,previews.get())
                captureListeningStage("discover-post-back")
                android.util.Log.i("MountDiag","native Back dismissed focused IME; Discover query=seed; reads=4 writes=0 previews=1")
            } catch(failure:Throwable) {
                runCatching {captureListeningStage("discover-post-back-failure")}
                throw failure
            }
            compose.onNodeWithContentDescription("Clear search").assertIsDisplayed().performClick()
            compose.onNodeWithText("Recent searches").assertIsDisplayed()
            compose.onNode(hasText("seed") and hasClickAction()).performClick()
            compose.waitUntil(10000){app.graph.discovery.state.value.let {it.results?.query=="seed"&&!it.pendingProviders}}
            tab("Artists").assertIsDisplayed().performClick()
            compose.waitUntil(10000){app.graph.discovery.state.value.results?.entities?.isNotEmpty()==true}
            val accepted=app.graph.discovery.state.value.results
            compose.onNodeWithText("Exact Artist").performScrollTo().performClick()
            waitFor(hasText("Exact Album") and hasClickAction())
            compose.onNodeWithContentDescription("Search this artist").performTextInput("Exact Album")
            compose.waitUntil(10000){catalogReads.count {it=="/api/v1/artists/$artistId/search"}==2}
            val scopedAlbum=hasText("Exact Album") and hasClickAction() and !hasSetTextAction()
            waitFor(scopedAlbum)
            compose.onNode(scopedAlbum).performClick()
            tracklist()
            captureListeningStage("discover-qualified-concrete-edition")
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNode(scopedAlbum).assertIsDisplayed()
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithContentDescription("Search this artist").assertIsDisplayed()
            compose.onNodeWithContentDescription("Back").performClick()
            tab("Artists").assertIsDisplayed().assertIsSelected()
            assertTrue(compose.onAllNodesWithText("Discover").fetchSemanticsNodes().isNotEmpty())
            assertSame(accepted,app.graph.discovery.state.value.results)
            assertEquals(2,catalogReads.count {it=="/api/v1/release-groups/$groupId/editions"})
            assertEquals(2,catalogReads.count {it=="/api/v1/albums/$releaseId/tracklist"})
            assertEquals(6,reads.get());assertEquals(6,metadataReads.size);assertEquals(0,writes.get())
            assertEquals(mapOf("seed" to 4,"Exact Artist" to 2),metadataReads.groupingBy {it.first}.eachCount())
            assertEquals(queue,model.playback.value.queue);assertEquals(selected,model.playback.value.selectedOccurrence);assertFalse(model.playback.value.isPlaying)
        } finally {server.dispatcher=old;app.graph.session.retire()}
    }
}
