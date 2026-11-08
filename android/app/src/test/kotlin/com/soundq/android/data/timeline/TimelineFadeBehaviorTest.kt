package com.soundq.android.data.timeline

import com.soundq.android.data.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class TimelineFadeBehaviorTest {
    private val sources=listOf("out","in","peer").map {TimelineSource(it,7,"Duplicate",10000,QueueSegment.Context)}
    private fun owner():TimelineOwner=TimelineOwner({null},{}).also {o->o.observe(sources);val d=o.state.value.document;check(o.commit(TimelineEdit(d.revision,d.clips[1],EditKind.Placement,8000)))}
    private fun edit(o:TimelineOwner,duration:Long=2000):TimelineFadeEdit {val d=o.state.value.document;return TimelineFadeEdit(d.revision,d.clips[0],d.clips[1],duration)}
    @Test fun previewCancelAndUndoKeepExactAcceptedSourcesAndPlacement() {
        val o=owner();val d=o.state.value.document;val e=edit(o)
        assertTrue(o.preview(e).accepted);assertSame(d,o.state.value.document) // Cancel simply drops this immutable preview.
        assertTrue(o.commit(e));val accepted=o.state.value.document
        assertEquals(2000L,accepted.clips[0].fadeOutMs);assertEquals(2000L,accepted.clips[1].fadeInMs)
        assertEquals(d.clips.map {it.sourceInMs to it.sourceOutMs},accepted.clips.map {it.sourceInMs to it.sourceOutMs})
        assertTrue(o.undo());assertEquals(d.clips,o.state.value.document.clips);assertFalse(o.commit(e))
    }
    @Test fun fullOverlapOnlyNeverClampsShortensOrRelocatesTheSource() {
        val o=owner();val d=o.state.value.document
        for(n in listOf(-1L,0L,1L,1999L,2001L,Long.MAX_VALUE))assertFalse(o.commit(edit(o,n)))
        assertEquals(d,o.state.value.document)
        assertFalse(o.commit(TimelineFadeEdit(d.revision,d.clips[0],d.clips[0],10000)))
        assertFalse(o.commit(TimelineFadeEdit(d.revision,d.clips[1],d.clips[0],2000)))
        assertFalse(o.commit(TimelineFadeEdit(d.revision,d.clips[1],d.clips[2],2000)))
    }
    @Test fun staleSourceAndReconstructedSameRevisionAreNotCapturedOccurrences() {
        val o=owner();val e=edit(o);val d=o.state.value.document
        assertFalse(o.commit(e.copy(outgoing=e.outgoing.copy())))
        o.observe(sources.map {if(it.occurrence=="in")it.copy(durationMs=11000)else it})
        assertFalse(o.commit(e));assertEquals(0L,o.state.value.document.clips[0].fadeOutMs)
        assertFalse(o.commit(e){false})
    }
    @Test fun placementCarriesFadeWithoutChangingSourceAndOtherEndpointFadesSurvive() {
        val o=owner();assertTrue(o.commit(edit(o)));var d=o.state.value.document
        assertTrue(o.commit(TimelineEdit(d.revision,d.clips[1],EditKind.Placement,9000)))
        d=o.state.value.document;assertEquals(2000L,d.clips[1].fadeInMs);assertEquals(9000L,d.clips[1].globalStartMs)
        assertEquals(2000L,d.clips[0].fadeOutMs);assertEquals(0L,d.clips[2].fadeInMs)
    }
    @Test fun acceptingPairPreservesOtherValidEndpointFadesAndRefusesUnsupportedRate() {
        val clips=sequentialTimeline(sources).mapIndexed {i,c->when(i){0->c.copy(fadeInMs=500);1->c.copy(globalStartMs=8000,fadeOutMs=500);else->c.copy(fadeInMs=300)}}
        val raw="""{"version":2,"document":${kotlinx.serialization.json.Json.encodeToString(TimelineDocument.serializer(),TimelineDocument(5,clips))}}"""
        val o=TimelineOwner({raw},{});o.observe(sources);assertTrue(o.commit(edit(o)))
        assertEquals(listOf(500L,2000L,300L),o.state.value.document.clips.map {it.fadeInMs})
        assertEquals(listOf(2000L,500L,0L),o.state.value.document.clips.map {it.fadeOutMs})
        val unsupported=clips.map {it.copy(fadeInMs=0,fadeOutMs=0,rates=RateAutomation(1.25))}
        val rateRaw="""{"version":1,"document":${kotlinx.serialization.json.Json.encodeToString(TimelineDocument.serializer(),TimelineDocument(5,unsupported))}}"""
        val rateOwner=TimelineOwner({rateRaw},{});rateOwner.observe(sources)
        val d=rateOwner.state.value.document
        assertFalse(rateOwner.commit(TimelineFadeEdit(d.revision,d.clips[0],d.clips[1],2000)))
    }
    @Test fun repositoryReconstructionKeepsFadesAndOldAccountOrRouteCannotCommit() {
        val dir=Files.createTempDirectory("fade-repo-").toFile()
        try {
            val s=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),MemoryStore());s.accept(s.beginIntent(),SecretTokens("a","r","fixture"));val scope=s.capture()!!
            fun repo()=TimelineRepository(s,dir){_,_,_,_->error("No analysis")}.also {it.observe(scope,sources)}
            val r=repo();var d=r.state.value.document
            assertTrue(r.commit(TimelineEdit(d.revision,d.clips[1],EditKind.Placement,8000)){true});d=r.state.value.document
            val e=TimelineFadeEdit(d.revision,d.clips[0],d.clips[1],2000)
            assertFalse(r.commit(e){false});assertTrue(r.commit(e){true})
            val accepted=r.state.value.document;r.observe(scope,sources);assertSame(accepted,r.state.value.document)
            val rebuilt=repo();assertEquals(accepted.clips,rebuilt.state.value.document.clips)
            s.retire();assertFalse(r.commit(e){true});assertFalse(r.undo {true})
        } finally {dir.deleteRecursively()}
    }
}
