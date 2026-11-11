package com.soundq.android.product.timeline

import com.soundq.android.data.timeline.*
import org.junit.Assert.*
import org.junit.Test

class WaveformLiveBpmFactsTest {
    private fun document():TimelineDocument {
        val a=TempoSourceIdentity("a",1,"source-a",30000,"grid-a","local_manual",120.0,0.0,1)
        val b=a.copy(occurrence="b",track=2,sourceKey="source-b",gridRevision="grid-b",sourceBpm=144.0)
        val intent=TempoRampIntent(1,TempoRampPolicy.SharedRampV1,a,b,120.0,TempoTarget(TempoTargetKind.Original,null),TempoCurve.LinearTime,0.0,10000.0,0,22,TempoGainLaw.EqualPower)
        return projectTempoDocument(TimelineDocument(4,listOf(
            TimelineClip("a",1,"A",30000,0,11000,0,QueueSegment.Context,fadeOutMs=10000),
            TimelineClip("b",2,"B",30000,0,20000,0,QueueSegment.Context,fadeInMs=10000)
        ),tempoRamps=listOf(intent)))
    }

    @Test fun acceptedObservationChangesOnlyNowWithDocumentViewportAndHeldFixed() {
        val document=document()
        val viewport=TimelineViewport(30000,300f,10.0,0)
        for(clip in document.clips) {
            val trace=tempoTraceSamples(clip,null,viewport)
            val held=heldPlaybackBpm(document,clip,null)
            val first=waveformCardFacts(document,clip,null,"8A",122.4,1000)
            val next=waveformCardFacts(document,clip,null,"8A",123.6,1000)
            assertTrue("Accepted live value must be retained separately: $first",first.contains("Now 122.4 BPM"))
            assertTrue(next.contains("Now 123.6 BPM"))
            assertEquals(first.filterNot {it.startsWith("Now ")},next.filterNot {it.startsWith("Now ")})
            assertTrue(first.contains("8A"))
            assertEquals(held,heldPlaybackBpm(document,clip,null))
            assertEquals(trace,tempoTraceSamples(clip,null,viewport))
        }
    }

    @Test fun absentAndNonfiniteObservationsRetainHeldAndKeyWithoutNow() {
        val document=document()
        for(clip in document.clips) {
            val expected=listOf(if(clip.occurrence=="a")"Held 120.00 BPM" else "Held 144.00 BPM","8A")
            for(observed in listOf(null,Double.NaN,Double.POSITIVE_INFINITY,Double.NEGATIVE_INFINITY)) {
                assertEquals(expected,waveformCardFacts(document,clip,null,"8A",observed,1000))
            }
        }
    }

    @Test fun rampWindowIsHalfOpenAndCannotExposeStaleLiveValues() {
        val document=document()
        for(clip in document.clips) {
            val law=clip.tempoMap!!.law
            for(position in listOf(law.startMs.toLong()-1,law.endMs.toLong(),law.endMs.toLong()+1)) {
                assertFalse(waveformCardFacts(document,clip,null,"8A",122.4,position).any {it.startsWith("Now ")})
            }
            for(position in listOf(law.startMs.toLong(),law.endMs.toLong()-1)) {
                assertTrue(waveformCardFacts(document,clip,null,"8A",122.4,position).contains("Now 122.4 BPM"))
            }
        }
    }

    @Test fun observationNeverReplacesHeldKeyOrCreatesAPlannedNow() {
        val document=document()
        for(clip in document.clips) {
            val held=if(clip.occurrence=="a")"Held 120.00 BPM" else "Held 144.00 BPM"
            val absent=waveformCardFacts(document,clip,null,"8A",null,1000)
            assertEquals(listOf(held,"8A"),absent)
            assertEquals(absent,waveformCardFacts(document,clip,null,"8A",122.4,1000).filterNot {it.startsWith("Now ")})
            assertFalse(waveformCardFacts(document,clip,null,null,null,1000).any {it.startsWith("Now ")})
        }
    }

    @Test fun nonRampFiniteObservationRetainsPredecessorEligibility() {
        val clip=TimelineClip("plain",3,"Plain",30000,0,30000,0,QueueSegment.Context)
        val document=TimelineDocument(clips=listOf(clip))
        val source=TempoSourceIdentity("plain",3,"source",30000,"grid","local_manual",120.0,0.0,1)
        assertEquals(listOf("Held 120.00 BPM","Now 122.4 BPM"),waveformCardFacts(document,clip,source,null,122.4,20000))
        assertEquals(listOf("Held 120.00 BPM"),waveformCardFacts(document,clip,source,null,null,20000))
    }

    @Test fun extraWholeFactLineGrowsGeometryWithoutTakingClearPlotSpace() {
        for(scale in listOf(1f,1.3f,2f)) {
            for(measuredContentHeight in listOf(60f,85f,130f,180f)) {
                val geometry=waveformCardGeometry(scale,true,measuredContentHeight)
                assertTrue(geometry.cardHeight>=measuredContentHeight)
                assertTrue(geometry.bodyHeight-geometry.cardHeight-8f>=57f)
                assertTrue(geometry.bodyHeight>=125f)
            }
        }
    }
}
