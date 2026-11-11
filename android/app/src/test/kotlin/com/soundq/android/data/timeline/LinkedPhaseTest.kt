package com.soundq.android.data.timeline

import com.soundq.android.data.*
import com.soundq.android.playback.arrangementPlan
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class LinkedPhaseTest {
    private val sources=listOf(TimelineSource("master",7,"Same recording A",60000,QueueSegment.Context),TimelineSource("incoming",7,"Same recording B",60000,QueueSegment.Manual))
    private fun owner():TimelineOwner=TimelineOwner({null},{}).also {it.observe(sources)}
    private fun edit(o:TimelineOwner,n:Int=1,start:Long=9300):PhaseEdit {
        val d=o.state.value.document
        return PhaseEdit(d.revision,d.clips[0],d.clips[1],PhaseGrid("manual:7:60000","a",500,125,125),PhaseGrid("manual:7:60000","b",500,250,250),n,start)
    }
    @Test fun explicitReferenceNotIncomingOwnGridMatchesCompatiblePredecessorRed() {
        val o=owner();val e=edit(o)
        val old=o.state.value.document
        assertTrue(o.preview(e).accepted);assertSame(old,o.state.value.document)
        assertTrue(o.commit(e));val d=o.state.value.document
        assertEquals(0L,d.clips[0].globalStartMs);assertEquals(9375L,d.clips[1].globalStartMs)
        assertEquals(9625L,d.phaseLink!!.guide(d.clips));assertEquals(19L,d.phaseLink!!.relativeSteps)
        assertEquals(9375L,d.arrangementPlan().clips[1].start)
    }
    @Test fun allLiteralBeatIncrementsAndLowerTieAreReferenceRelative() {
        for((n,expected) in listOf(1 to 9375L,4 to 9875L,16 to 7875L,32 to 15875L)) {
            val o=owner();assertTrue(o.commit(edit(o,n)));assertEquals("$n beats",expected,o.state.value.document.clips[1].globalStartMs)
        }
        val o=owner();assertTrue(o.commit(edit(o,1,125)));assertEquals(375L,o.state.value.document.clips[1].globalStartMs)
        val tie=owner();assertTrue(tie.commit(edit(tie,1,625)));assertEquals(375L,tie.state.value.document.clips[1].globalStartMs)
    }
    @Test fun independentGroupOriginsDriveTheAcceptedPlacementGuideAndReload() {
        for((increment,expected) in listOf(1 to 9375L,4 to 8375L,16 to 8375L,32 to 16375L)) {
            var raw:String?=null
            val o=TimelineOwner({raw},{raw=it});o.observe(sources)
            val e=edit(o,increment).let {it.copy(referenceGrid=it.referenceGrid.copy(groupOriginMs=1125),incomingGrid=it.incomingGrid.copy(groupOriginMs=750))}
            assertTrue(o.commit(e));val d=o.state.value.document
            assertEquals("$increment beats must use the supplied group origins",expected,d.clips[1].globalStartMs)
            val incomingAnchor=if(increment==1)250L else 750L
            assertEquals(expected+incomingAnchor,d.phaseLink!!.guide(d.clips))
            if(increment!=1)assertEquals(0L,(expected+750-1125)%(increment*500L))
            val rebuilt=TimelineOwner({raw},{error("read-only reconstruction")});rebuilt.observe(sources)
            assertTrue(rebuilt.state.value.writable);assertEquals(d.clips,rebuilt.state.value.document.clips)
            assertEquals(d.phaseLink,rebuilt.state.value.document.phaseLink)
        }
        val tie=owner();val e=edit(tie,4,9375).let {it.copy(referenceGrid=it.referenceGrid.copy(groupOriginMs=1125),incomingGrid=it.incomingGrid.copy(groupOriginMs=750))}
        assertTrue(tie.commit(e));assertEquals(8375L,tie.state.value.document.clips[1].globalStartMs)
    }
    @Test fun savedAnchorAlignedButGroupMisalignedRelationIsRefused() {
        val o=owner();val d=o.state.value.document
        val e=edit(o,4).let {it.copy(referenceGrid=it.referenceGrid.copy(groupOriginMs=1125),incomingGrid=it.incomingGrid.copy(groupOriginMs=750))}
        val wrong=d.copy(clips=listOf(d.clips[0],d.clips[1].copy(globalStartMs=9875)),phaseLink=PhaseLink("master","incoming",e.referenceGrid,e.incomingGrid,4,5,7,7,60000,60000))
        assertNotNull("The accepted guide must not certify a different group lattice",validatePhase(wrong))
    }
    @Test fun groupedUnknownOriginFractionalAndUnequalTempoRefuseWithoutMutation() {
        val o=owner();val e=edit(o,4)
        assertFalse(o.preview(e.copy(referenceGrid=e.referenceGrid.copy(groupOriginMs=null))).accepted)
        assertTrue(o.preview(e.copy(increment=1,referenceGrid=e.referenceGrid.copy(groupOriginMs=null),incomingGrid=e.incomingGrid.copy(groupOriginMs=null))).accepted)
        assertTrue(runCatching {PhaseGrid.manual("manual","1","128",0,0)}.isFailure)
        assertTrue(runCatching {PhaseGrid.manual("manual","1","-120",0,0)}.isFailure)
        assertFalse(o.preview(e.copy(incomingGrid=e.incomingGrid.copy(periodMs=600,groupOriginMs=250))).accepted)
        assertFalse(o.preview(e.copy(proposedStartMs=Long.MAX_VALUE)).accepted)
        assertFalse(o.preview(e.copy(referenceGrid=e.referenceGrid.copy(anchorMs=60001,groupOriginMs=null))).accepted)
    }
    @Test fun masterTranslationIncomingRelativeMoveHiddenAnchorTrimUnlockAndUndoAreAtomic() {
        val o=owner();assertTrue(o.commit(edit(o,4)));var d=o.state.value.document
        assertTrue(o.commit(TimelineEdit(d.revision,d.clips[0],EditKind.Placement,1000)));d=o.state.value.document
        assertEquals(listOf(1000L,10875L),d.clips.map {it.globalStartMs})
        assertTrue(o.commit(TimelineEdit(d.revision,d.clips[1],EditKind.Placement,13000)));d=o.state.value.document
        assertEquals(1000L,d.clips[0].globalStartMs);assertEquals(12875L,d.clips[1].globalStartMs)
        val beforeTrim=d
        assertTrue(o.commit(TimelineEdit(d.revision,d.clips[0],EditKind.TrimIn,5000)));d=o.state.value.document
        assertEquals(6000L,d.clips[0].globalStartMs);assertEquals(1000L,d.clips[0].globalStartMs-d.clips[0].sourceInMs)
        assertEquals(12875L,d.clips[1].globalStartMs);assertEquals(beforeTrim.phaseLink,d.phaseLink)
        assertTrue(o.commit(TimelineEdit(d.revision,d.clips[0],EditKind.TrimOut,10000)));d=o.state.value.document
        assertNull(validatePhase(d)) // hidden master anchor remains the original source beat
        val linked=d
        assertTrue(o.unlock(d.revision));assertNull(o.state.value.document.phaseLink);assertEquals(linked.clips,o.state.value.document.clips)
        assertTrue(o.undo());assertEquals(linked.phaseLink,o.state.value.document.phaseLink);assertEquals(linked.clips,o.state.value.document.clips)
    }
    @Test fun staleObjectsAndRevisionRouteRefuseAndRemovalVisiblyRetiresLink() {
        val o=owner();val e=edit(o)
        assertFalse(o.commit(e){false});assertFalse(o.commit(e.copy(reference=e.reference.copy())))
        assertTrue(o.commit(e));assertFalse(o.commit(e))
        val clips=o.state.value.document.clips
        o.observe(sources.take(1));assertNull(o.state.value.document.phaseLink);assertTrue(o.state.value.message!!.contains("retired"))
        o.observe(sources);assertNull(o.state.value.document.phaseLink);assertEquals(clips,o.state.value.document.clips)
    }
    @Test fun pairFadeTranslationPreservesEndpointsAndRelativeMoveRefuses() {
        val o=owner();assertTrue(o.commit(edit(o,1,50000)));var d=o.state.value.document
        val overlap=d.clips[0].globalEndMs-d.clips[1].globalStartMs
        assertTrue(o.commit(TimelineFadeEdit(d.revision,d.clips[0],d.clips[1],overlap)));d=o.state.value.document
        assertNotNull(d.phaseLink)
        assertFalse(o.preview(TimelineEdit(d.revision,d.clips[1],EditKind.Placement,40000)).accepted)
        assertTrue(o.commit(TimelineEdit(d.revision,d.clips[0],EditKind.Placement,1000)));d=o.state.value.document
        assertEquals(overlap,d.clips[0].fadeOutMs);assertEquals(overlap,d.clips[1].fadeInMs)
        assertFalse(o.preview(TimelineEdit(d.revision,d.clips[0],EditKind.TrimOut,59000)).accepted)
    }
    @Test fun fifthOverlapPairTranslationIsRejectedWithoutClampingAndNegativeStartSearchesAdmissibleBeat() {
        val o=owner();assertTrue(o.commit(edit(o,1,-100)));assertEquals(375L,o.state.value.document.clips[1].globalStartMs)
        val rows=sources+listOf("c","d","e").map {TimelineSource(it,8,it,60000,QueueSegment.Context)}
        val x=TimelineOwner({null},{});x.observe(rows)
        for(index in 2..4){val d=x.state.value.document;assertTrue(x.commit(TimelineEdit(d.revision,d.clips[index],EditKind.Placement,70000)))}
        assertTrue(x.commit(edit(x,1,5000)));val before=x.state.value.document
        val decision=x.preview(TimelineEdit(before.revision,before.clips[0],EditKind.Placement,70000))
        assertFalse(decision.accepted);assertSame(before,x.state.value.document)
    }
    @Test fun capturedGridCannotBeChangedWithoutUnlockAndRetirementCannotReviveOnReload() {
        var raw:String?=null
        val o=TimelineOwner({raw},{raw=it});o.observe(sources);assertTrue(o.commit(edit(o)))
        val d=o.state.value.document;val link=d.phaseLink!!
        val changed=PhaseEdit(d.revision,d.clips[0],d.clips[1],link.referenceGrid.copy(revision="changed"),link.incomingGrid,1,9300)
        assertFalse(o.preview(changed).accepted);assertEquals(d,o.state.value.document)
        o.observe(sources.take(1));assertFalse(raw!!.contains("phaseLink"))
        val reload=TimelineOwner({raw},{raw=it});reload.observe(sources)
        assertNull(reload.state.value.document.phaseLink)
        assertTrue(reload.state.value.writable)
    }
    @Test fun absoluteGroupGeometrySurvivesHiddenPrefixAndNonFourDownbeatsStayIndependent() {
        val o=owner();assertTrue(o.commit(edit(o,32)));val d=o.state.value.document
        val clip=d.clips[0].copy(sourceInMs=10000,globalStartMs=10000)
        val wave=TrackWaveform(TrackId(7),"a",60000,emptyList(),downbeats=listOf(10125,11625,13125))
        val ticks=phaseTicks(clip,TimelineViewport(60000,400f,20.0,10000),d.phaseLink!!.referenceGrid,wave)
        assertEquals(16125L,ticks.first {it.group==32}.sourceMs)
        assertEquals(listOf(10125L,11625L,13125L),ticks.filter {it.downbeat}.map {it.sourceMs})
        assertEquals(3,ticks.count {it.downbeat})
        assertEquals(10125L,ticks.first().globalMs)
    }
    @Test fun realFileReconstructionStrictVersionAndCorruptRelationProtection() {
        val dir=java.nio.file.Files.createTempDirectory(File(System.getenv("TMPDIR")).toPath(),"linked-draft-").toFile()
        try {
            val file=File(dir,"draft.json");val o=TimelineOwner({if(file.exists())file.readText()else null},{file.writeText(it)})
            o.observe(sources);assertTrue(o.commit(edit(o,16)));val accepted=o.state.value.document
            assertTrue(file.readText().contains("\"version\":3"))
            val reloaded=TimelineOwner({file.readText()},{file.writeText(it)});reloaded.observe(sources)
            assertEquals(accepted.clips,reloaded.state.value.document.clips);assertEquals(accepted.phaseLink,reloaded.state.value.document.phaseLink)
            val bad=file.readText().replace("\"relativeSteps\":1","\"relativeSteps\":2")
            file.writeText(bad);val refused=TimelineOwner({file.readText()},{error("must preserve rejected bytes")});refused.observe(sources)
            assertFalse(refused.state.value.writable);assertEquals(bad,file.readText())
        }finally{dir.deleteRecursively()}
    }
}
