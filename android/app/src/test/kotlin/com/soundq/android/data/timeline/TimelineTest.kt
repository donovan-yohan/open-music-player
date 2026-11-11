package com.soundq.android.data.timeline

import org.junit.Assert.*
import org.junit.Test

class TimelineTest {
    @Test fun trimsCanExtendLeftThroughNegativeDeltaWithoutMovingGlobalPlacement() {
        val rates=RateAutomation(2.0)
        assertEquals(-2000L,rates.sourceDelta(5000,4000))
        assertEquals(2000L,rates.sourceDelta(4000,5000))
    }
    @Test fun sourceTimeUsesRoundedIntegralAndInverseIncludingRampEdges() {
        val clip=TimelineClip("M1",7,"Ramp",10000,2000,8000,1000,QueueSegment.Manual,
            RateAutomation(1.0,listOf(RateSegment(1000,3000,1.0,2.0))))
        assertEquals(5000L,clip.sourceAt(3000))
        assertEquals(4000L,clip.globalAt(6000))
        assertEquals(6000L,clip.globalEndMs)
        assertEquals(3000L,clip.globalAt(5000))
        val fast=clip.copy(rates=RateAutomation(2.0))
        assertEquals(4000L,fast.globalEndMs)
    }

    @Test fun duplicateTracksRemainDistinctOccurrencesAndOrigins() {
        val clips = sequentialTimeline(listOf(
            TimelineSource("W1", 7, "Same", 10000, QueueSegment.Context),
            TimelineSource("M1", 7, "Same", 10000, QueueSegment.Manual),
            TimelineSource("C1", 8, "Next", 5000, QueueSegment.Continuation)))
        assertEquals(listOf("W1", "M1", "C1"), clips.map {it.occurrence})
        assertEquals(listOf(0L,10000L,20000L), clips.map {it.globalStartMs})
        assertEquals(listOf(QueueSegment.Context,QueueSegment.Manual,QueueSegment.Continuation),clips.map {it.segment})
    }
}
