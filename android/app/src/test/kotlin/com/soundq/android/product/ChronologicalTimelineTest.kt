package com.soundq.android.product

import com.soundq.android.data.timeline.*
import com.soundq.android.data.*
import com.soundq.android.playback.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class ChronologicalTimelineTest {
    private fun clip(id:String,track:Long,start:Long,end:Long)=TimelineClip(id,track,id,end-start,0,end-start,start,QueueSegment.Manual)
    private fun base()=TimelineDocument(7,listOf(clip("a",1,0,100000),clip("b",7,20000,30000),clip("c",7,40000,80000)))
    @Test fun tiesUseBaseOrdinalNotCandidateCollectionOrderAndKeepEndedDuplicates() {
        val base=base()
        val candidate=base.copy(clips=listOf(base.clips[2].copy(globalStartMs=20000),base.clips[1],base.clips[0]))
        val p=chronologicalTimeline(base,candidate)
        assertSame(base,p.base);assertSame(candidate,p.shown)
        assertEquals(listOf("a","b","c"),p.clips.map {it.occurrence})
        assertSame(candidate.clips[1],p.clips[1])
        assertEquals(listOf("a","b","c"),base.clips.map {it.occurrence})
        assertEquals(listOf(0L,20000L,40000L),base.clips.map {it.globalStartMs})
    }
    @Test fun repeatedCrossingsCancelRefusalAndCommitRetainCapturedClipAuthority() {
        val base=base();val b=base.clips[1]
        var projection=chronologicalTimeline(base)
        val g=TimelineGesture({edit->
            val candidate=runCatching {base.edited(edit)}.getOrNull()
            val reason=if(candidate==null) "Invalid" else validateTimeline(candidate.clips)
            projection=chronologicalTimeline(base,candidate?.takeIf {validateTimeline(it.clips)==null})
            EditDecision(reason==null,reason)
        },{})
        g.begin(base.revision,b,EditKind.Placement)
        g.update(50000);assertEquals(listOf("a","c","b"),projection.clips.map {it.occurrence})
        assertSame(b,g.preview!!.original)
        g.update(10000);assertEquals(listOf("a","b","c"),projection.clips.map {it.occurrence})
        g.update(60000);assertEquals(listOf("a","c","b"),projection.clips.map {it.occurrence})
        g.update(-1);assertFalse(g.decision.accepted);assertSame(base,projection.shown)
        g.cancel();projection=chronologicalTimeline(base)
        assertSame(base,projection.shown);assertEquals(20000L,b.globalStartMs)
        val committed=base.edited(TimelineEdit(base.revision,b,EditKind.Placement,50000)).copy(revision=8)
        val p=chronologicalTimeline(committed,projection)
        assertSame(committed,p.base);assertSame(committed,p.shown)
        assertEquals(listOf("a","c","b"),p.clips.map {it.occurrence})
        assertEquals(listOf("a","b","c"),committed.clips.map {it.occurrence})
    }
    @Test fun structurallyEqualReplacementCannotReviveOldPreview() {
        val base=base();val preview=chronologicalTimeline(base,base.edited(TimelineEdit(7,base.clips[1],EditKind.Placement,50000)))
        val replacement=base.copy()
        assertEquals(base,replacement);assertNotSame(base,replacement)
        assertEquals(TimelineDocumentIdentity(base),TimelineDocumentIdentity(base))
        assertNotEquals(TimelineDocumentIdentity(base),TimelineDocumentIdentity(replacement))
        assertSame(replacement,chronologicalTimeline(replacement,preview).shown)
    }
    @Test fun draftRowsNeverSeekOrMarkCurrentFromDraftIntervals() {
        val base=base();val p=chronologicalTimeline(base,base.edited(TimelineEdit(7,base.clips[1],EditKind.Placement,50000)))
        val accepted=AcceptedArrangement(ArrangementIdentity("service",1,"queue",7,"install"),base,
            base.clips.map {QueueOccurrence(it.occurrence,it.track,it.title,"Artist",false,it.sourceDurationMs)})
        val rows=arrangementQueueRows(p,accepted,25000)
        assertEquals(listOf("a","c","b"),rows.map {it.occurrence})
        assertEquals(listOf(true,false,true),rows.map {it.current})
        assertEquals(50000L,rows.last().startMs)
        assertTrue(rows.all {it.seekMs==null})
        val matched=arrangementQueueRows(chronologicalTimeline(base),accepted,25000)
        assertEquals(listOf(0L,20000L,40000L),matched.map {it.seekMs})
    }
    private class Store:SessionStore {
        override fun load(endpoint:ApiEndpoint):SecretTokens?=null
        override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){}
        override fun clear(){}
    }
    @Test fun qualifiedLinkedPreviewMovesBothOriginalsWithoutPersistenceOrCollectionReorder() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store())
        session.accept(session.beginIntent(),SecretTokens("a","r","account"));val scope=session.capture()!!
        val directory=Files.createTempDirectory(java.io.File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"chronology-phase").toFile()
        try {
            val grid=PhaseGrid("source","r",500,0,provenance="manual_timing_v2")
            val repo=TimelineRepository(session,directory){_,track,duration,_->TrackWaveform(track,"source",duration,emptyList(),phaseTiming=grid)}
            val sources=listOf(TimelineSource("a",1,"A",20000,QueueSegment.Manual),TimelineSource("b",2,"B",20000,QueueSegment.Manual),TimelineSource("c",3,"C",20000,QueueSegment.Manual))
            repo.observe(scope,sources);sources.forEach {repo.waveform(scope,TrackId(it.track),it.durationMs,valid={true})}
            var d=repo.state.value.document
            assertTrue(repo.commit(PhaseEdit(d.revision,d.clips[0],d.clips[1],grid,grid,1,500)){true})
            d=repo.state.value.document
            val edit=TimelineEdit(d.revision,d.clips[0],EditKind.Placement,50000)
            val bytes=directory.listFiles()!!.single().readText()
            val candidate=repo.previewDocument(d,edit){true}!!
            assertEquals(listOf(50000L,50500L,40000L),candidate.clips.map {it.globalStartMs})
            assertEquals(listOf("c","a","b"),chronologicalTimeline(d,candidate).clips.map {it.occurrence})
            assertEquals(listOf("a","b","c"),candidate.clips.map {it.occurrence})
            assertSame(d,repo.state.value.document);assertEquals(bytes,directory.listFiles()!!.single().readText())
            assertTrue(repo.commit(edit){true});assertEquals(candidate.clips,repo.state.value.document.clips)
        } finally {directory.deleteRecursively()}
    }
    @Test fun qualifiedAutoPreviewUsesRepositoryCandidateAndDoesNotPersist() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store())
        session.accept(session.beginIntent(),SecretTokens("a","r","account"));val scope=session.capture()!!
        val directory=Files.createTempDirectory(java.io.File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"chronology-preview").toFile()
        try {
            val repo=TimelineRepository(session,directory){_,track,duration,_->TrackWaveform(track,"s-${track.value}",duration,emptyList(),suggestedBpm=120.0)}
            val sources=listOf(TimelineSource("a",1,"A",20000,QueueSegment.Manual),TimelineSource("b",2,"B",20000,QueueSegment.Manual),TimelineSource("c",2,"C",20000,QueueSegment.Manual))
            repo.observe(scope,sources);sources.forEach {repo.waveform(scope,TrackId(it.track),it.durationMs,valid={true})}
            var d=repo.state.value.document
            assertTrue(repo.commit(TimelineTempoEdit(d,d.withAutoBpmCrossfade(true,d.clips.map {repo.tempoSource(it)!!}))){true})
            d=repo.state.value.document
            val state=repo.state.value;val bytes=directory.listFiles()!!.associate {it.name to it.readText()}
            val edit=TimelineEdit(d.revision,d.clips[1],EditKind.Placement,45000)
            val candidate=repo.previewDocument(d,edit){true}
            assertNotNull(candidate);assertSame(d,repo.state.value.document);assertSame(state,repo.state.value)
            assertEquals(listOf("a","c","b"),chronologicalTimeline(d,candidate).clips.map {it.occurrence})
            assertEquals(bytes,directory.listFiles()!!.associate {it.name to it.readText()})
            assertNull(repo.previewDocument(d,edit){false})
            assertNull(repo.previewDocument(d.copy(),edit){true})
            assertNull(repo.previewDocument(d,edit.copy(original=edit.original.copy())){true})
            assertNull(repo.previewDocument(d,edit.copy(valueMs=-1)){true})
            assertTrue(repo.commit(edit){true})
            assertEquals(candidate!!.clips,repo.state.value.document.clips)
            assertEquals(candidate.tempoRamps,repo.state.value.document.tempoRamps)
            assertNull(repo.previewDocument(d,edit){true})
            assertTrue(repo.undo {true});assertEquals(d.clips,repo.state.value.document.clips)
            session.accept(session.beginIntent(),SecretTokens("new","r","other"))
            assertNull(repo.previewDocument(repo.state.value.document,edit){true})
        } finally {directory.deleteRecursively()}
    }
}
