package com.soundq.android

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.content.IntentFilter
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

/** Mounted ordinary typing/refinement/external dispatch. Parent compiles and executes. */
class DiscoveryTypedJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun ordinaryTypingGroupedRefinementBackAndPreviewLeaveImportAndPlaybackUntouched() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val app=instrumentation.targetContext.applicationContext as SoundQApplication
        val server=ProductTransportFixture.server;val old=server.dispatcher
        val reads=AtomicInteger();val writes=AtomicInteger()
        val artistId="123e4567-e89b-12d3-a456-426614174001"
        val groupId="123e4567-e89b-12d3-a456-426614174002"
        val releaseId="123e4567-e89b-12d3-a456-426614174003"
        val recordingId="123e4567-e89b-12d3-a456-426614174004"
        val catalogReads=java.util.concurrent.CopyOnWriteArrayList<String>()
        val filter=IntentFilter(Intent.ACTION_VIEW).apply {addDataScheme("https")}
        val monitor=instrumentation.addMonitor(filter,Instrumentation.ActivityResult(Activity.RESULT_CANCELED,null),true)
        server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath=="/api/v1/discovery/search") {
                    reads.incrementAndGet()
                    check(request.url.queryParameter("providers")=="youtube,soundcloud,musicbrainz")
                    val q=request.url.queryParameter("q")!!
                    val c="""{"candidateId":"typed-source","provider":"youtube","sourceUrl":"https://youtu.be/fixture","title":"Typed source","artist":"Artist","uploader":"Uploader","durationMs":123000,"downloadable":true,"playable":false}"""
                    return MockResponse.Builder().code(200).body("""{"query":"$q","results":[$c],"sections":[{"kind":"artists","title":"Artists","items":[{"kind":"artist","id":"$artistId","title":"Exact Artist","subtitle":"Group"}]},{"kind":"albums","title":"Albums","items":[{"kind":"album","id":"$groupId","title":"Exact Album","subtitle":"Artist"}]}],"providers":[{"provider":"youtube","status":"ok","resultCount":1},{"provider":"soundcloud","status":"timeout","resultCount":0},{"provider":"musicbrainz","status":"ok","resultCount":2}],"selectionSessionId":"123e4567-e89b-12d3-a456-426614174010","selectionExpiresAt":"2030-01-01T00:00:00Z"}""").build()
                }
                val path=request.url.encodedPath
                val body=when(path) {
                    "/api/v1/artists/$artistId"->"""{"id":"$artistId","name":"Exact Artist","releases":[{"id":"$groupId","title":"Exact Album","date":"2026"}]}"""
                    "/api/v1/search/releases"->"""{"data":[{"id":8,"name":"Concrete 2026 edition","artist":"Exact Artist","mbReleaseId":"$releaseId","trackCount":1}],"total":1,"limit":20,"offset":0}"""
                    "/api/v1/albums/$releaseId"->"""{"id":"$releaseId","title":"Concrete 2026 edition","artist":"Exact Artist","trackCount":1,"tracks":[{"id":"$recordingId","title":"Exact recording","position":1,"inLibrary":false,"downloadable":false}]}"""
                    else->null
                }
                if(body!=null){check(request.method=="GET");catalogReads.add(path);return MockResponse.Builder().code(200).body(body).build()}
                if(request.url.encodedPath in setOf("/api/v1/source-selections","/api/v1/queue/items","/api/v1/research-jobs","/api/v1/discovery/assist"))writes.incrementAndGet()
                return old.dispatch(request)
            }
        }
        try {
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("typed@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("fixture-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){app.graph.library.state.value.rows.isNotEmpty()}
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            val queue=model.playback.value.queue;val selected=model.playback.value.selectedOccurrence
            compose.onAllNodesWithText("Discover").filterToOne(hasClickAction()).performClick()
            compose.onNodeWithContentDescription("Search sources").performTextInput("seed")
            try {
                compose.waitUntil(10000){app.graph.discovery.state.value.results?.query=="seed"}
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
                runCatching {compose.waitUntil(5000){app.graph.discovery.state.value.results?.query=="seed"}}
                captureListeningStage("discover-query-clock-control")
                throw AssertionError("Ordinary query failed before=$before; after explicit clock advance=${observation()}",original)
            }
            fun checkOptions(label:String) {
                val accepted=app.graph.discovery.state.value.results
                val count=reads.get()
                compose.onNodeWithContentDescription("Discover options").assertIsDisplayed().performClick()
                compose.onNodeWithText("Server tools").assertIsDisplayed()
                compose.onNodeWithText("Account and settings").assertIsDisplayed()
                captureListeningStage(label)
                instrumentation.sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
                compose.waitForIdle()
                compose.onNodeWithText("Server tools").assertDoesNotExist()
                assertSame(accepted,app.graph.discovery.state.value.results)
                assertEquals(count,reads.get())
            }
            compose.waitForIdle()
            captureListeningStage("discover-typed-song")
            checkOptions("discover-options-song")
            compose.onNode(hasText("Artist") and SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.Role,androidx.compose.ui.semantics.Role.Tab)).performClick()
            compose.onNodeWithText("Exact Artist").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.discovery.state.value.results?.query=="Exact Artist"}
            compose.waitForIdle()
            captureListeningStage("discover-refined-artist")
            checkOptions("discover-options-artist")
            assertEquals("Artist",app.graph.discovery.state.value.resultType.label)
            compose.onNodeWithContentDescription("Back to previous search").performClick()
            compose.waitUntil(10000){app.graph.discovery.state.value.results?.query=="seed"}
            compose.onNode(hasText("Album") and SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.Role,androidx.compose.ui.semantics.Role.Tab)).performClick()
            compose.onNodeWithText("Exact Album").assertExists()
            compose.onNode(hasText("Song") and SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.Role,androidx.compose.ui.semantics.Role.Tab)).performClick()
            compose.onNodeWithText("Typed source").performScrollTo().performClick()
            compose.onNodeWithText("Source details").assertExists()
            compose.onNode(hasText("YouTube · 2:03") and !hasClickAction()).assertExists()
            captureListeningStage("discover-source-details")
            compose.onNodeWithText("Preview source").performScrollTo().performClick()
            compose.waitUntil(5000){monitor.hits>0}
            compose.onNodeWithText("Source details").assertExists()
            assertEquals("seed",app.graph.discovery.state.value.results!!.query)
            assertEquals(0,writes.get());assertEquals(queue,model.playback.value.queue)
            assertEquals(selected,model.playback.value.selectedOccurrence);assertFalse(model.playback.value.isPlaying)
            assertEquals(2,reads.get())
            instrumentation.sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
            compose.onNodeWithContentDescription("Clear search").performScrollTo().performClick()
            compose.onNodeWithText("Recent searches").assertIsDisplayed()
            compose.onNode(hasText("seed") and hasClickAction()).performClick()
            compose.waitUntil(10000){app.graph.discovery.state.value.results?.query=="seed"}
            compose.onNode(hasText("Artist") and SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.Role,androidx.compose.ui.semantics.Role.Tab)).performScrollTo().performClick()
            val accepted=app.graph.discovery.state.value.results
            compose.onNodeWithContentDescription("More for Exact Artist").performScrollTo().performClick()
            compose.onNodeWithText("Artist details").assertIsDisplayed()
            compose.onNodeWithText("Details").performClick()
            compose.waitUntil(10000){app.graph.catalog.state.value.artist!=null}
            compose.onNodeWithText("Exact Album").performScrollTo().performClick()
            compose.onNodeWithText("Edition unavailable").performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("Search albums").performClick()
            compose.waitUntil(10000){app.graph.catalog.state.value.albums!=null}
            compose.onNodeWithText("Concrete 2026 edition").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.catalog.state.value.album!=null}
            compose.onNodeWithText("Exact recording").performScrollTo().assertIsDisplayed()
            captureListeningStage("discover-qualified-concrete-edition")
            repeat(4){instrumentation.sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK);compose.waitForIdle()}
            assertTrue(compose.onAllNodesWithText("Discover").fetchSemanticsNodes().isNotEmpty())
            assertSame(accepted,app.graph.discovery.state.value.results)
            assertEquals(listOf("/api/v1/artists/$artistId","/api/v1/search/releases","/api/v1/albums/$releaseId"),catalogReads.toList())
            assertEquals(3,reads.get());assertEquals(0,writes.get())
            assertEquals(queue,model.playback.value.queue);assertEquals(selected,model.playback.value.selectedOccurrence);assertFalse(model.playback.value.isPlaying)
        } finally {instrumentation.removeMonitor(monitor);server.dispatcher=old;app.graph.session.retire()}
    }
}
