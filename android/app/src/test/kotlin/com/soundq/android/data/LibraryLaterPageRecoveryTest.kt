package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test

class LibraryLaterPageRecoveryTest {
    private fun session()=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore()).also {
        it.accept(it.beginIntent(),SecretTokens("a","r","A"))
    }
    @Test fun explicitRetryOfFailedLaterPageRetainsRowsAndExactCursor() {
        val offsets=mutableListOf<Int>();var fail=true
        val repo=LibraryRepository(session(),{_,query,offset->
            assertEquals(LibraryQuery(text="100%_ +",sort=LibrarySort.Artist,ascending=true,liked=true),query)
            offsets+=offset
            if(offset==20&&fail)throw SafeFailure(SafeFailure.Reason.Network)
            LibraryPage((offset+1..minOf(offset+20,42)).map {Track(TrackId(it.toLong()),"Track $it",liked=true)},42,20,offset)
        },{_,_,_->})
        repo.refine(LibraryQuery(text="100%_ +",sort=LibrarySort.Artist,ascending=true,liked=true))
        repo.loadMore();val failed=repo.state.value;val retained=failed.rows
        assertEquals(SafeFailure.Reason.Network,failed.error)
        assertEquals(20,failed.nextOffset)
        fail=false
        // Explicit captured user intent, not the automatic near-bottom observer.
        val retry=repo.claimPageRetry(failed){true}
        assertNotNull("A failed append needs an exact-page retry, not an offset-zero reset",retry)
        assertSame(retained,repo.state.value.rows)
        repo.executeNextPage(retry!!)
        assertEquals(listOf(0,20,20),offsets)
        assertEquals((1L..40L).toList(),repo.state.value.rows.map {it.id.value})
        var selectedTracks:List<Track> = emptyList();var selectedIndex=-1
        repo.playAction(repo.state.value.rows,37) {tracks,index->selectedTracks=tracks;selectedIndex=index}()
        assertEquals((1L..40L).toList(),selectedTracks.map {it.id.value});assertEquals(37,selectedIndex)
        val selected=repo.captureTrack(repo.state.value.rows[37])!!
        assertEquals(38L,selected.track.id.value);assertTrue(repo.owns(selected))
        assertNull(repo.claimPageRetry(failed){true})
        assertNull(repo.state.value.error)
    }
    @Test fun cancelledRecoveryRestoresFailureWithoutAutomaticRetryAndFreshIntentCanRecover() {
        var visible=true;var fail=true;val offsets=mutableListOf<Int>()
        val repo=LibraryRepository(session(),{_,_,offset->offsets+=offset
            if(offset>0&&fail)throw SafeFailure(SafeFailure.Reason.Network)
            LibraryPage(listOf(Track(TrackId(offset.toLong()+1),"Song")),3,20,offset)
        },{_,_,_->})
        repo.refine(LibraryQuery());repo.loadMore();val failed=repo.state.value
        val cancelled=repo.claimPageRetry(failed){visible}!!
        visible=false;repo.executeNextPage(cancelled)
        assertSame(failed,repo.state.value);assertEquals(listOf(0,1),offsets)
        repo.loadMore();assertEquals(listOf(0,1),offsets)
        visible=true;fail=false
        repo.executeNextPage(repo.claimPageRetry(repo.state.value){visible}!!)
        assertEquals(listOf(0,1,1),offsets);assertNull(repo.state.value.error)
        assertEquals(listOf(1L,2L),repo.state.value.rows.map {it.id.value})
    }
    @Test fun retainedPlaybackCannotBorrowAReplacementScopeOrEqualQueryRefresh() {
        val s=session();val repo=LibraryRepository(s,{_,_,offset->LibraryPage(listOf(Track(TrackId(38),"Later song")),1,20,offset)},{_,_,_->})
        repo.refine(LibraryQuery());var plays=0
        val old=repo.playAction(repo.state.value.rows,0){_,_->plays++}
        old();assertEquals(1,plays)
        repo.refine(LibraryQuery());old();assertEquals(1,plays)
        val fresh=repo.playAction(repo.state.value.rows,0){_,_->plays++}
        s.accept(s.beginIntent(),SecretTokens("b","r","A"));fresh();assertEquals(1,plays)
        repo.playAction(repo.state.value.rows,0){_,_->plays++}();assertEquals(1,plays)
    }
    @Test fun retiredRecoveryCannotBorrowReplacementAccountOrQuery() {
        val session=session();var reads=0
        val repo=LibraryRepository(session,{_,_,offset->reads++;if(offset>0)throw SafeFailure(SafeFailure.Reason.Network)
            LibraryPage(listOf(Track(TrackId(1),"First")),3,20,offset)
        },{_,_,_->})
        repo.refine(LibraryQuery());repo.loadMore();val failed=repo.state.value
        session.accept(session.beginIntent(),SecretTokens("b","r","A"))
        assertNull(repo.claimPageRetry(failed){true})
        assertEquals(2,reads)
        repo.refine(LibraryQuery(text="new"))
        assertNull(repo.claimPageRetry(failed){true})
        assertEquals(3,reads)
    }
}
