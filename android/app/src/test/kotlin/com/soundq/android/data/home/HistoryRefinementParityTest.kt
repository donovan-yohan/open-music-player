package com.soundq.android.data.home

import com.soundq.android.data.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*

class HistoryRefinementParityTest {
    private fun session(f:HttpsFixture)=AccountSession(f.endpoint,MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("a","r","A"))}
    private fun event(id:Int,title:String="Other",artist:String="Artist",skipped:Boolean=false,eligible:Boolean=true)=
        """{"id":$id,"track":{"id":7,"title":"$title","artist":"$artist","inLibrary":$eligible},"playedAt":"2026-11-06T00:00:00Z","contextType":"playlist","contextId":"42","skipped":$skipped}"""
    private fun page(offset:Int,events:List<String>)="""{"plays":[${events.joinToString(",")}],"limit":50,"offset":$offset}"""
    @Test fun literalArtistAndSkippedFilterScansBeyondFirstFiftyPreservingEvents() {
        HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.History)
            f.reply(page(0,(1..50).map {event(it)}))
            f.reply(page(50,listOf(event(51,artist="100%_ +",skipped=true),event(52,artist="100%_ +",skipped=false),event(53,artist="100%_ +",skipped=true,eligible=false),event(54,artist="100%_ +",skipped=true))))
            val query=HistoryQuery("100%_ +",HistoryKind.Skipped)
            repo.executeHistory(repo.claimHistory(route,query=query)!!)
            val state=repo.history.value
            assertEquals(query,state.query);assertEquals(listOf(51L,53L,54L),state.rows.map {it.id})
            assertEquals(54,state.nextOffset);assertFalse(state.hasMore)
            assertEquals(listOf("0","50"),(1..2).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!.url.queryParameter("offset")})
            var plays=0;val selected=state.rows.last()
            repo.playAction(route,HomeSection.History,state.rows,selected.entry,selected.id) {tracks,index->
                plays++;assertEquals(listOf(7L),tracks.map {it.id.value});assertEquals(0,index)
            }()
            val unavailable=state.rows[1]
            repo.playAction(route,HomeSection.History,state.rows,unavailable.entry,unavailable.id){_,_->fail("Unavailable event played")}()
            assertEquals(1,plays);assertEquals("playlist",selected.contextType);assertEquals("42",selected.contextId)
        }
    }
    @Test fun filteredPageBoundaryDoesNotLoseUnconsumedRawEventsAndRetryKeepsIntent() {
        HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.History)
            val query=HistoryQuery("Match",HistoryKind.Listened)
            f.reply(page(0,(1..50).map {event(it,title=if(it==1)"Other" else "Match")}))
            f.reply(page(50,(51..100).map {event(it,title="Match")}))
            repo.executeHistory(repo.claimHistory(route,query=query)!!)
            val first=repo.history.value
            assertEquals((2L..51L).toList(),first.rows.map {it.id});assertEquals(51,first.nextOffset);assertTrue(first.hasMore)
            f.reply("{}",503);repo.executeHistory(repo.claimHistory(route,first,append=true)!!)
            val failed=repo.history.value
            assertSame(first.rows,failed.rows);assertTrue(failed.retryAppend);assertEquals(query,failed.query)
            f.reply(page(51,(52..55).map {event(it,title="Match")}))
            repo.executeHistory(repo.claimHistory(route,failed,append=failed.retryAppend)!!)
            val result=repo.history.value
            assertEquals((2L..55L).toList(),result.rows.map {it.id});assertFalse(result.hasMore)
            assertEquals(listOf("0","50","51","51"),(1..4).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!.url.queryParameter("offset")})
        }
    }
    @Test fun newFilterClaimsBeforeSchedulingAndPermanentlyRetiresOldSelection() {
        HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.History)
            f.reply(page(0,listOf(event(1,title="Old"))));repo.load(route,HomeSection.History)
            val old=repo.history.value;val row=old.rows.single();var plays=0
            val callback=repo.playAction(route,HomeSection.History,old.rows,row.entry,row.id){_,_->plays++}
            callback();assertEquals(1,plays)
            val newer=repo.claimHistory(route,old,query=HistoryQuery("New"))!!
            callback();assertEquals(1,plays)
            assertNull(repo.claimHistory(route,old,query=HistoryQuery("Old")))
            f.reply(page(0,listOf(event(2,title="New"))));repo.executeHistory(newer);repo.executeHistory(newer)
            assertEquals(listOf(2L),repo.history.value.rows.map {it.id});assertEquals(2,f.server.requestCount)
            callback();assertEquals(1,plays)
            s.accept(s.beginIntent(),SecretTokens("b","r","A"))
            assertNull(repo.claimHistory(route,repo.history.value,query=HistoryQuery("Borrowed")))
        }
    }
    @Test fun routeExitBetweenRawPagesCannotScanOrPublishMoreHistory() {
        HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val life=HomeRouteLifetime();val route=life.enter(HomeDestination.History)
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                entered.countDown();check(release.await(3,TimeUnit.SECONDS));return MockResponse.Builder().body(page(0,(1..50).map {event(it)})).build()
            }}
            try {
                val request=repo.claimHistory(route,query=HistoryQuery("Missing"))!!
                val read=pool.submit {repo.executeHistory(request)}
                assertTrue(entered.await(2,TimeUnit.SECONDS));life.enter(HomeDestination.Library);release.countDown();read.get(3,TimeUnit.SECONDS)
                assertEquals(1,f.server.requestCount);assertTrue(repo.history.value.rows.isEmpty())
            }finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(3,TimeUnit.SECONDS))}
        }
    }
}
