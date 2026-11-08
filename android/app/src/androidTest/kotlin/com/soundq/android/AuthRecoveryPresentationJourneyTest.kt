package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import com.soundq.android.data.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import androidx.test.platform.app.InstrumentationRegistry

/** Mounted normal auth surface. This checks interaction/semantics; parent owns rendered acceptance. */
class AuthRecoveryPresentationJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private fun action(label:String)=compose.onAllNodesWithText(label).filterToOne(hasClickAction())
    private fun editor(label:String)=compose.onNode(hasContentDescription(label) and hasSetTextAction(),useUnmergedTree=true)
    @Test fun emailAndPasswordSignInReturnsToLibraryWithoutRegistration() {
        val graph=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication).graph
        compose.waitUntil(10000){graph.session.state.value is AuthState.SignedOut}
        try {
            editor("Email").performTextInput("auth-presentation@example.test")
            editor("Password").performTextInput("test-only-password")
            val before=ProductTransportFixture.requests.size
            action("Sign in").performScrollTo().performClick()
            compose.waitUntil(10000){graph.session.state.value is AuthState.SignedIn&&compose.onAllNodesWithContentDescription("More for Fixture 1").fetchSemanticsNodes().isNotEmpty()}
            val sent=ProductTransportFixture.requests.drop(before)
            assertEquals(1,sent.count {it=="POST /api/v1/auth/login"})
            assertFalse(sent.any {it.contains("/auth/register")||it.contains("/auth/logout")})
            compose.waitForIdle();captureOfflineAuthStage("signed-in-library")
        } finally {compose.runOnIdle {graph.session.retire()}}
    }
    @Test fun signInAndCreateAccountStayInlineWithNormalEditorsAndNoForegroundRecoveryConsole() {
        val graph=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication).graph
        compose.waitUntil(10000){graph.session.state.value is AuthState.SignedOut}
        action("Sign in").assertIsDisplayed().assertIsEnabled()
        action("Create account").assertIsDisplayed().assertIsEnabled()
        val signIn=action("Sign in").fetchSemanticsNode().boundsInRoot
        val create=action("Create account").fetchSemanticsNode().boundsInRoot
        assertEquals("ordinary phone actions share one row",signIn.top,create.top,1f)
        compose.waitForIdle();captureOfflineAuthStage("sign-in")
        compose.onAllNodesWithText("SoundQ").assertCountEquals(1)
        compose.onAllNodesWithText("Use device downloads").assertCountEquals(0)
        compose.onAllNodesWithText("Try restoring saved session").assertCountEquals(0)
        compose.onAllNodesWithText("Native listening preview").assertCountEquals(0)
        compose.onAllNodesWithText("Reconnect").assertCountEquals(0)
        editor("Email").performTextInput("auth-presentation@example.test")
        editor("Password").performTextInput("test-only-password")
        action("Create account").performScrollTo().performClick()
        editor("Username").assertExists();editor("Confirm password").assertExists();editor("Password").assertTextEquals("")
        compose.waitForIdle();captureOfflineAuthStage("create-account")
        action("Sign in").performScrollTo().performClick()
        editor("Email").assertTextEquals("auth-presentation@example.test");editor("Password").assertTextEquals("")
        val before=ProductTransportFixture.requests.size
        compose.runOnIdle {graph.session.failure(graph.session.version(),SafeFailure.Reason.Network)}
        compose.onNodeWithText("Can’t reach SoundQ").performScrollTo().assertIsDisplayed()
        compose.waitForIdle();captureOfflineAuthStage("connection-error")
        compose.onAllNodesWithText("Reconnect").assertCountEquals(0) // no decoded saved session to reconnect
        action("More options").performScrollTo().performClick()
        compose.onAllNodesWithText("Listen offline").assertCountEquals(0) // no anonymous offline account
        assertEquals(before,ProductTransportFixture.requests.size)
    }
}
