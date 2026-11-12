package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.preferences.*
import com.soundq.android.playback.QueueOrigin
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Compiled ordinary routed journey, not executed without the separately owned device lease.
 * The existing runner supplies generated 12-second WAV via trusted loopback TLS. */
class LibraryContinuationJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun settingsNaturalEndContinuesSameQueueWithTypedOriginsAndNoRestoreAutoplay() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val graph=app.graph
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("continuation@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        compose.waitUntil(10000){graph.library.state.value.rows.size==3&&graph.listeningPreferences.state.value.ready}
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.onNodeWithContentDescription("Settings").performClick()
        compose.onNodeWithText("End of queue").performScrollTo().performClick()
        compose.onNodeWithText("Off",useUnmergedTree=true).performScrollTo().performClick()
        compose.waitUntil(10000){graph.listeningPreferences.state.value.mode==EndOfQueue.Off}
        val reconstructed=EndOfQueuePreferences(graph.directory.resolve("end-of-queue.v1.json"))
        reconstructed.load();assertEquals(EndOfQueue.Off,reconstructed.state.value.mode)
        compose.onNodeWithText("Shuffle library",useUnmergedTree=true).performScrollTo().performClick()
        compose.waitUntil(10000){graph.listeningPreferences.state.value.mode==EndOfQueue.ShuffleLibrary}
        repeat(2){InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)}
        try {
            // Refine through the mounted Library so its row callback owns the accepted list.
            val title="Fixture 1"
            compose.onNode(hasText("Search library") and hasSetTextAction()).performScrollTo().performTextInput(title)
            compose.onAllNodesWithText("Search").filterToOne(hasClickAction()).performScrollTo().performClick()
            compose.waitUntil(10000){graph.library.state.value.let {
                !it.loading&&it.error==null&&it.query.text==title&&it.rows.size==1&&it.rows.single().title==title
            }}
            compose.runOnIdle {assertSame(graph.library.state.value.rows,model.library.value.rows)}
            // The row owns More for this title; the compact player does not.
            compose.onNode(hasClickAction() and hasAnyDescendant(hasText(title)) and
                hasAnyDescendant(hasContentDescription("More for $title")),useUnmergedTree=true)
                .performScrollTo().performClick()
            compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.queue.size==1}
            val old=model.playback.value.queue.single()
            // No seek/Next: let generated audio reach the actual natural-end callback.
            compose.waitUntil(25000){model.playback.value.queue.size==3&&model.playback.value.isPlaying}
            val continued=model.playback.value
            assertEquals(old,continued.queue.first())
            assertTrue(continued.queue.drop(1).all {it.origin==QueueOrigin.Continuation&&!it.manual})
            assertEquals(3,continued.queue.map {it.occurrenceId}.distinct().size)
            assertNotEquals(old.occurrenceId,continued.selectedOccurrence)
            compose.runOnIdle {model.controller.pause()}
            compose.waitUntil(10000){!model.playback.value.isPlaying}
            reconstructed.load();assertEquals(EndOfQueue.ShuffleLibrary,reconstructed.state.value.mode)
            assertFalse(model.playback.value.isPlaying)
        }finally {compose.runOnIdle {model.controller.pause()}}
    }
}
