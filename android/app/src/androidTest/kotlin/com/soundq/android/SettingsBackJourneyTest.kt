package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.AuthState
import org.junit.Rule
import org.junit.Test

/** System Back is dispatched per press: presses that arrive before Settings recomposes still pop one page each. */
class SettingsBackJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private val graph get()=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication).graph

    @Test fun twoQuickBackPressesFromADetailPageCloseSettings() {
        compose.runOnIdle {if(graph.session.state.value !is AuthState.SignedOut)graph.session.retire()}
        compose.waitUntil(15000){compose.onAllNodesWithContentDescription("Library search query").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Settings").performClick()
        compose.onNode(hasText("End of queue") and hasClickAction()).performScrollTo().performClick()
        compose.onAllNodes(hasText("End of queue") and isHeading()).onFirst().assertIsDisplayed()
        // Both presses in one main-thread turn: the second runs before the first pop can recompose.
        compose.runOnUiThread {repeat(2){compose.activity.onBackPressedDispatcher.onBackPressed()}}
        compose.waitForIdle()
        compose.onNode(hasText("Settings") and isHeading()).assertDoesNotExist()
        compose.onNodeWithContentDescription("Library search query").assertIsDisplayed()
    }
}
