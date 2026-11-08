package com.soundq.android.product.timeline

import org.junit.Assert.*
import org.junit.Test

/** Supplied measured text boxes, not an Android raster or font-metrics substitute. */
class WaveformStatusTraceLayoutTest {
    @Test fun loadingAndFailureHaveTheirOwnSpaceAboveRetainedTrace() {
        for(statusHeight in listOf(16f,32f,72f)) {
            val g=waveformFeedbackGeometry(125f,68f,statusHeight,0f,24f)
            assertTrue("status must not intersect trace: $g",g.statusTop!!+statusHeight<=g.traceTop)
            assertTrue("identity must not intersect status: $g",g.statusTop>=68f+4f)
            assertTrue("keep 57dp clear lower plot between feedback and trace: $g",g.traceTop-(g.statusTop+statusHeight)>=57f)
        }
    }
    @Test fun siblingRefusalCannotShareStatusOrTraceAllocation() {
        val g=waveformFeedbackGeometry(165f,108f,42f,63f,52f)
        assertTrue("status and refusal need separate measured rows: $g",g.reasonTop!!>=g.statusTop!!+42f+4f)
        assertTrue("refusal must not intersect trace: $g",g.reasonTop+63f+57f<=g.traceTop)
        val only=waveformFeedbackGeometry(125f,68f,0f,36f,24f)
        assertNull(only.statusTop)
        assertTrue("loaded waveform refusal must also clear trace: $only",only.reasonTop!!+36f<=only.traceTop)
    }
    @Test fun noFeedbackRetainsDefaultCardAndLaneAllocation() {
        val normal=waveformFeedbackGeometry(125f,68f,0f,0f,32f)
        assertEquals(125f,normal.bodyHeight,0f)
        assertNull(normal.statusTop);assertNull(normal.reasonTop)
        assertEquals(165f,waveformFeedbackGeometry(165f,108f,0f,0f,42f).bodyHeight,0f)
    }
    @Test fun narrowEndpointsAreNotDiscardedAndStayInsideTheirViewport() {
        val g=tempoTraceLabelGeometry(120f,0f,110f,100f,20f,100f,20f)
        assertTrue("narrow trace must retain the end value: $g",g.lastX.isFinite())
        assertTrue(g.firstX>=0f&&g.firstX+100f<=120f)
        assertTrue(g.lastX>=0f&&g.lastX+100f<=120f)
        assertTrue(g.lastY>=24f)
        assertTrue(g.height>=g.lastY+20f+16f)
    }
    @Test fun wideEndpointsRetainOneRowAndClampedEdgeLabels() {
        val g=tempoTraceLabelGeometry(360f,280f,350f,48f,16f,48f,16f)
        assertTrue(g.firstX+48f<=360f)
        assertTrue(g.lastX+48f<=360f)
        val wide=tempoTraceLabelGeometry(360f,0f,360f,60f,16f,60f,16f)
        assertEquals(0f,wide.lastY,0f)
    }
    @Test fun measuredMetricsScaleWithoutShrinkingOrTakingFeedbackGap() {
        for(density in listOf(1f,3f))for(fontScale in listOf(1f,1.3f,1.6f,2f)) {
            val h=16f*fontScale*density
            val t=tempoTraceLabelGeometry(320f*density,0f,185f*density,80f*fontScale*density,h,80f*fontScale*density,h,4f*density)
            assertTrue(t.firstX+80f*fontScale*density<=320f*density)
            assertTrue(t.lastX+80f*fontScale*density<=320f*density)
            assertTrue(t.firstX+80f*fontScale*density+4f*density<=t.lastX||t.lastY>=h+4f*density)
            assertTrue(t.height>=t.lastY+h)
            val g=waveformFeedbackGeometry(165f,108f,h/density*2f,h/density*3f,t.height/density)
            assertTrue(g.reasonTop!!>=g.statusTop!!+h/density*2f+4f)
            assertTrue(g.traceTop-(g.reasonTop+h/density*3f)>=57f)
        }
    }
    @Test fun endpointLabelsUseMeasuredBoundsInsteadOfFixedDistance() {
        // The old 160dp admission admits both here, but enlarged glyph boxes intersect.
        val g=tempoTraceLabelGeometry(320f,20f,205f,132f,26f,132f,26f)
        assertTrue("both endpoint values must remain present: $g",g.lastX.isFinite())
        assertTrue("endpoint labels must not intersect: $g",g.firstX+132f+4f<=g.lastX||g.lastY>=30f)
        assertTrue("trace must contain full enlarged labels: $g",g.height>=g.lastY+26f)
    }
}
