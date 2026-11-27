package com.soundq.android.data

import com.soundq.android.data.catalog.ReleaseGroupMbid
import com.soundq.android.data.discovery.*
import okhttp3.*
import okhttp3.tls.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.net.*
import java.util.concurrent.*
import javax.net.SocketFactory

/** Real TLS on loopback with canonical hostnames. Only socket port/DNS admission are fixture seams. */
internal class CaaTlsFixture:AutoCloseable {
 val server=MockWebServer()
 private val cert=HeldCertificate.Builder().commonName("CAA fixture").addSubjectAlternativeName("coverartarchive.org").addSubjectAlternativeName("archive.org").addSubjectAlternativeName("dn711103.ca.archive.org").build()
 private val trust=HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
 init {server.useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory());server.start()}
 private val sockets=object:SocketFactory() {
  override fun createSocket():Socket=object:Socket(){override fun connect(endpoint:SocketAddress,timeout:Int){super.connect(InetSocketAddress(InetAddress.getLoopbackAddress(),server.port),timeout)}}
  override fun createSocket(h:String,p:Int)=error("unexpected socket overload")
  override fun createSocket(h:String,p:Int,l:InetAddress,lp:Int)=error("unexpected socket overload")
  override fun createSocket(h:InetAddress,p:Int)=error("unexpected socket overload")
  override fun createSocket(h:InetAddress,p:Int,l:InetAddress,lp:Int)=error("unexpected socket overload")
 }
 val client:OkHttpClient=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).socketFactory(sockets).dns {listOf(InetAddress.getLoopbackAddress())}.build()
 val ref=CaaArtworkRef.Group(ReleaseGroupMbid("48140466-cff6-3222-bd55-63c27e43190d"))
 fun read(client:OkHttpClient=this.client)=CaaArtworkRead(client,addressAllowed={it.isLoopbackAddress})
 fun reply(body:String="image",status:Int=200,location:String?=null){server.enqueue(MockResponse.Builder().code(status).body(body).apply {if(location!=null)addHeader("Location",location)}.build())}
 override fun close(){client.connectionPool.evictAll();client.dispatcher.executorService.shutdownNow();server.close()}
}

