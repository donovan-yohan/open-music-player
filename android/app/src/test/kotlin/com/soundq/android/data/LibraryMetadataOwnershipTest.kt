package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class LibraryMetadataOwnershipTest {
    private fun session()=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("a","r","A"))}
    private val a=Track(TrackId(7),"A",liked=false)
    private val b=Track(TrackId(8),"B",liked=false)
    private val facts=LibraryAnalysisFacts("analyzed",128.0,"A minor","8A")
    private fun page(rows:List<Track>,analysis:Map<TrackId,LibraryAnalysisFacts>,offset:Int=0,total:Int=rows.size)=LibraryPage(rows,total,20,offset,analysis=analysis)
    @Test fun acknowledgedPageAndPagingCarryOnlyVisibleCompactFacts() {
        val s=session()
        val repo=LibraryRepository(s,{_,_,offset->if(offset==0)page(listOf(a),mapOf(a.id to facts,TrackId(99) to facts),total=2)else page(listOf(b),mapOf(b.id to facts.copy(bpm=130.0)),offset,2)},{_,_,_->})
        repo.refine(LibraryQuery());assertEquals(mapOf(a.id to facts),repo.state.value.analysis)
        repo.loadMore();assertEquals(setOf(a.id,b.id),repo.state.value.analysis.keys)
        assertEquals(130.0,repo.state.value.analysis[b.id]?.bpm)
    }
    @Test fun refreshMissingFactsRemovesOldMetadataWithoutChangingTrackIdentity() {
        val s=session();var metadata=mapOf(a.id to facts)
        val repo=LibraryRepository(s,{_,_,_->page(listOf(a),metadata)},{_,_,_->})
        repo.refine(LibraryQuery());assertEquals(facts,repo.state.value.analysis[a.id])
        metadata=emptyMap();repo.refreshObserved(s.capture()!!,repo.state.value)
        assertTrue(repo.state.value.analysis.isEmpty());assertSame(a,repo.state.value.rows.single())
    }
    @Test fun likeReadbackReplacesMetadataAndDoesNotResurrectOldQueryFacts() {
        val s=session();var liked=false
        val repo=LibraryRepository(s,{_,_,_->page(listOf(a.copy(liked=liked)),mapOf(a.id to facts.copy(bpm=if(liked)129.0 else 128.0)))},{_,_,value->liked=value})
        repo.refine(LibraryQuery());repo.like(repo.state.value.rows.single())
        assertEquals(129.0,repo.state.value.analysis[a.id]?.bpm)
        assertEquals(true,repo.state.value.rows.single().liked)
    }
    @Test fun heldOldPageCannotPublishFactsAfterRefinementOrSameAccountReplacement() {
        val s=session();val entered=CountDownLatch(1);val release=CountDownLatch(1)
        val repo=LibraryRepository(s,{_,query,_->if(query.text=="held"){entered.countDown();check(release.await(3,TimeUnit.SECONDS));page(listOf(a),mapOf(a.id to facts))}else page(listOf(b),mapOf(b.id to facts.copy(bpm=140.0)))},{_,_,_->})
        val pool=Executors.newSingleThreadExecutor()
        try {
            val old=pool.submit {repo.refine(LibraryQuery(text="held"))};assertTrue(entered.await(2,TimeUnit.SECONDS))
            s.accept(s.beginIntent(),SecretTokens("new","new-r","A"));repo.refine(LibraryQuery(text="new"));release.countDown();old.get(3,TimeUnit.SECONDS)
            assertEquals(setOf(b.id),repo.state.value.analysis.keys);assertEquals(140.0,repo.state.value.analysis[b.id]?.bpm)
            s.retire();repo.retire();assertTrue(repo.state.value.analysis.isEmpty())
        }finally {release.countDown();pool.shutdownNow()}
    }
}
