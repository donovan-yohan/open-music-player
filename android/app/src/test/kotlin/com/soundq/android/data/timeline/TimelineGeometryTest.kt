package com.soundq.android.data.timeline
import com.soundq.android.data.TrackId
import org.junit.Assert.*
import org.junit.Test
class TimelineGeometryTest {
    @Test fun staleDisplayedDraftCannotTargetReplacementOrReorderedQueue() {
        val clip=TimelineClip("W1",7,"Same",10000,0,10000,0,QueueSegment.Context)
        val d=TimelineDocument(1,listOf(clip))
        assertTrue(d.matchesOccurrences(listOf("W1" to 7L)))
        assertFalse(d.matchesOccurrences(listOf("W1" to 8L)))
        assertFalse(d.matchesOccurrences(listOf("W2" to 7L)))
        assertFalse(d.matchesOccurrences(emptyList()))
    }
    @Test fun focalZoomPreservesFocalTimeAndPanStaysInBounds() {
        val v=TimelineViewport(100000,400f,10.0,10000)
        val zoom=v.zoom(2f,100f)
        assertEquals(20000L,zoom.time(100f));assertEquals(15000L,zoom.offsetMs)
        assertEquals(0L,v.pan(-10000f).offsetMs)
        assertEquals(60000L,v.pan(10000f).offsetMs)
    }
    @Test fun snapUsesActualSourceMarkersAndRateMappingRatherThanFixtureBpm() {
        val clip=TimelineClip("M",7,"Same",10000,2000,9000,10000,QueueSegment.Manual,RateAutomation(2.0))
        val wave=TrackWaveform(TrackId(7),"v1",10000,emptyList(),listOf(2000,2500,3000),listOf(2000,4000,6000))
        assertEquals(2500L,snapEditValue(clip,EditKind.TrimIn,2600,SnapMode.Beat,wave))
        assertEquals(4000L,snapEditValue(clip,EditKind.TrimOut,3900,SnapMode.Bar,wave))
        assertEquals(1234L,snapEditValue(clip,EditKind.Placement,1234,SnapMode.Beat,null))
    }
    @Test fun compilerPreservesEveryOccurrenceAndTimingWithoutMakingAudioClaim() {
        val clips=sequentialTimeline(listOf(TimelineSource("W1",7,"Same",10000,QueueSegment.Context),TimelineSource("M1",7,"Same",10000,QueueSegment.Manual)))
        val schedule=compileSchedule(TimelineDocument(42,clips))
        assertEquals(42L,schedule.revision);assertEquals(listOf("W1","M1"),schedule.clips.map {it.occurrence})
        assertEquals(listOf(10000L,20000L),schedule.clips.map {it.globalEndMs})
    }
}
