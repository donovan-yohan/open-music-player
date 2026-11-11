package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger

class LikeSettlementTest {
    @Test fun bothCompletionOrdersSettleDistinctRowsWithSameRowDedupe() {
        for(firstDone in listOf(0,1)) scenario(firstDone,null)
    }
    @Test fun refusedAndUncertainSiblingsNeverStrandPendingOrReplay() {
        for(reason in listOf(SafeFailure.Reason.Refused,SafeFailure.Reason.Uncertain))
            for(firstDone in listOf(0,1)) scenario(firstDone,reason)
    }
    private fun scenario(firstDone:Int,reason:SafeFailure.Reason?) {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore())
        session.accept(session.beginIntent(),SecretTokens("a","r","A"))
        val rows=listOf(Track(TrackId(1),"one",liked=false),Track(TrackId(2),"two",liked=false))
        val entered=List(2){CountDownLatch(1)};val release=List(2){CountDownLatch(1)}
        val writes=AtomicInteger();val reads=AtomicInteger()
        val repository=LibraryRepository(session,{_,_,offset->reads.incrementAndGet();LibraryPage(rows,2,20,offset)},{_,id,_->
            writes.incrementAndGet();val i=id.value.toInt()-1;entered[i].countDown();check(release[i].await(3,TimeUnit.SECONDS))
            if(i==1&&reason!=null)throw SafeFailure(reason)
        })
        repository.refine(LibraryQuery());val pool=Executors.newFixedThreadPool(2)
        try {
            val futures=rows.map {row->pool.submit {repository.like(row)}}
            entered.forEach {assertTrue(it.await(2,TimeUnit.SECONDS))}
            repository.like(rows[0]);assertEquals(2,writes.get())
            release[firstDone].countDown();futures[firstDone].get(3,TimeUnit.SECONDS)
            release[1-firstDone].countDown();futures[1-firstDone].get(3,TimeUnit.SECONDS)
            assertEquals("first row must settle independently",MutationOutcome.Confirmed,repository.state.value.mutations[rows[0].id])
            assertEquals(when(reason){SafeFailure.Reason.Refused->MutationOutcome.Refused;SafeFailure.Reason.Uncertain->MutationOutcome.Uncertain;else->MutationOutcome.Confirmed},repository.state.value.mutations[rows[1].id])
            assertFalse(repository.state.value.mutations.containsValue(MutationOutcome.Pending))
            assertEquals(2,writes.get());assertEquals(if(reason==SafeFailure.Reason.Refused)3-1 else 3,reads.get())
        }finally {release.forEach {it.countDown()};pool.shutdownNow();pool.awaitTermination(3,TimeUnit.SECONDS)}
    }
    @Test fun failedReadbackSettlesItsRowWhileSiblingRemainsConfirmed() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore())
        session.accept(session.beginIntent(),SecretTokens("a","r","A"))
        val rows=listOf(Track(TrackId(1),"one",liked=false),Track(TrackId(2),"two",liked=false))
        val held=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
        val calls=AtomicInteger()
        val repository=LibraryRepository(session,{_,_,offset->
            if(calls.incrementAndGet()==3)throw SafeFailure(SafeFailure.Reason.Network)
            LibraryPage(rows,2,20,offset)
        },{_,id,_->if(id.value==1L){held.countDown();check(release.await(3,TimeUnit.SECONDS))}})
        try {
            repository.refine(LibraryQuery());val first=pool.submit {repository.like(rows[0])}
            assertTrue(held.await(2,TimeUnit.SECONDS));repository.like(rows[1])
            release.countDown();first.get(3,TimeUnit.SECONDS)
            assertEquals(MutationOutcome.ReadbackFailed,repository.state.value.mutations[rows[0].id])
            assertEquals(MutationOutcome.Confirmed,repository.state.value.mutations[rows[1].id])
            assertFalse(repository.state.value.mutations.containsValue(MutationOutcome.Pending))
        } finally {release.countDown();pool.shutdownNow();pool.awaitTermination(3,TimeUnit.SECONDS)}
    }
    @Test fun queryAndAccountRetirementRejectOldSettlementAndReadback() {
        for(replace in listOf(false,true)) {
            val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore())
            session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            val repository=LibraryRepository(session,{scope,q,o->LibraryPage(listOf(Track(TrackId(1),scope.accountId+q.text,liked=false)),1,20,o)},{_,_,_->entered.countDown();check(release.await(3,TimeUnit.SECONDS))})
            try {
                repository.refine(LibraryQuery());val row=repository.state.value.rows.single()
                val old=pool.submit {repository.like(row)};assertTrue(entered.await(2,TimeUnit.SECONDS))
                if(replace)session.accept(session.beginIntent(),SecretTokens("b","br","B"))
                repository.refine(LibraryQuery(text="new"));val accepted=repository.state.value
                release.countDown();old.get(3,TimeUnit.SECONDS)
                assertSame(accepted,repository.state.value);assertTrue(repository.state.value.mutations.isEmpty())
            }finally {release.countDown();pool.shutdownNow();pool.awaitTermination(3,TimeUnit.SECONDS)}
        }
    }
}
