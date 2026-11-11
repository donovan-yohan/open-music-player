package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class LibraryPaginationRepositoryTest {
    private fun session()=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore()).also {
        it.accept(it.beginIntent(),SecretTokens("a","r","A"))
    }
    private fun track(id:Long)=Track(TrackId(id),"Track $id",liked=false)

    @Test fun emptyPageWithStaleTotalDoesNotRepeatTheSameOffset() {
        val offsets=mutableListOf<Int>()
        val repository=LibraryRepository(session(),{_,_,offset->
            offsets+=offset
            LibraryPage(if(offset==0)listOf(track(1))else emptyList(),99,20,offset)
        },{_,_,_->})
        repository.refine(LibraryQuery())
        repeat(4){repository.loadMore()}
        assertEquals("Empty pages must exhaust pagination despite a stale server total",listOf(0,1),offsets)
        assertEquals(listOf(TrackId(1)),repository.state.value.rows.map {it.id})
        assertNull(repository.state.value.error)
    }

    @Test fun duplicateOnlyPageCannotGrowRowsOrKeepPaginationAlive() {
        val offsets=mutableListOf<Int>()
        val first=track(1)
        val repository=LibraryRepository(session(),{_,_,offset->
            offsets+=offset;LibraryPage(listOf(first.copy()),99,20,offset)
        },{_,_,_->})
        repository.refine(LibraryQuery());repeat(4){repository.loadMore()}
        assertEquals(listOf(0,1),offsets)
        assertEquals(listOf(first),repository.state.value.rows)
    }

    @Test fun failedAppendRequiresExplicitRefreshInsteadOfAutomaticRetry() {
        val offsets=mutableListOf<Int>();var fail=true
        val repository=LibraryRepository(session(),{_,_,offset->
            offsets+=offset
            if(offset>0&&fail)throw SafeFailure(SafeFailure.Reason.Network)
            LibraryPage(listOf(track(offset.toLong()+1)),3,20,offset)
        },{_,_,_->})
        repository.refine(LibraryQuery());repository.loadMore();fail=false
        repeat(3){repository.loadMore()}
        assertEquals(listOf(0,1),offsets)
        assertEquals(SafeFailure.Reason.Network,repository.state.value.error)
        repository.refine(repository.state.value.query);repository.loadMore()
        assertEquals(listOf(0,1,0,1),offsets)
        assertNull(repository.state.value.error)
    }

    @Test fun claimConsumesExactStateBeforeSchedulingAndCannotBeReplayed() {
        val offsets=mutableListOf<Int>()
        val repository=LibraryRepository(session(),{_,_,offset->offsets+=offset;LibraryPage(listOf(track(offset.toLong()+1)),4,20,offset)},{_,_,_->})
        repository.refine(LibraryQuery());val expected=repository.state.value
        val request=repository.claimNextPage(expected){true}!!
        assertTrue(repository.state.value.loading)
        assertNull(repository.claimNextPage(expected){true})
        repository.executeNextPage(request);repository.executeNextPage(request)
        assertEquals(listOf(0,1),offsets)
        assertEquals(listOf(TrackId(1),TrackId(2)),repository.state.value.rows.map {it.id})
        assertNull(repository.claimNextPage(expected){true})
        assertNotNull(repository.claimNextPage(repository.state.value){true}.also {repository.abandonNextPage(it!!)})
        assertFalse(repository.state.value.loading)
    }

    @Test fun queryAndSameAccountReplacementRefuseScheduledOldClaims() {
        for(replaceAccount in listOf(false,true)) {
            val session=session();val offsets=mutableListOf<Int>()
            val repository=LibraryRepository(session,{_,_,offset->offsets+=offset;LibraryPage(listOf(track(1)),4,20,offset)},{_,_,_->})
            repository.refine(LibraryQuery());val old=repository.claimNextPage(repository.state.value){true}!!
            if(replaceAccount)session.accept(session.beginIntent(),SecretTokens("b","r","A"))
            repository.refine(LibraryQuery())
            repository.executeNextPage(old);repository.abandonNextPage(old)
            assertEquals(listOf(0,0),offsets)
            assertFalse(repository.state.value.loading)
            if(replaceAccount)assertNull(repository.claimNextPage(repository.state.value.copy()){true})
        }
    }

    @Test fun replacementAccountCannotRecaptureStillDisplayedOldRows() {
        val session=session();var reads=0
        val repository=LibraryRepository(session,{_,_,offset->reads++;LibraryPage(listOf(track(1)),4,20,offset)},{_,_,_->})
        repository.refine(LibraryQuery());val old=repository.state.value
        session.accept(session.beginIntent(),SecretTokens("b","r","A"))
        assertNull(repository.claimNextPage(old){true})
        assertEquals(1,reads)
    }

    @Test fun retiredVisitBeforeDispatchSettlesOnlyItsOwnLoadingAndFreshVisitCanContinue() {
        val offsets=mutableListOf<Int>();var visible=true
        val repository=LibraryRepository(session(),{_,_,offset->offsets+=offset;LibraryPage(listOf(track(offset.toLong()+1)),4,20,offset)},{_,_,_->})
        repository.refine(LibraryQuery())
        val old=repository.claimNextPage(repository.state.value){visible}!!
        visible=false;repository.executeNextPage(old);repository.abandonNextPage(old)
        assertEquals(listOf(0),offsets);assertFalse(repository.state.value.loading)
        visible=true
        val fresh=repository.claimNextPage(repository.state.value){visible}!!
        repository.executeNextPage(fresh)
        assertEquals(listOf(0,1),offsets)
    }

    @Test fun hidingDuringFetchRejectsRowsAndFailureWithoutRetrying() {
        for(fail in listOf(false,true)) {
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            val visible=java.util.concurrent.atomic.AtomicBoolean(true)
            val repository=LibraryRepository(session(),{_,_,offset->
                if(offset>0){entered.countDown();check(release.await(3,TimeUnit.SECONDS));if(fail)throw SafeFailure(SafeFailure.Reason.Network)}
                LibraryPage(listOf(track(offset.toLong()+1)),4,20,offset)
            },{_,_,_->})
            repository.refine(LibraryQuery());val original=repository.state.value.rows
            val request=repository.claimNextPage(repository.state.value){visible.get()}!!
            val pool=Executors.newSingleThreadExecutor()
            try {
                val work=pool.submit {repository.executeNextPage(request)}
                assertTrue(entered.await(2,TimeUnit.SECONDS));visible.set(false);release.countDown();work.get(3,TimeUnit.SECONDS)
                assertSame(original,repository.state.value.rows);assertNull(repository.state.value.error)
                assertFalse(repository.state.value.loading)
            }finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(3,TimeUnit.SECONDS))}
        }
    }

    @Test fun partiallyOverlappingPagesUseWireCursorAndPreserveAcknowledgedRows() {
        val offsets=mutableListOf<Int>();val first=track(1)
        val repository=LibraryRepository(session(),{_,_,offset->
            offsets+=offset
            LibraryPage(when(offset){0->listOf(first);1->listOf(first.copy(title="duplicate"),track(2));else->listOf(track(3))},4,20,offset)
        },{_,_,_->})
        repository.refine(LibraryQuery());repository.loadMore();repository.loadMore()
        assertEquals(listOf(0,1,3),offsets)
        assertEquals(listOf(TrackId(1),TrackId(2),TrackId(3)),repository.state.value.rows.map {it.id})
        assertSame(first,repository.state.value.rows.first())
        assertSame(first,repository.likeView(repository.session.capture()!!,first.id)!!.track)
        assertTrue(repository.state.value.endReached)
    }

    @Test fun duplicateExecutionCannotRetireTheOneInFlightFetch() {
        val entered=CountDownLatch(1);val release=CountDownLatch(1);var reads=0
        val repository=LibraryRepository(session(),{_,_,offset->
            reads++;if(offset>0){entered.countDown();check(release.await(3,TimeUnit.SECONDS))}
            LibraryPage(listOf(track(offset.toLong()+1)),4,20,offset)
        },{_,_,_->})
        repository.refine(LibraryQuery());val request=repository.claimNextPage(repository.state.value){true}!!
        val pool=Executors.newSingleThreadExecutor()
        try {
            val work=pool.submit {repository.executeNextPage(request)}
            assertTrue(entered.await(2,TimeUnit.SECONDS));repository.executeNextPage(request)
            assertTrue(repository.state.value.loading)
            release.countDown();work.get(3,TimeUnit.SECONDS)
            assertEquals(2,reads);assertEquals(listOf(TrackId(1),TrackId(2)),repository.state.value.rows.map {it.id})
        }finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(3,TimeUnit.SECONDS))}
    }

    @Test fun refreshAfterExhaustionRenewsPaginationWithoutChangingLikeAuthority() {
        var empty=true;val offsets=mutableListOf<Int>();var liked=false
        val repository=LibraryRepository(session(),{_,_,offset->
            offsets+=offset
            LibraryPage(if(offset>0&&empty)emptyList() else listOf(track(offset.toLong()+1).copy(liked=liked)),4,20,offset)
        },{_,_,value->liked=value})
        repository.refine(LibraryQuery());repository.loadMore();assertTrue(repository.state.value.endReached)
        empty=false;repository.refine(repository.state.value.query)
        assertFalse(repository.state.value.endReached);repository.loadMore()
        assertEquals(listOf(0,1,0,1),offsets)
        repository.like(repository.state.value.rows.first())
        assertEquals(true,repository.state.value.rows.first().liked)
        assertEquals(1,repository.state.value.nextOffset);assertFalse(repository.state.value.endReached)
        repository.loadMore();assertEquals(listOf(TrackId(1),TrackId(2)),repository.state.value.rows.map {it.id})
    }

    @Test fun cancelledImportRevealKeepsExplicitPaginationRecoveryBeforeFirstOrNextFetch() {
        for(cancelOffset in listOf(0,1)) {
            var visible=true;val offsets=mutableListOf<Int>()
            val repository=LibraryRepository(session(),{_,_,offset->offsets+=offset;LibraryPage(listOf(track(offset.toLong()+1)),3,20,offset)},{_,_,_->})
            repository.beforeImportPage={offset->if(offset==cancelOffset)visible=false}
            assertFalse(repository.revealImported(TrackId(3)){visible})
            assertFalse(repository.state.value.loading)
            repository.beforeImportPage=null;repository.loadMore()
            assertFalse(repository.state.value.loading)
            assertEquals(if(cancelOffset==0)listOf(0)else listOf(0,1),offsets)
            assertEquals(TrackId(if(cancelOffset==0)1 else 2),repository.state.value.rows.last().id)
        }
    }
}
