package com.soundq.android.localunlock

import com.soundq.android.data.*
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.RecordedRequest
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import javax.crypto.KeyGenerator

/** The lifecycle entry point must lock after rotation adoption, not just during the HTTP exchange. */
class LocalUnlockPersistenceTest {
    private class SaveGate(val fail:Boolean=false) {
        val entered=CountDownLatch(1)
        val release=CountDownLatch(1)
    }
    private class Fixture:AutoCloseable {
        val tls=HttpsFixture()
        val dir=Files.createTempDirectory(File(requireNotNull(System.getenv("TMPDIR"))).toPath(),"unlock-save").toFile()
        private val key=KeyGenerator.getInstance("AES").apply {init(256)}.generateKey()
        val record=dir.resolve("session")
        val encrypted=EncryptedSessionStore(record){key}
        val gate=AtomicReference<SaveGate?>()
        val writes=AtomicInteger()
        val adopted=AtomicReference<SecretTokens?>()
        val store=object:SessionStore {
            override fun load(endpoint:ApiEndpoint)=encrypted.load(endpoint)
            override fun save(endpoint:ApiEndpoint,tokens:SecretTokens) {
                writes.incrementAndGet()
                gate.getAndSet(null)?.let {
                    adopted.set(tokens);it.entered.countDown()
                    check(it.release.await(10,TimeUnit.SECONDS))
                    if(it.fail)throw IOException("fixture secure-save failure")
                }
                encrypted.save(endpoint,tokens)
            }
            override fun clear()=encrypted.clear()
        }
        val session=AccountSession(tls.endpoint,store)
        val api=SoundQApi(session,tls.client)
        val unlock=LocalUnlock(dir.resolve("local-unlock"),session)
        val pool=Executors.newSingleThreadExecutor()
        init {
            assertTrue(session.accept(session.beginIntent(),SecretTokens("old","old-refresh","A")))
            unlock.loadBeforeRestore()
            assertTrue(unlock.complete(unlock.requestEnrollment(true)!!,true){true})
            tls.server.dispatcher=object:Dispatcher() {
                override fun dispatch(request:RecordedRequest):MockResponse = when(request.url.encodedPath) {
                    "/api/v1/auth/refresh" -> {
                        assertEquals("POST",request.method)
                        assertEquals("{\"refreshToken\":\"old-refresh\"}",request.body!!.utf8())
                        MockResponse.Builder().body(tls.auth("A","rotated")).build()
                    }
                    "/api/v1/library" -> if(request.headers["Authorization"]=="Bearer old")MockResponse.Builder().code(401).build()
                        else MockResponse.Builder().body("""{"tracks":[],"total":0,"limit":20,"offset":0}""").build()
                    else -> error("unexpected fixture path")
                }
            }
        }
        fun startRotation(scope:AccountScope)=pool.submit<Boolean>{runCatching {api.library(scope,LibraryQuery(),0)}.isSuccess}
        fun awaitAdoption(g:SaveGate) {
            assertTrue("rotated credentials reached SessionStore.save",g.entered.await(5,TimeUnit.SECONDS))
            assertEquals("rotated",adopted.get()?.access)
            assertNull("consumed credentials must already be withdrawn",session.capture())
            assertEquals(2,tls.server.requestCount)
        }
        fun assertLocked(scope:AccountScope) {
            assertEquals(AuthState.LocalLocked,session.state.value)
            assertNull(session.capture());assertFalse(session.current(scope));assertFalse(session.remoteCurrent(scope))
            assertEquals(SafeFailure.Reason.Retired,(runCatching {api.library(scope,LibraryQuery(),0)}.exceptionOrNull() as SafeFailure).reason)
            assertFalse(api.authenticate("fixture@example.test","synthetic-password"))
            assertEquals("no dispatch from retained scope or password callback",2,tls.server.requestCount)
        }
        fun unlockAndRead(scope:AccountScope) {
            assertLocked(scope)
            val canceled=unlock.requestUnlock()!!;unlock.cancel()
            assertFalse(unlock.complete(canceled,true){true})
            val fresh=unlock.requestUnlock()!!
            assertTrue(unlock.complete(fresh,true){true})
            assertFalse("device-auth ticket is one-use",unlock.complete(fresh,true){true})
            assertEquals(AuthState.SignedIn("A"),session.state.value)
            assertFalse(session.current(scope));assertTrue(session.resumesLocal(scope))
            assertEquals("rotated",session.access(session.capture()!!))
            assertEquals("r-rotated",EncryptedSessionStore(record){key}.load(tls.endpoint)?.refresh)
            assertEquals(0,api.library(session.capture()!!,LibraryQuery(),0).total)
            assertEquals(3,tls.server.requestCount)
            val paths=(1..3).map {tls.server.takeRequest(2,TimeUnit.SECONDS)!!.url.encodedPath}
            assertEquals(listOf("/api/v1/library","/api/v1/auth/refresh","/api/v1/library"),paths)
        }
        override fun close() {
            gate.getAndSet(null)?.release?.countDown()
            pool.shutdownNow();check(pool.awaitTermination(5,TimeUnit.SECONDS))
            tls.close();dir.deleteRecursively()
        }
    }
    @Test fun saveFailureWhileLifecycleLockedRetainsRotationForLockedRetry() {
        Fixture().use {f ->
            val scope=f.session.capture()!!;val failed=SaveGate(fail=true);f.gate.set(failed)
            val request=f.startRotation(scope)
            try {
                f.awaitAdoption(failed);assertTrue(f.unlock.lock());f.assertLocked(scope)
                failed.release.countDown();assertFalse(request.get(5,TimeUnit.SECONDS))
                f.assertLocked(scope);assertEquals("old-refresh",f.encrypted.load(f.tls.endpoint)?.refresh)
                assertTrue(f.session.retrySave());assertEquals(3,f.writes.get())
                f.unlockAndRead(scope)
            }finally {failed.release.countDown();request.get(5,TimeUnit.SECONDS)}
        }
    }
    @Test fun sessionOwnerAlsoAdmitsDirectLocalLockDuringSaveRequiredRecovery() {
        Fixture().use {f ->
            val scope=f.session.capture()!!;val failed=SaveGate(fail=true);f.gate.set(failed)
            val request=f.startRotation(scope)
            try {
                f.awaitAdoption(failed);failed.release.countDown();assertFalse(request.get(5,TimeUnit.SECONDS))
                assertTrue(f.session.state.value is AuthState.SaveRequired)
                assertTrue(f.session.lockLocal());f.assertLocked(scope)
                assertTrue(f.session.retrySave());f.unlockAndRead(scope)
            }finally {failed.release.countDown();request.get(5,TimeUnit.SECONDS)}
        }
    }
    @Test fun lifecycleLockAfterRotationSaveFailureKeepsRetryLockedWithoutReplayingConsumedRefresh() {
        Fixture().use {f ->
            val scope=f.session.capture()!!;val failed=SaveGate(fail=true);f.gate.set(failed)
            val request=f.startRotation(scope)
            try {
                f.awaitAdoption(failed);failed.release.countDown()
                assertFalse(request.get(5,TimeUnit.SECONDS))
                assertTrue(f.session.state.value is AuthState.SaveRequired)
                assertNull(f.session.capture());assertFalse(f.session.remoteCurrent(scope))
                assertEquals("old-refresh",f.encrypted.load(f.tls.endpoint)?.refresh)
                assertTrue("SC-01: SaveRequired is still an enrolled installed session",f.unlock.lock())
                f.assertLocked(scope)
                val retryGate=SaveGate();f.gate.set(retryGate)
                val retry=f.pool.submit<Boolean>{f.session.retrySave()}
                try {
                    f.awaitAdoption(retryGate);f.assertLocked(scope);retryGate.release.countDown()
                    assertTrue(retry.get(5,TimeUnit.SECONDS))
                    assertEquals(3,f.writes.get())
                    f.unlockAndRead(scope)
                }finally {retryGate.release.countDown();retry.get(5,TimeUnit.SECONDS)}
            }finally {failed.release.countDown();request.get(5,TimeUnit.SECONDS)}
        }
    }
    @Test fun retiredEnrollmentAndOldSaveCannotRebindSameAccountReplacementOrOldPrompt() {
        retirementControl("A")
    }
    @Test fun retiredEnrollmentAndOldSaveCannotRebindDifferentAccountReplacementOrOldPrompt() {
        retirementControl("B")
    }
    private fun retirementControl(account:String) {
        Fixture().use {f ->
            val scope=f.session.capture()!!;val gate=SaveGate();f.gate.set(gate)
            val request=f.startRotation(scope)
            try {
                f.awaitAdoption(gate);assertTrue(f.unlock.lock())
                val prompt=f.unlock.requestUnlock()!!
                val retired=f.session.revoke();f.unlock.retire(retired.intent)
                val replacement=f.session.beginIntent()
                assertFalse(f.unlock.complete(prompt,true){true})
                gate.release.countDown();assertFalse(request.get(5,TimeUnit.SECONDS))
                assertNull(f.session.capture());assertFalse(f.session.retrySave())
                assertTrue(f.session.accept(replacement,SecretTokens("replacement","replacement-refresh",account)))
                assertFalse(f.unlock.state.value.enrolled);assertFalse(f.unlock.lock())
                assertFalse(f.session.current(scope));assertFalse(f.session.resumesLocal(scope))
                assertEquals(AuthState.SignedIn(account),f.session.state.value)
                assertEquals("replacement-refresh",f.encrypted.load(f.tls.endpoint)?.refresh)
                assertFalse(f.unlock.complete(prompt,true){true});assertEquals(2,f.tls.server.requestCount)
            }finally {gate.release.countDown();request.get(5,TimeUnit.SECONDS)}
        }
    }
    @Test fun enrollmentIdentityCannotLockAnotherAccountsPendingSave() {
        Fixture().use {f ->
            val replacement=f.session.beginIntent();val gate=SaveGate();f.gate.set(gate)
            val save=f.pool.submit<Boolean>{f.session.accept(replacement,SecretTokens("other","other-refresh","B"))}
            try {
                assertTrue(gate.entered.await(5,TimeUnit.SECONDS));assertNull(f.session.capture())
                assertFalse(f.unlock.lock());assertEquals(AuthState.Pending,f.session.state.value)
                gate.release.countDown();assertTrue(save.get(5,TimeUnit.SECONDS))
                assertFalse(f.unlock.lock());assertEquals(AuthState.SignedIn("B"),f.session.state.value)
                assertEquals("other-refresh",f.encrypted.load(f.tls.endpoint)?.refresh)
                assertEquals(0,f.tls.server.requestCount)
            }finally {gate.release.countDown();save.get(5,TimeUnit.SECONDS)}
        }
    }
    @Test fun lifecycleLockDuringAdoptedRotationSaveStaysLockedAfterPersistenceUntilFreshDeviceAuth() {
        Fixture().use {f ->
            val scope=f.session.capture()!!;val gate=SaveGate();f.gate.set(gate)
            val request=f.startRotation(scope)
            try {
                f.awaitAdoption(gate)
                assertEquals(AuthState.SignedIn("A"),f.session.state.value)
                assertTrue("SC-01: enrolled lifecycle lock must admit adopted pending credentials",f.unlock.lock())
                f.assertLocked(scope)
                val premature=f.unlock.requestUnlock()!!
                assertFalse("in-flight rotation cannot be unlocked",f.unlock.complete(premature,true){true})
                gate.release.countDown()
                assertFalse(request.get(5,TimeUnit.SECONDS))
                assertEquals(2,f.writes.get())
                f.unlockAndRead(scope)
            }finally {gate.release.countDown();request.get(5,TimeUnit.SECONDS)}
        }
    }
}
