package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicBoolean

class LargeLibraryPlaybackTest {
    private class Store:SessionStore {
        override fun load(endpoint:ApiEndpoint):SecretTokens?=null
        override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){}
        override fun clear(){}
    }
    private fun session()=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store()).also {
        check(it.accept(it.beginIntent(),SecretTokens("fixture","fixture","A")))
    }
    private fun rows(count:Int)=List(count){Track(TrackId(it+1L),"Same title","Fixture",durationMs=3000)}
    @Test fun completeCapturedQueryKeepsExactLaterRowAndDoesNotChangeBrowseAcknowledgement() {
        for(count in listOf(500,501,12037)) {
            val all=rows(count);val offsets=mutableListOf<Int>();val queries=mutableListOf<LibraryQuery>()
            val repo=LibraryRepository(session(),{_,q,offset->offsets+=offset;queries+=q;LibraryPage(all.drop(offset).take(100),count,100,offset)},{_,_,_->})
            val query=LibraryQuery(text="captured",sort=LibrarySort.Added,ascending=true,liked=true)
            repo.refine(query);repeat(5){repo.loadMore()}
            val state=repo.state.value;val selected=state.rows.lastIndex
            val capture=repo.capturePlayback(state.rows,selected)!!
            val complete=repo.playback(capture)!!
            assertEquals(all,complete.first);assertEquals(selected,complete.second)
            assertEquals(state.rows[selected],complete.first[complete.second]);assertSame(state,repo.state.value)
            assertTrue(queries.all {it==query});assertEquals((0 until count step 100).toList(),offsets.takeLast((count+99)/100))
        }
    }
    @Test fun repeatedRawLibraryMembershipIsRefusedInsteadOfCertifyingAnIncompleteContext() {
        // Library membership has unique IDs. Repeated recording occurrences are
        // legal in the canonical queue, not evidence of a complete offset scan.
        val all=rows(501).toMutableList().apply {this[500]=this[0].copy()}
        val repo=LibraryRepository(session(),{_,_,offset->LibraryPage(all.drop(offset).take(100),all.size,100,offset)},{_,_,_->})
        repo.refine(LibraryQuery());val state=repo.state.value
        val capture=repo.capturePlayback(state.rows,4)!!
        assertTrue(runCatching {repo.playback(capture)}.isFailure)
        assertSame(state,repo.state.value)
    }
    @Test fun heldPagingIsRetiredByCancelQueryAbaSameAccountReplacementAndLogout() {
        for(action in listOf("cancel","query","same-account","logout")) {
            val session=session();val entered=CountDownLatch(1);val release=CountDownLatch(1);val live=AtomicBoolean(true)
            val all=rows(12037);var holding=false
            val repo=LibraryRepository(session,{_,_,offset->
                if(holding&&offset==100){entered.countDown();check(release.await(5,TimeUnit.SECONDS))}
                LibraryPage(all.drop(offset).take(100),all.size,100,offset)
            },{_,_,_->})
            repo.refine(LibraryQuery());val capture=repo.capturePlayback(repo.state.value.rows,4)!!;holding=true
            val executor=Executors.newSingleThreadExecutor()
            try {
                val task=executor.submit<Pair<List<Track>,Int>?> {repo.playback(capture){live.get()}}
                assertTrue(entered.await(5,TimeUnit.SECONDS))
                when(action) {
                    "cancel"->live.set(false)
                    "query"->{repo.refine(LibraryQuery(text="B"));repo.refine(LibraryQuery())}
                    "same-account"->session.accept(session.beginIntent(),SecretTokens("new","new","A"))
                    else->session.retire()
                }
                release.countDown();assertNull(task.get(5,TimeUnit.SECONDS))
                if(action=="query")assertFalse(repo.ownsPlayback(capture))
            }finally {release.countDown();executor.shutdownNow()}
        }
    }
    @Test fun changedTotalShortPageOmittedMemberAndBudgetExcessAreRefusedNotTruncated() {
        for(kind in listOf("total","empty","omitted","budget","reordered")) {
            val all=rows(501);var playback=false
            val repo=LibraryRepository(session(),{_,_,offset->
                val page=all.drop(offset).take(100)
                when {
                    playback&&offset==100&&kind=="total"->LibraryPage(page,502,100,offset)
                    playback&&offset==100&&kind=="empty"->LibraryPage(emptyList(),501,100,offset)
                    playback&&offset==100&&kind=="omitted"->LibraryPage(page.drop(1),501,100,offset,page.map {it.id.value})
                    playback&&kind=="budget"->LibraryPage(page.map {it.copy(title="x".repeat(30000))},501,100,offset)
                    playback&&kind=="reordered"->LibraryPage(page.reversed(),501,100,offset)
                    else->LibraryPage(page,501,100,offset)
                }
            },{_,_,_->})
            repo.refine(LibraryQuery());val state=repo.state.value;val capture=repo.capturePlayback(state.rows,4)!!;playback=true
            assertTrue(kind,runCatching {repo.playback(capture)}.isFailure);assertSame(state,repo.state.value)
        }
    }

    @Test fun collectionSourceGuardSurvivesConsumptionButNotRouteQueryMutationRowsOrScopeRetirement() {
        for(action in listOf("route","query","mutation","rows","scope")) {
            val session=session();val all=rows(1001).map {it.copy(liked=true)};var route=true
            val repo=LibraryRepository(session,{_,_,offset->LibraryPage(all.drop(offset).take(500),all.size,500,offset)},{_,_,_->})
            repo.refine(LibraryQuery())
            val expected=repo.state.value
            val request=repo.claimCollectionPlay(expected,current={route})!!
            assertFalse(repo.collectionPlaybackCurrent(request))
            repo.readCollection(request)
            var starts=0
            repo.startCollection(request){tracks,index->assertEquals(all,tracks);assertEquals(0,index);starts++;null}
            assertEquals(1,starts)
            repo.abandonCollection(request)
            assertTrue("Successful consume/abandon must not self-revoke",repo.collectionPlaybackCurrent(request))
            when(action) {
                "route"->route=false
                "query"->{repo.refine(LibraryQuery(text="other"));repo.refine(LibraryQuery())}
                "mutation"->assertNotNull(repo.claimLike(repo.offerLike(session.capture()!!,expected.rows[0].id)!!))
                "rows"->repo.loadMore()
                else->session.accept(session.beginIntent(),SecretTokens("new","new","A"))
            }
            assertFalse(action,repo.collectionPlaybackCurrent(request))
        }
    }
}