class CaaArtworkReadTest {
 @Test fun retryAfterZeroDoesNotSendAnImplicitSecondArtworkRequest() {
  CaaTlsFixture().use {f->
   f.server.enqueue(MockResponse.Builder().code(503).addHeader("Retry-After","0").build())
   f.reply("should not be read")
   f.read().use {assertNull(it.load(f.ref){true})}
   assertEquals(1,f.server.requestCount)
  }
 }
 @Test fun observedChainUsesAnonymousTransportAndRealTls() {
  CaaTlsFixture().use {f->
   var inheritedEvents=0
   val dirty=f.client.newBuilder().addInterceptor {error("inherited application interceptor")}.addNetworkInterceptor {error("inherited network interceptor")}.eventListener(object:EventListener(){override fun callStart(call:Call){inheritedEvents++}}).build()
   f.reply("redirect",307,"https://archive.org/download/mbid-fixture/thumb.jpg")
   f.reply("redirect",302,"https://dn711103.ca.archive.org/0/items/mbid-fixture/thumb.jpg")
   f.reply("synthetic payload")
   f.read(dirty).use {assertEquals("synthetic payload",it.load(f.ref){true}!!.toString(Charsets.UTF_8))}
   assertEquals(3,f.server.requestCount);assertEquals(0,inheritedEvents)
   repeat(3){val req=f.server.takeRequest();for(h in listOf("Authorization","Cookie","Referer","Proxy-Authorization"))assertNull(req.headers[h])}
  }
 }
 @Test fun unsafeRedirectsAndLoopsAreRefusedWithoutDispatch() {
  for(location in listOf("http://archive.org/x","https://evilarchive.org/x","https://archive.org.evil.test/x",URI("https","user:pass","archive.org",-1,"/x",null,null).toASCIIString(),"https://archive.org:444/x","https://127.0.0.1/x","https://archive.org/x#fragment","https://coverartarchive.org/release-group/48140466-cff6-3222-bd55-63c27e43190d/front-250")) {
   CaaTlsFixture().use {f->f.reply("redirect",302,location);f.read().use {assertNull(location,it.load(f.ref){true})};assertEquals(1,f.server.requestCount)}
  }
 }
 @Test fun relativeLocationIsValidatedAndMissingLocationRefused() {
  CaaTlsFixture().use {f->f.reply("",302,"/next");f.reply("ok");f.read().use {assertNotNull(it.load(f.ref){true})};assertEquals(2,f.server.requestCount)}
  CaaTlsFixture().use {f->f.reply("",302);f.read().use {assertNull(it.load(f.ref){true})};assertEquals(1,f.server.requestCount)}
 }
 @Test fun privateDnsIsRefusedByProductionDefaultBeforeConnection() {
  CaaTlsFixture().use {f->CaaArtworkRead(f.client).use {assertNull(it.load(f.ref){true})};assertEquals(0,f.server.requestCount)}
  for(raw in listOf("127.0.0.1","10.0.0.1","172.16.0.1","192.168.1.1","169.254.169.254","100.64.0.1","0.0.0.0","192.0.2.1","198.18.0.1","224.0.0.1","::1","fc00::1","fe80::1","2001:db8::1"))assertFalse(raw,CaaArtworkRead.publicAddress(InetAddress.getByName(raw)))
  for(raw in listOf("8.8.8.8","1.1.1.1","2606:4700:4700::1111"))assertTrue(raw,CaaArtworkRead.publicAddress(InetAddress.getByName(raw)))
 }
 @Test fun redirectsBodiesAndImageShareOneBoundedBudget() {
  CaaTlsFixture().use {f->f.reply("x".repeat(65537),302,"https://archive.org/x");f.read().use {assertNull(it.load(f.ref){true})};assertEquals(1,f.server.requestCount)}
  CaaTlsFixture().use {f->f.reply("x".repeat(SourceArtworkRead.MAX_BYTES+1));f.read().use {assertNull(it.load(f.ref){true})}}
  CaaTlsFixture().use {f->repeat(5){f.reply("",302,"https://archive.org/hop$it")};f.read().use {assertNull(it.load(f.ref){true})};assertEquals(5,f.server.requestCount)}
  CaaTlsFixture().use {f->f.reply("x".repeat(65536),302,"https://archive.org/x");f.reply("x".repeat(SourceArtworkRead.MAX_BYTES-65536+1));f.read().use {assertNull(it.load(f.ref){true})}}
 }
 @Test fun consumerPredicateNeverRunsUnderReaderMonitor() {
  CaaTlsFixture().use {f->f.reply("healthy");f.read().use {reader->
   assertNotNull(reader.load(f.ref){assertFalse("reader/accepted-owner lock inversion",Thread.holdsLock(reader));true})
  }}
 }
 @Test fun oneOverallDeadlineIncludesRedirectWaits() {
  CaaTlsFixture().use {f->
   f.server.enqueue(MockResponse.Builder().code(307).addHeader("Location","https://archive.org/next").headersDelay(500,TimeUnit.MILLISECONDS).build())
   f.server.enqueue(MockResponse.Builder().body("late").headersDelay(1750,TimeUnit.MILLISECONDS).build())
   val start=System.nanoTime()
   CaaArtworkRead(f.client,addressAllowed={it.isLoopbackAddress},budgetNanos=TimeUnit.SECONDS.toNanos(2)).use {assertNull(it.load(f.ref){true})}
   assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime()-start)<4000);assertEquals(2,f.server.requestCount)
  }
 }
 @Test fun publicDnsCannotHidePrivateActualTransportAddress() {
  CaaTlsFixture().use {f->
   val misleading=f.client.newBuilder().dns {listOf(InetAddress.getByName("8.8.8.8"))}.build()
   try {CaaArtworkRead(misleading).use {assertNull(it.load(f.ref){true})};assertEquals(0,f.server.requestCount)}
   finally {misleading.connectionPool.evictAll();misleading.dispatcher.executorService.shutdownNow()}
  }
 }
 @Test fun retirementDuringNetworkCannotPublishOrRevive() {
  CaaTlsFixture().use {f->
   val entered=CountDownLatch(1);val release=CountDownLatch(1);val live=java.util.concurrent.atomic.AtomicBoolean(true);val executor=Executors.newSingleThreadExecutor()
   f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().body("late").build()}}
   f.read().use {reader->try {
    val job=executor.submit<ByteArray?> {reader.load(f.ref){live.get()}}
    assertTrue(entered.await(3,TimeUnit.SECONDS));live.set(false);reader.close();live.set(true);release.countDown();assertNull(job.get(5,TimeUnit.SECONDS));assertNull(reader.load(f.ref){true});assertEquals(1,f.server.requestCount)
   }finally {release.countDown();executor.shutdownNow();assertTrue(executor.awaitTermination(5,TimeUnit.SECONDS))}}
  }
 }
}
