package com.soundq.designsystem

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Device-lane tests; pure JVM execution is not a substitute for these mounted events. */
class PrecisionBpmControlTest {
    @get:Rule val compose = createComposeRule()
    private val draft = mutableDoubleStateOf(130.0)
    private val candidates = mutableListOf<Boolean>()
    private val lifecycle = mutableListOf<String>()
    private var state = PrecisionBpmControlStatus()
    private val visible = mutableStateOf(true)
    private val interruption = mutableIntStateOf(0)
    private var acceptedInterruption = -1
    private var acceptedVisible = false
    private var neutralColor = Color.Unspecified
    private fun mount(reduced: Boolean = false) {
        compose.setContent { SoundQTheme(reducedMotion = reduced) {
            val renderedInterruption = interruption.intValue
            val renderedVisible = visible.value
            neutralColor = SoundQ.colors.text
            SideEffect { acceptedInterruption = renderedInterruption; acceptedVisible = renderedVisible }
            if (visible.value) PrecisionBpmControl(value = draft.doubleValue, original = 120.0, range = 96.0..180.0,
                interruptionKey = interruption.intValue, onDraft = { draft.doubleValue = it }, onAdjustmentBegin = { lifecycle += "begin" },
                onAdjustmentEnd = { lifecycle += "end" }, onAdjustmentCancel = { lifecycle += "cancel" },
                onCandidateActiveChange = { candidates += it }, onInputStateChange = { state = it },
                modifier = Modifier.width(390.dp), footer = { Text(if (it.canSubmit) "Ready" else "Not ready") })
        } }
    }
    /** Paused-clock runOnIdle deliberately does not execute recomposition/SideEffect. */
    private fun acceptPresentation() {
        compose.mainClock.advanceTimeByFrame()
        compose.waitForIdle()
    }
    @Test fun heroTapSelectsAllTypingInvalidTextStaysAndDoneDoesNotSave() {
        mount()
        compose.onNodeWithTag("precision-bpm-surface").performTouchInput { click(Offset(center.x, 24f)) }
        compose.onNodeWithTag("precision-bpm-editor").assertTextEquals("130.00")
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.TextSelectionRange, TextRange(0, 6)))
        compose.onNodeWithTag("precision-bpm-editor").performTextReplacement("121,25")
        compose.runOnIdle { assertEquals(121.25, draft.doubleValue, 0.0); assertTrue(state.canSubmit) }
        compose.onNodeWithTag("precision-bpm-editor").performTextReplacement("999.00")
        compose.onNodeWithTag("precision-bpm-editor").assertTextEquals("999.00")
        compose.onNodeWithTag("precision-bpm-editor").performImeAction()
        compose.runOnIdle { assertFalse(state.canSubmit); assertEquals(121.25, draft.doubleValue, 0.0) }
    }
    @Test fun singleResetCompletesAt450msWithoutWaitingForADoubleTapDecision() {
        mount(); compose.mainClock.autoAdvance = false
        compose.onNodeWithTag("precision-bpm-reset").performTouchInput { click() }
        compose.mainClock.advanceTimeBy(96)
        compose.runOnIdle { assertTrue(draft.doubleValue < 130.0); assertTrue(draft.doubleValue > 120.0); assertTrue(state.isGliding) }
        compose.mainClock.advanceTimeBy(400)
        compose.runOnIdle { assertEquals(120.0, draft.doubleValue, 0.0); assertFalse(state.isGliding) }
    }
    @Test fun openingNativeEditorDoesNotQuantizeAnUntouchedDragDraft() {
        draft.doubleValue = 130.004567
        mount()
        compose.onNodeWithTag("precision-bpm-surface").performTouchInput { click(Offset(center.x, 24f)) }
        compose.runOnIdle { assertEquals(130.004567, draft.doubleValue, 0.0) }
        compose.onNodeWithTag("precision-bpm-editor").performImeAction()
        compose.runOnIdle { assertEquals(130.004567, draft.doubleValue, 0.0) }
    }
    @Test fun hardwareStepsUseShiftAndBoundsWithoutTakingTheNativeTextCaret() {
        mount()
        val surface = compose.onNodeWithTag("precision-bpm-surface")
        surface.performSemanticsAction(SemanticsActions.RequestFocus) { it() }
        surface.performKeyInput { pressKey(androidx.compose.ui.input.key.Key.DirectionUp) }
        compose.runOnIdle { assertEquals(130.01, draft.doubleValue, 1e-9) }
        surface.performKeyInput { keyDown(androidx.compose.ui.input.key.Key.ShiftLeft); pressKey(androidx.compose.ui.input.key.Key.DirectionDown); keyUp(androidx.compose.ui.input.key.Key.ShiftLeft) }
        compose.runOnIdle { assertEquals(129.01, draft.doubleValue, 1e-9) }
        surface.performKeyInput { pressKey(androidx.compose.ui.input.key.Key.MoveEnd) }
        compose.runOnIdle { assertEquals(180.0, draft.doubleValue, 0.0) }
        surface.performKeyInput { pressKey(androidx.compose.ui.input.key.Key.Enter) }
        compose.onNodeWithTag("precision-bpm-editor").performKeyInput { pressKey(androidx.compose.ui.input.key.Key.DirectionLeft) }
        compose.runOnIdle { assertEquals(180.0, draft.doubleValue, 0.0); assertTrue(state.isEditing) }
    }
    @Test fun realVerticalDragSuppressesClickAndCandidateBeginsAtDown() {
        mount()
        val surface = compose.onNodeWithTag("precision-bpm-surface")
        surface.performTouchInput { down(center) }
        compose.runOnIdle { assertEquals(true, candidates.last()) }
        surface.performTouchInput { moveBy(Offset(0f, -80f)); up() }
        compose.onNodeWithTag("precision-bpm-editor").assertDoesNotExist()
        compose.runOnIdle { assertTrue(draft.doubleValue > 130.0); assertEquals(false, candidates.last()); assertEquals(listOf("begin", "end"), lifecycle) }
    }
    @Test fun secondPointerCancelsAndAllContactsMustLiftBeforeAnotherAdjustment() {
        mount()
        compose.onNodeWithTag("precision-bpm-surface").performTouchInput {
            down(0, center); moveBy(Offset(0f, -80f)); down(1, center + Offset(20f, 0f))
            moveBy(Offset(0f, -30f)); up(0); moveBy(1, Offset(0f, -50f)); up(1)
        }
        compose.runOnIdle { assertEquals(130.0, draft.doubleValue, 0.0); assertEquals(listOf("begin", "cancel"), lifecycle); assertFalse(candidates.last()) }
    }
    @Test fun samePointerSecondResetDownIsInstantAndNeverSchedulesAnotherGlide() {
        mount()
        compose.mainClock.autoAdvance = false
        val reset = compose.onNodeWithTag("precision-bpm-reset")
        reset.performTouchInput { down(0, center); advanceEventTime(20); up(0) }
        compose.mainClock.advanceTimeBy(160)
        compose.runOnIdle { assertTrue(state.isGliding); assertTrue(draft.doubleValue in 120.0..130.0); assertFalse(state.canSubmit) }
        reset.performTouchInput { advanceEventTime(80); down(0, center) }
        // Numeric second-DOWN delivery is immediate; status is published on the next composition.
        compose.runOnIdle { assertEquals(120.0, draft.doubleValue, 0.0) }
        acceptPresentation()
        compose.runOnIdle { assertEquals(120.0, draft.doubleValue, 0.0); assertFalse(state.isGliding) }
        reset.performTouchInput { advanceEventTime(20); up(0) }
        compose.mainClock.advanceTimeBy(600)
        compose.runOnIdle { assertEquals(120.0, draft.doubleValue, 0.0); assertTrue(state.canSubmit) }
    }
    @Test fun newDragDownSupersedesGlideEvenBeforeTouchSlop() {
        mount(); compose.mainClock.autoAdvance = false
        compose.onNodeWithTag("precision-bpm-reset").performTouchInput { click() }
        compose.mainClock.advanceTimeBy(160)
        compose.onNodeWithTag("precision-bpm-surface").performTouchInput { down(center) }
        var held = 0.0
        compose.runOnIdle { held = draft.doubleValue }
        acceptPresentation()
        compose.runOnIdle { assertEquals(held, draft.doubleValue, 0.0) }
        compose.runOnIdle { held = draft.doubleValue; assertFalse(state.isGliding) }
        compose.mainClock.advanceTimeBy(600)
        compose.runOnIdle { assertEquals(held, draft.doubleValue, 0.0) }
        compose.onNodeWithTag("precision-bpm-surface").performTouchInput { cancel() }
    }
    @Test fun interruptionAndRemovalPermanentlyRetireRunningResetFrames() {
        mount(); compose.mainClock.autoAdvance = false
        compose.onNodeWithTag("precision-bpm-reset").performTouchInput { click() }
        compose.mainClock.advanceTimeBy(160)
        var held = 0.0
        compose.runOnIdle { interruption.intValue++ }
        // A value parameter cannot be accepted until its caller recomposes. The pinned clock sends
        // animation frames BEFORE recomposition; sample only after this positive apply barrier.
        acceptPresentation()
        compose.runOnIdle { assertEquals(interruption.intValue, acceptedInterruption); held = draft.doubleValue }
        compose.mainClock.advanceTimeBy(600)
        compose.runOnIdle { assertEquals(held, draft.doubleValue, 0.0); assertFalse(state.isGliding) }
        compose.onNodeWithTag("precision-bpm-reset").performTouchInput { click() }
        compose.mainClock.advanceTimeBy(100)
        compose.runOnIdle { visible.value = false }
        acceptPresentation()
        compose.runOnIdle { assertFalse(acceptedVisible); held = draft.doubleValue }
        compose.mainClock.advanceTimeBy(600)
        compose.runOnIdle { assertEquals(held, draft.doubleValue, 0.0) }
    }
    @Test fun resetMovedOrMultiContactNeverProducesAClickAfterDrag() {
        mount()
        val reset = compose.onNodeWithTag("precision-bpm-reset")
        reset.performTouchInput { down(center); moveBy(Offset(0f, 100f)); up() }
        compose.runOnIdle { assertEquals(130.0, draft.doubleValue, 0.0); assertFalse(state.isGliding) }
        reset.performTouchInput { down(0, center); down(1, center + Offset(10f, 0f)); up(0); up(1) }
        compose.runOnIdle { assertEquals(130.0, draft.doubleValue, 0.0); assertFalse(state.isGliding) }
    }
    @Test fun pointerCancelRestoresActualDownValueAfterCapturedMovement() {
        mount()
        compose.onNodeWithTag("precision-bpm-surface").performTouchInput {
            down(center); moveBy(Offset(0f, -80f)); cancel()
        }
        compose.runOnIdle { assertEquals(130.0, draft.doubleValue, 0.0); assertEquals(listOf("begin", "cancel"), lifecycle); assertFalse(candidates.last()) }
    }
    @Test fun pointerCancelAfterPositiveCaptureRollsBackAndFreshGestureStillEndsNormally() {
        mount()
        val surface = compose.onNodeWithTag("precision-bpm-surface")
        surface.performTouchInput { down(center); moveBy(Offset(0f, -80f)) }
        compose.runOnIdle { assertTrue(draft.doubleValue > 130.0); assertEquals(listOf("begin"), lifecycle) }
        surface.performTouchInput { cancel() }
        compose.runOnIdle { assertEquals(130.0, draft.doubleValue, 0.0); assertEquals(listOf("begin", "cancel"), lifecycle); assertFalse(candidates.last()) }
        surface.performTouchInput { down(0, center); moveBy(Offset(0f, -80f)); up(0) }
        compose.runOnIdle { assertTrue(draft.doubleValue > 130.0); assertEquals(listOf("begin", "cancel", "begin", "end"), lifecycle); assertFalse(candidates.last()) }
    }
    @Test fun resetPointerCancelDoesNotClickAndNextResetStillWorks() {
        mount(); compose.mainClock.autoAdvance = false
        val reset = compose.onNodeWithTag("precision-bpm-reset")
        reset.performTouchInput { down(center); cancel() }
        compose.mainClock.advanceTimeBy(600)
        compose.runOnIdle { assertEquals(130.0, draft.doubleValue, 0.0); assertFalse(state.isGliding); assertTrue(lifecycle.isEmpty()) }
        reset.performTouchInput { click() }
        compose.mainClock.advanceTimeBy(96)
        compose.runOnIdle { assertTrue(draft.doubleValue < 130.0); assertTrue(draft.doubleValue > 120.0); assertTrue(state.isGliding) }
        compose.mainClock.advanceTimeBy(400)
        compose.runOnIdle { assertEquals(120.0, draft.doubleValue, 0.0); assertFalse(state.isGliding) }
    }
    @Test fun invalidTextClearsDirectionalColorWithoutChangingAcceptedDraft() {
        mount()
        compose.onNodeWithTag("precision-bpm-surface").performTouchInput { click(Offset(center.x, 24f)) }
        val editor = compose.onNodeWithTag("precision-bpm-editor")
        // Both directions must become neutral, not retain the last accepted orange/cyan draft.
        for (valid in listOf("130.00", "110.00")) {
            editor.performTextReplacement(valid)
            editor.performTextReplacement("999.00")
            compose.runOnIdle { assertEquals(valid.toDouble(), draft.doubleValue, 0.0); assertFalse(state.canSubmit) }
            compose.onNodeWithText("Enter a valid BPM").assertExists()
            compose.onNodeWithText("Above original", substring = true).assertDoesNotExist()
            compose.onNodeWithText("Below original", substring = true).assertDoesNotExist()
            val pixels = editor.captureToImage().toPixelMap()
            var neutralPixels = 0
            for (y in 0 until pixels.height) for (x in 0 until pixels.width) {
                val pixel = pixels[x, y]
                if (kotlin.math.abs(pixel.red - neutralColor.red) < .03f &&
                    kotlin.math.abs(pixel.green - neutralColor.green) < .03f &&
                    kotlin.math.abs(pixel.blue - neutralColor.blue) < .03f) neutralPixels++
            }
            assertTrue("Invalid numeral must paint neutral text", neutralPixels > 20)
        }
    }
    @Test fun reducedMotionAndSemanticResetAreImmediateDrafts() {
        mount(reduced = true)
        compose.onNodeWithTag("precision-bpm-reset").performClick()
        compose.runOnIdle { assertEquals(120.0, draft.doubleValue, 0.0); assertFalse(state.isGliding) }
        compose.onNodeWithTag("precision-bpm-surface").performSemanticsAction(SemanticsActions.SetProgress) { it(121.25f) }
        compose.runOnIdle { assertEquals(121.25, draft.doubleValue, 0.0) }
    }
}
