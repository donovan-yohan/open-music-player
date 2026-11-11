package com.soundq.android.data

import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger

/** Real session/store/TLS boundary. Run alongside the retained local-only admission controls. */
class DeviceOnlyOnlineRestoreTest {
    private class Store : SessionStore {
        var saved:SecretTokens?=SecretTokens("old","old-r","A")
        var reads=0;var writes=0;var clears=0;var failSave=false
        override fun load(endpoint:ApiEndpoint)=saved.also {reads++}
        override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){writes++;if(failSave)throw java.io.IOException();saved=tokens}
        override fun clear(){clears++;saved=null}
    }
    @Test fun onlyExplicitCurrentDeviceIntentRestoresSameSavedAccountWithoutClearing() {
        HttpsFixture().use {f ->
            val store=Store();val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client)
            assertTrue(session.useDeviceDownloads());val local=session.capture()!!
            assertFalse(api.restore());assertEquals(0,f.server.requestCount)
            val ticket=session.claimOnlineRestore(local)!!
            assertNull(session.claimOnlineRestore(local));assertTrue(session.current(local))
            assertFalse(api.restore());assertEquals(1,store.reads)
            f.reply(f.auth("A","rotated"))
            assertTrue(api.restoreOnline(ticket));assertEquals(AuthState.SignedIn("A"),session.state.value)
            assertFalse(session.current(local));assertTrue(session.remoteCurrent(session.capture()!!))
            assertFalse(api.restoreOnline(ticket));assertNull(session.claimOnlineRestore(local))
            assertEquals(1,f.server.requestCount);assertEquals(2,store.reads);assertEquals(1,store.writes);assertEquals(0,store.clears)
            assertEquals("rotated",store.saved!!.access)
        }
    }
    @Test fun staleQueuedIntentCannotDecodeOrDispatchAcrossAccountABARevocationOrLocalLock() {
        for(change in listOf("same","other","logout","lock")) HttpsFixture().use {f ->
            val store=Store();val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client)
            assertTrue(session.useDeviceDownloads());val local=session.capture()!!;val ticket=session.claimOnlineRestore(local)!!
            when(change) {
                "same","other"->assertTrue(session.accept(session.beginIntent(),SecretTokens("new","new-r",if(change=="same")"A" else "B")))
                "logout"->session.revoke()
                "lock"->assertTrue(session.lockLocal())
            }
            assertFalse(api.restoreOnline(ticket));session.abandonOnlineRestore(ticket)
            assertEquals(1,store.reads);assertEquals(0,f.server.requestCount);assertEquals(0,store.clears)
            if(change=="lock") {
                assertEquals(AuthState.LocalLocked,session.state.value)
                assertTrue(session.completeLocalUnlock(session.localUnlockTicket()!!))
                assertEquals(AuthState.DeviceOnly("A"),session.state.value)
                assertFalse(api.restore());assertEquals(0,f.server.requestCount)
                assertNotNull(session.claimOnlineRestore(session.capture()!!))
            } else if(change!="logout")assertEquals(if(change=="same")"A" else "B",session.capture()!!.accountId)
        }
    }
    @Test fun staleIntentCannotRebindAfterReturningToDeviceModeForSameOrOtherAccount() {
        for(account in listOf("A","B")) HttpsFixture().use {f ->
            val store=Store();val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client)
            assertTrue(session.useDeviceDownloads());val original=session.capture()!!;val stale=session.claimOnlineRestore(original)!!
            assertTrue(session.accept(session.beginIntent(),SecretTokens("replacement","replacement-r",account)))
            session.failure(session.version(),SafeFailure.Reason.Network)
            assertTrue(session.useDeviceDownloads());val current=session.capture()!!;assertEquals(account,current.accountId)
            f.reply(f.auth(account,"fresh"))
            assertFalse("a retired click must not restore a later local-mode visit",api.restoreOnline(stale))
            assertEquals(AuthState.DeviceOnly(account),session.state.value);assertEquals(0,f.server.requestCount)
            val fresh=session.claimOnlineRestore(current)!!;assertTrue(api.restoreOnline(fresh));assertEquals(1,f.server.requestCount)
            assertEquals(AuthState.SignedIn(account),session.state.value);assertEquals(0,store.clears)
        }
    }
    @Test fun unenteredCancelledReservationCannotReplayAndFreshIntentWorks() {
        HttpsFixture().use {f ->
            val store=Store();val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client)
            assertTrue(session.useDeviceDownloads());val local=session.capture()!!
            val cancelled=session.claimOnlineRestore(local)!!;session.abandonOnlineRestore(cancelled)
            assertFalse(api.restoreOnline(cancelled));assertTrue(session.current(local));assertEquals(1,store.reads)
            val fresh=session.claimOnlineRestore(local)!!
            session.abandonOnlineRestore(cancelled) // old completion cannot release newer reservation
            assertNull(session.claimOnlineRestore(local))
            f.reply(f.auth("A","fresh"));assertTrue(api.restoreOnline(fresh));assertEquals(1,f.server.requestCount)
        }
    }
    @Test fun heldRefreshCannotReplayAndLateSameOrOtherAccountReplacementCannotPublish() {
        for(replacement in listOf<String?>(null,"A","B")) HttpsFixture().use {f ->
            val store=Store();val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client)
            assertTrue(session.useDeviceDownloads());val local=session.capture()!!;val ticket=session.claimOnlineRestore(local)!!
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().body(f.auth("A","rotated")).build()
            }}
            try {
                val work=pool.submit<Boolean>{api.restoreOnline(ticket)};assertTrue(entered.await(3,TimeUnit.SECONDS))
                assertFalse(api.restoreOnline(ticket));assertNull(session.claimOnlineRestore(local))
                session.abandonOnlineRestore(ticket) // cancellation after entry cannot release exchange ownership
                assertFalse(api.restoreOnline(ticket))
                if(replacement!=null)session.accept(session.beginIntent(),SecretTokens("replacement","replacement-r",replacement))
                release.countDown();assertEquals(replacement==null,work.get(3,TimeUnit.SECONDS))
                assertEquals(AuthState.SignedIn(replacement ?: "A"),session.state.value)
                assertEquals(if(replacement==null)"rotated" else "replacement",store.saved!!.access)
                assertEquals(1,f.server.requestCount);assertEquals(1,store.writes);assertEquals(0,store.clears)
            } finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(3,TimeUnit.SECONDS))}
        }
    }
    @Test fun revokedHeldOnlineExitCannotResurrectOrSaveAfterLogout() {
        HttpsFixture().use {f ->
            val store=Store();val original=store.saved;val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client)
            assertTrue(session.useDeviceDownloads());val ticket=session.claimOnlineRestore(session.capture()!!)!!
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().body(f.auth("A","late")).build()
            }}
            try {
                val work=pool.submit<Boolean>{api.restoreOnline(ticket)};assertTrue(entered.await(3,TimeUnit.SECONDS))
                session.revoke();release.countDown();assertFalse(work.get(3,TimeUnit.SECONDS))
                assertTrue(session.state.value is AuthState.SignedOut);assertNull(session.capture());assertFalse(api.restoreOnline(ticket))
                assertSame(original,store.saved);assertEquals(0,store.writes);assertEquals(0,store.clears);assertEquals(1,f.server.requestCount)
            } finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(3,TimeUnit.SECONDS))}
        }
    }
    @Test fun refusedRefreshPreservesSavedBytesAndExplicitLocalRecoveryWithoutAutomaticReplay() {
        HttpsFixture().use {f ->
            val store=Store();val original=store.saved;val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client)
            assertTrue(session.useDeviceDownloads());val ticket=session.claimOnlineRestore(session.capture()!!)!!
            f.server.enqueue(MockResponse.Builder().code(401).build())
            assertFalse(api.restoreOnline(ticket));assertTrue(session.state.value is AuthState.SignedOut)
            assertSame(original,store.saved);assertEquals(0,store.writes);assertEquals(0,store.clears)
            assertFalse(api.restoreOnline(ticket));assertTrue(session.useDeviceDownloads());assertFalse(api.restore())
            assertEquals(AuthState.DeviceOnly("A"),session.state.value);assertEquals(1,f.server.requestCount)
            f.reply(f.auth("A","recovered"));assertTrue(api.restoreOnline(session.claimOnlineRestore(session.capture()!!)!!))
            assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun explicitRestoreRetainsConsumedRotationSaveAndLockGuards() {
        HttpsFixture().use {f ->
            val store=Store();val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client)
            assertTrue(session.useDeviceDownloads());store.failSave=true
            f.reply(f.auth("A","rotated"));assertFalse(api.restoreOnline(session.claimOnlineRestore(session.capture()!!)!!))
            assertTrue(session.state.value is AuthState.SaveRequired);assertNull(session.capture());assertFalse(session.useDeviceDownloads());assertFalse(api.restore())
            store.failSave=false;assertTrue(session.retrySave());assertEquals("rotated",store.saved!!.access);assertEquals(1,f.server.requestCount)
        }
        HttpsFixture().use {f ->
            val store=Store();val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client)
            assertTrue(session.useDeviceDownloads());val ticket=session.claimOnlineRestore(session.capture()!!)!!
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().body(f.auth("A","locked-rotation")).build()
            }}
            try {
                val work=pool.submit<Boolean>{api.restoreOnline(ticket)};assertTrue(entered.await(3,TimeUnit.SECONDS));assertTrue(session.lockLocal())
                release.countDown();work.get(3,TimeUnit.SECONDS)
                assertEquals(AuthState.LocalLocked,session.state.value);assertNull(session.capture());assertEquals("locked-rotation",store.saved!!.access)
                assertTrue(session.completeLocalUnlock(session.localUnlockTicket()!!));assertEquals(AuthState.SignedIn("A"),session.state.value)
                assertEquals(1,f.server.requestCount);assertEquals(0,store.clears)
            } finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(3,TimeUnit.SECONDS))}
        }
    }
    @Test fun lockDuringSavedDecodeCannotArmAutomaticRestoreAfterUnlock() {
        HttpsFixture().use {f ->
            val backing=Store();val reads=AtomicInteger();val entered=CountDownLatch(1);val release=CountDownLatch(1)
            val store=object:SessionStore {
                override fun load(endpoint:ApiEndpoint):SecretTokens? {
                    if(reads.incrementAndGet()==2){entered.countDown();check(release.await(5,TimeUnit.SECONDS))}
                    return backing.load(endpoint)
                }
                override fun save(endpoint:ApiEndpoint,tokens:SecretTokens)=backing.save(endpoint,tokens)
                override fun clear()=backing.clear()
            }
            val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client);val pool=Executors.newSingleThreadExecutor()
            assertTrue(session.useDeviceDownloads());val ticket=session.claimOnlineRestore(session.capture()!!)!!
            try {
                val work=pool.submit<Boolean>{api.restoreOnline(ticket)};assertTrue(entered.await(3,TimeUnit.SECONDS));assertTrue(session.lockLocal())
                release.countDown();assertFalse(work.get(3,TimeUnit.SECONDS));assertEquals(AuthState.LocalLocked,session.state.value)
                assertTrue(session.completeLocalUnlock(session.localUnlockTicket()!!))
                assertTrue("unlock must not expose the startup auto-restore state",session.state.value is AuthState.SignedOut)
                assertTrue(session.useDeviceDownloads());assertFalse(api.restore());assertEquals(0,f.server.requestCount)
                assertEquals(0,backing.writes);assertEquals(0,backing.clears)
            } finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(3,TimeUnit.SECONDS))}
        }
    }
    @Test fun lockAfterSavedDecodeButBeforeExchangeCannotExposeRemoteAuthorityOnUnlock() {
        HttpsFixture().use {f ->
            val store=Store();val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client)
            assertTrue(session.useDeviceDownloads());val ticket=session.claimOnlineRestore(session.capture()!!)!!
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            try {
                val work=pool.submit<Boolean>{session.restoreOnline(ticket) {scope ->
                    assertTrue(session.remoteCurrent(scope));entered.countDown();check(release.await(5,TimeUnit.SECONDS))
                    session.refresh(scope){error("retired exchange must not run")}
                }}
                assertTrue(entered.await(3,TimeUnit.SECONDS));assertTrue(session.lockLocal())
                assertTrue(session.completeLocalUnlock(session.localUnlockTicket()!!));assertTrue(session.state.value is AuthState.SignedOut)
                assertNull("unlock must not expose loaded-but-undispatched saved tokens",session.capture())
                release.countDown();assertFalse(work.get(3,TimeUnit.SECONDS));assertEquals(0,f.server.requestCount)
                assertTrue(session.useDeviceDownloads());f.reply(f.auth("A","fresh"))
                assertTrue(api.restoreOnline(session.claimOnlineRestore(session.capture()!!)!!));assertEquals(1,f.server.requestCount)
            } finally {release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(3,TimeUnit.SECONDS))}
        }
    }
    @Test fun changedSavedAccountIsRejectedBeforeRemoteDispatchWithoutWritingOrClearing() {
        HttpsFixture().use {f ->
            val store=Store();val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client)
            assertTrue(session.useDeviceDownloads());val ticket=session.claimOnlineRestore(session.capture()!!)!!
            store.saved=SecretTokens("foreign","foreign-r","B")
            f.reply(f.auth("B","foreign-rotation")) // mutation control: unintended dispatch completes instead of timing out
            assertFalse(api.restoreOnline(ticket));assertNull(session.capture());assertEquals(0,f.server.requestCount)
            assertEquals("B",store.saved!!.accountId);assertEquals(0,store.writes);assertEquals(0,store.clears)
        }
    }
}
