package com.soundq.android.product.timeline

import com.soundq.android.data.timeline.*
import org.junit.Assert.*
import org.junit.Test

class TempoEditorIntegrationTest {
    private fun clip(id:String,track:Long,start:Long)=TimelineClip(id,track,id,20000,0,20000,start,QueueSegment.Manual)
    private fun identity(c:TimelineClip,bpm:Double)=TempoSourceIdentity(c.occurrence,c.track,"s-${c.track}",c.sourceDurationMs,"r","manual_timing_v2",bpm,0.0,1)
    private fun draft(a:TimelineClip,b:TimelineClip,target:TempoTarget=TempoTarget(TempoTargetKind.Original,null))=TempoRampIntent(1,TempoRampPolicy.SharedRampV1,identity(a,120.0),identity(b,150.0),120.0,target,TempoCurve.LinearTime,b.globalStartMs.toDouble(),a.globalEndMs.toDouble(),32,8,TempoGainLaw.Linear)
    @Test fun authoredFractionalPeriodTimingQualifiesWithoutRelaxingLegacyPhaseGrid() {
        for(bpm in listOf(138.0,151.0)) {
            val c=clip("a",1,0)
            val raw=kotlinx.serialization.json.Json.parseToJsonElement("""{"track_id":1,"schema_version":2,"status":"analyzed","override_revision":1,"overrides":{"manual_timing_v2":{"schema_version":2,"provenance":"manual_override","revision":1,"bpm":$bpm,"beat_anchor_ms":0}}}""").let {it as kotlinx.serialization.json.JsonObject}
            val wave=AnalysisWaveformJson.parse(raw,com.soundq.android.data.TrackId(1),20000)
            assertNull("Old phase-link precision stays strict",wave.phaseTiming)
            val identity=qualifiedTempoSource(c,wave)
            assertNotNull("Authored $bpm BPM must qualify for tempo independently of phase links",identity)
            assertEquals(bpm,identity!!.sourceBpm,0.0)
            assertEquals(0.0,identity.beatAnchorMs,0.0)
        }
        val generated=AnalysisWaveformJson.parse(kotlinx.serialization.json.Json.parseToJsonElement("""{"track_id":1,"schema_version":2,"status":"analyzed","summary":{"bpm":{"value":138}}}""") as kotlinx.serialization.json.JsonObject,com.soundq.android.data.TrackId(1),20000)
        assertNull("Generated BPM cannot invent an authored anchor",qualifiedTempoSource(clip("a",1,0),generated))
    }
    @Test fun explicitFitMovesIncomingKeepsSourceSelectionsAndUsesOneMap() {
        val a=clip("a",1,0);val b=clip("b",2,16000);val d=TimelineDocument(clips=listOf(a,b))
        val proposal=fitTempoEditorRamp(d,TempoEditorOverlap(a,b),draft(a,b))
        assertFalse(proposal.trimsSource)
        assertEquals(16000L,proposal.document.clips[1].globalStartMs)
        assertEquals(a.sourceOutMs,proposal.document.clips[0].sourceOutMs)
        assertEquals(b.sourceInMs,proposal.document.clips[1].sourceInMs)
        val i=proposal.document.tempoRamps.single()
        assertEquals(19555.555555555555,i.overlapEndMs,1e-8)
        val x=proposal.document.clips[0];val y=proposal.document.clips[1]
        for(t in listOf(i.overlapStartMs,17000.0,i.overlapEndMs)) {
            val beats=(x.sourceAtExact(t)-16000)*120/60000
            assertEquals(beats,y.sourceAtExact(t)*150/60000,1e-8)
            assertEquals(t,x.globalAtExact(x.sourceAtExact(t)),1e-7)
        }
        assertEquals(20000L,d.clips[0].globalEndMs)
        assertNull(d.clips[0].tempoMap)
    }
    @Test fun offBeatEofNeedsExplicitTrimDisclosureNotSilentDraftMutation() {
        val a=clip("a",1,0).copy(sourceOutMs=19800);val b=clip("b",2,16000)
        val d=TimelineDocument(clips=listOf(a,b))
        val fit=fitTempoEditorRamp(d,TempoEditorOverlap(a,b),draft(a,b))
        assertTrue(fit.trimsSource);assertTrue(fit.explanation.contains("19800 → 19500"))
        assertEquals(19800L,d.clips[0].sourceOutMs)
        assertEquals(19500L,fit.document.clips[0].sourceOutMs)
    }
    @Test fun repeatedRecordingPairsRemainOccurrenceOwnedAndThirdConnectedIsRefused() {
        val a=clip("a",1,0);val b=clip("b",1,16000);val c=clip("c",1,18000)
        val d=TimelineDocument(clips=listOf(a,b,c))
        val choices=tempoEditorOverlaps(d)
        assertEquals(3,choices.size);assertEquals(3,choices.map {it.id}.distinct().size)
        assertThrows(IllegalArgumentException::class.java){fitTempoEditorRamp(d,TempoEditorOverlap(a,b),draft(a,b))}
        assertTrue(d.tempoRamps.isEmpty())
    }
    @Test fun fitHonorsExplicitStartBeatRatherThanRelabelingRequestedRange() {
        val a=clip("a",1,0);val b=clip("b",2,16000);val d=TimelineDocument(clips=listOf(a,b))
        val fit=fitTempoEditorRamp(d,TempoEditorOverlap(a,b),draft(a,b).copy(startSharedBeat=24),requestedStartBeat=24)
        assertEquals(24L,fit.document.tempoRamps.single().startSharedBeat)
        assertEquals(12000L,fit.document.clips[1].globalStartMs)
        assertEquals(16000L,fit.document.clips[0].sourceOutMs)
        assertTrue(fit.trimsSource)
    }
    @Test fun customTargetHoldChangesIncomingEofAndDoesNotRewriteOriginalBpm() {
        val a=clip("a",1,0);val b=clip("b",2,16000);val d=TimelineDocument(clips=listOf(a,b))
        val fit=fitTempoEditorRamp(d,TempoEditorOverlap(a,b),draft(a,b,TempoTarget(TempoTargetKind.Custom,180.0)))
        val incoming=fit.document.clips[1]
        assertEquals(150.0,fit.document.tempoRamps.single().incoming.sourceBpm,0.0)
        assertEquals(180.0,incoming.tempoMap!!.law.bpmAt(30000.0),0.0)
        assertEquals(20000.0,incoming.sourceAtExact(incoming.globalAtExact(20000.0)),1e-7)
    }
}
