package com.soundq.android.data.home

import com.soundq.android.data.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*

class HomeFeedRepositoryTest {
    private fun session(f: HttpsFixture) = AccountSession(f.endpoint, MemoryStore()).also { it.accept(it.beginIntent(),SecretTokens("a","r","fixture")) }
    private val body = """{"tracks":[{"id":1,"title":"Blocked","inLibrary":false},{"id":7,"title":"Eligible","inLibrary":true},{"id":9,"title":"Legacy"}]}"""
    @Test fun failedHistoryRefreshRetainsOffsetZeroRetryIntent() {
        HttpsFixture().use { f ->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.History)
            fun event(id:Int)="""{"id":$id,"track":{"id":7,"title":"Repeat"},"playedAt":"2026-10-28T00:00:00Z","skipped":false}"""
            f.reply("""{"plays":[${(1..50).joinToString(",") {event(it)}}],"limit":50,"offset":0}""");repo.load(route,HomeSection.History)
            f.reply("{}",503);repo.load(route,HomeSection.History,repo.history.value)
            val refused=repo.history.value
            assertEquals(SafeFailure.Reason.Refused,refused.error);assertEquals(50,refused.rows.size)
            assertFalse("retry must preserve refresh rather than append intent",refused.retryAppend)
        }
    }
    @Test fun heldOlderGenerationCannotReplaceFreshResult() {
        HttpsFixture().use { f ->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.Home)
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            val count=java.util.concurrent.atomic.AtomicInteger()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                if(count.incrementAndGet()==1) {entered.countDown();check(release.await(3,TimeUnit.SECONDS));return MockResponse.Builder().body(body).build()}
                return MockResponse.Builder().body("""{"tracks":[{"id":99,"title":"Fresh"}]}""").build()
            }}
            try {
                val old=pool.submit {repo.load(route,HomeSection.Top)};assertTrue(entered.await(2,TimeUnit.SECONDS))
                repo.load(route,HomeSection.Top);release.countDown();old.get(3,TimeUnit.SECONDS)
                assertEquals(listOf(99L),repo.top.value.rows.map {it.track.id.value});assertFalse(repo.top.value.loading)
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun heldAccountReplyCannotPublishIntoReplacement() {
        HttpsFixture().use { f ->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.Home)
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                entered.countDown();check(release.await(3,TimeUnit.SECONDS));return MockResponse.Builder().body(body).build()
            }}
            try {
                val old=pool.submit {repo.load(route,HomeSection.Recent)};assertTrue(entered.await(2,TimeUnit.SECONDS))
                s.revoke();s.accept(s.beginIntent(),SecretTokens("new","new-r","fixture"));repo.retire()
                release.countDown();old.get(3,TimeUnit.SECONDS)
                assertTrue(repo.recent.value.rows.isEmpty());assertFalse(repo.recent.value.loading);assertNull(repo.recent.value.error)
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun emptyRefusalRetryAndInvalidRepliesRemainDistinct() {
        HttpsFixture().use { f ->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.Home)
            f.reply("{}",403);repo.load(route,HomeSection.Top)
            assertFalse(repo.top.value.loading);assertEquals(SafeFailure.Reason.Refused,repo.top.value.error)
            f.reply("""{"tracks":[]}""");repo.load(route,HomeSection.Top,repo.top.value)
            assertTrue(repo.top.value.rows.isEmpty());assertNull(repo.top.value.error);assertFalse(repo.top.value.loading)
            f.reply("""{"tracks":[{"id":7,"title":"Safe","inLibrary":{},"artworkUrl":"http://unsafe.invalid/cover"}]}""")
            repo.load(route,HomeSection.Top,repo.top.value)
            assertFalse(repo.top.value.rows.single().eligible);assertNull(repo.top.value.rows.single().track.artwork)
            val rows=repo.top.value.rows
            f.reply("not JSON");repo.load(route,HomeSection.Top,repo.top.value)
            assertEquals(SafeFailure.Reason.InvalidResponse,repo.top.value.error);assertSame(rows,repo.top.value.rows)
        }
    }
    @Test fun heldRefreshPersistsRotationButCannotRetryRetiredRoute() {
        HttpsFixture().use { f ->
            val s=session(f);val life=HomeRouteLifetime();val route=life.enter(HomeDestination.Home)
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath.endsWith("/auth/refresh")) {entered.countDown();check(release.await(3,TimeUnit.SECONDS));return MockResponse.Builder().body(f.auth(access="rotated")).build()}
                return MockResponse.Builder().code(401).body("{}").build()
            }}
            try {
                val api=SoundQApi(s,f.client);val scope=s.capture()!!
                val result=pool.submit<SafeFailure.Reason?> {try {api.recent(scope,route::current);null}catch(e:SafeFailure){e.reason}}
                assertTrue(entered.await(2,TimeUnit.SECONDS));life.enter(HomeDestination.Library);release.countDown()
                assertEquals(SafeFailure.Reason.Retired,result.get(3,TimeUnit.SECONDS))
                assertEquals("rotated",s.access(scope));assertEquals(2,f.server.requestCount)
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun networkDispatchBoundaryRejectsRetiredRouteAndAccount() {
        for(account in listOf(false,true)) HttpsFixture().use { f ->
            val s=session(f);val life=HomeRouteLifetime();val route=life.enter(HomeDestination.Home)
            val client=f.client.newBuilder().addInterceptor {chain ->
                if(account) s.revoke() else {life.enter(HomeDestination.Library);life.enter(HomeDestination.Home)}
                chain.proceed(chain.request())
            }.build()
            val api=SoundQApi(s,client);val scope=s.capture()!!
            val error=runCatching {api.recent(scope,route::current)}.exceptionOrNull() as SafeFailure
            assertEquals(SafeFailure.Reason.Retired,error.reason);assertEquals(0,f.server.requestCount)
        }
    }
    @Test fun retainedRetryCannotAdoptReplacementAccount() {
        HttpsFixture().use { f ->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.Home)
            f.reply("{}",403);repo.load(route,HomeSection.Recent)
            val refused=repo.recent.value
            assertEquals(SafeFailure.Reason.Refused,refused.error)
            s.revoke();s.accept(s.beginIntent(),SecretTokens("b","rb","fixture"))
            f.reply(body);repo.load(route,HomeSection.Recent,refused)
            assertEquals("old rendered retry belongs to old account",1,f.server.requestCount)
        }
    }
    @Test fun routeExitBeforeRefreshDispatchDoesNotSendRefreshOrRevokeAccount() {
        assertUndispatchedRefreshPreservesAccount(false)
    }
    @Test fun routeExitBeforeRefreshDispatchNeverNeedsFailingStore() {
        assertUndispatchedRefreshPreservesAccount(true)
    }
    private fun assertUndispatchedRefreshPreservesAccount(failSave:Boolean) {
        HttpsFixture().use { f ->
            val store=MemoryStore();val s=AccountSession(f.endpoint,store)
            assertTrue(s.accept(s.beginIntent(),SecretTokens("a","r","fixture")))
            val scope=s.capture()!!;val signedIn=s.state.value;val saved=store.tokens;val writes=store.writes
            store.fail=failSave
            val life=HomeRouteLifetime();val route=life.enter(HomeDestination.Home)
            val client=f.client.newBuilder().addInterceptor { chain ->
                if(chain.request().url.encodedPath.endsWith("/auth/refresh")) life.enter(HomeDestination.Library)
                chain.proceed(chain.request())
            }.build()
            val api=SoundQApi(s,client)
            f.reply("{}",401);f.reply(f.auth());f.reply(body)
            val error=runCatching {api.recent(scope,route::current)}.exceptionOrNull() as? SafeFailure
            assertEquals(SafeFailure.Reason.Retired,error?.reason)
            assertEquals("refresh is route-admitted before network dispatch",1,f.server.requestCount)
            assertTrue("route cancellation must preserve original capability",s.current(scope))
            assertEquals("a",s.access(scope));assertSame(signedIn,s.state.value)
            assertEquals("undispatched exchange must not write",writes,store.writes);assertSame(saved,store.tokens)
            assertEquals("GET",f.server.takeRequest(2,TimeUnit.SECONDS)!!.method)
        }
    }
    @Test fun staleRoutesAccountsAndGenerationCannotRevivePlaybackOrRetry() {
        HttpsFixture().use { f ->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val life=HomeRouteLifetime();val a=life.enter(HomeDestination.Home)
            f.reply(body);repo.load(a,HomeSection.Recent)
            val old=repo.recent.value;val row=old.rows[1]
            var plays=0
            val play=repo.playAction(a,HomeSection.Recent,old.rows,row,play={_,_->plays++})
            play();assertEquals(1,plays)
            life.enter(HomeDestination.History);val again=life.enter(HomeDestination.Home)
            play();repo.load(a,HomeSection.Recent,old)
            assertEquals(1,plays);assertEquals(1,f.server.requestCount)
            f.reply(body);repo.load(again,HomeSection.Recent)
            val current=repo.recent.value
            val newer=repo.playAction(again,HomeSection.Recent,current.rows,current.rows[1],play={_,_->plays++})
            f.reply(body);repo.load(again,HomeSection.Recent,current);newer()
            assertEquals(1,plays)
            val last=repo.recent.value
            val lastAction=repo.playAction(again,HomeSection.Recent,last.rows,last.rows[1],play={_,_->plays++})
            s.revoke();s.accept(s.beginIntent(),SecretTokens("b","rb","fixture"));lastAction()
            assertEquals(1,plays)
            life.close();repo.load(again,HomeSection.Recent)
            assertEquals(3,f.server.requestCount)
        }
    }
    @Test fun heldRouteReadCannotPublishAfterSameRouteReentry() {
        HttpsFixture().use { f ->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val life=HomeRouteLifetime();val route=life.enter(HomeDestination.Home)
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                entered.countDown();check(release.await(3,TimeUnit.SECONDS));return MockResponse.Builder().body(body).build()
            }}
            try {
                val read=pool.submit {repo.load(route,HomeSection.Recent)}
                assertTrue(entered.await(2,TimeUnit.SECONDS));assertTrue(repo.recent.value.loading)
                life.enter(HomeDestination.Library);life.enter(HomeDestination.Home);release.countDown();read.get(3,TimeUnit.SECONDS)
                assertTrue(repo.recent.value.rows.isEmpty());assertEquals(1,f.server.requestCount)
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun historyPagesByRawEventCountRetainsRepeatsAndPlaysSingleton() {
        HttpsFixture().use { f ->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.History)
            fun event(id:Int)="""{"id":$id,"track":{"id":7,"title":"Repeat","inLibrary":true},"playedAt":"2026-10-28T00:00:00Z","contextType":"queue","skipped":false}"""
            f.reply("""{"plays":[${(1..50).joinToString(",") {event(it)}}],"limit":50,"offset":0}""")
            repo.load(route,HomeSection.History)
            assertEquals(50,repo.history.value.rows.size);assertTrue(repo.history.value.hasMore)
            val initial=repo.history.value
            f.reply("{}",403);repo.load(route,HomeSection.History,initial,append=true)
            assertEquals(initial.rows,repo.history.value.rows);assertEquals(SafeFailure.Reason.Refused,repo.history.value.error)
            f.reply("""{"plays":[${event(51)}],"limit":50,"offset":50}""")
            repo.load(route,HomeSection.History,repo.history.value,append=true)
            val result=repo.history.value
            assertEquals(51,result.rows.size);assertEquals(51,result.nextOffset);assertFalse(result.hasMore)
            assertEquals(51,result.rows.map {it.id}.distinct().size);assertEquals(1,result.rows.map {it.entry.track.id}.distinct().size)
            var calls=0
            val row=result.rows.last()
            repo.playAction(route,HomeSection.History,result.rows,row.entry,row.id,play={tracks,index->assertEquals(listOf(7L),tracks.map {it.id.value});assertEquals(0,index);calls++})()
            assertEquals(1,calls)
            assertEquals(listOf("0","50","50"),(1..3).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!.url.queryParameter("offset")})
            assertEquals(3,f.server.requestCount)
        }
    }
    @Test fun realFeedPublishesThenPlaysFilteredIdentityNotOldIndex() {
        HttpsFixture().use { f ->
            val s=session(f);val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val life=HomeRouteLifetime();val route=life.enter(HomeDestination.Home)
            f.reply(body);repo.load(route,HomeSection.Recent)
            val rows=repo.recent.value.rows
            assertEquals(3,rows.size)
            var tracks:List<Track> = emptyList();var index=-1
            repo.playAction(route,HomeSection.Recent,rows,rows[1],play={t,i->tracks=t;index=i})()
            assertEquals(listOf(7L,9L),tracks.map {it.id.value});assertEquals(0,index)
            repo.playAction(route,HomeSection.Recent,rows,rows[0],play={_,_->fail("ineligible action dispatched")})()
        }
    }
}
