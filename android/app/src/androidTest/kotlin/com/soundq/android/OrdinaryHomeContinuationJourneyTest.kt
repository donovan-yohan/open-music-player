package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Ordinary startup and central fixture. Authored only; requires canonical SDK/runtime qualification. */
class OrdinaryHomeContinuationJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()

    @Test fun centralFixtureFiveBufferedAndNetworkContinuationRetainsFullPlaybackContext() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        compose.signInThroughSettings("ordinary-recent@example.test","test-only-password"){app.graph.session.capture()!=null}
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        val before=ProductTransportFixture.requests.count {it=="GET /api/v1/me/plays/recent"}
        compose.onNode(hasText("Home") and hasClickAction() and !isHeading()).performClick()
        compose.waitUntil(10000){model.home.recent.value.rows.size==20&&!model.home.recent.value.loading}
        val accepted=model.home.recent.value.rows
        assertEquals(5,model.home.recent.value.visibleCount)
        compose.onNodeWithText("Recent fixture 6").assertDoesNotExist()
        captureListeningStage("home-first-five")
        val list=compose.onNode(hasScrollToIndexAction())
        list.performScrollToNode(hasText("Your top tracks"))
        compose.onNodeWithText("Your top tracks").assertIsDisplayed()
        list.performScrollToNode(hasText("Recent fixture 1"))
        compose.onNode(hasText("Recent fixture 1") and hasClickAction()).performClick()
        compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.queue.map {it.trackId}==(1L..20L).toList()}
        compose.onNodeWithContentDescription("Pause").performClick()
        for(visible in listOf(10,15,20)) {
            list.performScrollToNode(hasText("Load more"))
            compose.onNodeWithText("Load more").performClick()
            compose.waitUntil(10000){model.home.recent.value.visibleCount==visible}
            assertSame(accepted,model.home.recent.value.rows)
            assertEquals(before+1,ProductTransportFixture.requests.count {it=="GET /api/v1/me/plays/recent"})
        }
        list.performScrollToNode(hasText("Load more"))
        compose.onNodeWithText("Load more").performClick()
        compose.waitUntil(10000){model.home.recent.value.rows.size==23&&!model.home.recent.value.loading}
        assertEquals(23,model.home.recent.value.visibleCount)
        assertFalse(model.home.recent.value.hasMore)
        assertEquals(before+2,ProductTransportFixture.requests.count {it=="GET /api/v1/me/plays/recent"})
        list.performScrollToNode(hasText("Recent fixture 23"))
        compose.onNode(hasText("Recent fixture 23") and hasClickAction()).assertIsNotEnabled()
        compose.onNodeWithText("Load more").assertDoesNotExist()
        list.performScrollToNode(hasText("Recent fixture 21"))
        compose.onNode(hasText("Recent fixture 21") and hasClickAction()).performClick()
        compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.queue.map {it.trackId}==(1L..22L).toList()&&model.playback.value.queue.firstOrNull {it.occurrenceId==model.playback.value.selectedOccurrence}?.trackId==21L}
        captureListeningStage("home-selected-continuation")
        compose.onNodeWithContentDescription("Pause").performClick()
        compose.onNode(hasText("Library") and hasClickAction() and !isHeading()).performClick()
        compose.onNode(hasContentDescription("Library search query") and hasSetTextAction()).assertExists()
    }
}
