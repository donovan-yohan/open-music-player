package com.soundq.android.playback

import org.junit.Assert.*
import org.junit.Test
import com.soundq.android.data.*
import mockwebserver3.*
import okhttp3.*
import okhttp3.tls.*
import java.util.concurrent.*

class AuthTransportRaceTest {
    @Test fun heldLoginAfterLogoutCannotAdoptAndHeldLibraryCannotPublish() {
        com.soundq.android.data.HttpsFixture().use {f ->
            val loginEntered=CountDownLatch(1);val loginRelease=CountDownLatch(1)
            val libraryEntered=CountDownLatch(1);val libraryRelease=CountDownLatch(1)
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath.endsWith("login")){loginEntered.countDown();loginRelease.await(3,TimeUnit.SECONDS);return MockResponse.Builder().body(f.auth("A")).build()}
                libraryEntered.countDown();libraryRelease.await(3,TimeUnit.SECONDS)
                return MockResponse.Builder().body("""{"tracks":[{"id":1,"title":"Private A"}],"total":1,"limit":20,"offset":0}""").build()
            }}
            val session=AccountSession(f.endpoint,com.soundq.android.data.MemoryStore());val api=SoundQApi(session,f.client)
            val pool=Executors.newSingleThreadExecutor()
            try {
                val login=pool.submit<Boolean>{api.authenticate("a@example.test","synthetic-password")}
                assertTrue(loginEntered.await(2,TimeUnit.SECONDS));session.retire();loginRelease.countDown()
                assertFalse(login.get(3,TimeUnit.SECONDS));assertNull(session.capture())
                session.accept(session.beginIntent(),SecretTokens("a","r","A"));val scope=session.capture()!!
                val page=pool.submit<SafeFailure.Reason?>{try{api.library(scope,LibraryQuery(),0);null}catch(e:SafeFailure){e.reason}}
                assertTrue(libraryEntered.await(2,TimeUnit.SECONDS));session.accept(session.beginIntent(),SecretTokens("b","br","B"));libraryRelease.countDown()
                assertEquals(SafeFailure.Reason.Retired,page.get(3,TimeUnit.SECONDS));assertEquals("B",session.capture()?.accountId)
            }finally {loginRelease.countDown();libraryRelease.countDown();pool.shutdownNow()}
        }
    }
    @Test fun actual401RequestsShareOneRefreshRotation() {
        com.soundq.android.data.HttpsFixture().use {f ->
            val bothExpired=CountDownLatch(2);val refreshEntered=CountDownLatch(1);val release=CountDownLatch(1)
            val rotations=java.util.concurrent.atomic.AtomicInteger()
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath.endsWith("refresh")) {
                    rotations.incrementAndGet();refreshEntered.countDown();release.await(3,TimeUnit.SECONDS)
                    assertEquals("r-a",kotlinx.serialization.json.Json.parseToJsonElement(request.body!!.utf8()).let {(it as kotlinx.serialization.json.JsonObject)["refreshToken"].toString().trim('"')})
                    return MockResponse.Builder().body(f.auth("A","a2")).build()
                }
                if(request.headers["Authorization"]=="Bearer a"){bothExpired.countDown();bothExpired.await(3,TimeUnit.SECONDS);return MockResponse.Builder().code(401).body("{}").build()}
                return MockResponse.Builder().body("""{"tracks":[],"total":0,"limit":20,"offset":0}""").build()
            }}
            val session=AccountSession(f.endpoint,com.soundq.android.data.MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r-a","A"));val scope=session.capture()!!
            val api=SoundQApi(session,f.client);val pool=Executors.newFixedThreadPool(2)
            try {
                val first=pool.submit<LibraryPage>{api.library(scope,LibraryQuery(),0)};val second=pool.submit<LibraryPage>{api.library(scope,LibraryQuery(),0)}
                assertTrue(refreshEntered.await(3,TimeUnit.SECONDS));release.countDown()
                assertEquals(0,first.get(4,TimeUnit.SECONDS).total);assertEquals(0,second.get(4,TimeUnit.SECONDS).total);assertEquals(1,rotations.get())
            }finally {release.countDown();pool.shutdownNow()}
        }
    }
}
