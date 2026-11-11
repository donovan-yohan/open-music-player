package com.soundq.android.playback

import com.soundq.android.data.timeline.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

/** Executable producer handoff: these are real authored/projected documents, not native test vectors. */
object NativeTempoPolicyFixtures {
    private fun sources()=listOf(
        TempoSourceIdentity("a",1,"s1",10000,"r1","local_manual",138.0,31.25,1),
        TempoSourceIdentity("b",2,"s2",10000,"r2","local_manual",126.5,7.75,1))
    fun independent():TimelineDocument {
        val sources=sources()
        return TimelineDocument(clips=listOf(
            TimelineClip("a",1,"A",10000,101,9701,0,QueueSegment.Context,fadeOutMs=200),
            TimelineClip("b",2,"B",10000,203,9803,7000,QueueSegment.Context,fadeInMs=200)))
            .withPlaybackTempo(TempoPlaybackIntent(sources[0],140.25))
            .withPlaybackTempo(TempoPlaybackIntent(sources[1],132.125))
    }
    fun auto(curve:TempoCurve):TimelineDocument {
        val auto=independent().withAutoBpmCrossfade(true,sources())
        return projectTempoDocument(auto.copy(tempoRamps=auto.tempoRamps.map {it.copy(curve=curve)}))
    }
    fun tempoOnly(auto:Boolean=false,curve:TempoCurve=TempoCurve.LinearTime):TimelineDocument {
        val held=independent()
        val intents=held.playbackTempos.map {it.copy(source=it.source.copy(
            gridProvenance=if(it.source.occurrence=="a")"analysis_bpm" else "local_bpm",beatAnchorMs=0.0,beatAnchorKnown=false))}
        val doc=projectTempoDocument(held.copy(playbackTempos=intents))
        if(!auto)return doc
        val projected=doc.withAutoBpmCrossfade(true,intents.map {it.source})
        return projectTempoDocument(projected.copy(tempoRamps=projected.tempoRamps.map {it.copy(curve=curve)}))
    }
    fun legacy():TimelineDocument {
        val a=TempoSourceIdentity("a",1,"s1",10000,"r1","local_manual",120.0,0.0,1)
        val b=a.copy(occurrence="b",track=2,sourceKey="s2",sourceBpm=144.0)
        return TimelineDocument(clips=listOf(
            TimelineClip("a",1,"A",10000,0,5500,0,QueueSegment.Context,fadeOutMs=5000),
            TimelineClip("b",2,"B",10000,0,9000,0,QueueSegment.Context,fadeInMs=5000)),
            tempoRamps=listOf(TempoRampIntent(1,TempoRampPolicy.SharedRampV1,a,b,120.0,
                TempoTarget(TempoTargetKind.Original,null),TempoCurve.LinearTime,0.0,5000.0,0,11,TempoGainLaw.EqualPower)))
    }
    @JvmStatic fun main(args:Array<String>) {
        val documents=listOf("independent" to independent(),"auto-linear" to auto(TempoCurve.LinearTime),
            "auto-smooth" to auto(TempoCurve.SmoothTime),"legacy" to legacy(),
            "tempo-only-independent" to tempoOnly(),"tempo-only-auto-linear" to tempoOnly(true),
            "tempo-only-auto-smooth" to tempoOnly(true,TempoCurve.SmoothTime))
        val json=kotlinx.serialization.json.buildJsonArray {
            for((name,doc) in documents) {
                // Rehydrate the durable producer state before exporting the service payload.
                val readback=Json.decodeFromString<TimelineDocument>(Json.encodeToString(doc))
                val payload=readback.nativeArrangementPayload()
                add(kotlinx.serialization.json.buildJsonObject {
                    put("name",kotlinx.serialization.json.JsonPrimitive(name))
                    put("values",kotlinx.serialization.json.JsonArray(payload.values.map {kotlinx.serialization.json.JsonPrimitive(it)}))
                    put("tempo",kotlinx.serialization.json.JsonArray(payload.tempo!!.map {kotlinx.serialization.json.JsonPrimitive(it)}))
                    put("positions",kotlinx.serialization.json.JsonArray(projectTempoDocument(readback).clips.map {kotlinx.serialization.json.JsonPrimitive(it.sourceAtExact(if(name=="legacy")2500.0 else 7500.0))}))
                })
            }
        }
        java.io.File(args.single()).writeText(json.toString())
    }
}

