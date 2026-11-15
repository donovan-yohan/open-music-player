package com.soundq.designsystem

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.InputMode
import androidx.compose.ui.input.InputModeManager
import androidx.compose.ui.platform.LocalInputModeManager
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class RowRevealMotionTest {
    @get:Rule val compose=createComposeRule()
    @Test fun actualCompletionOneOpenRowAndKeyboardAreManualOnly() {
        val owner=RowRevealOwner();val first=RowRevealState(owner);val second=RowRevealState(owner)
        var likes=0;var queued=0;var plays=0
        lateinit var input:InputModeManager
        lateinit var view:android.view.View
        compose.setContent {SoundQTheme {
            input=LocalInputModeManager.current;view=LocalView.current
            Column(Modifier.width(320.dp)) {
                SoundQRevealMediaRow("First","Artist",false,first,true,false,true,{likes++},{queued++},{plays++},{})
                SoundQRevealMediaRow("Second","Artist",false,second,true,false,true,{likes++},{queued++},{plays++},{})
            }
        }}
        val row=compose.onNode(hasClickAction() and hasAnyDescendant(hasText("First")) and hasAnyDescendant(hasContentDescription("More for First")),useUnmergedTree=true)
        compose.mainClock.autoAdvance=false
        row.performTouchInput {down(center);moveBy(Offset(-40.dp.toPx(),0f),delayMillis=100)}
        repeat(3){compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
        row.performTouchInput {moveBy(Offset(-60.dp.toPx(),0f),delayMillis=100)}
        repeat(3){compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
        assertEquals(RowRevealPhase.Dragging,first.phase)
        compose.onNodeWithContentDescription("Like First",useUnmergedTree=true).assertIsNotEnabled()
        row.performTouchInput {up()}
        compose.mainClock.advanceTimeByFrame();compose.waitForIdle()
        assertEquals(RowRevealPhase.Settling,first.phase);assertFalse(first.actionable)
        compose.mainClock.advanceTimeBy(240);compose.waitForIdle()
        compose.onNodeWithContentDescription("Like First").assertIsEnabled()
        assertEquals(0,likes+queued+plays)
        compose.runOnIdle {second.request(true)}
        compose.mainClock.advanceTimeBy(240);compose.waitForIdle()
        assertFalse(first.actionable);assertTrue(second.actionable)
        compose.onNodeWithContentDescription("Add Second to listening queue").performClick()
        assertEquals(1,queued);assertEquals(0,likes+plays)
        compose.mainClock.autoAdvance=true
        row.performClick();assertEquals(1,plays)
        // Clickable's SystemDefined focus refuses touch mode in foundation 1.12.1.
        // Key injection targets the root; it neither focuses this row nor admits keyboard mode.
        compose.runOnIdle {
            assertTrue(input.requestInputMode(InputMode.Keyboard))
            assertEquals(InputMode.Keyboard,input.inputMode)
            assertFalse(view.isInTouchMode)
        }
        var focused=false
        row.performSemanticsAction(SemanticsActions.RequestFocus){focused=it()}
        assertTrue("Actual row accepts keyboard focus",focused)
        row.assertIsFocused()
        row.performKeyInput {pressKey(Key.DirectionLeft)}
        compose.waitForIdle();assertTrue(first.actionable)
        row.assertIsFocused()
        row.performKeyInput {pressKey(Key.Escape)}
        compose.waitForIdle();assertFalse(first.actionable)
        row.assertIsFocused()
        assertEquals(RowRevealPhase.Closed,first.phase)
        assertEquals(1,queued);assertEquals(1,plays);assertEquals(0,likes)
    }
    @Test fun reducedMotionUsesSameTerminalPathWithoutTimedTravel() {
        val state=RowRevealState(RowRevealOwner());var writes=0
        compose.setContent {SoundQTheme(reducedMotion=true) {
            SoundQRevealMediaRow("Reduced","Artist",false,state,true,false,true,{writes++},{writes++},{},{})
        }}
        compose.runOnIdle {state.request(true)}
        compose.waitForIdle();assertTrue(state.actionable);assertEquals(0,writes)
        compose.onNodeWithContentDescription("Like Reduced").performClick()
        compose.waitForIdle();assertEquals(1,writes);assertEquals(RowRevealPhase.Closed,state.phase)
    }
}
