package com.soundq.android.product.timeline

import com.soundq.android.data.timeline.*
import org.junit.Assert.*
import org.junit.Test

class WaveformBpmTraceTest {
    @Test fun acceptedPlaybackTempoRemainsVisibleWithoutSelectedSource() {
        val clip=TimelineClip("a",1,"A",12347,0,12347,0,QueueSegment.Manual)
        val id=TempoSourceIdentity("a",1,"source",12347,"r1","local_manual",138.0,31.25,1)
        val document=TimelineDocument(clips=listOf(clip)).withPlaybackTempo(TempoPlaybackIntent(id,140.25))
        val accepted=document.clips.single()
        assertEquals(140.25,heldPlaybackBpm(document,accepted,null)!!,0.0)
        val points=tempoTraceSamples(accepted,null,TimelineViewport(30000,900f,100.0,0))
        assertFalse("An accepted held BPM must not disappear when no source is selected",points.isEmpty())
        assertTrue(points.all {kotlin.math.abs(it.second-140.25)<1e-9})
    }
    @Test fun viewportTraceUsesActualAbsoluteLawAndConstantPrefixHold() {
        val a=TimelineClip("a",1,"A",12347,0,12347,0,QueueSegment.Context)
        val b=TimelineClip("b",2,"B",17777,0,17777,9000,QueueSegment.Context)
        val sa=TempoSourceIdentity("a",1,"s1",12347,"r1","local_manual",138.0,31.25,1)
        val sb=sa.copy(occurrence="b",track=2,sourceKey="s2",durationMs=17777,sourceBpm=126.5)
        val document=TimelineDocument(clips=listOf(a,b)).withPlaybackTempo(TempoPlaybackIntent(sa,140.25)).withAutoBpmCrossfade(true,listOf(sa,sb))
        val v=TimelineViewport(30000,900f,100.0,8000)
        val trace=tempoTraceSamples(document.clips[0],sa,v)
        assertEquals(0f,trace.first().first,0f)
        assertEquals(140.25,trace.first().second,1e-9)
        val law=document.clips[0].tempoMap!!.law
        trace.forEach {(x,bpm)->assertEquals(law.bpmAt(8000+x/100.0*1000),bpm,1e-5)}
        val incoming=tempoTraceSamples(document.clips[1],sb,v)
        assertEquals(100f,incoming.first().first,1e-6f)
        assertEquals(140.25,incoming.first().second,1e-9)
        assertEquals(126.5,incoming.last().second,1e-9)
        assertEquals(126.5,heldPlaybackBpm(document,document.clips[1],sb)!!,0.0)
        assertEquals("140.25",bpmText(140.25))
        assertEquals("138",bpmText(138.0))
    }
}
