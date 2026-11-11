package com.soundq.designsystem

import org.junit.Assert.*
import org.junit.Test

class PrecisionBpmInputTest {
    @Test fun diagonalCaptureIntegratesOnlyBeyondTheSlopBoundary() {
        val drafts = mutableListOf<Double>()
        val input = PrecisionBpmInputController(10.0..600.0, {}, { drafts += it }, {}, {})
        input.pointerDown(120.0, 0.0, 0.0, 8.0)
        input.pointerMove(1.0, -16.0)
        val expected = PrecisionBpmGesture(120.0, 10.0, 600.0, .5, -8.0).move(1.0, -16.0)
        assertEquals(expected, drafts.single(), 1e-12)
        input.cancelPointer()
        assertEquals(120.0, drafts.last(), 0.0)
        val count = drafts.size
        input.cancelPointer(); input.pointerMove(0.0, -50.0); input.pointerUp()
        assertEquals(count, drafts.size)
    }
    @Test fun smallHorizontalJitterStillTapsButHorizontalScrubSuppressesTap() {
        val input = PrecisionBpmInputController(10.0..600.0, {}, {}, {}, {})
        input.pointerDown(120.0, .5, 0.0, 8.0, .08)
        input.pointerMove(.51, 1.0)
        assertTrue(input.pointerUp())
        input.pointerDown(120.0, .5, 0.0, 8.0, .08)
        input.pointerMove(.8, 0.0)
        assertFalse(input.pointerUp())
    }
    @Test fun intentTokensRetireOldFramesAndCannotReviveAfterDisposal() {
        val intent = PrecisionBpmIntent()
        val first = intent.next()
        assertTrue(intent.accepts(first))
        val second = intent.next()
        assertFalse(intent.accepts(first))
        assertTrue(intent.accepts(second))
        intent.dispose()
        assertFalse(intent.accepts(second))
        assertFalse(intent.accepts(intent.next()))
    }
    @Test fun pointerSlopCancellationAndHorizontalTravelHaveOneOwner() {
        val drafts = mutableListOf<Double>()
        val events = mutableListOf<String>()
        val input = PrecisionBpmInputController(10.0..600.0, { events += "begin" }, { drafts += it }, { events += "end" }, { events += "cancel" })
        input.pointerDown(120.0, .5, 0.0, 8.0)
        input.pointerMove(1.0, 0.0)
        assertTrue(drafts.isEmpty())
        input.pointerMove(1.0, -10.0)
        assertEquals(120.004, drafts.last(), 1e-9)
        assertFalse(input.pointerUp())
        assertEquals(listOf("begin", "end"), events)
        input.pointerDown(drafts.last(), 0.0, 0.0, 8.0)
        input.pointerMove(0.0, -18.0)
        input.cancelPointer()
        assertEquals(120.004, drafts.last(), 1e-9)
        assertEquals("cancel", events.last())
        // A contact which never crosses slop is a tap, not an adjustment.
        input.pointerDown(120.0, .5, 0.0, 8.0)
        assertTrue(input.pointerUp())
    }
    @Test fun invalidEditorTextHasNoStaleAcceptedDraftRelation() {
        val range = 96.0..180.0
        for (value in listOf(130.0, 110.0)) {
            assertNull(precisionBpmInputRelation(value, 120.0, parsePrecisionBpmText("999.00", range)))
            assertNull(precisionBpmInputRelation(value, 120.0, parsePrecisionBpmText("", range)))
        }
        // Opening the rounded display must not erase the untouched full-precision relation.
        assertEquals(BpmRelation.Above, precisionBpmInputRelation(120.004, 120.0, parsePrecisionBpmText("120.00", range)))
        assertEquals(BpmRelation.Below, precisionBpmInputRelation(119.996, 120.0, null))
    }
    @Test fun decimalTextAdmitsOnlyCompleteFiniteInRangeHundredths() {
        assertEquals(121.25, parsePrecisionBpmText("121,25", 10.0..600.0).value!!, 0.0)
        for (text in listOf("", "121.", "121,", "NaN", "Infinity", "1e2", "1,234.5", "120.123", "999.00", "-1", " 120")) {
            assertNull(text, parsePrecisionBpmText(text, 10.0..600.0).value)
        }
    }
}
