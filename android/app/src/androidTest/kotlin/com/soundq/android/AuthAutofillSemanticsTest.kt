package com.soundq.android

import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Compile-only until an explicitly authorized device run. Synthetic inputs, no captures. */
class AuthAutofillSemanticsTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private fun editor(label:String)=compose.onNode(hasContentDescription(label) and hasSetTextAction(),useUnmergedTree=true)
    private fun role(label:String,type:ContentType) {
        val node=editor(label)
        node.assert(SemanticsMatcher.expectValue(SemanticsProperties.ContentType,type))
        node.assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.EditableText))
        node.assert(SemanticsMatcher.keyIsDefined(SemanticsActions.OnFillData))
        compose.onAllNodes(hasContentDescription(label) and SemanticsMatcher.keyIsDefined(SemanticsProperties.ContentType),useUnmergedTree=true).assertCountEquals(1)
    }
    private fun visible(label:String)=editor(label).fetchSemanticsNode().config[SemanticsProperties.EditableText].text=="test-only-password"
    @Test fun actualAuthEditorsExposeExactRolesAndIndependentConfirmReveal() {
        compose.waitUntil(10000){compose.onAllNodes(hasContentDescription("Email") and hasSetTextAction(),useUnmergedTree=true).fetchSemanticsNodes().isNotEmpty()}
        role("Email",ContentType.EmailAddress)
        role("Password",ContentType.Password)
        compose.onAllNodesWithText("Create account").filterToOne(hasClickAction()).performScrollTo().performClick()
        role("Username",ContentType.NewUsername)
        role("Email",ContentType.EmailAddress)
        role("Password",ContentType.NewPassword)
        role("Confirm password",ContentType.NewPassword)
        editor("Password").performScrollTo().performTextInput("test-only-password")
        editor("Confirm password").performScrollTo().performTextInput("test-only-password")
        assertFalse(visible("Password"));assertFalse(visible("Confirm password"))
        compose.onNodeWithContentDescription("Show Password").performScrollTo().performClick()
        assertTrue(visible("Password"));assertFalse(visible("Confirm password"))
        compose.onNodeWithContentDescription("Show Confirm password").performScrollTo().performClick()
        assertTrue(visible("Password"));assertTrue(visible("Confirm password"))
        compose.onNodeWithContentDescription("Hide Password").performScrollTo().performClick()
        assertFalse(visible("Password"));assertTrue(visible("Confirm password"))
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performScrollTo().performClick()
        role("Password",ContentType.Password)
        editor("Password").assertTextEquals("")
        compose.onAllNodesWithText("Create account").filterToOne(hasClickAction()).performScrollTo().performClick()
        editor("Confirm password").assertTextEquals("")
        compose.onNodeWithContentDescription("Show Password").assertExists()
        compose.onNodeWithContentDescription("Show Confirm password").assertExists()
    }
}
