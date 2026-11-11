package com.soundq.android.data

import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import javax.crypto.KeyGenerator

class RestoreOwnershipTest {
    @Test fun duplicateRestoreSharesAdmissionBeforeEncryptedLoadAndPersistsRotation() {
        HttpsFixture().use { f ->
            val dir=Files.createTempDirectory("soundq-restore-owner").toFile()
            val release=CountDownLatch(1);val pool=Executors.newFixedThreadPool(2)
            try {
                val key=KeyGenerator.getInstance("AES").apply {init(256)}.generateKey()
                val encrypted=EncryptedSessionStore(dir.resolve("session")){key}
                encrypted.save(f.endpoint,SecretTokens("old","old-r","A"))
                val loads=AtomicInteger()
                val store=object:SessionStore {
                    override fun load(endpoint:ApiEndpoint)=encrypted.load(endpoint).also {loads.incrementAndGet()}
                    override fun save(endpoint:ApiEndpoint,tokens:SecretTokens)=encrypted.save(endpoint,tokens)
                    override fun clear()=encrypted.clear()
                }
                val session=AccountSession(f.endpoint,store)
                session.failure(session.version(),SafeFailure.Reason.Network,true)
                val api=SoundQApi(session,f.client);val entered=CountDownLatch(1)
                f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                    entered.countDown();check(release.await(3,TimeUnit.SECONDS))
                    return MockResponse.Builder().body(f.auth("A","rotated")).build()
                }}
                val first=pool.submit<Boolean>{api.restore()}
                assertTrue(entered.await(2,TimeUnit.SECONDS))
                val thread=AtomicReference<Thread>();val admitted=CountDownLatch(1)
                val second=pool.submit<Boolean>{thread.set(Thread.currentThread());admitted.countDown();api.restore()}
                assertTrue(admitted.await(2,TimeUnit.SECONDS))
                // Positive duplicate admission: both implementations wait on their shared future.
                val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(2)
                while(System.nanoTime()<deadline && thread.get().stackTrace.none {it.className=="java.util.concurrent.CompletableFuture"&&it.methodName=="get"}) Thread.yield()
                assertTrue("second restore must reach its shared completion wait",thread.get().stackTrace.any {it.className=="java.util.concurrent.CompletableFuture"&&it.methodName=="get"})
                val observedLoads=loads.get()
                release.countDown()
                val results=listOf(first.get(3,TimeUnit.SECONDS),second.get(3,TimeUnit.SECONDS))
                assertEquals("one encrypted decode per admitted restore lifetime",1,observedLoads)
                assertEquals(listOf(true,true),results)
                assertTrue(session.state.value is AuthState.SignedIn)
                assertEquals("rotated",session.access(session.capture()!!))
                assertEquals("rotated",encrypted.load(f.endpoint)!!.access)
                assertEquals(1,f.server.requestCount)
            } finally {release.countDown();pool.shutdownNow();pool.awaitTermination(3,TimeUnit.SECONDS);dir.deleteRecursively()}
        }
    }
    @Test fun retiredRestoreCannotPublishAndRefusedRestoreHasNoCapability() {
        for(replace in listOf(false,true)) HttpsFixture().use {f ->
            val store=MemoryStore().apply {tokens=SecretTokens("old","old-r","A")}
            val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client)
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                entered.countDown();check(release.await(3,TimeUnit.SECONDS))
                return if(replace)MockResponse.Builder().body(f.auth("A","rotated")).build() else MockResponse.Builder().code(401).build()
            }}
            try {
                val restore=pool.submit<Boolean>{api.restore()};assertTrue(entered.await(2,TimeUnit.SECONDS))
                if(replace)session.accept(session.beginIntent(),SecretTokens("b","br","B"))
                release.countDown();assertFalse(restore.get(3,TimeUnit.SECONDS))
                if(replace){assertEquals("B",session.capture()!!.accountId);assertEquals("B",store.tokens!!.accountId)}
                else {assertNull(session.capture());assertTrue(session.state.value is AuthState.SignedOut)}
                assertEquals(1,f.server.requestCount)
            } finally {release.countDown();pool.shutdownNow();pool.awaitTermination(3,TimeUnit.SECONDS)}
        }
    }
    @Test fun restoredRotationSaveRetryKeepsSingleExchangeAndNoUsableOldTokens() {
        HttpsFixture().use {f ->
            val store=MemoryStore().apply {tokens=SecretTokens("old","old-r","A");fail=true}
            val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client)
            f.reply(f.auth("A","rotated"))
            assertFalse(api.restore());assertTrue(session.state.value is AuthState.SaveRequired);assertNull(session.capture())
            assertFalse(api.restore());assertEquals(1,f.server.requestCount)
            store.fail=false;assertTrue(session.retrySave())
            assertEquals("rotated",session.access(session.capture()!!));assertEquals("rotated",store.tokens!!.access)
            assertEquals(1,f.server.requestCount)
        }
    }
    @Test fun singleRestoreUsesOrdinaryEncryptedDecoder() {
        HttpsFixture().use {f ->
            val dir=Files.createTempDirectory("soundq-single-restore").toFile()
            try {
                val key=KeyGenerator.getInstance("AES").apply {init(256)}.generateKey()
                val store=EncryptedSessionStore(dir.resolve("session")){key}
                store.save(f.endpoint,SecretTokens("old","old-r","A"))
                val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client)
                f.reply(f.auth("A","rotated"))
                assertTrue(api.restore());assertEquals("rotated",store.load(f.endpoint)!!.access)
                assertEquals("A",session.capture()!!.accountId)
            } finally {dir.deleteRecursively()}
        }
    }
}
