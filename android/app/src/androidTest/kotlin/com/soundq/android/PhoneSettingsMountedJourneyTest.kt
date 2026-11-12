package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import org.junit.Rule
import org.junit.Test

/** Synthetic runner setup, real signed-out product route. Device-local settings never need an account. */
class PhoneSettingsMountedJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun ordinarySignedOutGearReachesLocalAudioAndTheme() {
        compose.waitUntil(15000){compose.onAllNodesWithContentDescription("Settings").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Settings").performClick()
        compose.onNode(hasText("Settings") and isHeading()).assertIsDisplayed()
        compose.onNode(hasText("Local audio") and hasClickAction()).performScrollTo().performClick()
        compose.onNode(hasText("Local audio") and isHeading()).assertIsDisplayed()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNode(hasText("Theme") and hasClickAction()).performScrollTo().performClick()
        for(choice in listOf("System","Light","Dark"))compose.onNode(hasText(choice) and isSelectable()).assertIsDisplayed()
    }
}
