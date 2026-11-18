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
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Semaphore

/** Identical controls can run on the predecessor. The reflection adapter only supplies the
 * predecessor's existing all-demand admission when the new priority API is absent.
 * These are loader/consumer controls, NOT a simulated native LazyColumn acceptance claim.
 */
class ThumbnailLookaheadTest {
    private class Store:SessionStore {
        private var saved:SecretTokens?=null
        override fun load(endpoint:ApiEndpoint):SecretTokens?=saved
        override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){saved=tokens}
        override fun clear(){saved=null}
    }
    private class Fixture(decode:(ByteArray)->Bitmap?=::decodeLibraryArtwork):AutoCloseable {
        val cert=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val trust=HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        val server=MockWebServer().apply {useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory());start()}
        val client=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
        val session=AccountSession(ApiEndpoint.parse(server.url("/api/v1").toString()),Store())
        val loader:LibraryArtwork
        init {account("A");loader=LibraryArtwork(session,client,decode)
            server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest)=MockResponse.Builder().body(Buffer().write(png())).build()}}
        fun account(id:String){check(session.accept(session.beginIntent(),SecretTokens("fixture-only","fixture-only",id)))}
        fun track(path:String)=Track(TrackId(1),"Fixture",artwork=server.url(path).toString())
        fun open(path:String,visible:Boolean=false,current:()->Boolean={true}):LibraryArtwork.Row {
            val method=loader.javaClass.declaredMethods.firstOrNull {it.name.startsWith("openThumbnail")&&it.parameterTypes.size==4}
            return if(method==null)loader.open(session.capture(),track(path),current)
                else method.invoke(loader,session.capture(),track(path),visible,current) as LibraryArtwork.Row
        }
        override fun close(){loader.close();server.close();client.connectionPool.evictAll();client.dispatcher.executorService.shutdownNow()}
    }
    companion object {
        private fun png(width:Int=8)=java.io.ByteArrayOutputStream().also {javax.imageio.ImageIO.write(java.awt.image.BufferedImage(width,6,2),"png",it)}.toByteArray()
        private fun await(condition:()->Boolean){val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(5);while(!condition()){if(System.nanoTime()>end)fail("Thumbnail boundary did not settle");Thread.sleep(2)}}
        private fun held(latch:CountDownLatch){while(latch.count>0)try {latch.await()}catch(_:InterruptedException){}}
        private fun promote(row:LibraryArtwork.Row){row.javaClass.methods.firstOrNull {it.name=="visibility"}?.invoke(row,true)}
    }
    @Test fun precomposedConsumerStartsBeforeEntryAndKeepsPixelsOnEntry() {
        Fixture().use {f->ArtworkBindingProbe().use {p->
            p.visible.value=false
            p.render {TrackArtwork(com.soundq.android.AppGraph(f.loader),f.session.capture(),f.track("/before-entry"),{true})}
            await {p.pixels()!=null}
            assertFalse(p.visible.value);assertEquals(1,f.server.requestCount)
            val image=p.pixels();p.visible.value=true
            await {p.pixels()===image};assertEquals(1,f.server.requestCount)
        }}
    }
    @Test fun realConsumerLimitsHeldSpeculationAndVisibleAndSelectedMakeProgress() {
        val entered=CountDownLatch(1);val release=CountDownLatch(1);val count=AtomicInteger()
        Fixture {data->count.incrementAndGet();if(data[19].toInt()==8){entered.countDown();held(release)};decodeLibraryArtwork(data)}.use {f->try {
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest)=MockResponse.Builder().body(Buffer().write(png(if(request.url.encodedPath.startsWith("/spec-"))8 else 9))).build()}
            val probes=(0..7).map {ArtworkBindingProbe()}
            try {
                // Each is the exact ordinary TrackArtwork binding, precomposed but not visible.
                probes.forEachIndexed {i,p->p.visible.value=false;p.render {TrackArtwork(com.soundq.android.AppGraph(f.loader),f.session.capture(),f.track("/spec-$i"),{true})}}
                assertTrue(entered.await(5,TimeUnit.SECONDS))
                // Decode callback holds all three if speculative admission incorrectly uses all workers.
                // For the correct variant only the first held speculative callback runs.
                val visible=f.open("/visible",true);visible.start()
                val selected=f.loader.openPlayer(f.session.capture(),f.track("/selected")){true};selected.start()
                await {selected.bitmap()!=null&&visible.bitmap()!=null}
                assertEquals(1L,release.count)
                assertTrue("At most one speculative decode may be running",count.get()<=2)
            } finally {probes.forEach {it.close()}}
        }finally {release.countDown()}}
    }
    @Test fun sharedFlightPromotesWithoutAnotherTransferOrDecode() {
        val entered=CountDownLatch(1);val release=CountDownLatch(1);val count=AtomicInteger()
        Fixture {data->count.incrementAndGet();entered.countDown();held(release);decodeLibraryArtwork(data)}.use {f->try {
            val ahead=f.open("/same");ahead.start();assertTrue(entered.await(5,TimeUnit.SECONDS))
            promote(ahead)
            val visible=f.open("/same",true);visible.start();ahead.close();release.countDown()
            await {visible.bitmap()!=null};assertEquals(1,count.get());assertEquals(1,f.server.requestCount)
            val pixels=visible.bitmap();visible.close();val returning=f.open("/same",true)
            assertSame(pixels,returning.bitmap());returning.start();assertEquals(1,f.server.requestCount)
        }finally {release.countDown()}}
    }
    @Test fun cancelledRunningSpeculationRemainsChargedAndAbandonedWindowDoesNotDispatch() {
        val entered=CountDownLatch(1);val release=CountDownLatch(1)
        Fixture {data->entered.countDown();held(release);decodeLibraryArtwork(data)}.use {f->try {
            val first=f.open("/old");first.start();assertTrue(entered.await(5,TimeUnit.SECONDS))
            val waiting=(1..7).map {f.open("/old-$it").also {it.start()}}
            first.close();waiting.forEach {it.close()}
            val reversed=f.open("/reverse");reversed.start()
            assertEquals(1,f.server.requestCount);assertEquals(1,f.loader.pendingWorkCount())
            reversed.close();release.countDown();await {f.loader.pendingWorkCount()==0}
            assertEquals(1,f.server.requestCount)
            val fresh=f.open("/healthy",true);fresh.start();await {fresh.bitmap()!=null}
        }finally {release.countDown()}}
    }
    @Test fun visibleAdmissionDisplacesSpeculativeLeasesWithinOriginalRowCap() {
        Fixture().use {f->
            val speculative=(0..7).map {f.open("/spec-$it")}
            val visible=(0 until LibraryArtwork.MAX_ROWS).map {f.open("/visible-$it",true)}
            assertTrue(visible.all {it.current()});assertEquals(LibraryArtwork.MAX_ROWS,f.loader.resources().rows)
            visible.first().close();promote(speculative.first());speculative.first().start()
            await {speculative.first().bitmap()!=null}
            assertEquals(LibraryArtwork.MAX_ROWS,f.loader.resources().rows)
        }
    }
    @Test fun speculativeCacheNeverRenewsAccountRouteOrLocalOnlyAuthority() {
        Fixture().use {f->
            var current=true;val first=f.open("/owned",false){current};first.start();await {first.bitmap()!=null}
            current=false;assertNull(first.bitmap());current=true;assertFalse(first.current())
            val scope=f.session.capture();f.account("B");f.account("A")
            val old=f.loader.open(scope,f.track("/owned")){true};old.start();assertFalse(old.current())
            val offline=f.open("/offline");f.session.failure(f.session.version(),SafeFailure.Reason.Network)
            assertTrue(f.session.useDeviceDownloads())
            offline.start();assertFalse(offline.current());assertEquals(1,f.server.requestCount)
        }
    }
    @Test fun speculativeWorkAndCacheStayWithinUnchangedCeilings() {
        Fixture().use {f->
            repeat(80) {i->val row=f.open("/cache-$i");row.start();await {row.bitmap()!=null};row.close()}
            val resource=f.loader.resources()
            assertTrue(resource.cacheEntries<=LibraryArtwork.MAX_CACHE_ENTRIES)
            assertTrue(resource.cacheBytes<=LibraryArtwork.MAX_CACHE_BYTES)
            assertTrue(resource.jobs<=LibraryArtwork.MAX_JOBS);assertTrue(resource.running<=LibraryArtwork.MAX_WORKERS)
            assertEquals(0,resource.rows)
        }
    }
    @Test fun acknowledgedLibraryConsumerWarmsAndRetiresItsOriginalPredicate() {
        Fixture().use {f->ArtworkBindingProbe().use {p->
            val track=f.track("/library")
            val library=LibraryRepository(f.session,{_,_,_->LibraryPage(listOf(track),1,20,0)},{_,_,_->})
            library.refine(LibraryQuery());val capture=library.captureTrack(track)!!
            var foreground=true
            p.render {LibraryRowArtwork(f.loader,capture){foreground&&library.owns(capture)}}
            await {p.pixels()!=null};assertFalse(p.visible.value);assertEquals(1,f.server.requestCount)
            foreground=false;assertNull(p.pixels());foreground=true;assertNull(p.pixels())
        }}
    }
    @Test fun phoneConsumerWarmsOffMainReusesOnEntryAndRetiresAccess() {
        Fixture().use {f->ArtworkBindingProbe().use {p->
            val graph=com.soundq.android.AppGraph(f.loader,f.session)
            val reads=AtomicInteger();var worker=""
            graph.applicationContext.read={reads.incrementAndGet();worker=Thread.currentThread().name;png()}
            val ref=com.soundq.android.playback.PlaybackRef.Device("synthetic-original")
            p.render {PhoneArtwork(graph,ref,72,{true})}
            await {p.pixels()!=null};assertFalse(p.visible.value)
            assertTrue(worker.startsWith("DefaultDispatcher-worker"));assertEquals(1,reads.get())
            val image=p.pixels();p.visible.value=true
            p.render {PhoneArtwork(graph,ref,72,{true})}
            assertSame(image,p.pixels());assertEquals(1,reads.get())
            graph.phoneAudio.available=false;assertNull(p.pixels());assertEquals(0,f.server.requestCount)
            assertEquals(1,graph.applicationContext.released.get())
        }}
    }
    @Test fun phoneConsumerReservesVisibleReaderWhileSpeculativeOriginalIsHeld() {
        val entered=CountDownLatch(1);val release=CountDownLatch(1)
        Fixture().use {f->
            val graph=com.soundq.android.AppGraph(f.loader,f.session)
            val speculative=AtomicInteger();val visible=AtomicInteger()
            graph.applicationContext.read={locator->
                if(locator.startsWith("spec")){speculative.incrementAndGet();entered.countDown();held(release)}else visible.incrementAndGet()
                png()
            }
            val probes=(0..7).map {ArtworkBindingProbe()};val demand=ArtworkBindingProbe()
            try {
                probes.forEachIndexed {i,p->p.render {PhoneArtwork(graph,com.soundq.android.playback.PlaybackRef.Device("spec-$i"),72,{true})}}
                assertTrue(entered.await(5,TimeUnit.SECONDS))
                demand.visible.value=true
                demand.render {PhoneArtwork(graph,com.soundq.android.playback.PlaybackRef.Device("visible"),72,{true})}
                await {demand.pixels()!=null}
                assertEquals(1L,release.count);assertEquals(1,speculative.get());assertEquals(1,visible.get())
            } finally {
                // Retire the source before releasing blocking hardware. Queued originals must refuse.
                graph.phoneAudio.available=false;probes.forEach {it.close()};demand.close();release.countDown()
                await {graph.applicationContext.released.get()>=speculative.get()+visible.get()}
            }
        }
    }
    @Test fun queuedLocalSpeculationPromotesPastHeldSpeculation()=runBlocking<Unit> {
        val gate=ThumbnailReadGate(Semaphore(2));val release=CompletableDeferred<Unit>();val entered=CompletableDeferred<Unit>()
        val first=async {gate.read(false,{awaitCancellation()}) {entered.complete(Unit);release.await();1}}
        entered.await();val visible=MutableStateFlow(false)
        val second=async(start=CoroutineStart.UNDISPATCHED) {gate.read(false,{visible.first {it}}) {2}}
        visible.value=true
        assertEquals(2,withTimeout(5000){second.await()});assertFalse(first.isCompleted)
        release.complete(Unit);assertEquals(1,first.await())
    }
    @Test fun runningLocalReadIsReusedOnEntryAndLeavesSelectedPermit()=runBlocking<Unit> {
        val gate=ThumbnailReadGate(Semaphore(2));val release=CompletableDeferred<Unit>();val entered=CompletableDeferred<Unit>();val visible=MutableStateFlow(false);val reads=AtomicInteger()
        val first=async {gate.read(false,{visible.first {it}}) {reads.incrementAndGet();entered.complete(Unit);release.await();1}}
        entered.await();visible.value=true
        val selected=async {gate.read(true,{error("demand never waits")}) {2}}
        assertEquals(2,withTimeout(5000){selected.await()});release.complete(Unit)
        assertEquals(1,first.await());assertEquals(1,reads.get())
    }
}
