package com.soundq.android.data.timeline

import org.junit.Assert.*
import org.junit.Test

class TempoTransitionTest {
    private fun fixture(): Pair<TempoRampIntent,TempoFitContext> {
        val a=TempoSourceIdentity("a",1,"source-a",30000,"grid-a","local_manual",120.0,0.0,1)
        val b=a.copy(occurrence="b",sourceKey="source-b",gridRevision="grid-b",sourceBpm=180.0)
        val intent=TempoRampIntent(1,TempoRampPolicy.SharedRampV1,a,b,120.0,TempoTarget(TempoTargetKind.Original,null),TempoCurve.LinearTime,0.0,8000.0,0,20,TempoGainLaw.EqualPower)
        return intent to TempoFitContext(TempoParticipantFit(a,0.0,0.0,10000.0,0.0,0.5,2.0),TempoParticipantFit(b,0.0,0.0,20000.0,0.0,0.5,2.0),emptyList(),4,0.0,8000.0,120.0,0)
    }
    @Test fun plannerFitsExistingOverlapWithoutChangingSourceOrGain() {
        val (intent,context)=fixture()
        val result=planTempoTransition(intent,context)
        assertTrue(result.toString(),result is TempoPlanResult.Valid)
        val plan=(result as TempoPlanResult.Valid).plan
        assertEquals(10000.0,plan.outgoingSourceAt(8000.0),1e-8)
        assertEquals(6666.666666666667,plan.incomingSourceAt(8000.0),1e-8)
        assertEquals(21333.333333333336,plan.incomingEndMs,1e-7)
        assertEquals(intent,plan.intent)
        assertEquals(TempoGainLaw.EqualPower,plan.intent.gainLaw)
    }
    @Test fun invalidFitNeverClampsOrRewritesCapturedSources() {
        val (i,c)=fixture()
        fun refused(intent:TempoRampIntent=i,context:TempoFitContext=c,reason:TempoFitReason) {
            val result=planTempoTransition(intent,context)
            assertTrue("Expected $reason but $result",result is TempoPlanResult.Invalid)
            assertEquals(reason,(result as TempoPlanResult.Invalid).reason)
        }
        refused(i.copy(version=2),reason=TempoFitReason.InvalidIntent)
        refused(i.copy(target=TempoTarget(TempoTargetKind.Custom,Double.NaN)),reason=TempoFitReason.InvalidIntent)
        refused(context=c.copy(outgoing=c.outgoing.copy(source=c.outgoing.source.copy(gridRevision="new"))),reason=TempoFitReason.IdentityChanged)
        refused(context=c.copy(outgoingEffectiveStartBpm=124.0),reason=TempoFitReason.IdentityChanged)
        refused(i.copy(incoming=i.incoming.copy(gridLaw=2)),c.copy(incoming=c.incoming.copy(source=i.incoming.copy(gridLaw=2))),TempoFitReason.TimingNeeded)
        refused(context=c.copy(outgoing=c.outgoing.copy(maxRate=1.1)),reason=TempoFitReason.StretchLimit)
        refused(context=c.copy(outgoing=c.outgoing.copy(sourceOutMs=9000.0)),reason=TempoFitReason.SourceBounds)
        refused(context=c.copy(outgoing=c.outgoing.copy(sourceOutMs=11000.0)),reason=TempoFitReason.GeometryMismatch)
        refused(context=c.copy(overlapEndMs=8100.0),reason=TempoFitReason.GeometryMismatch)
        refused(i.copy(lengthBeats=16),reason=TempoFitReason.BeatCountMismatch)
        refused(context=c.copy(incoming=c.incoming.copy(sourceInMs=1.0,sourceAtOverlapStartMs=1.0)),reason=TempoFitReason.BeatPhaseMismatch)
        refused(context=c.copy(otherWindows=listOf(TempoVoiceWindow("peer",4000.0,9000.0))),reason=TempoFitReason.ConnectedConflict)
        refused(context=c.copy(maxVoices=1),reason=TempoFitReason.Capacity)
        refused(context=c.copy(otherWindows=(1..4).map {TempoVoiceWindow("peer$it",9000.0,10000.0)}),reason=TempoFitReason.Capacity)
        assertEquals(10000.0,c.outgoing.sourceOutMs,0.0)
        assertEquals(30000,i.outgoing.durationMs)
        assertTrue(planTempoTransition(i,c.copy(otherWindows=listOf(TempoVoiceWindow("peer",21333.333333333336,23000.0)))) is TempoPlanResult.Valid)
        refused(context=c.copy(otherWindows=listOf(TempoVoiceWindow("peer",9000.0,10000.0))),reason=TempoFitReason.ConnectedConflict)
    }
    @Test fun originalAndEqualCustomStayDistinctThroughStrictSerialization() {
        val (i,c)=fixture()
        val custom=i.copy(target=TempoTarget(TempoTargetKind.Custom,180.0))
        val json=kotlinx.serialization.json.Json
        val originalText=json.encodeToString(TempoRampIntent.serializer(),i)
        val customText=json.encodeToString(TempoRampIntent.serializer(),custom)
        assertNotEquals(originalText,customText)
        assertEquals(custom,json.decodeFromString(TempoRampIntent.serializer(),customText))
        assertTrue(planTempoTransition(custom,c) is TempoPlanResult.Valid)
        assertThrows(kotlinx.serialization.SerializationException::class.java) {json.decodeFromString(TempoRampIntent.serializer(),"{}")}
    }
    @Test fun inverseUsesSameIntegralAcrossRampAndHeldTails() {
        for(curve in TempoCurve.entries) {
            val law=SharedTempoLaw(1000.0,9000.0,120.0,180.0,curve)
            for(from in listOf(-2000.0,1000.0,4555.0,9000.0,12000.0)) {
                for(to in listOf(-3000.0,1000.0,3000.0,7777.7,9000.0,19000.0)) {
                    val delta=law.sourceDeltaMs(from,to,128.0)
                    assertEquals("$curve $from -> $to",to,law.globalForSourceDeltaMs(from,delta,128.0),1e-7)
                }
            }
            assertEquals(180.0,law.bpmAt(11000.0),0.0)
            assertEquals(3000.0,law.sourceDeltaMs(9000.0,11000.0,120.0),1e-8)
            assertEquals(20.0,law.beatsAt(9000.0),1e-10)
        }
    }
    @Test fun staleSharedBeatOriginIsRefusedInsteadOfRelabeled() {
        val (i,c)=fixture()
        val result=planTempoTransition(i.copy(startSharedBeat=1),c)
        assertTrue(result is TempoPlanResult.Invalid)
        assertEquals(TempoFitReason.GeometryMismatch,(result as TempoPlanResult.Invalid).reason)
    }
    @Test fun roundedInverseIsEarliestIntegerReachAcrossPositiveAndNegativeDeltas() {
        val law=SharedTempoLaw(1000.0,9000.0,120.0,180.0,TempoCurve.SmoothTime)
        for(delta in listOf(-15000L,-1L,0L,1L,2345L,9000L,25000L)) {
            val result=law.globalForRoundedSourceDeltaMs(4000L,delta,128.0)
            fun rounded(t:Long)=kotlin.math.floor(law.sourceDeltaMs(4000.0,t.toDouble(),128.0)+0.5).toLong()
            assertTrue("$delta at $result",rounded(result)>=delta)
            assertTrue("earlier $delta at $result",rounded(result-1)<delta)
        }
    }
    @Test fun lawsRejectNonpositiveAndNonfiniteDomain() {
        assertThrows(IllegalArgumentException::class.java){SharedTempoLaw(0.0,0.0,120.0,128.0,TempoCurve.LinearTime)}
        assertThrows(IllegalArgumentException::class.java){SharedTempoLaw(0.0,1.0,Double.NaN,128.0,TempoCurve.LinearTime)}
        assertThrows(IllegalArgumentException::class.java){SharedTempoLaw(0.0,1.0,120.0,0.0,TempoCurve.SmoothTime)}
        val law=SharedTempoLaw(0.0,8000.0,120.0,180.0,TempoCurve.SmoothTime)
        assertThrows(IllegalArgumentException::class.java){law.rateAt(1.0,0.0)}
        assertThrows(IllegalArgumentException::class.java){law.beatsAt(Double.NaN)}
        assertThrows(IllegalArgumentException::class.java){law.globalForSourceDeltaMs(1.0,Double.POSITIVE_INFINITY,120.0)}
    }
    @Test fun smoothIntegralMatchesIndependentQuadratureAndSignedAdditivity() {
        val random=java.util.Random(718)
        for(curve in TempoCurve.entries) repeat(32) {
            val b0=45.0+random.nextDouble()*155.0;val b1=45.0+random.nextDouble()*155.0
            val law=SharedTempoLaw(1700.0,11700.0,b0,b1,curve)
            val u=random.nextDouble()
            val n=10000;val h=u/n
            var sum=0.0
            for(j in 0..n) {
                val x=j*h
                val f=if(curve==TempoCurve.LinearTime)x else 3*x*x-2*x*x*x
                sum+=(b0+(b1-b0)*f)*(if(j==0||j==n)1 else if(j%2==0)2 else 4)
            }
            val expected=sum*h/3*10000/60000
            val t=1700+10000*u
            assertEquals(expected,law.beatsAt(t),1e-9)
            assertEquals(t,law.globalForSourceDeltaMs(1700.0,law.sourceDeltaMs(1700.0,t,130.0),130.0),1e-7)
            val whole=law.sourceDeltaMs(-500.0,14000.0,130.0)
            assertEquals(whole,law.sourceDeltaMs(-500.0,t,130.0)+law.sourceDeltaMs(t,14000.0,130.0),1e-7)
            assertEquals(-whole,law.sourceDeltaMs(14000.0,-500.0,130.0),1e-7)
        }
    }
    @Test fun linearLawIntegratesSharedPulseInsteadOfLatestRate() {
        val law = SharedTempoLaw(1000.0, 9000.0, 120.0, 180.0, TempoCurve.LinearTime)
        assertEquals(150.0, law.bpmAt(5000.0), 1e-12)
        // Four seconds at average 135 BPM: 9 shared beats, not 10.
        assertEquals(9.0, law.beatsAt(5000.0), 1e-12)
        assertEquals(4500.0, law.sourceDeltaMs(1000.0, 5000.0, 120.0), 1e-9)
        assertEquals(1.25, law.rateAt(5000.0, 120.0), 1e-12)
    }
}
