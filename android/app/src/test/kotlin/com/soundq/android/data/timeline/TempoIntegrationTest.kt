package com.soundq.android.data.timeline

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class TempoIntegrationTest {
    private fun source(id:String,track:Long,bpm:Double)=TempoSourceIdentity(id,track,"source-$track",20000,"grid-$track","manual_timing_v2",bpm,0.0,1)
    private fun intent()=TempoRampIntent(1,TempoRampPolicy.SharedRampV1,source("a",1,120.0),source("b",2,120.0),120.0,TempoTarget(TempoTargetKind.Original,null),TempoCurve.LinearTime,16000.0,20000.0,32,8,TempoGainLaw.Linear)
    private fun sources()=listOf(TimelineSource("a",1,"A",20000,QueueSegment.Manual),TimelineSource("b",2,"B",20000,QueueSegment.Manual))
    private fun saved():String {
        val clips=sequentialTimeline(sources()).map {if(it.occurrence=="b")it.copy(globalStartMs=16000,fadeInMs=4000) else it.copy(fadeOutMs=4000)}
        return buildJsonObject {
            put("version",4)
            put("document",buildJsonObject {put("revision",3);put("clips",Json.encodeToJsonElement(clips));put("tempoRamps",JsonArray(listOf(Json.encodeToJsonElement(intent()))))})
        }.toString()
    }
    @Test fun explicitV4RampLoadsWithoutReplacingBytes() {
        var disk=saved();val original=disk;var writes=0
        val owner=TimelineOwner({disk},{disk=it;writes++});owner.observe(sources())
        assertTrue("A supported explicit v4 ramp must load",owner.state.value.writable)
        assertEquals(original,disk);assertEquals(0,writes)
        assertEquals(16000L,owner.state.value.document.clips[1].globalStartMs)
    }
    @Test fun rampFadeAdmissionUsesOutputTimeRatherThanSourceLength() {
        val i=intent().copy(target=TempoTarget(TempoTargetKind.Custom,96.0),outgoingEffectiveStartBpm=96.0,overlapStartMs=0.0,overlapEndMs=20000.0,startSharedBeat=0,lengthBeats=32)
        val clips=sequentialTimeline(sources()).map {c->if(c.occurrence=="a")c.copy(sourceOutMs=16000,rates=RateAutomation(0.8),fadeOutMs=20000) else c.copy(globalStartMs=0,fadeInMs=20000)}
        val projected=projectTempoDocument(TimelineDocument(clips=clips,tempoRamps=listOf(i)))
        assertNull("Mapped fade is output time, not source time",validateTimeline(projected.clips))
    }
    @Test fun renderedScheduleRetainsTempoMapAndUnequalBpmSourceGeometry() {
        val i=intent().copy(outgoing=source("a",1,120.0),incoming=source("b",2,150.0),target=TempoTarget(TempoTargetKind.Custom,180.0),overlapStartMs=0.0,overlapEndMs=8000.0,startSharedBeat=0,lengthBeats=20)
        val clips=sequentialTimeline(sources()).map {if(it.occurrence=="a")it.copy(sourceOutMs=10000,fadeOutMs=8000) else it.copy(globalStartMs=0,fadeInMs=8000)}
        val document=projectTempoDocument(TimelineDocument(clips=clips,tempoRamps=listOf(i)))
        val outgoing=document.clips[0];val incoming=document.clips[1]
        assertEquals(4500.0,outgoing.sourceAtExact(4000.0),1e-8)
        assertEquals(3600.0,incoming.sourceAtExact(4000.0),1e-8)
        assertEquals(8000L,outgoing.globalEndMs)
        val schedule=compileSchedule(document)
        assertEquals(8000L,schedule.clips[0].globalEndMs)
    }
    @Test fun tempoTransactionSavesWholeIntentAndUndoRestoresPriorVolumeDraft() {
        var disk=saved();val owner=TimelineOwner({disk},{disk=it});owner.observe(sources())
        val old=owner.state.value.document
        val changed=old.copy(tempoRamps=old.tempoRamps.map {it.copy(target=TempoTarget(TempoTargetKind.Custom,120.0),curve=TempoCurve.SmoothTime,gainLaw=TempoGainLaw.EqualPower)})
        assertTrue(owner.commit(TimelineTempoEdit(old,changed)))
        assertEquals(TempoTargetKind.Custom,owner.state.value.document.tempoRamps.single().target.kind)
        val restarted=TimelineOwner({disk},{disk=it});restarted.observe(sources())
        assertEquals(owner.state.value.document.tempoRamps,restarted.state.value.document.tempoRamps)
        assertTrue(owner.undo());assertEquals(old.tempoRamps,owner.state.value.document.tempoRamps)
        assertFalse(owner.commit(TimelineTempoEdit(old,changed)))
        val current=owner.state.value.document
        assertFalse(owner.commit(TimelineTempoEdit(current,current.copy(tempoRamps=emptyList()))){false})
    }
    @Test fun rejectedCandidateKeepsPriorIntentBytesAndUndoEntry() {
        var disk=saved();val owner=TimelineOwner({disk},{disk=it});owner.observe(sources())
        val old=owner.state.value.document;val bytes=disk
        val invalid=old.copy(tempoRamps=old.tempoRamps.map {it.copy(version=2)})
        assertFalse(owner.commit(TimelineTempoEdit(old,invalid)))
        assertSame(old,owner.state.value.document);assertEquals(bytes,disk)
        val a=old.clips[0]
        assertFalse(owner.commit(TimelineEdit(old.revision,a,EditKind.Placement,1000)))
        assertEquals(bytes,disk)
    }
    @Test fun normalizedServiceRoundtripRecreatesIdenticalMapsWithoutSerializingDerivedFields() {
        var disk=saved();val owner=TimelineOwner({disk},{disk=it});owner.observe(sources())
        val document=owner.state.value.document
        val bytes=Json.encodeToString(document)
        assertFalse(bytes.contains("tempoMap"))
        val decoded=Json.decodeFromString<TimelineDocument>(bytes)
        assertNotEquals(document,decoded)
        assertEquals(document,projectTempoDocument(decoded))
        assertEquals(tempoMapsByOccurrence(document),tempoMapsByOccurrence(decoded))
        assertEquals(compileSchedule(document),compileSchedule(decoded))
    }
    @Test fun nativeGainCompatibilityRefusesLinearWithoutChangingStoredIntent() {
        var disk=saved();val owner=TimelineOwner({disk},{disk=it});owner.observe(sources())
        val document=owner.state.value.document
        assertTrue(validateNativeTempoPlan(document)!!.contains("Equal power"))
        assertEquals(TempoGainLaw.Linear,document.tempoRamps.single().gainLaw)
        val equal=document.copy(tempoRamps=document.tempoRamps.map {it.copy(gainLaw=TempoGainLaw.EqualPower)})
        assertNull(validateNativeTempoPlan(equal))
        assertEquals(setOf("a","b"),tempoMapsByOccurrence(equal).keys)
        assertTrue(tempoMapsByOccurrence(TimelineDocument(clips=sequentialTimeline(sources()))).isEmpty())
    }
    @Test fun sourceRemovalRetainsIntentAndBytesRatherThanConvertingToVolume() {
        var disk=saved();val owner=TimelineOwner({disk},{disk=it});owner.observe(sources())
        val bytes=disk;val ramps=owner.state.value.document.tempoRamps
        owner.observe(sources().take(1))
        assertFalse(owner.state.value.writable)
        assertEquals(ramps,owner.state.value.document.tempoRamps)
        assertEquals(bytes,disk)
    }
    @Test fun unknownVersionAndUnknownTempoFieldsStayReadOnlyWithoutRewrite() {
        for(raw in listOf(saved().replace("\"version\":4","\"version\":6"),saved().replace("\"tempoRamps\":","\"future\":true,\"tempoRamps\":"))) {
            var disk=raw;val owner=TimelineOwner({disk},{disk=it});owner.observe(sources())
            assertFalse(owner.state.value.writable);assertEquals(raw,disk)
        }
    }
}
