package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import org.junit.Rule
import org.junit.Test

/** Synthetic runner setup, real signed-out product route. No account or fixture intent.
 * The signed-out Account branch must remain scrollable without nesting a viewport
 * inside SoundQSheet's unbounded body. Settings itself has no nested scroller. */
class PhoneSettingsMountedJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun ordinarySignedOutAccountReachesSettingsLocalAudioAndAppearance() {
        compose.waitUntil(15000){compose.onAllNodesWithContentDescription("Account and settings").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Account and settings").performClick()
        compose.onNodeWithText("Settings").performScrollTo().performClick()
        compose.onNodeWithText("Local audio").performScrollTo().performClick()
        compose.onNodeWithText("Phone audio").assertIsDisplayed()
        compose.onNodeWithText("Open audio file").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Back to Settings").performScrollTo().performClick()
        compose.onNodeWithContentDescription("Choose appearance").performScrollTo().performClick()
        compose.onNodeWithText("Follow this device's appearance").assertIsDisplayed()
        compose.onNodeWithText("Use the light palette").assertIsDisplayed()
        compose.onNodeWithText("Use the dark palette").assertIsDisplayed()
    }
}
