package com.soundq.android.product.timeline

import com.soundq.android.data.timeline.*
import org.junit.Assert.*
import org.junit.Test

/** Parent-owned SpectralRateProjection must consume the same map as the lane/native payload. */
class TempoSpectralMapTest {
    @Test fun spectralSourceAndInverseFollowSharedRampNotRateOne() {
        val a=TimelineClip("a",1,"A",20000,0,20000,0,QueueSegment.Manual)
        val b=a.copy(occurrence="b",track=2,globalStartMs=16000)
        val sa=TempoSourceIdentity("a",1,"a",20000,"r","manual_timing_v2",120.0,0.0,1)
        val sb=sa.copy(occurrence="b",track=2,sourceKey="b",sourceBpm=150.0)
        val i=TempoRampIntent(1,TempoRampPolicy.SharedRampV1,sa,sb,120.0,TempoTarget(TempoTargetKind.Original,null),TempoCurve.LinearTime,16000.0,20000.0,32,8,TempoGainLaw.EqualPower)
        val fit=fitTempoEditorRamp(TimelineDocument(clips=listOf(a,b)),TempoEditorOverlap(a,b),i)
        for(c in fit.document.clips) {
            val projection=SpectralRateProjection(c)
            assertEquals("Spectral source must follow shared BPM",c.sourceAt(18000),projection.sourceAt(18000))
            assertEquals(c.globalAt(c.sourceAt(18000)),projection.globalAt(c.sourceAt(18000)))
            assertEquals(c.globalEndMs,projection.globalEndMs)
        }
    }
}
