package com.soundq.android.product.discovery

import com.soundq.android.data.CaaTlsFixture
import com.soundq.android.product.artwork.decodeArtwork
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.awt.image.BufferedImage
import javax.imageio.ImageIO

/** Host-only ImageIO/Bitmap facade test. Native BitmapFactory/paint is a separate instrumentation source. */
class RadarArtworkPoolTest {
 private fun png(width:Int=247,height:Int=250):ByteArray=ByteArrayOutputStream().also {ImageIO.write(BufferedImage(width,height,BufferedImage.TYPE_INT_RGB),"png",it)}.toByteArray()
 private fun settle(pool:RadarArtworkPool) {val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(5);while(pool.resources()[1]!=0&&System.nanoTime()<end)Thread.sleep(2);assertEquals(0,pool.resources()[1])}
 @Test fun identicalRefsCoalesceAndRetiredSubscriberDoesNotCancelPeer() {
  CaaTlsFixture().use {f->
   val entered=CountDownLatch(1);val release=CountDownLatch(1)
   f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {entered.countDown();check(release.await(5,TimeUnit.SECONDS));return mockwebserver3.MockResponse.Builder().body(okio.Buffer().write(png())).build()}}
   val pool=RadarArtworkPool(reader={f.read(it)})
   val live=AtomicBoolean(true);val one=pool.open(f.client,f.ref){live.get()};val two=pool.open(f.client,f.ref){true}
   try {
    one.start();assertTrue(entered.await(3,TimeUnit.SECONDS));two.start();assertEquals(1,pool.resources()[1]);live.set(false);assertNull(one.bitmap());live.set(true);release.countDown();settle(pool)
    assertNull(one.bitmap());assertNotNull(two.bitmap());assertEquals(1,f.server.requestCount)
    val warm=pool.open(f.client,f.ref){true};try {warm.start();assertNotNull(warm.bitmap());assertEquals(1,f.server.requestCount)}finally {warm.close()}
   }finally {release.countDown();one.close();two.close();settle(pool);assertEquals(0,pool.resources()[0])}
  }
 }
 @Test fun retiredSameRefFinallyCannotEraseHeldSuccessorFlight() {
  CaaTlsFixture().use {f->
   f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest)=mockwebserver3.MockResponse.Builder().body(okio.Buffer().write(png())).build()}
   val first=CountDownLatch(1);val second=CountDownLatch(1);val releaseFirst=CountDownLatch(1);val releaseSecond=CountDownLatch(1);val count=java.util.concurrent.atomic.AtomicInteger()
   val pool=RadarArtworkPool(decode={data->if(count.incrementAndGet()==1){first.countDown();check(releaseFirst.await(5,TimeUnit.SECONDS))}else {second.countDown();check(releaseSecond.await(5,TimeUnit.SECONDS))};decodeArtwork(data,192)},reader={f.read(it)})
   val old=pool.open(f.client,f.ref){true};var successor:RadarArtworkPool.Lease?=null;var peer:RadarArtworkPool.Lease?=null
   try {
    old.start();assertTrue(first.await(3,TimeUnit.SECONDS));old.close();successor=pool.open(f.client,f.ref){true};successor.start();assertTrue(second.await(3,TimeUnit.SECONDS));assertEquals(2,pool.resources()[1])
    releaseFirst.countDown();val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(3);while(pool.resources()[1]!=1&&System.nanoTime()<end)Thread.sleep(2);assertEquals(1,pool.resources()[1])
    peer=pool.open(f.client,f.ref){true};peer.start();assertEquals(1,pool.resources()[1]);assertEquals(2,f.server.requestCount)
    releaseSecond.countDown();settle(pool);assertNotNull(successor.bitmap());assertNotNull(peer.bitmap());assertNull(old.bitmap());assertEquals(2,f.server.requestCount)
   }finally {releaseFirst.countDown();releaseSecond.countDown();old.close();successor?.close();peer?.close();settle(pool)}
  }
 }
 @Test fun heldDecodeRetirementKeepsActualJobChargedAndCannotPublish() {
  CaaTlsFixture().use {f->
   f.server.enqueue(mockwebserver3.MockResponse.Builder().body(okio.Buffer().write(png())).build())
   val entered=CountDownLatch(1);val release=CountDownLatch(1)
   val pool=RadarArtworkPool(decode={data->entered.countDown();check(release.await(5,TimeUnit.SECONDS));decodeArtwork(data,192)},reader={f.read(it)})
   val old=pool.open(f.client,f.ref){true}
   try {old.start();assertTrue(entered.await(3,TimeUnit.SECONDS));old.close();assertEquals(1,pool.resources()[1]);assertNull(old.bitmap());release.countDown();settle(pool);assertNull(old.bitmap());assertEquals(0,pool.resources()[2])}
   finally {release.countDown();old.close();settle(pool)}
  }
 }
 @Test fun eachCapturedOwnerDimensionIsTerminalAtCheckedDraw() {
  for(dimension in listOf("account","route","page","song","draft","foreground"))CaaTlsFixture().use {f->
   f.server.enqueue(mockwebserver3.MockResponse.Builder().body(okio.Buffer().write(png())).build())
   val pool=RadarArtworkPool(reader={f.read(it)});val expected=Any();var accepted:Any=expected
   val lease=pool.open(f.client,f.ref){accepted===expected}
   try {lease.start();settle(pool);val pixels=lease.bitmap();assertNotNull(dimension,pixels)
    val draw=DrawBoundary();draw.paint(pixels,lease::bitmap);assertEquals(1,draw.images)
    accepted=Any();draw.paint(pixels,lease::bitmap);assertEquals(dimension,1,draw.images)
    accepted=expected;draw.paint(pixels,lease::bitmap);assertEquals("ABA $dimension",1,draw.images)
    val successor=pool.open(f.client,f.ref){true};try {successor.start();assertNotNull(successor.bitmap());draw.paint(successor.bitmap(),successor::bitmap);assertEquals(2,draw.images)}finally {successor.close()}
   }finally {lease.close();settle(pool)}
  }
 }
 @Test fun corruptDataHasStableNegativeCacheAndNoRetryLoop() {
  CaaTlsFixture().use {f->
   f.reply("not an image");val pool=RadarArtworkPool(reader={f.read(it)})
   repeat(10){val lease=pool.open(f.client,f.ref){true};try {lease.start();settle(pool);assertNull(lease.bitmap())}finally {lease.close()}}
   assertEquals(1,f.server.requestCount)
  }
 }
 @Test fun leaseAndJobAdmissionAreBoundedAndShareSourceSemaphore() {
  CaaTlsFixture().use {f->
   val pool=RadarArtworkPool(reader={f.read(it)});val leases=mutableListOf<RadarArtworkPool.Lease>()
   kotlinx.coroutines.runBlocking {repeat(3){discoveryArtworkWorkers.acquire()}}
   try {
    repeat(70){n->val ref=com.soundq.android.data.discovery.CaaArtworkRef.Group(com.soundq.android.data.catalog.ReleaseGroupMbid("%08x-1111-4111-8111-111111111111".format(n+1)));leases+=pool.open(f.client,ref){true}}
    assertEquals(64,pool.resources()[0]);leases.forEach {it.start()};assertEquals(32,pool.resources()[1]);assertEquals(0,f.server.requestCount)
    leases.forEach {it.close()};assertEquals(0,pool.resources()[0]);settle(pool);assertEquals(0,pool.resources()[1])
   }finally {leases.forEach {it.close()};repeat(3){discoveryArtworkWorkers.release()};settle(pool)}
   assertEquals(0,f.server.requestCount);assertTrue(pool.resources()[2]<=RadarArtworkPool.MAX_CACHE_ENTRIES)
  }
 }
 @Test fun warmCacheEvictsAndHeldJobsNeverExceedSharedThreePermits() {
  CaaTlsFixture().use {f->
   val pool=RadarArtworkPool(reader={f.read(it)})
   repeat(22){n->
    val ref=com.soundq.android.data.discovery.CaaArtworkRef.Group(com.soundq.android.data.catalog.ReleaseGroupMbid("%08x-1111-4111-8111-111111111111".format(n+1)))
    f.server.enqueue(mockwebserver3.MockResponse.Builder().body(okio.Buffer().write(png())).build())
    val lease=pool.open(f.client,ref){true};try {lease.start();settle(pool);assertNotNull(lease.bitmap());assertTrue(pool.resources()[2]<=16);assertTrue(pool.resources()[3]<=2*1024*1024)}finally {lease.close()}
   }
   assertEquals(22,f.server.requestCount)
  }
  CaaTlsFixture().use {f->
   val refs=(1..4).associateWith {n->"%08x-1111-4111-8111-111111111111".format(n)}
   val releases=refs.mapValues {CountDownLatch(1)}
   val entrants=LinkedBlockingQueue<Int>()
   val transfers=CopyOnWriteArrayList<Int>()
   val inDecode=AtomicInteger();val peak=AtomicInteger()
   f.server.dispatcher=object:mockwebserver3.Dispatcher() {
    override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
     val n=refs.entries.single {request.url.encodedPath=="/release-group/${it.value}/front-250"}.key
     transfers+=n
     return mockwebserver3.MockResponse.Builder().body(okio.Buffer().write(png(32+n,32))).build()
    }
   }
   val pool=RadarArtworkPool(decode={data->
    val pixels=checkNotNull(decodeArtwork(data,192));val n=pixels.width-32
    val active=inDecode.incrementAndGet();peak.updateAndGet {maxOf(it,active)}
    try {entrants.add(n);check(releases.getValue(n).await(5,TimeUnit.SECONDS));pixels}finally {inDecode.decrementAndGet()}
   },reader={f.read(it)})
   val leases=refs.mapValues {(_,id)->pool.open(f.client,com.soundq.android.data.discovery.CaaArtworkRef.Group(com.soundq.android.data.catalog.ReleaseGroupMbid(id))){true}}
   try {
    leases.values.forEach {it.start()}
    val holders=List(3){checkNotNull(entrants.poll(3,TimeUnit.SECONDS))}.toSet()
    assertEquals(3,holders.size);assertEquals(3,inDecode.get());assertEquals(0,discoveryArtworkWorkers.availablePermits)
    assertEquals(3,f.server.requestCount);assertEquals(holders,transfers.toSet());assertEquals(4,pool.resources()[1])
    holders.forEach {leases.getValue(it).close()}
    assertEquals("canceled decode holders remain charged until exit",4,pool.resources()[1]);assertEquals(0,discoveryArtworkWorkers.availablePermits)
    val survivor=(refs.keys-holders).single()
    // Let precisely one actual holder exit. The admitted fourth job can acquire its permit.
    releases.getValue(holders.first()).countDown()
    assertEquals(survivor,entrants.poll(3,TimeUnit.SECONDS))
    assertEquals(3,inDecode.get());assertEquals(0,discoveryArtworkWorkers.availablePermits)
    releases.values.forEach {it.countDown()};settle(pool)
    assertEquals("actual client decode peak",3,peak.get())
    assertEquals("four cumulative distinct transfers",refs.keys.sorted(),transfers.sorted());assertEquals(4,f.server.requestCount)
    assertEquals(32+survivor,leases.getValue(survivor).bitmap()?.width)
    holders.forEach {assertNull(leases.getValue(it).bitmap())};assertEquals(1,pool.resources()[2])
   }finally {releases.values.forEach {it.countDown()};leases.values.forEach {it.close()};settle(pool)}
  }
 }
 @Test fun boundsPrecedePixelAllocationAndOddDimensionsStayWithin192() {
  val image=decodeArtwork(png(),192)!!;assertTrue(image.width in 1..192&&image.height in 1..192);assertTrue(image.allocationByteCount<=192*192*4)
  assertNull(decodeArtwork(ByteArray(4_000_001),192));assertNull(decodeArtwork("corrupt".toByteArray(),192))
 }
}
