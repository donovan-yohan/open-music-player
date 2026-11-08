package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class LibraryRepositoryTest {
    @Test fun queryChangeFencesHeldPageAndLikeReadsBackWithoutOptimism() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore())
        session.accept(session.beginIntent(),SecretTokens("a","r","fixture"))
        val held=CountDownLatch(1);val release=CountDownLatch(1)
        var liked=false; var writes=0
        val row=Track(TrackId(1),"Fixture",liked=false)
        val repository=LibraryRepository(session,{_,q,offset ->
            if(q.text=="held") {held.countDown(); assertTrue(release.await(3,TimeUnit.SECONDS))}
            LibraryPage(listOf(row.copy(title=q.text,liked=liked)),1,20,offset)
        },{_,_,value -> writes++; assertEquals(false,repositorySnapshotLike); liked=value })
        val pool=Executors.newSingleThreadExecutor()
        try {
            val old=pool.submit {repository.refine(LibraryQuery(text="held"))}
            assertTrue(held.await(3,TimeUnit.SECONDS))
            repository.refine(LibraryQuery(text="new"));release.countDown();old.get(3,TimeUnit.SECONDS)
            assertEquals("new",repository.state.value.rows.single().title)
            repositorySnapshotLike=repository.state.value.rows.single().liked
            repository.like(repository.state.value.rows.single())
            assertEquals(1,writes);assertEquals(true,repository.state.value.rows.single().liked)
            assertEquals(MutationOutcome.Confirmed,repository.state.value.mutations[TrackId(1)])
            session.retire();repository.loadMore();assertTrue(repository.state.value.rows.isEmpty())
        } finally {release.countDown();pool.shutdownNow()}
    }
    @Test fun retainedLikeCallbackCannotMutateReplacementAccountWithSameTrackId() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore())
        session.accept(session.beginIntent(),SecretTokens("a","r","A"))
        var writes=0
        val repository=LibraryRepository(session,{_,_,offset ->LibraryPage(listOf(Track(TrackId(1),"Same ID",liked=false)),1,20,offset)},{_,_,_ ->writes++})
        repository.refine(LibraryQuery());val retained=repository.state.value.rows.single()
        session.accept(session.beginIntent(),SecretTokens("b","br","B"));repository.refine(LibraryQuery())
        repository.like(retained)
        assertEquals(0,writes)
    }
    private var repositorySnapshotLike:Boolean?=false
}
