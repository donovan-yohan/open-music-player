package com.soundq.android.data.timeline

import org.junit.Assert.*
import org.junit.Test

class TempoPlaybackWorkflowTest {
    private fun document():TimelineDocument=TimelineDocument(clips=listOf(
        TimelineClip("a",1,"A",12347,0,12347,0,QueueSegment.Manual),
        TimelineClip("b",2,"B",17777,0,17777,9000,QueueSegment.Manual)))
    private fun identity(c:TimelineClip,bpm:Double)=TempoSourceIdentity(c.occurrence,c.track,"source-${c.track}",c.sourceDurationMs,"r1","local_manual",bpm,31.25,1)
    @Test fun exactQueueUndoRestoresTempoWritabilityWithoutTransferringIntentToNewOccurrence() {
        var disk:String?=null
        val inputs=document().clips.map {TimelineSource(it.occurrence,it.track,it.title,it.sourceDurationMs,it.segment)}
        val owner=TimelineOwner({disk},{disk=it});owner.observe(inputs)
        var d=owner.state.value.document
        val id=identity(d.clips[0],138.0)
        assertTrue(owner.commit(TimelineTempoEdit(d,d.withPlaybackTempo(TempoPlaybackIntent(id,140.25)))))
        val original=owner.state.value.document;val bytes=disk
        owner.observe(inputs.drop(1))
        assertFalse(owner.state.value.writable);assertEquals(bytes,disk)
        owner.observe(listOf(inputs[0].copy(occurrence="fresh"),inputs[1]))
        assertFalse(owner.state.value.writable)
        assertNull(owner.state.value.document.clips.single {it.occurrence=="fresh"}.heldTempo)
        owner.observe(inputs)
        assertTrue("Exact queue Undo must recover a temporary missing-occurrence projection",owner.state.value.writable)
        assertNull(owner.state.value.message)
        d=owner.state.value.document
        assertEquals(original.playbackTempos,d.playbackTempos)
        assertEquals(original.clips.map {it.sourceInMs to it.sourceOutMs},d.clips.map {it.sourceInMs to it.sourceOutMs})
        assertEquals(original.clips.map {it.globalStartMs},d.clips.map {it.globalStartMs})
        assertEquals(bytes,disk)
        assertTrue(owner.commit(TimelineTempoEdit(d,d.withPlaybackTempo(TempoPlaybackIntent(id,141.0)))))
        val reload=TimelineOwner({disk},{disk=it});reload.observe(inputs)
        assertTrue(reload.state.value.writable);assertEquals(141.0,reload.state.value.document.playbackTempos.single().playbackBpm,0.0)
        val unreadable="{unreadable"
        val broken=TimelineOwner({unreadable},{error("Unreadable bytes must not be replaced")});broken.observe(inputs)
        broken.observe(inputs.drop(1));broken.observe(inputs)
        assertFalse("Queue changes cannot clear a durable read refusal",broken.state.value.writable)
        var fail=false;var linkedBytes:String?=null
        val linkedInputs=listOf(TimelineSource("master",7,"A",60000,QueueSegment.Manual),TimelineSource("incoming",7,"B",60000,QueueSegment.Manual))
        val linked=TimelineOwner({linkedBytes},{if(fail)error("disk") else linkedBytes=it});linked.observe(linkedInputs)
        val pair=linked.state.value.document
        assertTrue(linked.commit(PhaseEdit(pair.revision,pair.clips[0],pair.clips[1],PhaseGrid("manual:7:60000","a",500,125,125),PhaseGrid("manual:7:60000","b",500,250,250),1,9300)))
        val beforeFailure=linkedBytes;fail=true
        linked.observe(linkedInputs.take(1));assertFalse(linked.state.value.writable)
        linked.observe(linkedInputs)
        assertFalse("Queue Undo cannot clear a failed durable link retirement",linked.state.value.writable)
        assertEquals(beforeFailure,linkedBytes)
    }
    @Test fun tempoOnlyAutoHasExactSourceMapButCannotEnterStrictBeatFit() {
        val original=document()
        val ids=original.clips.map {c->identity(c,138.0).copy(gridProvenance="analysis_bpm",beatAnchorMs=0.0,beatAnchorKnown=false)}
        val held=original.withPlaybackTempo(TempoPlaybackIntent(ids[0],140.25))
        val auto=held.withAutoBpmCrossfade(true,ids)
        val ramp=auto.tempoRamps.single()
        assertEquals(12347.0,auto.clips[0].sourceAtExact(ramp.overlapEndMs),1e-7)
        assertEquals(original.clips.map {it.sourceInMs to it.sourceOutMs},auto.clips.map {it.sourceInMs to it.sourceOutMs})
        val raw=held.clips
        fun fit(c:TimelineClip,id:TempoSourceIdentity)=TempoParticipantFit(id,c.globalStartMs.toDouble(),c.sourceInMs.toDouble(),c.sourceOutMs.toDouble(),c.sourceAtExact(ramp.overlapStartMs),0.8,1.5)
        val context=TempoFitContext(fit(raw[0],ids[0]),fit(raw[1],ids[1]),emptyList(),4,ramp.overlapStartMs,ramp.overlapEndMs,140.25,0)
        val strict=planTempoTransition(ramp.copy(policy=TempoRampPolicy.SharedRampV1),context)
        assertEquals(TempoFitReason.TimingNeeded,(strict as TempoPlanResult.Invalid).reason)
        val manualName=ids[0].copy(gridProvenance="local_manual")
        assertFalse("Renaming an unknown anchor cannot grant legacy phase authority",manualName.supportsTempoOnly())
        val renamed=planTempoTransition(ramp.copy(policy=TempoRampPolicy.SharedRampV1,outgoing=manualName),context.copy(outgoing=context.outgoing.copy(source=manualName)))
        assertEquals(TempoFitReason.TimingNeeded,(renamed as TempoPlanResult.Invalid).reason)
        val json=kotlinx.serialization.json.Json
        val identityBytes=json.encodeToString(TempoSourceIdentity.serializer(),ids[0])
        assertTrue(identityBytes.contains("\"beatAnchorKnown\":false"))
        assertEquals(ids[0],json.decodeFromString(TempoSourceIdentity.serializer(),identityBytes))
        val legacy=json.encodeToString(TempoSourceIdentity.serializer(),identity(original.clips[0],138.0))
        assertFalse(legacy.contains("beatAnchorKnown"))
        assertTrue(json.decodeFromString(TempoSourceIdentity.serializer(),legacy).beatAnchorKnown)
        var disk:String?=null
        val inputs=original.clips.map {TimelineSource(it.occurrence,it.track,it.title,it.sourceDurationMs,it.segment)}
        val owner=TimelineOwner({disk},{disk=it});owner.observe(inputs)
        val d=owner.state.value.document
        assertTrue(owner.commit(TimelineTempoEdit(d,auto)))
        assertTrue(disk!!.contains("\"version\":5"))
        val savedBytes=requireNotNull(disk)
        val reload=TimelineOwner({disk},{disk=it});reload.observe(inputs)
        assertTrue(reload.state.value.writable);assertEquals(auto.tempoRamps,reload.state.value.document.tempoRamps)
        assertFalse(reload.state.value.document.tempoRamps.single().outgoing.beatAnchorKnown)
        val futureBytes=savedBytes.replace("\"beatAnchorKnown\":false","\"beatAnchorKnown\":false,\"futureTiming\":1")
        disk=futureBytes
        val future=TimelineOwner({disk},{disk=it});future.observe(inputs)
        assertFalse(future.state.value.writable);assertEquals(futureBytes,disk)
        assertTrue(owner.undo());assertEquals(d.playbackTempos,owner.state.value.document.playbackTempos)
    }
    @Test fun ordinaryOffBeatSourcesHoldDecimalPlaybackAndAutoUsesExactSelectedEof() {
        val original=document()
        val sources=original.clips.mapIndexed {i,c->identity(c,if(i==0)138.0 else 126.5)}
        val held=original.withPlaybackTempo(TempoPlaybackIntent(sources[0],140.25))
        assertTrue(held.tempoRamps.isEmpty())
        assertEquals(140.25/138.0,held.clips[0].rates.baseRate,1e-12)
        assertEquals(12347.0,held.clips[0].sourceAtExact(held.clips[0].globalAtExact(12347.0)),1e-7)
        val auto=held.withAutoBpmCrossfade(true,sources)
        val ramp=auto.tempoRamps.single()
        assertEquals(TempoRampPolicy.AutoSourceBoundsV1,ramp.policy)
        assertEquals(original.clips.map {it.globalStartMs},auto.clips.map {it.globalStartMs})
        assertEquals(original.clips.map {it.sourceInMs to it.sourceOutMs},auto.clips.map {it.sourceInMs to it.sourceOutMs})
        assertEquals(12347.0,auto.clips[0].sourceAtExact(ramp.overlapEndMs),1e-7)
        assertEquals(auto.clips[0].tempoMap!!.law.bpmAt(10000.0),auto.clips[1].tempoMap!!.law.bpmAt(10000.0),0.0)
        assertEquals(126.5,auto.clips[1].tempoMap!!.law.bpmAt(30000.0),0.0)
        val off=auto.withAutoBpmCrossfade(false,sources)
        assertFalse(off.autoBpmCrossfade)
        assertTrue(off.tempoRamps.isEmpty())
        assertEquals(held.playbackTempos,off.playbackTempos)
        assertEquals(auto.clips.map {it.fadeInMs to it.fadeOutMs},off.clips.map {it.fadeInMs to it.fadeOutMs})
        assertNull(validateTimeline(off.clips))
    }
    @Test fun changingIncomingTargetReplansButKeepsSourceAndStart() {
        val d=document();val ids=d.clips.map {identity(it,138.0)}
        val auto=d.withAutoBpmCrossfade(true,ids)
        val changed=auto.withPlaybackTempo(TempoPlaybackIntent(ids[1],145.125))
        assertEquals(145.125,changed.clips[1].tempoMap!!.law.targetBpm,0.0)
        assertEquals(9000L,changed.clips[1].globalStartMs)
        assertEquals(17777L,changed.clips[1].sourceOutMs)
        val restored=changed.withPlaybackTempo(TempoPlaybackIntent(ids[1],138.0))
        assertEquals(138.0,restored.clips[1].tempoMap!!.law.targetBpm,0.0)
    }
    @Test fun autoCanArmWithoutOverlapAndFuturePlacementReplansWithoutSourceTrim() {
        val d=document().copy(clips=document().clips.mapIndexed {i,c->if(i==1)c.copy(globalStartMs=12347) else c})
        val ids=d.clips.map {identity(it,138.0)}
        val armed=d.withAutoBpmCrossfade(true,ids)
        assertTrue(armed.autoBpmCrossfade);assertTrue(armed.tempoRamps.isEmpty())
        val owner=TimelineOwner({null},{})
        owner.observe(d.clips.map {TimelineSource(it.occurrence,it.track,it.title,it.sourceDurationMs,it.segment)})
        val first=owner.state.value.document
        val held=first.copy(playbackTempos=ids.map {TempoPlaybackIntent(it,it.sourceBpm)},autoBpmCrossfade=true)
        assertTrue(owner.commit(TimelineTempoEdit(first,held)))
        val current=owner.state.value.document
        assertTrue(owner.commit(TimelineEdit(current.revision,current.clips[1],EditKind.Placement,9000)))
        val projected=owner.state.value.document
        assertEquals(TempoRampPolicy.AutoSourceBoundsV1,projected.tempoRamps.single().policy)
        assertEquals(9000L,projected.clips[1].globalStartMs)
        assertEquals(d.clips.map {it.sourceInMs to it.sourceOutMs},projected.clips.map {it.sourceInMs to it.sourceOutMs})
        assertTrue(owner.undo())
        assertTrue(owner.state.value.document.tempoRamps.isEmpty())
        assertTrue(owner.state.value.document.autoBpmCrossfade)
    }
    @Test fun invalidTempoAndProspectiveFifthVoiceRefuseWithoutMutatingDraft() {
        val d=document();val source=identity(d.clips[0],138.0)
        assertTrue(runCatching {d.withPlaybackTempo(TempoPlaybackIntent(source,Double.NaN))}.isFailure)
        assertTrue(runCatching {d.withPlaybackTempo(TempoPlaybackIntent(source,300.0))}.isFailure)
        val one=TimelineClip("x",3,"X",10000,0,10000,0,QueueSegment.Manual)
        val peers=(1..4).map {i->TimelineClip("p$i",(i+3).toLong(),"P",10000,0,10000,11000,QueueSegment.Manual)}
        val many=TimelineDocument(clips=listOf(one)+peers)
        assertNull(validateTimeline(many.clips))
        assertTrue(runCatching {many.withPlaybackTempo(TempoPlaybackIntent(identity(one,120.0),96.0))}.isFailure)
        assertEquals(RateAutomation(),many.clips[0].rates)
        assertTrue(many.playbackTempos.isEmpty())
    }
}
