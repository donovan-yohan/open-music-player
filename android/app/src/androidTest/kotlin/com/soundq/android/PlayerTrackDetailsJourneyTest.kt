package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import com.soundq.android.product.ProductViewModel
import kotlinx.serialization.json.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/** Ordinary production Activity/Info/details/editor/TLS journey. COMPILED ONLY, not runtime qualified. */
class PlayerTrackDetailsJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    /** Reveal the real lazy item before resolving an otherwise uncomposed target. */
    private fun reveal(matcher:SemanticsMatcher):SemanticsNodeInteraction {
        compose.onNode(hasScrollToNodeAction()).performScrollToNode(matcher)
        return compose.onNode(matcher).assertIsDisplayed().assertIsEnabled()
    }

    @Test fun filteredPlayingSongInfoEditSaveReloadReturnsToPlayerWithoutQueueOrPlayIntentChanges() {
        val graph=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication).graph
        val server=ProductTransportFixture.server;val fallback=server.dispatcher
        val writes=CopyOnWriteArrayList<String>();val paths=CopyOnWriteArrayList<String>()
        val effective=java.util.concurrent.atomic.AtomicReference("Fixture 1")
        server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            val path=request.url.encodedPath;paths.add(request.method+" "+path)
            fun reply(body:String)=MockResponse.Builder().body(body).build()
            if(path=="/api/v1/tracks/1/metadata-override") {
                val body=request.body!!.utf8();writes.add(body);val data=Json.parseToJsonElement(body).jsonObject
                effective.set(data.getValue("title").jsonPrimitive.content)
                return reply(buildJsonObject {put("track_id",1);put("has_metadata_override",true);data.forEach {(k,v)->put(k,v)}}.toString())
            }
            if(path=="/api/v1/library"&&request.url.queryParameter("limit")=="100")return reply("""{"tracks":[{"id":1,"title":"${effective.get()}","artist":"Synthetic ensemble","duration_ms":12000,"mb_verified":false,"has_metadata_override":${effective.get()!="Fixture 1"}}],"total":1,"limit":100,"offset":0}""")
            return fallback.dispatch(request)
        }}
        try {
            graph.session.retire()
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("player-details@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){graph.library.state.value.rows.isNotEmpty()}
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            val libraryRow=hasText("Fixture 1") and hasClickAction() and hasAnyDescendant(hasContentDescription("More for Fixture 1"))
            reveal(libraryRow).performClick()
            compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.positionMs>0}
            compose.onNodeWithContentDescription("Pause").performClick()
            compose.waitUntil(10000){!model.playback.value.isPlaying}
            // Library search is now fixed above, rather than an item in, the track list.
            compose.onNodeWithContentDescription("Library search query").assertIsDisplayed().performTextReplacement("Fixture 2")
            compose.onNodeWithContentDescription("Search library").assertIsDisplayed().performClick()
            compose.waitUntil(10000){!graph.library.state.value.loading&&graph.library.state.value.query.text=="Fixture 2"&&graph.library.state.value.rows.none {it.id.value==1L}&&graph.library.state.value.rows.any {it.id.value==2L}}
            reveal(hasContentDescription("More for Fixture 2"))
            val libraryBefore=graph.library.state.value
            val compactRow=hasText("Fixture 1") and hasClickAction() and !hasAnyDescendant(hasContentDescription("More for Fixture 1"))
            compose.onNode(compactRow).performClick()
            compose.onNodeWithText("Now playing").assertExists()
            val before=model.playback.value;val start=paths.size
            val info=compose.onNodeWithContentDescription("Song details")
            info.assertHeightIsAtLeast(androidx.compose.ui.unit.Dp(48f));info.assertWidthIsAtLeast(androidx.compose.ui.unit.Dp(48f));info.performClick()
            compose.waitUntil(10000){graph.trackDetails.state.value.detail!=null&&!graph.trackDetails.state.value.loading}
            compose.onNodeWithText("Edit metadata").performScrollTo().performClick()
            compose.onNodeWithContentDescription("Title").performScrollTo().assertIsDisplayed().assertIsEnabled().performTextReplacement("Personal player title")
            compose.onNodeWithContentDescription("Close Edit metadata").performScrollTo().performClick()
            compose.onNodeWithText("Keep editing").performClick()
            compose.onNodeWithContentDescription("Title").assertTextContains("Personal player title")
            assertTrue(writes.isEmpty())
            compose.onNodeWithText("Save metadata").performScrollTo().performClick()
            compose.waitUntil(10000){graph.trackDetails.state.value.detail?.track?.title=="Personal player title"&&graph.trackDetails.state.value.outcome==MutationOutcome.Confirmed}
            compose.onNodeWithContentDescription("Back to Song details").performScrollTo().performClick()
            compose.onNodeWithText("Reload details").performScrollTo().performClick()
            compose.waitUntil(10000){!graph.trackDetails.state.value.loading&&graph.trackDetails.state.value.detail?.track?.title=="Personal player title"}
            compose.onNodeWithContentDescription("Close Song details").performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()
            compose.onNodeWithText("Now playing").assertExists()
            assertNull(graph.trackDetails.state.value.detail)
            val after=model.playback.value
            assertEquals(before.queue,after.queue);assertEquals(before.selectedOccurrence,after.selectedOccurrence)
            assertEquals(before.positionMs,after.positionMs);assertFalse(after.isPlaying)
            assertEquals(before.selectionIncarnation,after.selectionIncarnation)
            assertEquals("Fixture 1",after.title)
            assertEquals(libraryBefore.query,graph.library.state.value.query);assertEquals(libraryBefore.rows,graph.library.state.value.rows)
            assertEquals(1,writes.size)
            assertEquals(listOf("PUT /api/v1/tracks/1/metadata-override"),paths.drop(start).filter {it.startsWith("PUT")})
            assertTrue(paths.drop(start).count {it=="GET /api/v1/library"}>=3)
            assertFalse(paths.drop(start).any {it.contains("playback/urls")||it.contains("/media/")})
        } finally {server.dispatcher=fallback;graph.session.retire()}
    }
}
