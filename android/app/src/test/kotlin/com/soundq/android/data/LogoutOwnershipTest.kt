package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*

class LogoutOwnershipTest {
    @Test fun capturedLogoutCleanupCannotRetireOrClearReplacement() {
        HttpsFixture().use {f ->
            val store=MemoryStore();val session=AccountSession(f.endpoint,store)
            session.accept(session.beginIntent(),SecretTokens("a","ar","A"))
            val api=SoundQApi(session,f.client);val a=session.capture()!!
            val retired=api.revokeLogout()
            assertFalse(session.current(a));assertNull(session.capture())
            session.accept(session.beginIntent(),SecretTokens("b","br","B"))
            api.finishLogout(retired)
            assertEquals("B",session.capture()!!.accountId);assertEquals("B",store.tokens!!.accountId)
            assertEquals(0,f.server.requestCount)
        }
    }
    @Test fun localRevokeDoesNotWaitForHeldStoreSave() {
        val entered=CountDownLatch(1);val release=CountDownLatch(1)
        val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),object:SessionStore {
            override fun load(endpoint:ApiEndpoint):SecretTokens?=null
            override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){entered.countDown();check(release.await(3,TimeUnit.SECONDS))}
            override fun clear(){}
        })
        val pool=Executors.newSingleThreadExecutor()
        try {
            val intent=session.beginIntent()
            val save=pool.submit<Boolean>{session.accept(intent,SecretTokens("a","r","A"))}
            assertTrue(entered.await(2,TimeUnit.SECONDS))
            session.revoke()
            assertFalse(session.owns(intent));assertNull(session.capture())
            release.countDown();assertFalse(save.get(3,TimeUnit.SECONDS))
            assertTrue(session.state.value is AuthState.SignedOut)
        } finally {release.countDown();pool.shutdownNow();pool.awaitTermination(3,TimeUnit.SECONDS)}
    }
    @Test fun restoreCannotReloadRetiredDurableBytesWhileCleanupIsQueued() {
        HttpsFixture().use {f ->
            val store=MemoryStore();val session=AccountSession(f.endpoint,store)
            session.accept(session.beginIntent(),SecretTokens("a","ar","A"))
            val api=SoundQApi(session,f.client);val retired=api.revokeLogout()
            f.reply(f.auth("A","rotated"))
            assertFalse(api.restore());assertNull(session.capture());assertEquals(0,f.server.requestCount)
            api.finishLogout(retired);assertNull(store.tokens)
        }
    }
    @Test fun remoteLogoutUsesCapturedAccessAfterLocalRevocation() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","ar","A"))
            val api=SoundQApi(session,f.client);val retired=api.revokeLogout()
            assertNull(session.capture());f.reply("",204);api.finishLogout(retired)
            val request=f.server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("/api/v1/auth/logout",request.url.encodedPath);assertEquals("Bearer a",request.headers["Authorization"])
        }
    }
}
