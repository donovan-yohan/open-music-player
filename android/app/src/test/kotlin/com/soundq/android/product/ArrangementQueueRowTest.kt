package com.soundq.android.product

import com.soundq.android.data.timeline.*
import com.soundq.android.playback.*
import org.junit.Assert.*
import org.junit.Test

class ArrangementQueueRowTest {
    private fun accepted():AcceptedArrangement {
        val clips=listOf(
            TimelineClip("second",7,"Draft title",6000,0,4000,2000,QueueSegment.Context),
            TimelineClip("first",7,"Draft title",6000,0,2000,0,QueueSegment.Context),
        )
        return AcceptedArrangement(ArrangementIdentity("service",1,"queue",4,"install"),TimelineDocument(4,clips),
            listOf(QueueOccurrence("first",7,"First occurrence","Original artist",false,6000),QueueOccurrence("second",7,"Second occurrence","Other artist",false,6000)))
    }
    @Test fun duplicateRecordingKeepsOccurrenceNamesAndAcceptedDocumentOrder() {
        val rows=arrangementQueueRows(accepted(),1000)
        assertEquals(listOf("second","first"),rows.map {it.occurrence})
        assertEquals(listOf("Second occurrence","First occurrence"),rows.map {it.title})
        assertEquals(listOf("Other artist","Original artist"),rows.map {it.artist})
        assertEquals(listOf(false,true),rows.map {it.current})
    }
    @Test fun halfOpenBoundarySelectsOnlyTheSuccessorAndNoInventedEndRow() {
        val rows=arrangementQueueRows(accepted(),2000)
        assertEquals(listOf(true,false),rows.map {it.current})
        assertTrue(arrangementQueueRows(accepted(),6000).none {it.current})
    }
    @Test fun overlapExposesBothCurrentSourcesRatherThanSyntheticSelection() {
        val original=accepted()
        val shifted=original.copy(document=original.document.copy(clips=original.document.clips.map {if(it.occurrence=="second")it.copy(globalStartMs=1000)else it}))
        assertEquals(listOf(true,true),arrangementQueueRows(shifted,1500).map {it.current})
        assertEquals(listOf(1000L,0L),arrangementQueueRows(shifted,1500).map {it.startMs})
    }
}
