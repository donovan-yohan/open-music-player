package com.soundq.android.data

import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger

class NotificationLikeOwnershipTest {
    @Test fun disjointSiblingReadbackPreservesOriginalAcknowledgementAndNextDelete() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val repository=LibraryRepository(session,api::library,api::like)
            val held=CountDownLatch(1);val release=CountDownLatch(1);val aReads=AtomicInteger();val methods=CopyOnWriteArrayList<String>();val liked=ConcurrentHashMap<Long,Boolean>()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(r:RecordedRequest):MockResponse {
                if(r.method!="GET") {
                    val id=r.url.encodedPath.substringBefore("/like").substringAfterLast('/').toLong()
                    methods.add("${r.method}:$id");liked[id]=r.method=="POST"
                    return MockResponse.Builder().code(204).build()
                }
                val id=if(r.url.queryParameter("q")=="B")8L else 7L
                val snapshot=liked[id]==true
                if(id==7L&&aReads.incrementAndGet()==2){held.countDown();check(release.await(5,TimeUnit.SECONDS))}
                return MockResponse.Builder().body("""{"tracks":[{"id":$id,"title":"track$id","is_liked":$snapshot}],"total":1,"limit":20,"offset":0}""").build()
            }}
            val pool=Executors.newSingleThreadExecutor()
            try {
                repository.refine(LibraryQuery(text="A"));val a=repository.state.value.rows.single()
                val first=pool.submit{repository.like(a)};assertTrue("A POST ACK must reach held true GET",held.await(3,TimeUnit.SECONDS))
                repository.refine(LibraryQuery(text="B"));assertEquals(TrackId(8),repository.state.value.rows.single().id)
                repository.like(repository.state.value.rows.single());val b=repository.state.value
                assertEquals(listOf("POST:7","POST:8"),methods.toList())
                release.countDown();first.get(4,TimeUnit.SECONDS)
                assertSame("A cannot replace newer B list",b,repository.state.value)
                assertEquals("Disjoint B cannot discard A true acknowledgement",true,repository.likeView(session.capture()!!,TrackId(7))!!.track.liked)
                assertEquals(MutationOutcome.Confirmed,repository.likeView(session.capture()!!,TrackId(7))!!.outcome)
                val next=repository.claimLike(repository.offerLike(session.capture()!!,TrackId(7))!!)!!
                assertEquals(MutationOutcome.Confirmed,repository.executeLike(next))
                assertEquals(listOf("POST:7","POST:8","DELETE:7"),methods.toList())
            } finally {release.countDown();pool.shutdownNow();check(pool.awaitTermination(5,TimeUnit.SECONDS))}
        }
    }
    @Test fun newerSameTargetObservationSurvivesOldSuccessOrReadFailure() {
        for(fail in listOf(false,true)) {
            val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val held=CountDownLatch(1);val release=CountDownLatch(1);val reads=AtomicInteger();val pool=Executors.newSingleThreadExecutor()
            val repository=LibraryRepository(session,{_,q,o ->
                if(reads.incrementAndGet()==2){held.countDown();check(release.await(4,TimeUnit.SECONDS));if(fail)throw SafeFailure(SafeFailure.Reason.Network);LibraryPage(listOf(Track(TrackId(7),"old",liked=true)),1,20,o)}
                else LibraryPage(listOf(Track(TrackId(7),q.text,liked=false)),1,20,o)
            },{_,_,_->})
            try {
                repository.refine(LibraryQuery(text="original"));val first=pool.submit{repository.like(repository.state.value.rows.single())}
                assertTrue(held.await(2,TimeUnit.SECONDS));repository.refine(LibraryQuery(text="newer"));val newer=repository.state.value
                release.countDown();first.get(3,TimeUnit.SECONDS)
                assertSame("Old target settlement cannot replace a newer query",newer,repository.state.value)
                val view=repository.likeView(session.capture()!!,TrackId(7))!!
                assertEquals("New target observation must survive old readback/failure",false,view.track.liked)
                assertEquals("newer",view.track.title)
            } finally {release.countDown();pool.shutdownNow();check(pool.awaitTermination(4,TimeUnit.SECONDS))}
        }
    }
    @Test fun oldAbandonCompletionCannotReleaseNewerReceiptOrEnteredWrite() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
        val held=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor();val writes=AtomicInteger()
        val repository=LibraryRepository(session,{_,_,o->LibraryPage(listOf(Track(TrackId(7),"owned",liked=false)),1,20,o)},{_,_,_->writes.incrementAndGet();held.countDown();check(release.await(4,TimeUnit.SECONDS))})
        repository.refine(LibraryQuery());val scope=session.capture()!!
        val old=repository.claimLike(repository.offerLike(scope,TrackId(7))!!)!!;repository.abandonLike(old)
        val newer=repository.claimLike(repository.offerLike(scope,TrackId(7))!!)!!
        repository.abandonLike(old);assertNull(repository.offerLike(scope,TrackId(7)))
        try {
            val first=pool.submit{repository.executeLike(newer)};assertTrue(held.await(2,TimeUnit.SECONDS))
            repository.abandonLike(newer);assertNull(repository.offerLike(scope,TrackId(7)));assertEquals(1,writes.get())
            release.countDown();first.get(3,TimeUnit.SECONDS);assertNotNull(repository.offerLike(scope,TrackId(7)))
        } finally {release.countDown();pool.shutdownNow();check(pool.awaitTermination(4,TimeUnit.SECONDS))}
    }
    @Test fun acceptedLikeUpdatesRefinedRowsWithoutReplacingTheirQueryOrMetadata() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
        val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor();var liked=false
        val repository=LibraryRepository(session,{_,q,o->LibraryPage(listOf(Track(TrackId(7),q.text,liked=liked)),1,20,o)},{_,_,value->entered.countDown();check(release.await(4,TimeUnit.SECONDS));liked=value})
        try {
            repository.refine(LibraryQuery());val row=repository.state.value.rows.single();val pending=pool.submit{repository.like(row)};assertTrue(entered.await(2,TimeUnit.SECONDS))
            repository.refine(LibraryQuery(text="new",sort=LibrarySort.Title,ascending=true));release.countDown();pending.get(3,TimeUnit.SECONDS)
            assertEquals("new",repository.state.value.query.text);assertEquals("new",repository.state.value.rows.single().title)
            assertEquals(true,repository.state.value.rows.single().liked)
            assertEquals(true,repository.likeView(session.capture()!!,TrackId(7))!!.track.liked)
        } finally {release.countDown();pool.shutdownNow()}
    }
    @Test fun readbackFailureBlocksBothCallersUntilExplicitGetOnlyReconciliation() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
        var fail=false;var liked=false;var writes=0
        val repository=LibraryRepository(session,{_,_,o->if(fail)throw SafeFailure(SafeFailure.Reason.Network);LibraryPage(listOf(Track(TrackId(7),"owned",liked=liked)),1,20,o)},{_,_,v->writes++;liked=v;fail=true})
        repository.refine(LibraryQuery());repository.like(repository.state.value.rows.single())
        assertEquals(MutationOutcome.ReadbackFailed,repository.likeView(session.capture()!!,TrackId(7))!!.outcome)
        repository.like(repository.state.value.rows.single());assertNull(repository.offerLike(session.capture()!!,TrackId(7)));assertEquals(1,writes)
        fail=false;repository.reconcileLike(session.capture()!!,TrackId(7));assertEquals(1,writes);assertEquals(true,repository.state.value.rows.single().liked);assertNotNull(repository.offerLike(session.capture()!!,TrackId(7)))
    }
    @Test fun claimedActionRetiredBeforeIoDispatchMakesZeroWrites() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"));var writes=0
        val repository=LibraryRepository(session,{_,_,o->LibraryPage(listOf(Track(TrackId(7),"owned",liked=false)),1,20,o)},{_,_,_->writes++})
        repository.refine(LibraryQuery());val receipt=repository.claimLike(repository.offerLike(session.capture()!!,TrackId(7))!!)!!
        session.lockLocal();assertEquals(MutationOutcome.Refused,repository.executeLike(receipt));assertEquals(0,writes)
    }
    @Test fun removedTargetNeverRegainsToggleAuthorityFromOldAcknowledgement() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
        var removed=false
        val repository=LibraryRepository(session,{_,_,o->LibraryPage(if(removed)emptyList() else listOf(Track(TrackId(7),"owned",liked=false)),if(removed)0 else 1,20,o)},{_,_,_->removed=true})
        repository.refine(LibraryQuery());repository.like(repository.state.value.rows.single())
        assertNull("Absent target is unknown, not an old false",repository.offerLike(session.capture()!!,TrackId(7)))
    }
    @Test fun offPageReadUsesOwnedPagesWithoutResettingVisibleFilter() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
        val requests=mutableListOf<Pair<LibraryQuery,Int>>()
        val repository=LibraryRepository(session,{_,q,o->requests.add(q to o);if(q.text.isNotEmpty())LibraryPage(emptyList(),0,20,o) else LibraryPage(listOf(Track(TrackId(if(o==0)8 else 7),"owned",liked=true)),2,1,o)},{_,_,_->error("GET only")})
        repository.refine(LibraryQuery(text="retained",liked=true));val before=repository.state.value
        repository.reconcileLike(session.capture()!!,TrackId(7))
        assertEquals(before.query,repository.state.value.query);assertTrue(repository.state.value.rows.isEmpty());assertEquals(listOf(0,0,1),requests.map {it.second})
        assertEquals(true,repository.likeView(session.capture()!!,TrackId(7))!!.track.liked)
    }
    @Test fun explicitReadAfterMutationCannotBeOverwrittenByAnOlderCollectionReply() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
        var liked=false;val held=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor();val heldReads=AtomicInteger()
        val repository=LibraryRepository(session,{_,q,o->val value=liked;if(q.text=="held"&&heldReads.incrementAndGet()==1){held.countDown();check(release.await(3,TimeUnit.SECONDS))};LibraryPage(listOf(Track(TrackId(7),"owned",liked=value)),1,20,o)},{_,_,v->liked=v})
        try {repository.refine(LibraryQuery());val offer=repository.offerLike(session.capture()!!,TrackId(7))!!
            val read=pool.submit {repository.refine(LibraryQuery(text="held"))};assertTrue(held.await(2,TimeUnit.SECONDS))
            // The captured acknowledged identity, not the old visible row, is the current-song action.
            val receipt=repository.claimLike(offer)!!;repository.executeLike(receipt)
            release.countDown();read.get(3,TimeUnit.SECONDS);assertEquals(true,repository.likeView(session.capture()!!,TrackId(7))!!.track.liked)
        } finally {release.countDown();pool.shutdownNow()}
    }
    @Test fun refinementCannotReleaseEnteredLikeLockOrReplayItsWrite() {
        HttpsFixture().use { f ->
            val session=AccountSession(f.endpoint,MemoryStore())
            session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client)
            val library=LibraryRepository(session,api::library,api::like)
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val writes=AtomicInteger()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.method=="POST") {writes.incrementAndGet();entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().code(204).build()}
                return MockResponse.Builder().body("""{"tracks":[{"id":7,"title":"Owned","is_liked":false}],"total":1,"limit":20,"offset":0}""").build()
            }}
            val pool=Executors.newFixedThreadPool(2)
            try {
                library.refine(LibraryQuery());val row=library.state.value.rows.single()
                val first=pool.submit {library.like(row)};assertTrue(entered.await(3,TimeUnit.SECONDS))
                library.refine(LibraryQuery(text="Owned"))
                val second=pool.submit {library.like(library.state.value.rows.single())}
                second.get(2,TimeUnit.SECONDS)
                assertEquals("Refinement must not release entered account/track lock",1,writes.get())
                release.countDown();first.get(3,TimeUnit.SECONDS)
            } finally {release.countDown();pool.shutdownNow();pool.awaitTermination(5,TimeUnit.SECONDS)}
        }
    }
}
