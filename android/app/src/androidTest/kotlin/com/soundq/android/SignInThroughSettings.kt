package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.ComposeTestRule

/**
 * Signed-out startup opens the offline Library, not a sign-in form. The ordinary route to sign in is
 * Library gear → Settings → Account → Sign in. Submits the fixture credentials, waits for the session,
 * then closes Settings with its own Back so the caller continues from the signed-in Library.
 */
internal fun ComposeTestRule.signInThroughSettings(email:String,password:String,signedIn:()->Boolean) {
    waitUntil(15000){onAllNodesWithContentDescription("Library search query").fetchSemanticsNodes().isNotEmpty()&&
        onAllNodesWithContentDescription("Settings").fetchSemanticsNodes().isNotEmpty()}
    onNodeWithContentDescription("Settings").performClick()
    onNode(hasText("Account") and hasClickAction()).performScrollTo().performClick()
    onNode(hasText("Sign in") and hasClickAction()).performScrollTo().performClick()
    waitUntil(10000){onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
    onNodeWithContentDescription("Email").performTextInput(email)
    onNodeWithContentDescription("Password").performTextInput(password)
    onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
    waitUntil(15000){signedIn()}
    // The accepted session retires the Sign in page; Account then Settings remain.
    waitUntil(10000){onAllNodes(hasText("Account") and isHeading()).fetchSemanticsNodes().isNotEmpty()}
    for(page in listOf("Account","Settings")) {
        onAllNodes(hasText(page) and isHeading()).onFirst().assertIsDisplayed()
        onNodeWithContentDescription("Back").performClick()
    }
    waitUntil(10000){onAllNodes(hasText("Settings") and isHeading()).fetchSemanticsNodes().isEmpty()}
}