class NativeArrangementPayloadTest {
    @Test fun overlapPolicyIsExplicitWithoutInventingBeatAnchors() {
        val independent=NativeTempoPolicyFixtures.independent().nativeArrangementPayload().tempo!!
        assertEquals(2.0,independent[6],0.0)
        assertEquals(2.0,independent[14],0.0)
        for(curve in TempoCurve.entries) {
            val auto=NativeTempoPolicyFixtures.auto(curve).nativeArrangementPayload().tempo!!
            assertEquals(3.0,auto[6],0.0)
            assertEquals(3.0,auto[14],0.0)
            assertEquals(independent[5],auto[5],0.0)
            assertEquals(independent[13],auto[13],0.0)
        }
        assertEquals(1.0,NativeTempoPolicyFixtures.legacy().nativeArrangementPayload().tempo!![6],0.0)
    }
    @Test fun tempoOnlyUnknownPhaseKeepsZeroUnclaimedAndLegacyStillRefuses() {
        for(auto in listOf(false,true)) {
            val doc=NativeTempoPolicyFixtures.tempoOnly(auto)
            val payload=doc.nativeArrangementPayload().tempo!!
            assertEquals(if(auto)3.0 else 2.0,payload[6],0.0)
            assertEquals(payload[6],payload[14],0.0)
            assertEquals(0.0,payload[5],0.0)
            assertEquals(0.0,payload[13],0.0)
            assertTrue(doc.playbackTempos.all {!it.source.beatAnchorKnown})
        }
        val legacy=NativeTempoPolicyFixtures.legacy()
        val ramp=legacy.tempoRamps.single()
        assertThrows(IllegalArgumentException::class.java) {
            legacy.copy(tempoRamps=listOf(ramp.copy(outgoing=ramp.outgoing.copy(
                beatAnchorKnown=false,gridProvenance="analysis_bpm")))).nativeArrangementPayload()
        }
    }
    @Test fun decimalConstantAndSourceBoundsAutoPayloadNeverFallBackToRateOne() {
        val a=TimelineClip("a",1,"A",12347,0,12347,0,QueueSegment.Context)
        val b=TimelineClip("b",2,"B",17777,0,17777,9000,QueueSegment.Context)
        val sa=TempoSourceIdentity("a",1,"s1",12347,"r1","local_manual",138.0,31.25,1)
        val sb=sa.copy(occurrence="b",track=2,sourceKey="s2",durationMs=17777,sourceBpm=126.5)
        val held=TimelineDocument(clips=listOf(a,b)).withPlaybackTempo(TempoPlaybackIntent(sa,140.25))
        val payload=held.nativeArrangementPayload()
        assertArrayEquals(doubleArrayOf(138.0,140.25,140.25,0.0,1.0,31.25,2.0,0.0),payload.tempo!!.take(8).toDoubleArray(),0.0)
        assertEquals(12347L,payload.values[2])
        assertThrows(IllegalArgumentException::class.java){held.arrangementPlan()}
        val auto=held.withAutoBpmCrossfade(true,listOf(sa,sb))
        val native=auto.nativeArrangementPayload()
        val law=requireNotNull(native.tempo)
        assertEquals(16,law.size)
        val ramp=auto.tempoRamps.single()
        assertEquals(9000.0,law[3],0.0)
        assertEquals(ramp.overlapEndMs,law[4],0.0)
        assertEquals(law[1],law[9],0.0)
        assertEquals(law[2],law[10],0.0)
        assertEquals(12347.0,auto.clips[0].sourceAtExact(ramp.overlapEndMs),1e-7)
        assertEquals(listOf(0L,9000L),auto.clips.map {it.globalStartMs})
        assertEquals(held.playbackTempos,auto.withAutoBpmCrossfade(false,listOf(sa,sb)).playbackTempos)
    }
    private fun document(curve:TempoCurve=TempoCurve.LinearTime):TimelineDocument {
        val outgoing=TempoSourceIdentity("out",7,"source-out",30000,"grid-out","local_manual",120.0,0.0,1)
        val incoming=outgoing.copy(occurrence="in",track=8,sourceKey="source-in",gridRevision="grid-in",sourceBpm=144.0)
        val ramp=TempoRampIntent(1,TempoRampPolicy.SharedRampV1,outgoing,incoming,120.0,
            TempoTarget(TempoTargetKind.Original,null),curve,0.0,10000.0,0,22,TempoGainLaw.EqualPower)
        return TimelineDocument(4,listOf(
            TimelineClip("out",7,"Outgoing",30000,0,11000,0,QueueSegment.Context,fadeOutMs=10000),
            TimelineClip("in",8,"Incoming",30000,0,20000,0,QueueSegment.Context,fadeInMs=10000)
        ),tempoRamps=listOf(ramp))
    }

