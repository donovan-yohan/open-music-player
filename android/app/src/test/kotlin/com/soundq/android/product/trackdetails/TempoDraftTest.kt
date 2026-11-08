package com.soundq.android.product.trackdetails

import org.junit.Assert.*
import org.junit.Test

class TempoDraftTest {
    @Test fun twoTapsSetExactBpmWithoutOtherFacts() {
        val draft=TempoDraft().tap(1000).tap(1500)
        assertEquals(120.0,draft.text.toDoubleOrNull())
        assertNull(draft.error)
    }

    @Test fun tappedResultOutsideSupportedRangeIsRejectedWithoutClamping() {
        val draft=TempoDraft(text="123.25").tap(1000).tap(1100)
        assertEquals("123.25",draft.text)
        assertNotNull(draft.error)
        assertEquals(listOf(1000L,1100L),draft.tapsMs)
    }

    @Test fun tapMeanUsesOnlyStrictlyPositiveConsecutiveIntervals() {
        val draft=listOf(1000L,1500L,1500L,1400L,2400L).fold(TempoDraft()) {d,t->d.tap(t)}
        assertEquals(80.0,draft.text.toDouble(),0.0)
    }

    @Test fun tapWindowRetainsOnlyEightTimestamps() {
        val taps=listOf(0L,1000L,2000L,2500L,3000L,3500L,4000L,4500L,5000L,5500L)
        val draft=taps.fold(TempoDraft()) {d,t->d.tap(t)}
        assertEquals(taps.takeLast(8),draft.tapsMs)
        assertEquals(120.0,draft.text.toDouble(),0.0)
    }

    @Test fun duplicateOnlyTapsDoNotInventTempo() {
        val draft=TempoDraft().tap(1000).tap(1000)
        assertEquals("",draft.text)
        assertNull(draft.error)
    }

    @Test fun scalingUsesCurrentExplicitDraftBeforeEffectiveTempo() {
        val half=TempoDraft(text="123.5").scale(0.5,100.0)
        assertEquals(61.75,half.text.toDouble(),0.0)
        assertEquals(123.5,half.scale(2.0,100.0).text.toDouble(),0.0)
    }

    @Test fun blankDraftCanScaleAcknowledgedEffectiveTempo() {
        assertEquals(246.5,TempoDraft().scale(2.0,123.25).text.toDouble(),0.0)
        assertEquals(30.0,TempoDraft().scale(0.5,60.0).text.toDouble(),0.0)
        assertEquals(300.0,TempoDraft().scale(2.0,150.0).text.toDouble(),0.0)
    }

    @Test fun invalidExplicitDraftNeverFallsBackToEffectiveTempo() {
        listOf("bad","NaN","Infinity","29","301").forEach {text->
            val rejected=TempoDraft(text=text).scale(0.5,120.0)
            assertEquals(text,rejected.text)
            assertNotNull(rejected.error)
        }
        assertNotNull(TempoDraft().scale(2.0,null).error)
    }

    @Test fun unsupportedScaledResultIsRejectedWithoutClamping() {
        listOf("30" to 0.5,"200" to 2.0).forEach {(text,multiplier)->
            val rejected=TempoDraft(text=text).scale(multiplier,120.0)
            assertEquals(text,rejected.text)
            assertNotNull(rejected.error)
        }
    }

    @Test fun typedAndScaledEditsStartFreshTapMeasurements() {
        val tapping=TempoDraft().tap(1000).tap(1500)
        assertEquals(emptyList<Long>(),tapping.typed("121.25").tapsMs)
        assertEquals("121.25",tapping.typed("121.25").text)
        assertEquals(emptyList<Long>(),tapping.scale(0.5,120.0).tapsMs)
        assertNull(TempoDraft(error="Rejected").typed("120").error)
    }

    @Test fun firstTapRetainsExplicitTextWithoutCreatingTempo() {
        val draft=TempoDraft(text="123.25").tap(1000)
        assertEquals("123.25",draft.text)
        assertEquals(listOf(1000L),draft.tapsMs)
        assertNull(draft.error)
    }
}
