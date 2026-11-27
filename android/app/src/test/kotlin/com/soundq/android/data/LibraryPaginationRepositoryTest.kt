package com.soundq.android.data

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.job
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

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

    @Test fun retiredAppendSettlesAfterHeldCollectionHandoffAndLetsDeferredImportAndReturnContinue() {
        val account=session();val scope=checkNotNull(account.capture())
        val corpus=(1L..501L).map {track(it).copy(liked=true)}
        val imported=track(502).copy(liked=true)
        val query=LibraryQuery(text="liked",liked=true,sort=LibrarySort.Title,ascending=true)
        val visible=AtomicBoolean(true);val append=CountDownLatch(1);val releaseAppend=CountDownLatch(1)
        val refresh=CountDownLatch(1);val releaseRefresh=CountDownLatch(1)
        val firstPages=AtomicInteger();val secondPages=AtomicInteger();var starts=0
        val repository=LibraryRepository(account,{readScope,readQuery,offset->
            assertEquals(scope.epoch,readScope.epoch);assertEquals(query,readQuery)
            if(offset==0&&firstPages.incrementAndGet()==3) {
                refresh.countDown();check(releaseRefresh.await(5,TimeUnit.SECONDS))
                LibraryPage(listOf(imported)+corpus.take(499),502,500,offset)
            }else{
                if(offset==500&&secondPages.incrementAndGet()==2) {
                    append.countDown();check(releaseAppend.await(5,TimeUnit.SECONDS))
                }
                val current=if(firstPages.get()>=3)listOf(imported)+corpus else corpus
                LibraryPage(current.drop(offset).take(500),current.size,500,offset)
            }
        },{_,_,_->throw AssertionError("no mutation")})
        val pool=Executors.newSingleThreadExecutor()
        val jobs=CoroutineScope(SupervisorJob()+Dispatchers.Default)
        try {
            repository.refine(query);val accepted=repository.state.value
            val play=checkNotNull(repository.claimCollectionPlay(accepted,selected=corpus[499].id){visible.get()})
            repository.readCollection(play)
            repository.startCollection(play,holdForDelivery=true) {rows,index->
                assertEquals(corpus,rows);assertEquals(499,index);assertTrue(repository.collectionPlaybackCurrent(play));starts++;null
            }
            assertEquals(1,starts);assertTrue(repository.state.value.collectionLoading)
            repository.scheduleImportRefresh(scope,jobs)
            val importJob=jobs.coroutineContext.job.children.single()
            val page=checkNotNull(repository.claimNextPage(repository.state.value){visible.get()})
            val work=pool.submit {repository.executeNextPage(page)}
            assertTrue(append.await(3,TimeUnit.SECONDS));assertTrue(repository.state.value.loading)
            assertFalse("handoff must not consume collection Play while a page can replace its acknowledged rows",
                repository.collectionPlaybackCurrent(play))
            visible.set(false);repository.abandonCollection(play)
            assertFalse(repository.state.value.collectionLoading);assertTrue(repository.state.value.loading)
            assertEquals(1L,refresh.count)
            releaseAppend.countDown();work.get(3,TimeUnit.SECONDS)
            assertFalse("retired append must clear its own loading after collection retirement copied the state",repository.state.value.loading)
            assertFalse(repository.state.value.collectionLoading);assertNull(repository.state.value.error)
            assertSame(accepted.rows,repository.state.value.rows)
            assertEquals(accepted.pageRevision,repository.state.value.pageRevision)
            assertTrue("deferred import must be admitted after append retirement",refresh.await(3,TimeUnit.SECONDS))
            releaseRefresh.countDown();runBlocking {withTimeout(5000){importJob.join()}}
            assertEquals(imported.id,repository.state.value.rows.first().id)
            assertFalse(repository.state.value.collectionLoading);assertEquals(query,repository.state.value.query)
            val returned=checkNotNull(repository.claimNextPage(repository.state.value){true})
            repository.executeNextPage(returned)
            assertFalse(repository.state.value.loading);assertTrue(repository.state.value.endReached)
            assertEquals(listOf(imported)+corpus,repository.state.value.rows)
            assertEquals(3,firstPages.get());assertEquals(3,secondPages.get());assertEquals(1,starts)
        }finally {
            releaseAppend.countDown();releaseRefresh.countDown();jobs.cancel();pool.shutdownNow()
            assertTrue(pool.awaitTermination(3,TimeUnit.SECONDS))
        }
    }

    @Test fun deferredImportRefreshSurvivesSameScopeCredentialSave() = deferredRefreshDuringSave("success")

    @Test fun deferredImportRefreshDoesNotSurviveFailedSaveOrRetiredScopeOrQuery() {
        for (end in listOf("failure", "scope", "query")) deferredRefreshDuringSave(end)
    }

    private fun deferredRefreshDuringSave(end: String) {
        val saving = CountDownLatch(1)
        val release = CountDownLatch(1)
        val store = object : SessionStore by MemoryStore() {
            override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) {
                if (tokens.access != "rotated") return
                saving.countDown()
                check(release.await(5,TimeUnit.SECONDS))
                if (end == "failure") throw java.io.IOException("secure save unavailable")
            }
        }
        val auth = AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),store)
        assertTrue(auth.accept(auth.beginIntent(), SecretTokens("initial","refresh","A")))
        val scope = checkNotNull(auth.capture())
        val reads = mutableListOf<LibraryQuery>()
        val query = LibraryQuery(text="matches",liked=true)
        val first = track(1).copy(liked=true)
        val imported = track(77).copy(liked=true)
        val repository = LibraryRepository(auth,{ actual, q, offset ->
            assertEquals(scope.epoch,actual.epoch)
            assertEquals(0,offset)
            reads += q
            LibraryPage(listOf(if (reads.size <= 2) first else imported),1,20,offset)
        },{_,_,_->throw AssertionError("no mutation")})
        val queue = java.util.concurrent.ConcurrentLinkedQueue<Runnable>()
        val jobs = CoroutineScope(SupervisorJob()+object : kotlinx.coroutines.CoroutineDispatcher() {
            override fun dispatch(context: kotlin.coroutines.CoroutineContext, block: Runnable) { queue.add(block) }
        })
        fun drain() { while (true) (queue.poll() ?: return).run() }
        val pool = Executors.newSingleThreadExecutor()
        try {
            repository.refine(query)
            val play = checkNotNull(repository.claimCollectionPlay(repository.state.value) { true })
            repository.readCollection(play)
            repository.startCollection(play,holdForDelivery=true) { rows, _ -> assertEquals(listOf(first),rows); null }
            assertTrue(repository.state.value.collectionLoading)
            repository.scheduleImportRefresh(scope,jobs)
            val refresh = jobs.coroutineContext.job.children.single()
            drain()
            assertFalse(refresh.isCompleted)
            val rotate = pool.submit<Boolean> { auth.refresh(scope) { SecretTokens("rotated","rotated-refresh","A") } }
            assertTrue(saving.await(3,TimeUnit.SECONDS))
            assertFalse(auth.remoteCurrent(scope))
            repository.abandonCollection(play)
            drain() // Deliver collection release while the original bearer is withdrawn.
            assertEquals(listOf(query,query),reads)
            if (end == "scope") auth.beginIntent()
            if (end == "query") repository.retire()
            drain()
            release.countDown()
            assertEquals(end == "success" || end == "query",rotate.get(3,TimeUnit.SECONDS))
            drain()
            assertTrue(refresh.isCompleted)
            if (end == "success") {
                assertEquals(scope.epoch,auth.capture()?.epoch)
                assertEquals("rotated",auth.access(scope))
                assertEquals("collection release must not consume the pending import observation during secure save",
                    listOf(query,query,query),reads)
                assertEquals(listOf(TrackId(77)),repository.state.value.rows.map(Track::id))
                assertEquals(query,repository.state.value.query)
            } else assertEquals(end,listOf(query,query),reads)
        } finally {
            release.countDown();jobs.cancel();drain();pool.shutdownNow()
            assertTrue(pool.awaitTermination(3,TimeUnit.SECONDS))
        }
    }

    @Test fun abandonedAppendRetryRestoresPriorFailureButCannotEraseTerminalSuccess() {
        var fail=true
        val repository=LibraryRepository(session(),{_,_,offset->
            if(offset!=0&&fail)throw SafeFailure(SafeFailure.Reason.Network)
            LibraryPage(listOf(track(offset+1L)),2,20,offset)
        },{_,_,_->})
        repository.refine(LibraryQuery());repository.loadMore();val failed=repository.state.value
        assertTrue(failed.failedAppend);assertEquals(SafeFailure.Reason.Network,failed.error)
        val abandoned=checkNotNull(repository.claimPageRetry(failed){true})
        assertFalse(repository.state.value.failedAppend);assertNull(repository.state.value.error)
        repository.abandonNextPage(abandoned)
        assertEquals(failed,repository.state.value)
        fail=false
        val completed=checkNotNull(repository.claimPageRetry(repository.state.value){true})
        repository.executeNextPage(completed);repository.abandonNextPage(completed)
        assertFalse(repository.state.value.failedAppend);assertNull(repository.state.value.error)
        assertEquals(listOf(TrackId(1),TrackId(2)),repository.state.value.rows.map {it.id})
    }

    @Test fun heldAppendCleanupCannotSettleNewRefinementOrLaterPage() {
        val entered=CountDownLatch(1);val release=CountDownLatch(1)
        val original=LibraryQuery(liked=true);val replacement=original.copy(text="replacement")
        val repository=LibraryRepository(session(),{_,query,offset->
            if(query==original&&offset>0){entered.countDown();check(release.await(3,TimeUnit.SECONDS))}
            val base=if(query==original)1L else 10L
            LibraryPage(listOf(track(base+offset)),2,20,offset)
        },{_,_,_->})
        repository.refine(original)
        val old=checkNotNull(repository.claimNextPage(repository.state.value){true})
        val pool=Executors.newSingleThreadExecutor()
        try {
            val work=pool.submit {repository.executeNextPage(old)}
            assertTrue(entered.await(3,TimeUnit.SECONDS))
            val refinement=checkNotNull(repository.claimRefinement(replacement));val loading=repository.state.value
            release.countDown();work.get(3,TimeUnit.SECONDS)
            assertTrue(loading.loading);assertSame(loading,repository.state.value)
            repository.executeRefinement(refinement)
            val later=checkNotNull(repository.claimNextPage(repository.state.value){true});val laterLoading=repository.state.value
            repository.abandonNextPage(old)
            assertSame(laterLoading,repository.state.value)
            repository.executeNextPage(later)
            assertEquals(replacement,repository.state.value.query)
            assertEquals(listOf(TrackId(10),TrackId(11)),repository.state.value.rows.map {it.id})
        }finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(3,TimeUnit.SECONDS))}
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
