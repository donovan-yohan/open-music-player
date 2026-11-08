package com.soundq.designsystem

import androidx.compose.runtime.*
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Actual common sheet plus controlled precision input. No audio or durable Save is substituted. */
class PrecisionBpmSheetTest {
    @get:Rule val compose=createComposeRule()

    @Test fun verticalPrecisionContactDoesNotScrollOrDismissItsOwningSheet() {
        val value=mutableDoubleStateOf(130.0)
        var dismissed=0
        var candidate=false
        compose.setContent {SoundQTheme {
            SoundQSheet("Playback BPM",{dismissed++},dismissAdmission={!candidate}) {
                PrecisionBpmControl(value.doubleValue,120.0,96.0..180.0,{value.doubleValue=it},
                    onCandidateActiveChange={candidate=it})
            }
        }}
        val surface=compose.onNodeWithTag("precision-bpm-surface")
        surface.assertIsDisplayed()
        val original=surface.fetchSemanticsNode().boundsInRoot
        surface.performTouchInput {down(center)}
        compose.runOnIdle {assertTrue(candidate)}
        surface.performTouchInput {moveBy(Offset(0f,-100f));up()}
        surface.assertIsDisplayed()
        val after=surface.fetchSemanticsNode().boundsInRoot
        compose.runOnIdle {
            assertEquals(0,dismissed)
            assertFalse(candidate)
            assertTrue(value.doubleValue>130.0)
            assertEquals(original.top,after.top,1f)
        }
        compose.onNodeWithTag("precision-bpm-editor").assertDoesNotExist()
        compose.onNodeWithContentDescription("Close Playback BPM").performClick()
        compose.runOnIdle {assertEquals(1,dismissed)}
    }
}
