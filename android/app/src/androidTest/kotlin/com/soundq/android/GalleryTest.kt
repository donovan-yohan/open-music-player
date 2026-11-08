package com.soundq.android
import androidx.activity.compose.setContent
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import org.junit.Rule
import org.junit.Test
class GalleryTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    @Test fun navigationReturnsWithDraftAndSelection() {
        compose.activityRule.scenario.onActivity { activity -> activity.setContent { SoundQApp() } }
        compose.onNodeWithText("Filter fixtures").performTextInput("Orbital")
        compose.onNodeWithContentDescription("Select Orbital morning").performClick()
        compose.onNodeWithContentDescription("Select Orbital morning").assertIsSelected()
        compose.activityRule.scenario.recreate()
        // MainActivity installs ProductApp on every onCreate. Reinstall this test's
        // actual gallery root on the recreated owner, retaining its ViewModelStore.
        compose.activityRule.scenario.onActivity { activity -> activity.setContent { SoundQApp() } }
        compose.onNodeWithContentDescription("Select Orbital morning").assertIsSelected()
        compose.onNodeWithContentDescription("Open infrastructure").performClick()
        compose.onNodeWithText("Infrastructure").assertExists()
        compose.onNodeWithContentDescription("Back to gallery").performClick()
        compose.onNodeWithText("Orbital").assertExists()
        compose.onNodeWithContentDescription("Select Orbital morning").assertIsSelected()
    }
}
