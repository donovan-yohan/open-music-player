package com.soundq.android.data.home

import com.soundq.android.data.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicReference

/** Admission and durability have separate owners, over real TLS and observable storage. */
class HomeRefreshTest {
    @Test fun dispatchedRotationStillPersistsOrRequiresSaveAfterRouteExit() {
        for(failSave in listOf(false,true)) HttpsFixture().use { f ->
            val store=MemoryStore();val s=AccountSession(f.endpoint,store)
            s.accept(s.beginIntent(),SecretTokens("a","r","fixture"));val scope=s.capture()!!;val saved=store.tokens
            store.fail=failSave
            val life=HomeRouteLifetime();val route=life.enter(HomeDestination.Home)
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath.endsWith("/auth/refresh")) {
                    entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().body(f.auth(access="rotated")).build()
                }
                return MockResponse.Builder().code(401).body("{}").build()
            }}
            try {
                val api=SoundQApi(s,f.client)
                val result=pool.submit<SafeFailure.Reason?> {try {api.recent(scope,route::current);null}catch(e:SafeFailure){e.reason}}
                assertTrue(entered.await(3,TimeUnit.SECONDS));life.enter(HomeDestination.Library);release.countDown()
                assertEquals(SafeFailure.Reason.Retired,result.get(5,TimeUnit.SECONDS));assertEquals(2,f.server.requestCount);assertEquals(2,store.writes)
                if(failSave) {
                    assertNull(s.capture());assertTrue(s.state.value is AuthState.SaveRequired);assertSame(saved,store.tokens)
                    store.fail=false;assertTrue(s.retrySave());assertEquals(2,f.server.requestCount);assertEquals(3,store.writes)
                }
                assertEquals("rotated",s.access(scope));assertEquals("rotated",store.tokens!!.access);assertEquals("r-rotated",store.tokens!!.refresh)
                assertEquals(AuthState.SignedIn("fixture"),s.state.value)
            } finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(3,TimeUnit.SECONDS))}
        }
    }
    @Test fun refusedAndRealTransportFailureStillRetireCredentials() {
        for(networkFailure in listOf(false,true)) HttpsFixture().use { f ->
            val store=MemoryStore();val s=AccountSession(f.endpoint,store);s.accept(s.beginIntent(),SecretTokens("a","r","fixture"))
            val saved=store.tokens;val api=SoundQApi(s,f.client);val repo=HomeFeedRepository(s,api)
            val route=HomeRouteLifetime().enter(HomeDestination.Home)
            if(networkFailure) {
                f.reply("{}",401)
                // A real local connection refusal at refresh construction, before network admission.
                val client=f.client.newBuilder().addInterceptor {chain->
                    if(chain.request().url.encodedPath.endsWith("/auth/refresh")) f.server.close()
                    chain.proceed(chain.request())
                }.build()
                val failure=runCatching {SoundQApi(s,client).recent(s.capture()!!,route::current)}.exceptionOrNull() as SafeFailure
                assertEquals(SafeFailure.Reason.Retired,failure.reason)
            } else {
                f.reply("{}",401);f.reply("{}",403);repo.load(route,HomeSection.Recent)
                assertEquals(2,f.server.requestCount)
            }
            assertNull(s.capture());val out=s.state.value as AuthState.SignedOut
            assertEquals(if(networkFailure)SafeFailure.Reason.Uncertain else SafeFailure.Reason.Refused,out.error);assertTrue(out.uncertain)
            assertEquals(1,store.writes);assertSame(saved,store.tokens)
        }
    }
    @Test fun concurrentCallersSettleUndispatchedFlightAndLaterRefreshCanSucceed() {
        HttpsFixture().use { f ->
            val store=MemoryStore();val s=AccountSession(f.endpoint,store);s.accept(s.beginIntent(),SecretTokens("a","r","fixture"))
            val scope=s.capture()!!;val signedIn=s.state.value
            val life=HomeRouteLifetime();val route=life.enter(HomeDestination.Home)
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newFixedThreadPool(2)
            val secondThread=AtomicReference<Thread>();val secondStarted=CountDownLatch(1)
            val client=f.client.newBuilder().addInterceptor {chain->
                if(chain.request().url.encodedPath.endsWith("/auth/refresh")&&route.current()) {
                    entered.countDown();check(release.await(5,TimeUnit.SECONDS))
                }
                chain.proceed(chain.request())
            }.build()
            val api=SoundQApi(s,client)
            fun read():SafeFailure.Reason?=try {api.recent(scope,route::current);null}catch(e:SafeFailure){e.reason}
            try {
                f.reply("{}",401);f.reply("{}",401)
                val first=pool.submit<SafeFailure.Reason?> {read()};assertTrue(entered.await(3,TimeUnit.SECONDS))
                val second=pool.submit<SafeFailure.Reason?> {secondThread.set(Thread.currentThread());secondStarted.countDown();read()}
                assertTrue(secondStarted.await(3,TimeUnit.SECONDS))
                val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(3)
                while(System.nanoTime()<deadline&&!secondThread.get().stackTrace.any {it.className=="java.util.concurrent.CompletableFuture"&&it.methodName=="get"})Thread.sleep(5)
                assertTrue("second API caller joined actual refresh future",secondThread.get().stackTrace.any {it.className=="java.util.concurrent.CompletableFuture"&&it.methodName=="get"})
                life.enter(HomeDestination.Library);release.countDown()
                assertEquals(SafeFailure.Reason.Retired,first.get(5,TimeUnit.SECONDS));assertEquals(SafeFailure.Reason.Retired,second.get(5,TimeUnit.SECONDS))
                assertEquals(2,f.server.requestCount);assertEquals(1,store.writes);assertSame(signedIn,s.state.value);assertEquals("a",s.access(scope))
                val fresh=life.enter(HomeDestination.Home)
                f.reply("{}",401);f.reply(f.auth(access="fresh"));f.reply("""{"tracks":[]}""")
                assertTrue(api.recent(scope,fresh::current).isEmpty());assertEquals("fresh",s.access(scope));assertEquals(2,store.writes);assertEquals(5,f.server.requestCount)
            } finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(3,TimeUnit.SECONDS))}
        }
    }
}
