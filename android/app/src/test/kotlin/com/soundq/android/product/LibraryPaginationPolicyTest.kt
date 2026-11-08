package com.soundq.android.product

import com.soundq.android.data.*
import org.junit.Assert.*
import org.junit.Test

class LibraryPaginationPolicyTest {
    private val page=LibraryState(rows=(1L..20L).map {Track(TrackId(it),"Track $it")},total=80,nextOffset=20,pageRevision=1)

    @Test fun approachesBottomOncePerAcceptedPageNotOncePerScrollEmission() {
        val gate=LibraryPaginationGate()
        assertFalse(gate.claim(page,10,20,5))
        assertTrue(gate.claim(page,14,20,5))
        assertFalse(gate.claim(page,19,20,5))
        assertFalse(gate.claim(page,2,20,5))
        assertFalse(gate.claim(page,19,20,5))
        assertTrue(gate.claim(page.copy(rows=page.rows+page.rows.map {it.copy(id=TrackId(it.id.value+20))},nextOffset=40,pageRevision=2),35,40,5))
    }
    @Test fun loadingErrorExhaustedEmptyAndUnlaidOutRowsNeverRequest() {
        for(blocked in listOf(page.copy(loading=true),page.copy(error=SafeFailure.Reason.Network),page.copy(endReached=true),page.copy(total=20),page.copy(total=null),page.copy(rows=emptyList()))) {
            assertFalse(LibraryPaginationGate().claim(blocked,19,20,5))
        }
        assertFalse(LibraryPaginationGate().claim(page,-1,20,5))
        assertFalse(LibraryPaginationGate().claim(page,19,0,5))
        assertFalse(LibraryPaginationGate().claim(page,19,19,5))
    }
    @Test fun transientLoadingAndRowHeartPaintCannotRearmUnchangedCursor() {
        val gate=LibraryPaginationGate()
        assertTrue(gate.claim(page,19,20,5))
        assertFalse(gate.claim(page.copy(loading=true),19,20,5))
        assertFalse(gate.claim(page.copy(rows=page.rows.map {it.copy(liked=true)}),19,20,5))
        assertFalse(gate.claim(page.copy(mutations=mapOf(TrackId(1) to MutationOutcome.Refused)),19,20,5))
        assertTrue(gate.claim(page.copy(pageRevision=2),19,20,5))
    }
    @Test fun retiredVisitCannotReviveAndFreshVisitCanContinueSamePage() {
        val old=LibraryPaginationGate();assertTrue(old.current());old.close()
        assertFalse(old.current());assertFalse(old.claim(page,19,20,5))
        assertTrue(LibraryPaginationGate().claim(page,19,20,5))
    }
    @Test fun shortVisiblePageFillsViewportButDoesNotRetryAnUnchangedPage() {
        val short=page.copy(rows=page.rows.take(2),nextOffset=2)
        val gate=LibraryPaginationGate()
        assertTrue(gate.claim(short,1,2,5));assertFalse(gate.claim(short,1,2,5))
    }
}
