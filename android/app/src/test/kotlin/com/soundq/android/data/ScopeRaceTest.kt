package com.soundq.android.data

import mockwebserver3.*
import okhttp3.*
import okhttp3.tls.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*

internal class HttpsFixture : AutoCloseable {
    val server=MockWebServer()
    private val cert=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
    private val trust=HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
    val client:OkHttpClient=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
    init {server.useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory());server.start()}
    val endpoint get()=ApiEndpoint.parse(server.url("/api/v1").toString())
    fun reply(body:String,code:Int=200) {val response=MockResponse.Builder().code(code);if(code!=204)response.body(body);server.enqueue(response.build())}
    fun auth(account:String="fixture",access:String="a") = """{"accessToken":"$access","refreshToken":"r-$access","user":{"id":"$account"}}"""
    override fun close() {server.close();client.connectionPool.evictAll();client.dispatcher.executorService.shutdown()}
}
class ScopeRaceTest {
    @Test fun acceptedTokenSaveRetryNeverSendsSecondLogin() {
        HttpsFixture().use { f ->
            val store=MemoryStore().apply {fail=true};val session=AccountSession(f.endpoint,store);val api=SoundQApi(session,f.client)
            f.reply(f.auth());assertFalse(api.authenticate("fixture@example.test","synthetic-password"))
            assertTrue(session.state.value is AuthState.SaveRequired)
            store.fail=false
            // Retry entry must reuse the accepted response, not create another account/login.
            assertTrue(api.authenticate("fixture@example.test","synthetic-password"))
            assertEquals(1,f.server.requestCount);assertEquals("fixture",session.capture()?.accountId)
        }
    }
    @Test fun refreshIsSingleFlightAndLateRotationCannotRetireReplacement() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore())
        session.accept(session.beginIntent(),SecretTokens("a","r","A"));val scope=session.capture()!!
        val entered=CountDownLatch(1);val release=CountDownLatch(1);val calls=java.util.concurrent.atomic.AtomicInteger()
        val pool=Executors.newFixedThreadPool(2)
        try {
            val exchange:(String)->SecretTokens={calls.incrementAndGet();entered.countDown();release.await();SecretTokens("a2","r2","A")}
            val first=pool.submit<Boolean>{session.refresh(scope,"a",exchange)}
            assertTrue(entered.await(2,TimeUnit.SECONDS))
            val second=pool.submit<Boolean>{session.refresh(scope,"a",exchange)}
            session.accept(session.beginIntent(),SecretTokens("b","br","B"));release.countDown()
            assertFalse(first.get(2,TimeUnit.SECONDS));assertFalse(second.get(2,TimeUnit.SECONDS))
            assertEquals(1,calls.get());assertEquals("B",session.capture()?.accountId)
        } finally {release.countDown();pool.shutdownNow()}
    }
    @Test fun redirectDoesNotLeakBearerAndUncertainLikeIsNotReplayed() {
        HttpsFixture().use { f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","fixture"))
            val api=SoundQApi(session,f.client)
            f.server.enqueue(MockResponse.Builder().code(302).addHeader("Location","https://elsewhere.invalid/api/v1/library").build())
            val e=runCatching {api.library(session.capture()!!,LibraryQuery(),0)}.exceptionOrNull() as SafeFailure
            assertEquals(SafeFailure.Reason.Endpoint,e.reason)
            f.reply("{}",503)
            val like=runCatching {api.like(session.capture()!!,TrackId(7),true)}.exceptionOrNull() as SafeFailure
            assertEquals(SafeFailure.Reason.Uncertain,like.reason);assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun heldDescriptorCannotPublishAfterLogout() {
        HttpsFixture().use { f ->
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                entered.countDown();release.await(3,TimeUnit.SECONDS)
                return MockResponse.Builder().body("""{"urls":[{"trackId":7,"url":"https://media.invalid/object?signature=synthetic","expiresAt":"2030-01-01T00:00:00Z"}]}""").build()
            }}
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val scope=session.capture()!!;val pool=Executors.newSingleThreadExecutor()
            try {
                val result=pool.submit<SafeFailure.Reason?> {try {api.descriptor(scope,TrackId(7));null}catch(e:SafeFailure){e.reason}}
                assertTrue(entered.await(2,TimeUnit.SECONDS));session.retire();release.countDown()
                assertEquals(SafeFailure.Reason.Retired,result.get(3,TimeUnit.SECONDS))
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
}
