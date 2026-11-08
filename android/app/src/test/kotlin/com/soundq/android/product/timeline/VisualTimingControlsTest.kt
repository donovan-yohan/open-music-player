package com.soundq.android.product.timeline

import com.soundq.android.data.TrackId
import com.soundq.android.data.timeline.*
import org.junit.Assert.*
import org.junit.Test

class VisualTimingControlsTest {
    private val clip=TimelineClip("a",7,"Track",10000,1000,9000,3000,QueueSegment.Manual)
    private fun wave(key:String="source",bpm:Double?=null)=TrackWaveform(TrackId(7),key,10000,listOf(PeakTier("fine",floatArrayOf(-.2f,-.8f),floatArrayOf(.4f,.9f))),beats=listOf(1000,1500,2000),suggestedBpm=bpm)
    @Test fun pointerMappingClampsAndSnapsOnlyToRealNearbyMarkers() {
        assertEquals(1000L,sourceMarkerAt(-2f,100f,1000,9000,listOf(1500),8f))
        assertEquals(9000L,sourceMarkerAt(120f,100f,1000,9000,listOf(1500),8f))
        assertEquals(1500L,sourceMarkerAt(7f,100f,1000,9000,listOf(1500),8f))
        assertEquals(5000L,sourceMarkerAt(50f,100f,1000,9000,listOf(1500),8f))
    }
    @Test fun explicitPickKeepsOriginalIdentityAndReplacementCannotReuseIt() {
        val picked=SourceTimingPick.forSource(clip,wave())!!.copy(anchorMs=1500,groupOriginMs=1000)
        assertTrue(picked.matches(clip,wave()))
        assertFalse(picked.matches(clip,wave("replacement")))
        assertFalse(picked.matches(clip.copy(sourceDurationMs=9999),wave()))
        assertNull(SourceTimingPick.forSource(clip,wave().copy(durationMs=9999)))
    }
    @Test fun generatedBpmNeverCreatesPhaseAndManualPeriodRemainsExact() {
        val empty=SourceTimingPick.forSource(clip,wave(bpm=120.0))!!
        assertNull(empty.phaseGrid(clip,wave(bpm=120.0)))
        val picked=empty.copy(bpm="120",anchorMs=1500)
        assertEquals(500L,picked.phaseGrid(clip,wave())!!.periodMs)
        assertNull(picked.copy(bpm="123").phaseGrid(clip,wave()))
        assertNull(picked.copy(groupOriginMs=1600).phaseGrid(clip,wave()))
        assertNull(picked.phaseGrid(clip,wave("replacement")))
    }
    @Test fun qualifiedAdoptionAndOriginRemainIndependent() {
        val grid=PhaseGrid("source","revision",500,1500,1000,provenance="manual_timing_v2")
        val w=wave().copy(phaseTiming=grid)
        val selected=SourceTimingPick.forSource(clip,w)!!.adopt(w)!!
        assertEquals(grid,selected.phaseGrid(clip,w))
        assertNull(selected.copy(groupOriginMs=null).phaseGrid(clip,w)!!.groupOriginMs)
        assertNull(SourceTimingPick.forSource(clip,wave())!!.adopt(wave()))
    }
    @Test fun beatNudgesUseQualifiedSourceAndExistingClipMap() {
        val w=wave().copy(phaseTiming=PhaseGrid("source","r",500,1500))
        assertEquals(3500L,timingBeatNudge(clip,EditKind.Placement,3000,1,w))
        assertEquals(500L,timingBeatNudge(clip,EditKind.TrimIn,1000,-1,w))
        assertNull(timingBeatNudge(clip,EditKind.Placement,3000,1,wave(bpm=120.0)))
        assertNull(timingBeatNudge(clip,EditKind.TrimOut,10000,1,w))
        assertEquals(3250L,timingBeatNudge(clip.copy(rates=RateAutomation(2.0)),EditKind.Placement,3000,1,w))
    }
    @Test fun visualEditsStillUseOwnerUndoBoundsAndFullOverlapPolicy() {
        val owner=TimelineOwner({null},{})
        owner.observe(listOf(TimelineSource("a",7,"A",10000,QueueSegment.Manual),TimelineSource("b",8,"B",10000,QueueSegment.Manual)))
        var d=owner.state.value.document
        val placement=TimelineEdit(d.revision,d.clips[1],EditKind.Placement,8000)
        assertTrue(owner.commit(placement));d=owner.state.value.document
        val fade=fullOverlapFade(d.revision,d.clips[0],d.clips[1])
        assertTrue(owner.preview(fade).accepted)
        assertFalse(owner.commit(fade){false});assertSame(d,owner.state.value.document)
        assertFalse(owner.preview(fade.copy(durationMs=1000)).accepted)
        assertTrue(owner.commit(fade));assertTrue(owner.state.value.canUndo)
        assertTrue(owner.undo());assertEquals(d.clips,owner.state.value.document.clips)
        val fresh=owner.state.value.document
        assertFalse(owner.commit(TimelineEdit(fresh.revision,fresh.clips[0],EditKind.TrimIn,9500)))
        assertSame(fresh,owner.state.value.document)
        assertFalse(owner.commit(placement))
    }
    @Test fun fadeUsesExactlyTheExistingOverlapAndNeverTrims() {
        val outgoing=clip.copy(sourceInMs=0,sourceOutMs=10000,globalStartMs=0)
        val incoming=clip.copy(occurrence="b",globalStartMs=8000)
        val edit=fullOverlapFade(4,outgoing,incoming)
        assertEquals(2000L,edit.durationMs)
        assertEquals(outgoing,edit.outgoing)
        assertEquals(incoming,edit.incoming)
    }
}
