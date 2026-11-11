package com.soundq.android.product.artwork

import com.soundq.android.data.*
import mockwebserver3.*
import okhttp3.*
import okhttp3.tls.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*

/** Real TLS/shared production owner. BitmapFactory is the runner's ImageIO-only boundary. */
class SharedArtworkTest {
    private class Store:SessionStore {
        override fun load(endpoint:ApiEndpoint):SecretTokens?=null
        override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){}
        override fun clear(){}
    }
    private fun png():ByteArray=java.io.ByteArrayOutputStream().also {
        javax.imageio.ImageIO.write(java.awt.image.BufferedImage(8,6,java.awt.image.BufferedImage.TYPE_INT_ARGB),"png",it)
    }.toByteArray()
    private fun await(condition:()->Boolean) {
        val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
        while(!condition()){if(System.nanoTime()>deadline)fail("Shared artwork did not settle");Thread.sleep(2)}
    }
    private class Fixture(val decode:((ByteArray)->android.graphics.Bitmap?)?=null):AutoCloseable {
        val certificate=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val trust=HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val server=MockWebServer().apply {useHttps(HandshakeCertificates.Builder().heldCertificate(certificate).build().sslSocketFactory());start()}
        val client=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
        val session=AccountSession(ApiEndpoint.parse(server.url("/api/v1").toString()),Store())
        val loader:LibraryArtwork
        init {account("A");loader=if(decode==null)LibraryArtwork(session,client) else LibraryArtwork(session,client,decode)}
        fun account(id:String){check(session.accept(session.beginIntent(),SecretTokens("private","private",id)))}
        fun track(path:String="/warm.png")=Track(TrackId(7),"Fixture",artwork=server.url(path).toString())
        fun open(track:Track=track(),current:()->Boolean={true})=loader.open(session.capture(),track,current)
        override fun close(){loader.close();server.close();client.connectionPool.evictAll();client.dispatcher.executorService.shutdownNow()}
    }
    @Test fun warmRevisitHasPixelsBeforeStartAndNoSecondRequest() {
        Fixture().use {f->
            f.server.enqueue(MockResponse.Builder().body(Buffer().write(png())).build())
            val first=f.open();first.start();await {first.bitmap()!=null}
            val pixels=first.bitmap();first.close()
            val returning=f.open()
            assertSame("Warm visit must not begin with fallback",pixels,returning.bitmap())
            assertSame(pixels,returning.state.value)
            returning.start()
            assertEquals(1,f.server.requestCount)
        }
    }
    @Test fun duplicateSubscribersShareDecodeAndClosingOnePreservesOther() {
        val entered=CountDownLatch(1);val release=CountDownLatch(1)
        val decodes=java.util.concurrent.atomic.AtomicInteger()
        Fixture {data->
            decodes.incrementAndGet();entered.countDown()
            while(release.count>0)try {release.await()}catch(_:InterruptedException){}
            decodeLibraryArtwork(data)
        }.use {f->try {
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest)=MockResponse.Builder().body(Buffer().write(png())).build()}
            val one=f.open();one.start();assertTrue(entered.await(5,TimeUnit.SECONDS))
            val two=f.open(f.track().copy(id=TrackId(8)));two.start()
            one.close();release.countDown();await {two.bitmap()!=null}
            assertNull(one.bitmap());assertFalse(one.current())
            assertEquals("Identical source/rendition must share transfer",1,f.server.requestCount)
            assertEquals(1,decodes.get())
        }finally {release.countDown()}}
    }
    @Test fun unrelatedSourcePublishesWhileDecodeHeld() {
        val entered=CountDownLatch(1);val release=CountDownLatch(1)
        val decodes=java.util.concurrent.atomic.AtomicInteger()
        Fixture {data->
            if(decodes.incrementAndGet()==1){entered.countDown();while(release.count>0)try {release.await()}catch(_:InterruptedException){}}
            decodeLibraryArtwork(data)
        }.use {f->try {
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest)=MockResponse.Builder().body(Buffer().write(png())).build()}
            val held=f.open(f.track("/held"));held.start();assertTrue(entered.await(5,TimeUnit.SECONDS))
            val fresh=f.open(f.track("/fresh"));fresh.start();await {fresh.bitmap()!=null}
            assertEquals(1L,release.count);assertNull(held.bitmap());assertEquals(2,f.server.requestCount)
            release.countDown();await {held.bitmap()!=null}
        }finally {release.countDown()}}
    }
    @Test fun unrelatedSourcePublishesWhileTransferHeld() {
        val entered=CountDownLatch(1);val release=CountDownLatch(1)
        Fixture().use {f->try {
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath=="/held"){entered.countDown();release.await()}
                return MockResponse.Builder().body(Buffer().write(png())).build()
            }}
            val held=f.open(f.track("/held"));held.start();assertTrue(entered.await(5,TimeUnit.SECONDS))
            val fresh=f.open(f.track("/fresh"));fresh.start();await {fresh.bitmap()!=null}
            assertEquals(1L,release.count);assertNull(held.bitmap());assertEquals(2,f.server.requestCount)
            release.countDown();await {held.bitmap()!=null}
        }finally {release.countDown()}}
    }
    @Test fun restoredQueueReadsAcknowledgedLibraryWithoutRememberAndAccountAbaCannotBorrowMetadata() {
        val session=AccountSession(ApiEndpoint.parse("https://localhost/api/v1"),Store())
        fun account(id:String){check(session.accept(session.beginIntent(),SecretTokens("private","private",id)))}
        account("A")
        val track=Track(TrackId(7),"Restored",artwork="https://localhost/cover.png")
        val library=LibraryRepository(session,{_,_,_->LibraryPage(listOf(track),1,20,0)},{_,_,_->})
        library.refine(LibraryQuery())
        val graph=com.soundq.android.GraphMetadataBoundary(session,library)
        assertSame(track,graph.track(track.id))
        graph.rememberTracks(listOf(track))
        account("B");account("A")
        assertNull(graph.track(track.id))
        library.refine(LibraryQuery());assertSame(track,graph.track(track.id))
    }
    @Test fun accountBoundHomeTrackLoadsWithoutCatalogAndOldScopeNeverBorrowsReturnedAccount() {
        val certificate=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val trust=HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val server=MockWebServer().apply {useHttps(HandshakeCertificates.Builder().heldCertificate(certificate).build().sslSocketFactory());start()}
        val client=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager)
            .addInterceptor {chain->chain.proceed(chain.request().newBuilder().header("Authorization","must-not-leak").header("Cookie","must-not-leak").build())}.build()
        val session=AccountSession(ApiEndpoint.parse(server.url("/api/v1").toString()),Store())
        fun account(id:String){check(session.accept(session.beginIntent(),SecretTokens("private","private",id)))}
        account("A")
        val track=Track(TrackId(7),"Home source",artwork=server.url("/home.png?signature=private").toString())
        val scope=session.capture()!!
        try {LibraryArtwork(session,client).use {loader->
            server.enqueue(MockResponse.Builder().body(Buffer().write(png())).build())
            var mounted=true
            val row=loader.open(scope,track,{mounted});row.start();await {row.bitmap()!=null}
            val request=server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("/home.png",request.url.encodedPath);assertNull(request.headers["Authorization"]);assertNull(request.headers["Cookie"])
            val held=row.bitmap()!!;val draw=DrawBoundary();val alive=java.util.concurrent.atomic.AtomicBoolean(true)
            draw.paintRow(held,alive,row);assertEquals(1,draw.images)
            mounted=false;draw.paintRow(held,alive,row);assertEquals(1,draw.images)
            assertNull(row.bitmap());mounted=true;assertFalse(row.current())
            account("B");account("A")
            val stale=loader.open(scope,track,{true});stale.start();assertFalse(stale.current());assertEquals(1,server.requestCount)
            server.enqueue(MockResponse.Builder().body(Buffer().write(png())).build())
            val fresh=loader.open(session.capture(),track,{true});fresh.start();await {fresh.bitmap()!=null}
            assertFalse(stale.current());assertNotNull(fresh.bitmap())
        }} finally {server.close();client.connectionPool.evictAll();client.dispatcher.executorService.shutdownNow()}
    }
}
