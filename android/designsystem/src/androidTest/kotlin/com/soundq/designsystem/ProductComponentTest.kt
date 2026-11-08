package com.soundq.designsystem

import androidx.compose.ui.test.*
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.runtime.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class ProductComponentTest {
    @get:Rule val compose=createComposeRule()
    @Test fun queueGripCancelNeverMovesOrPlaysAndAccessibleReorderIsOccurrenceKeyed() {
        var selected=0;val moved=mutableListOf<Pair<String,Int>>()
        compose.setContent {SoundQTheme {SoundQOccurrenceQueue(listOf(QueueRowVisual("a","Duplicate","Fixture",true),QueueRowVisual("b","Duplicate","Fixture",false)),{selected++},{id,to->moved.add(id to to)},{})}}
        val grip=compose.onAllNodesWithContentDescription("Reorder Duplicate").onFirst()
        grip.performTouchInput {down(center);moveBy(androidx.compose.ui.geometry.Offset(0f,70f));cancel()}
        assertEquals(0,selected);assertTrue(moved.isEmpty())
        compose.onAllNodesWithContentDescription("More for Duplicate").onFirst().performClick()
        compose.onNodeWithText("Move later").performClick()
        assertEquals(listOf("a" to 1),moved);assertEquals(0,selected)
    }
    @Test fun dirtySheetVetoesScrimSwipeAndCloseUntilParentAdmitsDismissal() {
        var dismissed=0;var blocked=0
        val dirty=mutableStateOf(true)
        compose.setContent {SoundQTheme {SoundQSheet("Guarded",{dismissed++},dismissAdmission={if(dirty.value){blocked++;false}else true}) {androidx.compose.material3.Text("Mounted editor")}}}
        compose.onNodeWithText("Mounted editor").assertIsDisplayed()
        compose.onNodeWithContentDescription("Close Guarded").performClick()
        compose.runOnIdle {assertEquals(0,dismissed);assertTrue(blocked>0)}
        compose.onNodeWithText("Mounted editor").assertIsDisplayed()
        val beforeSwipe=blocked
        compose.onNodeWithContentDescription("Drag to close Guarded").performTouchInput {
            swipe(center,androidx.compose.ui.geometry.Offset(centerX,centerY+120.dp.toPx()),500)
        }
        compose.runOnIdle {assertEquals(0,dismissed);assertTrue(blocked>beforeSwipe)}
        compose.onNodeWithText("Mounted editor").assertIsDisplayed()
        val beforeScrim=blocked
        compose.onAllNodes(isRoot()).filterToOne(hasAnyDescendant(hasText("Guarded"))).performTouchInput {click(androidx.compose.ui.geometry.Offset(4f,4f))}
        compose.runOnIdle {assertEquals(0,dismissed);assertTrue(blocked>beforeScrim)}
        compose.onNodeWithText("Mounted editor").assertIsDisplayed()
        compose.runOnIdle {dirty.value=false}
        compose.onNodeWithContentDescription("Close Guarded").performClick()
        compose.runOnIdle {assertEquals(1,dismissed)}
    }
    @Test fun secureFieldRevealPreservesNativeSelectionAndEdits() {
        var value=TextFieldValue("synthetic secret")
        compose.setContent {var input by remember {mutableStateOf(value)};var reveal by remember {mutableStateOf(false)}
            SoundQTheme {SoundQEntryField(input,{input=it;value=it},"Password",secure=true,revealed=reveal,onReveal={reveal=!reveal})}}
        compose.onNodeWithContentDescription("Password").performTextReplacement("fixture")
        compose.onNodeWithContentDescription("Show Password").performClick()
        assertEquals("fixture",value.text)
        compose.onNodeWithContentDescription("Hide Password").assertExists()
    }
}