    @Test fun exactVersionedPayloadCarriesBothMembersAndKeepsOriginalSourceBounds() {
        for(curve in TempoCurve.entries) {
            val doc=document(curve)
            val payload=doc.nativeArrangementPayload()
            assertEquals(2*6,payload.values.size)
            assertArrayEquals(longArrayOf(0,0,11000,0,10000,0,0,0,20000,10000,0,0),payload.values)
            assertArrayEquals(doubleArrayOf(120.0,120.0,144.0,0.0,10000.0,0.0,1.0,curve.ordinal.toDouble(),
                144.0,120.0,144.0,0.0,10000.0,0.0,1.0,curve.ordinal.toDouble()),payload.tempo!!,0.0)
            val projected=projectTempoDocument(doc)
            assertEquals(projected.clips.maxOf {it.globalEndMs},payload.durationMs)
            assertEquals(10000L,projected.clips.first().globalEndMs)
            assertEquals(20000L,projected.clips.last().sourceOutMs)
        }
    }

    @Test fun legacySaveCannotSilentlyDropExplicitTempoIntent() {
        val doc=document()
        assertThrows(IllegalArgumentException::class.java){doc.arrangementPlan()}
        val plain=doc.copy(tempoRamps=emptyList())
        assertFalse(doc.matchesArrangement(plain.arrangementPlan()))
        assertNull(plain.nativeArrangementPayload().tempo)
    }

    @Test fun unsupportedGainRateAndConflictingGeometryRefuseRatherThanRenderRateOne() {
        val doc=document()
        val ramp=doc.tempoRamps.single()
        assertThrows(IllegalArgumentException::class.java){doc.copy(tempoRamps=listOf(ramp.copy(gainLaw=TempoGainLaw.Linear))).nativeArrangementPayload()}
        val rate=doc.clips.first().copy(rates=RateAutomation(1.1))
        assertThrows(IllegalArgumentException::class.java){doc.copy(clips=listOf(rate)+doc.clips.drop(1)).nativeArrangementPayload()}
        assertThrows(IllegalArgumentException::class.java){doc.copy(tempoRamps=listOf(ramp.copy(overlapEndMs=11000.0))).nativeArrangementPayload()}
    }

    @Test fun serializedServiceReadbackRebuildsMapsBeforeEqualityAndSourceProjection() {
        val projected=projectTempoDocument(document())
        val accepted=AcceptedArrangement(ArrangementIdentity("service",1,"queue",4,"request"),projected,emptyList())
        val readback=Json.decodeFromString<AcceptedArrangement>(Json.encodeToString(accepted)).withProjectedDocument()
        assertEquals(accepted,readback)
        val positions=readback.sourcePositions(5000)
        assertEquals(5250L,positions["out"])
        assertEquals(4375L,positions["in"])
        assertEquals(projected.nativeArrangementPayload().values.toList(),readback.document.nativeArrangementPayload().values.toList())
    }
    @Test fun slowedOutputTailRemainsSeekablePastTheOldSourceSpan() {
        val doc=document()
        val projected=projectTempoDocument(doc)
        val oldEnd=doc.clips.maxOf {it.globalStartMs+it.sourceOutMs-it.sourceInMs}
        val outputEnd=projected.clips.maxOf {it.globalEndMs}
        assertTrue(outputEnd>oldEnd)
        assertEquals(oldEnd+500,doc.arrangementSeekTarget(oldEnd+500))
        assertEquals(outputEnd,doc.arrangementSeekTarget(Long.MAX_VALUE))
        assertEquals(0L,doc.arrangementSeekTarget(-1))
    }
}
