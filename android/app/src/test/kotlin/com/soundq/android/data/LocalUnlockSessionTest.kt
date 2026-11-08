package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test

class LocalUnlockSessionTest {
    private val endpoint=ApiEndpoint.parse("https://unlock.example.test/api/v1")
    private fun owner():AccountSession = AccountSession(endpoint,object:SessionStore {
        override fun load(endpoint:ApiEndpoint)=SecretTokens("access","refresh","one")
        override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){}
        override fun clear(){}
    }).also {it.accept(it.beginIntent(),SecretTokens("access","refresh","one"))}
    @Test fun localLockRevokesRemoteAndDeviceCallbacksWithoutSigningOutOrResuming() {
        val session=owner();val scope=session.capture()!!
        session.javaClass.methods.firstOrNull {it.name=="lockLocal"}?.invoke(session)
        assertFalse("local lock must revoke pre-lock remote capabilities",session.remoteCurrent(scope))
        assertFalse(session.current(scope));assertNull(session.capture())
        assertEquals("LocalLocked",session.state.value.javaClass.simpleName)
    }
    @Test fun cancelledSupersededAndAccountABAPromptsCannotUnlock() {
        val session=owner();val before=session.capture()!!;session.lockLocal()
        val first=session.localUnlockTicket()!!;val second=session.localUnlockTicket()!!
        assertFalse(session.completeLocalUnlock(first));session.cancelLocalUnlock()
        assertFalse(session.completeLocalUnlock(second));val final=session.localUnlockTicket()!!
        assertTrue(session.completeLocalUnlock(final));assertTrue(session.resumesLocal(before));assertEquals(AuthState.SignedIn("one"),session.state.value)
        val fresh=session.capture()!!;assertTrue(session.remoteCurrent(fresh))
        session.lockLocal();val old=session.localUnlockTicket()!!
        session.revoke();session.accept(session.beginIntent(),SecretTokens("new","new-refresh","one"))
        assertFalse(session.completeLocalUnlock(old));assertFalse(session.resumesLocal(fresh));assertEquals(AuthState.SignedIn("one"),session.state.value)
    }
    @Test fun heldRotationPersistsExactlyOnceWhileLockedWithoutPublishingServerAuthority() {
        val saved=java.util.concurrent.atomic.AtomicReference<SecretTokens?>()
        val session=AccountSession(endpoint,object:SessionStore {
            override fun load(endpoint:ApiEndpoint)=saved.get()
            override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){saved.set(tokens)}
            override fun clear(){saved.set(null)}
        });session.accept(session.beginIntent(),SecretTokens("a","old-refresh","one"));val scope=session.capture()!!
        val entered=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1)
        val pool=java.util.concurrent.Executors.newSingleThreadExecutor()
        try {
            val result=pool.submit<Boolean>{session.refresh(scope){entered.countDown();release.await();SecretTokens("rotated","new-refresh","one")}}
            assertTrue(entered.await(2,java.util.concurrent.TimeUnit.SECONDS));assertTrue(session.lockLocal());release.countDown()
            result.get(2,java.util.concurrent.TimeUnit.SECONDS)
            assertEquals("new-refresh",saved.get()?.refresh)
            assertEquals(AuthState.LocalLocked,session.state.value);assertNull(session.capture());assertFalse(session.current(scope))
            assertTrue(session.completeLocalUnlock(session.localUnlockTicket()!!));assertEquals(AuthState.SignedIn("one"),session.state.value)
            assertEquals("rotated",session.access(session.capture()!!))
        } finally {release.countDown();pool.shutdownNow()}
    }
    @Test fun trustedTlsDispatchedRotationSurvivesLocalLockButCannotPublishWhileLocked() {
        HttpsFixture().use {tls ->
            val saved=MemoryStore();val session=AccountSession(tls.endpoint,saved)
            session.accept(session.beginIntent(),SecretTokens("old","old-refresh","one"));val scope=session.capture()!!
            val entered=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1)
            tls.server.dispatcher=object:mockwebserver3.Dispatcher() {
                override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                    assertEquals("/api/v1/auth/refresh",request.url.encodedPath)
                    entered.countDown();check(release.await(3,java.util.concurrent.TimeUnit.SECONDS))
                    return mockwebserver3.MockResponse.Builder().body(tls.auth("one","rotated")).build()
                }
            }
            val pool=java.util.concurrent.Executors.newSingleThreadExecutor()
            try {
                val future=pool.submit<Boolean>{SoundQApi(session,tls.client).restore()}
                // restore on an already active session is intentionally refused; use existing API consumer to rotate.
                assertFalse(future.get(2,java.util.concurrent.TimeUnit.SECONDS))
                tls.server.dispatcher=object:mockwebserver3.Dispatcher() {
                    override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                        if(request.url.encodedPath.endsWith("/auth/refresh")) {
                            entered.countDown();check(release.await(3,java.util.concurrent.TimeUnit.SECONDS))
                            return mockwebserver3.MockResponse.Builder().body(tls.auth("one","rotated")).build()
                        }
                        return mockwebserver3.MockResponse.Builder().code(401).build()
                    }
                }
                val request=pool.submit<Boolean>{runCatching {SoundQApi(session,tls.client).library(scope,LibraryQuery(),0)}.isSuccess}
                assertTrue(entered.await(2,java.util.concurrent.TimeUnit.SECONDS));assertTrue(session.lockLocal());release.countDown()
                assertFalse(request.get(3,java.util.concurrent.TimeUnit.SECONDS));assertNull(session.capture());assertEquals(AuthState.LocalLocked,session.state.value)
                assertTrue(session.completeLocalUnlock(session.localUnlockTicket()!!));assertEquals("rotated",session.access(session.capture()!!))
                assertEquals(2,tls.server.requestCount)
            }finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun startupGatePreventsSavedTokenReadAndRefreshUntilExplicitUnlock() {
        var reads=0;var exchanges=0
        val session=AccountSession(endpoint,object:SessionStore {
            override fun load(endpoint:ApiEndpoint):SecretTokens? {reads++;return SecretTokens("a","r","one")}
            override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){}
            override fun clear(){}
        })
        assertTrue(session.lockLocal());assertFalse(session.restore {exchanges++;true})
        assertFalse(session.useDeviceDownloads());assertEquals(0,reads);assertEquals(0,exchanges)
        assertTrue(session.completeLocalUnlock(session.localUnlockTicket()!!))
        assertTrue(session.restore {exchanges++;true});assertEquals(1,reads);assertEquals(1,exchanges)
    }
}
