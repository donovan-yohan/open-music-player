package com.soundq.android.data.timeline

import org.junit.Assert.*
import org.junit.Test

class TimelineOwnerTest {
    private fun sources(n:Int=2)= (1..n).map {TimelineSource("M$it",7,"Same",10000,QueueSegment.Manual)}
    @Test fun oversizedOrdinaryContextRetainsDraftAndRejectsActionsUntilSupportedRecovery() {
        var disk:String?=null;var writes=0
        val owner=TimelineOwner({disk},{disk=it;writes++});val input=sources();owner.observe(input)
        var d=owner.state.value.document
        assertTrue(owner.commit(TimelineEdit(d.revision,d.clips[1],EditKind.TrimIn,2000)))
        d=owner.state.value.document
        val edit=TimelineEdit(d.revision,d.clips[1],EditKind.TrimOut,8000)
        val tempo=TimelineTempoEdit(d,d.copy(autoBpmCrossfade=true))
        val saved=disk;val beforeWrites=writes
        for(n in listOf(501,1001)) {
            owner.observe(sources(n))
            assertFalse(owner.state.value.writable);assertFalse(owner.state.value.canUndo)
            assertEquals(d,owner.state.value.document)
            assertFalse(owner.preview(edit).accepted);assertFalse(owner.commit(edit))
            assertFalse(owner.preview(tempo).accepted);assertFalse(owner.commit(tempo));assertFalse(owner.undo())
            assertEquals(saved,disk);assertEquals(beforeWrites,writes)
        }
        owner.observe(input)
        assertTrue(owner.state.value.writable);assertEquals(d.clips,owner.state.value.document.clips)
        assertFalse(owner.commit(edit));assertFalse(owner.commit(tempo));assertEquals(saved,disk)
        val fresh=owner.state.value.document
        assertTrue(owner.commit(TimelineEdit(fresh.revision,fresh.clips[1],EditKind.TrimOut,8000)))
    }
    @Test fun oversizedFirstObservationPreservesRejectedSavedBytesAcrossRecovery() {
        val bad="{not-valid-json";var disk=bad
        val owner=TimelineOwner({disk},{disk=it});owner.observe(sources(1001));owner.observe(sources())
        assertFalse(owner.state.value.writable);assertEquals(bad,disk)
        assertTrue(owner.state.value.message!!.contains("unreadable"))
    }
    @Test fun oversizedContextDoesNotEvictPriorAbsentDirtyDrafts() {
        val owner=TimelineOwner({null},{})
        val input=sources();owner.observe(input)
        val d=owner.state.value.document
        assertTrue(owner.commit(TimelineEdit(d.revision,d.clips[1],EditKind.TrimIn,2000)))
        owner.observe(emptyList());owner.observe(sources(1001));owner.observe(input)
        assertTrue(owner.state.value.writable);assertEquals(2000L,owner.state.value.document.clips[1].sourceInMs)
    }
    @Test fun oversizedCapabilityDoesNotSwallowMalformedOccurrenceOrSourceIdentity() {
        val owner=TimelineOwner({null},{error("must not write")})
        for(input in listOf(sources(501).map {it.copy(occurrence="same")},sources(501).mapIndexed {i,s->if(i==500)s.copy(track=0) else s},sources(501).mapIndexed {i,s->if(i==500)s.copy(durationMs=0) else s})) {
            try {owner.observe(input);fail("Malformed sources must still be rejected")}catch(_:IllegalArgumentException){}
        }
    }
    @Test fun initialEmptyControllerObservationCannotEraseRestorableDraft() {
        var disk:String?=null
        val first=TimelineOwner({disk},{disk=it});first.observe(sources())
        val d=first.state.value.document
        assertTrue(first.commit(TimelineEdit(d.revision,d.clips[1],EditKind.TrimIn,2000)))
        val restarted=TimelineOwner({disk},{disk=it});restarted.observe(emptyList());restarted.observe(sources())
        assertEquals(2000L,restarted.state.value.document.clips[1].sourceInMs)
    }
    @Test fun queueReorderRetainsHorizontalPlacementAndDuplicateIdentity() {
        val owner=TimelineOwner({null},{})
        val input=sources();owner.observe(input)
        val d=owner.state.value.document
        assertTrue(owner.commit(TimelineEdit(d.revision,d.clips[1],EditKind.Placement,3000)))
        owner.observe(input.reversed())
        assertEquals(listOf("M2","M1"),owner.state.value.document.clips.map {it.occurrence})
        assertEquals(listOf(3000L,0L),owner.state.value.document.clips.map {it.globalStartMs})
        assertFalse(owner.state.value.canUndo)
    }
    @Test fun rejectedSavedBytesRemainUntouchedAndEditingIsRefused() {
        val bytes="{not-valid-json";var disk=bytes
        val owner=TimelineOwner({disk},{disk=it});owner.observe(sources())
        val d=owner.state.value.document
        assertFalse(owner.state.value.writable)
        assertFalse(owner.commit(TimelineEdit(d.revision,d.clips[1],EditKind.Placement,0)))
        assertEquals(bytes,disk)
    }
    @Test fun previewDoesNotPersistAndAcceptedEditIsDurableAndUndoable() {
        var disk:String?=null;var writes=0
        val owner=TimelineOwner({disk},{disk=it;writes++});owner.observe(sources())
        val before=owner.state.value.document
        val edit=TimelineEdit(before.revision,before.clips[1],EditKind.Placement,4000)
        val beforeWrites=writes
        assertTrue(owner.preview(edit).accepted)
        assertEquals(before,owner.state.value.document);assertEquals(beforeWrites,writes)
        assertTrue(owner.commit(edit));assertEquals(4000L,owner.state.value.document.clips[1].globalStartMs)
        assertEquals(0L,owner.state.value.document.clips[0].globalStartMs)
        val restored=TimelineOwner({disk},{disk=it});restored.observe(sources())
        assertEquals(4000L,restored.state.value.document.clips[1].globalStartMs)
        assertTrue(owner.undo());assertEquals(10000L,owner.state.value.document.clips[1].globalStartMs)
        assertFalse(owner.commit(edit));assertFalse(owner.state.value.canUndo)
    }
    @Test fun fifthHalfOpenOverlapIsRefusedWithoutClampingOrDropping() {
        val owner=TimelineOwner({null},{});owner.observe(sources(5))
        for(index in 1..3) {
            val d=owner.state.value.document
            assertTrue(owner.commit(TimelineEdit(d.revision,d.clips[index],EditKind.Placement,0)))
        }
        val d=owner.state.value.document
        assertFalse(owner.preview(TimelineEdit(d.revision,d.clips[4],EditKind.Placement,9999)).accepted)
        assertTrue(owner.commit(TimelineEdit(d.revision,d.clips[4],EditKind.Placement,10000)))
        assertEquals(5,owner.state.value.document.clips.size)
    }
    @Test fun trimKeepsGlobalPlacementAndRejectsInvalidRangeOrRetiredCallback() {
        val owner=TimelineOwner({null},{});owner.observe(sources())
        val d=owner.state.value.document
        assertTrue(owner.commit(TimelineEdit(d.revision,d.clips[1],EditKind.TrimIn,2000)))
        val next=owner.state.value.document
        assertEquals(10000L,next.clips[1].globalStartMs)
        assertEquals(18000L,next.clips[1].globalEndMs)
        assertFalse(owner.commit(TimelineEdit(next.revision,next.clips[1],EditKind.TrimOut,2500)))
        assertFalse(owner.commit(TimelineEdit(next.revision,next.clips[1],EditKind.TrimOut,9000)){false})
    }
    @Test fun authoritativeEmptyRetainsExactIdentitiesButNewOccurrenceAndChangedSourceUseDefaults() {
        var disk:String?=null
        val owner=TimelineOwner({disk},{disk=it});val input=sources();owner.observe(input)
        var d=owner.state.value.document
        assertTrue(owner.commit(TimelineEdit(d.revision,d.clips[1],EditKind.TrimIn,2000)))
        d=owner.state.value.document
        assertTrue(owner.commit(TimelineEdit(d.revision,d.clips[1],EditKind.Placement,3000)))
        val accepted=owner.state.value.document.clips[1]
        val stale=TimelineEdit(owner.state.value.document.revision,accepted,EditKind.TrimOut,8000)
        owner.observe(emptyList());assertTrue(owner.state.value.document.clips.isEmpty())
        owner.observe(input);assertEquals(accepted,owner.state.value.document.clips[1])
        assertFalse(owner.commit(stale))
        owner.observe(input.take(1)+input.last().copy(occurrence="new-B"))
        assertEquals(0L,owner.state.value.document.clips.last().sourceInMs)
        owner.observe(input.take(1)+input.last().copy(track=8))
        assertEquals(0L,owner.state.value.document.clips.last().sourceInMs)
        owner.observe(input)
        assertEquals(0L,owner.state.value.document.clips.last().sourceInMs)
        owner.observe(input.take(1)+input.last().copy(durationMs=11000))
        assertEquals(11000L,owner.state.value.document.clips.last().sourceOutMs)
        assertEquals(0L,owner.state.value.document.clips.last().sourceInMs)
    }
    @Test fun absentRetentionIsBoundedAndReportsEvictionWithoutDroppingCurrentEdits() {
        val owner=TimelineOwner({null},{})
        val first=sources(500);owner.observe(first)
        val d=owner.state.value.document
        assertTrue(owner.commit(TimelineEdit(d.revision,d.clips.first(),EditKind.TrimIn,2000)))
        val next=first.map {it.copy(occurrence="second-${it.occurrence}")}
        owner.observe(next);owner.observe(emptyList()) // 1000 absent candidates, most recent 500 retained.
        assertTrue(owner.state.value.message?.contains("Older removed")==true)
        owner.observe(first.take(1))
        assertEquals(0L,owner.state.value.document.clips.single().sourceInMs)
        val now=owner.state.value.document
        assertTrue(owner.commit(TimelineEdit(now.revision,now.clips.single(),EditKind.TrimIn,3000)))
        owner.observe(next.take(499)+first.take(1))
        assertEquals(3000L,owner.state.value.document.clips.last().sourceInMs)
        owner.observe(emptyList());owner.observe(first.take(1))
        assertEquals(3000L,owner.state.value.document.clips.single().sourceInMs)
    }
    @Test fun unknownSavedDataStaysUnwritableThroughRemovalAndRestoration() {
        for(bytes in listOf("{\"version\":2,\"document\":{}}","{\"version\":1,\"future\":true,\"document\":{}}")) {
            var disk=bytes;val owner=TimelineOwner({disk},{disk=it});owner.observe(sources())
            owner.observe(emptyList());owner.observe(sources())
            val d=owner.state.value.document
            assertFalse(owner.state.value.writable)
            assertFalse(owner.commit(TimelineEdit(d.revision,d.clips[1],EditKind.TrimIn,2000)))
            assertEquals(bytes,disk)
        }
    }
    @Test fun storageFailureDoesNotPublishAnAcceptedEdit() {
        var fail=false
        val owner=TimelineOwner({null},{if(fail)error("disk")});owner.observe(sources())
        val d=owner.state.value.document;fail=true
        assertFalse(owner.commit(TimelineEdit(d.revision,d.clips[1],EditKind.Placement,0)))
        assertEquals(d,owner.state.value.document)
    }
}
