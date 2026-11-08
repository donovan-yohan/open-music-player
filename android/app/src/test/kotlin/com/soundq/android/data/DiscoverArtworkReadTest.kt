package com.soundq.android.data

import com.soundq.android.data.discovery.SourceArtworkRead
import org.junit.Assert.*
import org.junit.Test

class DiscoverArtworkReadTest {
    @Test fun artworkUsesOnlyCapturedHttpsWithoutCredentialsRedirectsOrStalePublication() {
        HttpsFixture().use {f->
            val url=f.server.url("/cover").toString()
            val credentialed=f.client.newBuilder().addInterceptor {chain->chain.proceed(chain.request().newBuilder().header("Authorization","must-not-leak").header("Cookie","must-not-leak").build())}.build()
            SourceArtworkRead(credentialed).use {read->
                f.reply("real fixture image bytes")
                val bytes=read.load(url){true}!!
                assertEquals("real fixture image bytes",bytes.toString(Charsets.UTF_8))
                val request=f.server.takeRequest();assertEquals("GET",request.method)
                assertNull(request.headers["Authorization"]);assertNull(request.headers["Cookie"])
                assertNull(read.load(url){false});assertEquals(1,f.server.requestCount)
                f.reply("",302);assertNull(read.load(url){true});assertEquals(2,f.server.requestCount)
                assertNull(read.load("http://images.example/cover"){true})
                read.close();assertNull(read.load(url){true});assertEquals(2,f.server.requestCount)
            }
        }
    }
    @Test fun heldArtworkCannotPublishAfterItsAcceptedSourceRetires() {
        HttpsFixture().use {f->
            val entered=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1)
            val valid=java.util.concurrent.atomic.AtomicBoolean(true)
            val pool=java.util.concurrent.Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:mockwebserver3.Dispatcher() {
                override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                    entered.countDown();check(release.await(5,java.util.concurrent.TimeUnit.SECONDS))
                    return mockwebserver3.MockResponse.Builder().code(200).body("held artwork").build()
                }
            }
            SourceArtworkRead(f.client).use {read->
                try {
                    val work=pool.submit<ByteArray?> {read.load(f.server.url("/cover").toString()){valid.get()}}
                    assertTrue(entered.await(3,java.util.concurrent.TimeUnit.SECONDS))
                    valid.set(false);release.countDown()
                    assertNull(work.get(5,java.util.concurrent.TimeUnit.SECONDS));assertEquals(1,f.server.requestCount)
                } finally {release.countDown();pool.shutdownNow()}
            }
        }
    }
    @Test fun oversizedArtworkIsRefused() {
        HttpsFixture().use {f->
            SourceArtworkRead(f.client).use {read->
                f.reply("x".repeat(SourceArtworkRead.MAX_BYTES+1))
                assertNull(read.load(f.server.url("/cover").toString()){true})
            }
        }
    }
}
