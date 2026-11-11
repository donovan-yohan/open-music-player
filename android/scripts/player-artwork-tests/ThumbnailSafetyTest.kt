package com.soundq.android.product.artwork

import android.graphics.Bitmap
import com.soundq.android.data.*
import mockwebserver3.*
import okhttp3.*
import okhttp3.tls.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*
import java.util.concurrent.atomic.*

/** Exact acquisition/paint policy with TLS. Resource counts are aggregate observations, not authority. */
class ThumbnailSafetyTest {
    private class Store:SessionStore {
        var saved:SecretTokens?=null
        override fun load(endpoint:ApiEndpoint)=saved
        override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){saved=tokens}
        override fun clear(){saved=null}
    }
    private class Fixture(decoder:(ByteArray)->Bitmap?=::decodeLibraryArtwork):AutoCloseable {
        val cert=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val server=MockWebServer().apply {useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory());start()}
        val trust=HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        val client=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
        val session=AccountSession(ApiEndpoint.parse(server.url("/api/v1").toString()),Store())
        val loader:LibraryArtwork
        init {account("A");loader=LibraryArtwork(session,client,decoder)}
        fun account(id:String){check(session.accept(session.beginIntent(),SecretTokens("synthetic","synthetic",id)))}
        fun track(path:String="/art")=Track(TrackId(7),"Same",artwork=server.url(path).toString())
        fun row(track:Track=track(),current:()->Boolean={true})=loader.open(session.capture(),track,current)
        override fun close(){loader.close();check(awaitTermination(loader));server.close();client.connectionPool.evictAll();client.dispatcher.executorService.shutdownNow()}
        private fun awaitTermination(loader:LibraryArtwork):Boolean {
            val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
            while(loader.pendingWorkCount()!=0&&System.nanoTime()<end)Thread.sleep(2)
            return loader.pendingWorkCount()==0
        }
    }
    companion object {
        private fun png(w:Int=8,h:Int=6):ByteArray=java.io.ByteArrayOutputStream().also {
            javax.imageio.ImageIO.write(java.awt.image.BufferedImage(w,h,java.awt.image.BufferedImage.TYPE_INT_ARGB),"png",it)
        }.toByteArray()
        private fun reply(data:ByteArray=png())=MockResponse.Builder().body(Buffer().write(data)).build()
        private fun await(test:()->Boolean) {
            val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
            while(!test()){if(System.nanoTime()>end)fail("Thumbnail safety did not settle");Thread.sleep(2)}
        }
        private fun hold(release:CountDownLatch) {while(release.count>0)try {release.await()}catch(_:InterruptedException){}}
    }
    @Test fun twoLiveConsumersReceiveIdenticalPixelsWithOneTransferAndDecode() {
        val entered=CountDownLatch(1);val release=CountDownLatch(1);val decodes=AtomicInteger()
        Fixture {data->decodes.incrementAndGet();entered.countDown();hold(release);decodeLibraryArtwork(data)}.use {f->try {
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest)=reply()}
            val a=f.row();a.start();assertTrue(entered.await(5,TimeUnit.SECONDS))
            val b=f.row(f.track().copy(id=TrackId(8)));b.start();release.countDown()
            await {a.bitmap()!=null&&b.bitmap()!=null};assertSame(a.bitmap(),b.bitmap())
            assertEquals(1,f.server.requestCount);assertEquals(1,decodes.get())
            b.close();assertNotNull(a.bitmap())
        }finally {release.countDown()}}
    }
    @Test fun zeroSubscribersCancelRunningWorkWithoutLettingSuccessorBorrowItsResult() {
        val entered=CountDownLatch(1);val release=CountDownLatch(1);val decodes=AtomicInteger()
        val successorEntered=CountDownLatch(1);val successorRelease=CountDownLatch(1)
        Fixture {data->
            if(decodes.incrementAndGet()==1){entered.countDown();hold(release)}
            else {successorEntered.countDown();hold(successorRelease)}
            decodeLibraryArtwork(data)
        }.use {f->try {
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest)=reply(if(f.server.requestCount==1)png(8,6) else png(9,7))}
            val a=f.row();a.start();assertTrue(entered.await(5,TimeUnit.SECONDS))
            val b=f.row();b.start();a.close();b.close()
            assertEquals(1,f.loader.pendingWorkCount()) // Cancelled decode still owns a worker.
            val successor=f.row();successor.start();assertTrue(successorEntered.await(5,TimeUnit.SECONDS))
            release.countDown();await {f.loader.pendingWorkCount()==1}
            // J1 finally must not remove the still-held same-key replacement J2.
            val peer=f.row();peer.start();successorRelease.countDown();await {successor.bitmap()!=null&&peer.bitmap()!=null}
            assertSame(successor.bitmap(),peer.bitmap());assertEquals(2,decodes.get());assertEquals(2,f.server.requestCount)
            await {f.loader.pendingWorkCount()==0}
            assertNull(a.bitmap());assertNull(b.bitmap());assertEquals(9,successor.bitmap()!!.width)
            val warm=f.row();assertSame(successor.bitmap(),warm.bitmap())
        }finally {release.countDown();successorRelease.countDown()}}
    }
    @Test fun shutdownRefusesLatePublicationAndNewLeaseAndReleasesOwnedWork() {
        val entered=CountDownLatch(1);val release=CountDownLatch(1)
        Fixture {data->entered.countDown();hold(release);decodeLibraryArtwork(data)}.use {f->try {
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest)=reply()}
            val row=f.row();row.start();assertTrue(entered.await(5,TimeUnit.SECONDS))
            f.loader.close();assertFalse(row.current());assertNull(row.state.value)
            val after=f.row();after.start();assertFalse(after.current());assertNull(after.bitmap())
            release.countDown();await {f.loader.pendingWorkCount()==0}
            assertEquals(0,f.loader.resources().cacheEntries);assertEquals(1,f.server.requestCount)
        }finally {release.countDown()}}
    }
    @Test fun cancelledRunningAndQueuedJobsRemainBoundedAndHealthySuccessorRecovers() {
        val entered=CountDownLatch(LibraryArtwork.MAX_WORKERS);val release=CountDownLatch(1);val decodes=AtomicInteger()
        Fixture {data->if(decodes.incrementAndGet()<=LibraryArtwork.MAX_WORKERS){entered.countDown();hold(release)};decodeLibraryArtwork(data)}.use {f->try {
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest)=reply()}
            val held=(1..LibraryArtwork.MAX_WORKERS).map {f.row(f.track("/held-$it")).also {it.start()}}
            assertTrue(entered.await(5,TimeUnit.SECONDS))
            val queued=f.row(f.track("/never"));val duplicate=f.row(f.track("/never"))
            queued.start();duplicate.start();assertEquals(4,f.loader.pendingWorkCount())
            queued.close();assertEquals(4,f.loader.pendingWorkCount())
            duplicate.close();assertEquals(3,f.loader.pendingWorkCount())
            held.forEach {it.close()};assertEquals(3,f.loader.pendingWorkCount())
            val waiting=(1..LibraryArtwork.MAX_ROWS).map {f.row(f.track("/queued-$it")).also {it.start()}}
            val player=f.loader.openPlayer(f.session.capture(),f.track("/queued-player")){true};player.start()
            val resources=f.loader.resources()
            assertEquals(LibraryArtwork.MAX_JOBS,resources.jobs);assertEquals(3,resources.running)
            assertEquals(32,resources.rows);assertEquals(1,resources.players)
            val excess=f.loader.openPlayer(f.session.capture(),f.track("/overflow")){true};excess.start();assertFalse(excess.current())
            assertEquals(36,f.loader.pendingWorkCount());assertEquals(3,f.server.requestCount)
            waiting.forEach {it.close()};player.close();assertEquals(3,f.loader.pendingWorkCount())
            val successor=f.row(f.track("/successor"));successor.start();release.countDown()
            await {successor.bitmap()!=null&&f.loader.pendingWorkCount()==0}
            assertEquals(4,f.server.requestCount);assertTrue(held.all {!it.current()&&it.bitmap()==null})
            assertEquals(0,f.loader.resources().running)
        }finally {release.countDown()}}
    }
    @Test fun byteEvictionDropsCacheOwnershipWithoutRecyclingLiveOrPendingDrawPixels() {
        Fixture().use {f->
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest)=reply(png(192,192))}
            val first=f.row(f.track("/first"));first.start();await {first.bitmap()!=null};val held=first.bitmap()!!
            for(i in 1..60) {
                val row=f.row(f.track("/entry-$i"));row.start();await {row.bitmap()!=null};row.close()
                assertTrue(f.loader.resources().cacheBytes<=LibraryArtwork.MAX_CACHE_BYTES)
            }
            val missing=f.row(f.track("/first"));assertNull(missing.bitmap())
            val draw=DrawBoundary();val mounted=AtomicBoolean(true);draw.paintRow(held,mounted,first);assertEquals(1,draw.images)
            val count=f.server.requestCount;missing.start();await {missing.bitmap()!=null};assertEquals(count+1,f.server.requestCount)
            assertNotSame(held,missing.bitmap());assertSame(held,first.bitmap())
            first.close();draw.paintRow(held,mounted,first);assertEquals(1,draw.images)
        }
    }
    @Test fun entryBoundUsesLruAndDoesNotKeepAllVisitedArtwork() {
        Fixture().use {f->
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest)=reply()}
            for(i in 0 until LibraryArtwork.MAX_CACHE_ENTRIES) {
                val row=f.row(f.track("/entry-$i"));row.start();await {row.bitmap()!=null};row.close()
            }
            f.row(f.track("/entry-0")).use {assertNotNull(it.bitmap())}
            val newest=f.row(f.track("/newest"));newest.start();await {newest.bitmap()!=null};newest.close()
            assertEquals(64,f.loader.resources().cacheEntries)
            f.row(f.track("/entry-0")).use {assertNotNull(it.bitmap())}
            f.row(f.track("/entry-1")).use {assertNull(it.bitmap())}
        }
    }
    @Test fun playerAndRowRenditionsHaveSeparateBoundsAndBothReuseWarmPixels() {
        Fixture().use {f->
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest)=reply(png(1024,1024))}
            val player=f.loader.openPlayer(f.session.capture(),f.track()){true};player.start();await {player.bitmap()!=null}
            val big=player.bitmap()!!;assertEquals(1024,big.width);player.close()
            val row=f.row();assertNull(row.bitmap());row.start();await {row.bitmap()!=null}
            val small=row.bitmap()!!;assertTrue(small.width<=192);assertTrue(small.allocationByteCount<=192*192*4);row.close()
            val returning=f.loader.openPlayer(f.session.capture(),f.track()){true};assertSame(big,returning.bitmap())
            f.row().use {assertSame(small,it.bitmap())};assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun cacheHitsStillAdmitEveryLeaseAndRefuseForeignScopeLockAccountAbaAndDeviceOnly() {
        Fixture().use {f->
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest)=reply()}
            val oldScope=f.session.capture()!!;var localOnly=false
            val old=f.row(current={!localOnly});old.start();await {old.bitmap()!=null};val pixels=old.bitmap()!!
            localOnly=true;assertNull(old.bitmap());localOnly=false;assertFalse(old.current())
            val denied=f.row(current={false});denied.start();assertFalse(denied.current());assertNull(denied.state.value)
            val fresh=f.row();assertSame(pixels,fresh.bitmap());fresh.close()
            val other=AccountSession(ApiEndpoint.parse("https://different.invalid/api/v1"),Store())
            check(other.accept(other.beginIntent(),SecretTokens("synthetic","synthetic","A")))
            val foreign=f.loader.open(other.capture(),f.track()){true};foreign.start();assertFalse(foreign.current())
            f.account("B");f.account("A")
            val stale=f.loader.open(oldScope,f.track()){true};stale.start();assertFalse(stale.current())
            val successor=f.row();assertNull(successor.bitmap());successor.start();await {successor.bitmap()!=null}
            val retained=successor.bitmap()!!;val draw=DrawBoundary();val mounted=AtomicBoolean(true)
            draw.paintRow(retained,mounted,successor);assertEquals(1,draw.images)
            assertTrue(f.session.lockLocal());draw.paintRow(retained,mounted,successor);assertEquals(1,draw.images)
            assertEquals(0,f.loader.resources().cacheEntries)
            assertTrue(f.session.completeLocalUnlock(f.session.localUnlockTicket()!!));assertFalse(successor.current())
            val unlocked=f.row();assertNull(unlocked.bitmap());unlocked.start();await {unlocked.bitmap()!=null};unlocked.close()
            f.session.failure(f.session.version(),SafeFailure.Reason.Network);assertTrue(f.session.useDeviceDownloads())
            val offline=f.row();offline.start();assertFalse(offline.current());assertNull(offline.bitmap())
            assertEquals(0,f.loader.resources().cacheEntries);assertEquals(3,f.server.requestCount)
        }
    }
    @Test fun sourceVersionAndOriginalMetadataPredicateCannotBorrowReplacementAuthority() {
        Fixture().use {f->
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest)=reply(if(request.url.query=="v=1")png(8,6)else png(9,7))}
            val one=f.track("/art?v=1");val two=one.copy(artwork=f.track("/art?v=2").artwork)
            val accepted=AtomicReference(one)
            val old=f.row(one){accepted.get()===one};old.start();await {old.bitmap()!=null}
            val held=old.bitmap()!!;accepted.set(two)
            val fresh=f.row(two){accepted.get()===two};assertNull(fresh.bitmap());fresh.start();await {fresh.bitmap()!=null}
            assertEquals(9,fresh.bitmap()!!.width)
            val draw=DrawBoundary();draw.paintRow(held,AtomicBoolean(true),old);assertEquals(0,draw.images)
            accepted.set(one);assertFalse(old.current())
            val returning=f.row(one){accepted.get()===one};assertSame(held,returning.bitmap());returning.start()
            assertEquals(2,f.server.requestCount)
        }
    }
}
