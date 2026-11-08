package com.soundq.designsystem

import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Real mounted modal + real touch packets, not an extracted policy facade. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[34])
class SheetGestureOwnershipTest {
    @get:Rule val compose=createComposeRule()

    @Test fun downwardBodyAtTopDoesNotHideOrDismissFormSheet() {
        var dismissed=0
        val scroll=ScrollState(0)
        compose.setContent {SoundQTheme {SoundQSheet("Gesture form",{dismissed++},scrollState=scroll) {
            Box(Modifier.fillMaxWidth().height(120.dp).testTag("body")) {Text("Form body")}
            repeat(25){Text("Field $it",Modifier.height(48.dp))}
        }}}
        compose.onNodeWithTag("body").performTouchInput {swipe(center,Offset(centerX,centerY+450f),500)}
        compose.onNodeWithText("Gesture form").assertIsDisplayed()
        compose.runOnIdle {assertEquals("Body must not request dismissal",0,dismissed);assertEquals(0,scroll.value)}
    }

    @Test fun formStillScrollsIndependently() {
        var dismissed=0
        val scroll=ScrollState(0)
        compose.setContent {SoundQTheme {SoundQSheet("Scroll form",{dismissed++},scrollState=scroll) {
            Box(Modifier.fillMaxWidth().height(120.dp).testTag("body")) {Text("Form body")}
            repeat(25){Text("Field $it",Modifier.height(48.dp))}
        }}}
        compose.onNodeWithTag("body").performTouchInput {swipe(center,Offset(centerX,centerY-250f),500)}
        compose.runOnIdle {assertTrue("Form scroll owner must receive upward input",scroll.value>0);assertEquals(0,dismissed)}
    }

    @Test fun deliberateHandleDragDismissesButShortAndCancelledDragsDoNot() {
        var dismissed=0
        compose.setContent {SoundQTheme {SoundQSheet("Handle form",{dismissed++}) {Text("Form body")}}}
        val handle=compose.onNodeWithContentDescription("Drag to close Handle form")
        handle.assertHeightIsAtLeast(48.dp).assertWidthIsAtLeast(48.dp)
        handle.performTouchInput {down(center);moveBy(Offset(0f,12f));up()}
        compose.runOnIdle {assertEquals(0,dismissed)}
        handle.performTouchInput {down(center);moveBy(Offset(0f,120.dp.toPx()));cancel()}
        compose.runOnIdle {assertEquals(0,dismissed)}
        handle.performTouchInput {swipe(center,Offset(centerX,centerY+120.dp.toPx()),500)}
        compose.runOnIdle {assertEquals(1,dismissed)}
    }

    @Test fun workspaceHandleRejectsAccidentalInputThenHidesBeforeDismissal() {
        var dismissed=0
        compose.setContent {SoundQTheme {SoundQWorkspaceSheet("Handle workspace",{dismissed++}) {
            Box(Modifier.weight(1f).fillMaxWidth().testTag("workspace body")) {Text("Workspace content")}
        }}}
        val handle=compose.onNodeWithContentDescription("Drag to close Handle workspace")
        handle.assertHeightIsEqualTo(48.dp).assertWidthIsAtLeast(48.dp)
        handle.performTouchInput {down(center);moveBy(Offset(0f,12.dp.toPx()));up()}
        handle.performTouchInput {down(center);moveBy(Offset(0f,120.dp.toPx()));cancel()}
        handle.performTouchInput {swipe(center,Offset(centerX+120.dp.toPx(),centerY+20.dp.toPx()),500)}
        handle.performTouchInput {
            down(0,center);down(1,center+Offset(10f,0f))
            moveBy(0,Offset(0f,120.dp.toPx()));up(1);up(0)
        }
        compose.runOnIdle {assertEquals(0,dismissed)}
        compose.onNodeWithText("Handle workspace").assertIsDisplayed()
        compose.onNodeWithTag("workspace body").assertHeightIsAtLeast(48.dp)
        handle.performTouchInput {swipe(center,Offset(centerX,centerY+120.dp.toPx()),500)}
        compose.runOnIdle {assertEquals(1,dismissed)}
        // The fixture deliberately stays composed. Only the real Hidden transition hides it.
        compose.onNodeWithText("Handle workspace").assertIsNotDisplayed()
    }

    @Test fun workspaceHandleHiddenTransitionCancelsQueueGestureBeforeFreshDismissal() {
        var dismissed=0;var cancelled=0
        val gesture=QueueGestureState()
        compose.setContent {SoundQTheme {SoundQWorkspaceSheet("Guarded workspace",{dismissed++},queueGesture=gesture) {
            Text("Retained workspace")
        }}}
        compose.runOnIdle {gesture.cancelGesture={cancelled++;gesture.cancelGesture=null}}
        val handle=compose.onNodeWithContentDescription("Drag to close Guarded workspace")
        handle.performTouchInput {swipe(center,Offset(centerX,centerY+120.dp.toPx()),500)}
        compose.runOnIdle {assertEquals(1,cancelled);assertEquals(0,dismissed)}
        compose.onNodeWithText("Retained workspace").assertIsDisplayed()
        handle.performTouchInput {swipe(center,Offset(centerX,centerY+120.dp.toPx()),500)}
        compose.runOnIdle {assertEquals(1,cancelled);assertEquals(1,dismissed)}
        compose.onNodeWithText("Retained workspace").assertIsNotDisplayed()
    }

    @Test fun workspaceRetainsHeaderActionsCloseAndBoundedWeightedContent() {
        var dismissed=0;var actions=0;var cancelled=0
        val gesture=QueueGestureState()
        compose.setContent {SoundQTheme {SoundQWorkspaceSheet("Bounded workspace",{dismissed++},queueGesture=gesture,
            actions={SoundQIconButton(SoundQIcon.More,"Workspace action",{actions++})}) {
            Box(Modifier.weight(1f).fillMaxWidth().testTag("weighted workspace")) {Text("Weighted content")}
            Text("Retained footer")
        }}}
        compose.onNodeWithText("Bounded workspace").assertIsDisplayed()
        compose.onNodeWithText("Retained footer").assertIsDisplayed()
        compose.onNodeWithTag("weighted workspace").assertHeightIsAtLeast(48.dp)
        compose.onNodeWithContentDescription("Workspace action").performClick()
        compose.runOnIdle {assertEquals(1,actions);gesture.cancelGesture={cancelled++;gesture.cancelGesture=null}}
        compose.onNodeWithContentDescription("Close Bounded workspace").performClick()
        compose.runOnIdle {assertEquals(1,cancelled);assertEquals(0,dismissed)}
        compose.onNodeWithText("Weighted content").assertIsDisplayed()
        compose.onNodeWithContentDescription("Close Bounded workspace").performClick()
        compose.runOnIdle {assertEquals(1,dismissed)}
    }

    @Test fun dirtyHandleAdmissionRetainsMountedEditor() {
        var dismissed=0;var blocked=0
        compose.setContent {SoundQTheme {SoundQSheet("Dirty form",{dismissed++},dismissAdmission={blocked++;false}) {Text("Dirty draft")}}}
        compose.onNodeWithContentDescription("Drag to close Dirty form").performTouchInput {swipe(center,Offset(centerX,centerY+120.dp.toPx()),500)}
        compose.onNodeWithText("Dirty draft").assertIsDisplayed()
        compose.runOnIdle {assertEquals(0,dismissed);assertEquals(1,blocked)}
    }
}
