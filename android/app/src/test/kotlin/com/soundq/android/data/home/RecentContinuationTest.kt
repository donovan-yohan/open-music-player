package com.soundq.android.data.home

import com.soundq.android.data.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import mockwebserver3.*

class RecentContinuationTest {
    private fun session(f:HttpsFixture)=AccountSession(f.endpoint,MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("a","r","fixture"))}
    private val revision="a".repeat(64)
    private fun page(ids:List<Int>,offset:Int=0,more:Boolean=false,rev:String=revision)=
        """{"tracks":[${ids.joinToString(","){"""{"id":$it,"title":"Same title","inLibrary":${it!=1}}"""}}],"limit":20,"offset":$offset,"revision":"$rev","hasMore":$more}"""
    @Test fun zeroThreeFiveAndSixUseCanonicalRowsAndRealEndEvidence() {
        for(n in listOf(0,3,5,6,20)) HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.Home)
            f.reply(page((1..n).toList()));repo.load(route,HomeSection.Recent)
            val initial=repo.recent.value
            assertEquals(n,initial.rows.size);assertEquals(minOf(5,n),initial.visibleCount);assertEquals(n>5,initial.hasMore)
            assertEquals((1..n).map {it.toLong()},initial.rows.map {it.track.id.value})
            while(repo.recent.value.hasMore)repo.load(route,HomeSection.Recent,repo.recent.value,append=true)
            assertEquals(n,repo.recent.value.visibleCount);assertSame(initial.rows,repo.recent.value.rows)
            assertEquals(1,f.server.requestCount)
        }
    }
    @Test fun beyondFortyTraversesWithoutDedupeOrArtificialTwentyEnd() {
        HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.Home)
            f.reply(page((1..20).toList(),more=true));repo.load(route,HomeSection.Recent)
            val counts=mutableListOf(repo.recent.value.visibleCount)
            f.reply(page((21..40).toList(),20,true));f.reply(page((41..43).toList(),40,false))
            while(repo.recent.value.hasMore) {repo.load(route,HomeSection.Recent,repo.recent.value,append=true);counts+=repo.recent.value.visibleCount}
            assertEquals(listOf(5,10,15,20,25,30,35,40,43),counts)
            assertEquals((1..43).map {it.toLong()},repo.recent.value.rows.map {it.track.id.value})
            assertEquals(listOf("0","20","40"),(1..3).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!.url.queryParameter("offset")})
            assertEquals(3,f.server.requestCount)
        }
    }
    @Test fun appendClaimsBeforeIoIsSingleUseAndFailureKeepsRowsCursorAndRetryIntent() {
        HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.Home)
            f.reply(page((1..20).toList(),more=true));repo.load(route,HomeSection.Recent)
            repeat(3){repo.load(route,HomeSection.Recent,repo.recent.value,append=true)}
            val before=repo.recent.value
            val request=repo.claimRecent(route,before,append=true)!!
            assertTrue(repo.recent.value.loading);assertEquals(1,f.server.requestCount)
            assertNull(repo.claimRecent(route,before,append=true));assertNull(repo.claimRecent(route,repo.recent.value,append=true))
            f.reply("{}",503);repo.executeRecent(request);repo.executeRecent(request)
            val failed=repo.recent.value
            assertEquals(SafeFailure.Reason.Refused,failed.error);assertTrue(failed.retryAppend)
            assertEquals(20,failed.visibleCount);assertEquals(20,failed.nextOffset);assertSame(before.rows,failed.rows);assertEquals(revision,failed.revision)
            f.reply(page(listOf(21),20));repo.executeRecent(repo.claimRecent(route,failed,append=failed.retryAppend)!!)
            assertEquals(21,repo.recent.value.visibleCount);assertEquals(21,repo.recent.value.nextOffset);assertFalse(repo.recent.value.hasMore)
            assertEquals(listOf("0","20","20"),(1..3).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!.url.queryParameter("offset")})
            assertEquals(3,f.server.requestCount)
        }
    }
    @Test fun mutationConflictReplacesAtZeroAndResetsFiveWithoutTouchingTopOrHistory() {
        HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.Home)
            f.reply(page((1..20).toList(),more=true));repo.load(route,HomeSection.Recent)
            f.reply("""{"tracks":[{"id":99,"title":"Top"}]}""");repo.load(route,HomeSection.Top)
            val top=repo.top.value;val history=repo.history.value
            repeat(3){repo.load(route,HomeSection.Recent,repo.recent.value,append=true)}
            val before=repo.recent.value;var calls=0
            val old=repo.playAction(route,HomeSection.Recent,before.rows,before.rows[1],play={_,_->calls++})
            f.reply("{}",409);f.reply(page((21 downTo 2).toList(),rev="b".repeat(64)))
            repo.load(route,HomeSection.Recent,before,append=true)
            assertEquals(5,repo.recent.value.visibleCount);assertEquals("b".repeat(64),repo.recent.value.revision)
            assertEquals((21 downTo 2).map {it.toLong()},repo.recent.value.rows.map {it.track.id.value})
            assertSame(top,repo.top.value);assertSame(history,repo.history.value);old();assertEquals(0,calls)
            val paths=(1..4).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!.url}
            assertEquals("20",paths[2].queryParameter("offset"));assertEquals("0",paths[3].queryParameter("offset"));assertNull(paths[3].queryParameter("revision"))
        }
    }
    @Test fun conflictThenReplacementFailureCannotRetryOldCursorOrOldActions() {
        HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.Home)
            f.reply(page((1..20).toList(),more=true));repo.load(route,HomeSection.Recent)
            repeat(3){repo.load(route,HomeSection.Recent,repo.recent.value,append=true)}
            f.reply("{}",409);f.reply("{}",503);repo.load(route,HomeSection.Recent,repo.recent.value,append=true)
            val failed=repo.recent.value
            assertFalse(failed.loading);assertFalse(failed.retryAppend);assertNull(failed.revision);assertTrue(failed.rows.isEmpty());assertFalse(failed.hasMore)
            f.reply(page(listOf(99)));repo.load(route,HomeSection.Recent,failed,append=failed.retryAppend)
            assertEquals(1,repo.recent.value.visibleCount)
        }
    }
    @Test fun refreshNewRouteAndAccountAbaRetirePendingClaimAndResetFive() {
        HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val life=HomeRouteLifetime();val route=life.enter(HomeDestination.Home)
            f.reply(page((1..20).toList(),more=true));repo.load(route,HomeSection.Recent)
            repeat(3){repo.load(route,HomeSection.Recent,repo.recent.value,append=true)}
            val old=repo.claimRecent(route,repo.recent.value,append=true)!!
            val refresh=repo.claimRecent(route,repo.recent.value)!!
            repo.abandonRecent(old);assertTrue(repo.recent.value.loading)
            f.reply(page((1..20).toList(),more=true));repo.executeRecent(refresh);repo.executeRecent(old)
            assertEquals(5,repo.recent.value.visibleCount);assertEquals(2,f.server.requestCount)
            repeat(3){repo.load(route,HomeSection.Recent,repo.recent.value,append=true)}
            val queued=repo.claimRecent(route,repo.recent.value,append=true)!!
            life.enter(HomeDestination.Library);val again=life.enter(HomeDestination.Home)
            repo.executeRecent(queued);repo.abandonRecent(queued);assertEquals(2,f.server.requestCount)
            f.reply(page((1..20).toList(),more=true));repo.load(again,HomeSection.Recent);assertEquals(5,repo.recent.value.visibleCount)
            repeat(3){repo.load(again,HomeSection.Recent,repo.recent.value,append=true)}
            val accountClaim=repo.claimRecent(again,repo.recent.value,append=true)!!
            s.revoke();s.accept(s.beginIntent(),SecretTokens("b","rb","other"));s.revoke();s.accept(s.beginIntent(),SecretTokens("a2","ra2","fixture"))
            repo.retire();repo.executeRecent(accountClaim);assertTrue(repo.recent.value.rows.isEmpty());assertFalse(repo.recent.value.loading)
            f.reply(page((1..20).toList(),more=true));repo.load(again,HomeSection.Recent);assertEquals(5,repo.recent.value.visibleCount);assertEquals(4,f.server.requestCount)
        }
    }
    @Test fun malformedContinuationNeverReplacesAcknowledgedRows() {
        HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.Home)
            val valid=page((1..20).toList(),more=true)
            val invalid=listOf(valid.replace("\"hasMore\":true","\"hasMore\":\"true\""),valid.replace("\"offset\":0","\"offset\":\"0\""),valid.replace("\"limit\":20","\"limit\":19"),valid.replace(revision,"wrong"),page(listOf(7,7)),page(listOf(7),more=true),"""{"tracks":[]}""")
            for(body in invalid) {
                f.reply(valid);repo.load(route,HomeSection.Recent)
                val rows=repo.recent.value.rows
                f.reply(body);repo.load(route,HomeSection.Recent,repo.recent.value)
                assertEquals(SafeFailure.Reason.InvalidResponse,repo.recent.value.error);assertSame(rows,repo.recent.value.rows)
            }
        }
    }
    @Test fun emptyPageCannotTurnPromisedContinuationIntoFakeExhaustion() {
        HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.Home)
            f.reply(page((1..20).toList(),more=true));repo.load(route,HomeSection.Recent)
            repeat(3){repo.load(route,HomeSection.Recent,repo.recent.value,append=true)}
            val before=repo.recent.value
            f.reply(page(emptyList(),20));repo.load(route,HomeSection.Recent,before,append=true)
            assertEquals(SafeFailure.Reason.InvalidResponse,repo.recent.value.error)
            assertSame(before.rows,repo.recent.value.rows);assertTrue(repo.recent.value.hasMore);assertTrue(repo.recent.value.retryAppend)
        }
    }
    @Test fun duplicateIdAcrossPagesIsRefusedNotSilentlyDeduped() {
        HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.Home)
            f.reply(page((1..20).toList(),more=true));repo.load(route,HomeSection.Recent)
            repeat(3){repo.load(route,HomeSection.Recent,repo.recent.value,append=true)}
            val before=repo.recent.value
            f.reply(page(listOf(20,21),20));repo.load(route,HomeSection.Recent,before,append=true)
            assertEquals(SafeFailure.Reason.InvalidResponse,repo.recent.value.error)
            assertSame(before.rows,repo.recent.value.rows);assertEquals(20,repo.recent.value.nextOffset);assertEquals(20,repo.recent.value.visibleCount)
        }
    }
    @Test fun heldAppendCannotPublishAfterRouteOrSourceRetirement() {
        for(sourceRetirement in listOf(false,true)) HttpsFixture().use {f->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val life=HomeRouteLifetime();val route=life.enter(HomeDestination.Home)
            f.reply(page((1..20).toList(),more=true));repo.load(route,HomeSection.Recent)
            repeat(3){repo.load(route,HomeSection.Recent,repo.recent.value,append=true)}
            val claim=repo.claimRecent(route,repo.recent.value,append=true)!!
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:Dispatcher() {override fun dispatch(request:RecordedRequest):MockResponse {
                entered.countDown();check(release.await(3,TimeUnit.SECONDS));return MockResponse.Builder().body(page(listOf(21),20)).build()
            }}
            try {
                val result=pool.submit {repo.executeRecent(claim)}
                assertTrue(entered.await(2,TimeUnit.SECONDS))
                if(sourceRetirement)repo.retire() else {life.enter(HomeDestination.Library);life.enter(HomeDestination.Home)}
                release.countDown();result.get(3,TimeUnit.SECONDS)
                assertEquals(if(sourceRetirement)0 else 20,repo.recent.value.rows.size)
                assertFalse(repo.recent.value.loading);assertEquals(2,f.server.requestCount)
                assertNull(repo.claimRecent(route,repo.recent.value,append=true))
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun repositoryOptsIntoRevisionCheckedCanonicalRecentPages() {
        HttpsFixture().use { f ->
            val s=AccountSession(f.endpoint,MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("a","r","fixture"))}
            val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.Home)
            f.reply("""{"tracks":[{"id":7,"title":"Same title","inLibrary":true}],"limit":20,"offset":0,"revision":"${"a".repeat(64)}","hasMore":false}""")
            repo.load(route,HomeSection.Recent)
            assertEquals(7L,repo.recent.value.rows.single().track.id.value)
            val request=f.server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("true",request.url.queryParameter("continuation"))
            assertEquals("0",request.url.queryParameter("offset"))
        }
    }
}
