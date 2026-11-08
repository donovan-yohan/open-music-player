package com.soundq.android

import com.soundq.designsystem.*

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

/** Real mounted modal + real touch packets, not an extracted policy facade. */
class FormSheetGestureOwnershipTest {
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

    @Test fun dirtyHandleAdmissionRetainsMountedEditor() {
        var dismissed=0;var blocked=0
        compose.setContent {SoundQTheme {SoundQSheet("Dirty form",{dismissed++},dismissAdmission={blocked++;false}) {Text("Dirty draft")}}}
        compose.onNodeWithContentDescription("Drag to close Dirty form").performTouchInput {swipe(center,Offset(centerX,centerY+120.dp.toPx()),500)}
        compose.onNodeWithText("Dirty draft").assertIsDisplayed()
        compose.runOnIdle {assertEquals(0,dismissed);assertEquals(1,blocked)}
    }
}
