package com.soundq.android

import android.graphics.Bitmap
import androidx.compose.runtime.*
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import com.soundq.android.data.discovery.*
import com.soundq.android.product.discovery.*
import com.soundq.designsystem.SoundQTheme
import kotlinx.serialization.json.*
import mockwebserver3.*
import okhttp3.OkHttpClient
import okhttp3.tls.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.net.*
import java.util.concurrent.TimeUnit
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import javax.net.SocketFactory

/** SOURCE ONLY in this release: not SDK-compiled or executed. Uses no downloaded CAA asset bytes.
 * Mounts the released Radar composable + real repository/parser/BitmapFactory/Canvas, not full screens.
 */
class RadarArtworkImageTest {
 @get:Rule val compose=createComposeRule()

 private fun artworkClient(apiClient:OkHttpClient,server:MockWebServer):OkHttpClient {
  // Android may resolve localhost and getLoopbackAddress() to different families.
  // Use the actual listener for DNS and TCP, leaving the CAA HTTPS origin and TLS identity intact.
  val bound=server.socketAddress
  check(bound.address.isLoopbackAddress)
  val sockets=object:SocketFactory() {
   override fun createSocket():Socket=object:Socket(){override fun connect(endpoint:SocketAddress,timeout:Int){super.connect(bound,timeout)}}
   override fun createSocket(h:String,p:Int)=error("unexpected overload")
   override fun createSocket(h:String,p:Int,l:InetAddress,lp:Int)=error("unexpected overload")
   override fun createSocket(h:InetAddress,p:Int)=error("unexpected overload")
   override fun createSocket(h:InetAddress,p:Int,l:InetAddress,lp:Int)=error("unexpected overload")
  }
  return apiClient.newBuilder().socketFactory(sockets).dns {listOf(bound.address)}.build()
 }

 @Test fun syntheticPngAndJpegPaintThenAcceptedPageReplacementRefusesOldPixels() {
  for(format in listOf(Bitmap.CompressFormat.PNG,Bitmap.CompressFormat.JPEG)) {
   val cert=HeldCertificate.Builder().addSubjectAlternativeName("localhost").addSubjectAlternativeName("coverartarchive.org").addSubjectAlternativeName("archive.org").addSubjectAlternativeName("dn711103.ca.archive.org").build()
   val trust=HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
   val server=MockWebServer().apply {useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory());start()}
   val apiClient=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
   val artClient=artworkClient(apiClient,server)
   val store=object:SessionStore {override fun load(endpoint:ApiEndpoint):SecretTokens?=null;override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){};override fun clear(){}}
   val session=AccountSession(ApiEndpoint.parse(server.url("/api/v1").toString()),store).apply {accept(beginIntent(),SecretTokens("synthetic-access","r","A"))}
   val repository=DiscoveryRepository(session,SoundQApi(session,apiClient),radarAdmitted=true)
   val view=repository.open()!!;repository.showRadar(view){true}
   val base=Json.parseToJsonElement(InstrumentationRegistry.getInstrumentation().context.assets.open("release-radar-wire.json").bufferedReader().readText()).jsonObject
   val row=base.getValue("items").jsonArray.single().jsonObject
   val wire=JsonObject(base+mapOf("policyVersion" to JsonPrimitive("recording-radar-v2"),"items" to JsonArray(listOf(JsonObject(row+mapOf("releaseGroupMbid" to JsonPrimitive("48140466-cff6-3222-bd55-63c27e43190d"))))))).toString()
   server.enqueue(MockResponse.Builder().body(wire).build());repository.loadRadar(repository.claimRadar(view)!!)
   val page=repository.radar.value.page!!;val song=page.songs.single();val draft=repository.state.value.draft
   val source=Bitmap.createBitmap(247,250,Bitmap.Config.ARGB_8888).apply {eraseColor(android.graphics.Color.MAGENTA)}
   val output=java.io.ByteArrayOutputStream();source.compress(format,100,output);source.recycle()
   server.enqueue(MockResponse.Builder().code(307).addHeader("Location","https://archive.org/download/fixture/thumb").build())
   server.enqueue(MockResponse.Builder().code(302).addHeader("Location","https://dn711103.ca.archive.org/0/items/fixture/thumb").build())
   server.enqueue(MockResponse.Builder().body(Buffer().write(output.toByteArray())).build())
   val pool=RadarArtworkPool(reader={CaaArtworkRead(it,addressAllowed={address->address.isLoopbackAddress})})
   val shown=mutableStateOf(true)
   val surface=RadarArtworkRoute()
   try {
    // Each format uses the SAME composition; one test content root is installed below only once.
    mount.value={SoundQTheme {if(shown.value)Box(Modifier.testTag("radar-art")){RadarArtwork(artClient,repository,view,page,song,draft,surface,pool)}}}
    if(!installed){compose.setContent {mount.value()};installed=true}
    fun magenta():Boolean {val pixels=compose.onNodeWithTag("radar-art").captureToImage().toPixelMap();val c=pixels[pixels.width/2,pixels.height/2];return c.red>0.9f&&c.blue>0.9f&&c.green<0.1f}
    compose.waitUntil(5000){magenta()}
    assertEquals("recording-radar-v2",server.takeRequest(2,TimeUnit.SECONDS)!!.headers["X-SoundQ-Radar-Policy"])
    repeat(3){val req=server.takeRequest(2,TimeUnit.SECONDS)!!;assertNull(req.headers["Authorization"]);assertNull(req.headers["Cookie"])}
    server.enqueue(MockResponse.Builder().body(wire).build());repository.loadRadar(repository.claimRadar(view,true)!!)
    // Retain OLD composable arguments and force a real Canvas frame; no old bitmap may paint.
    compose.onNodeWithTag("radar-art").captureToImage();compose.waitUntil(5000){!magenta()}
    compose.runOnIdle {shown.value=false};compose.waitForIdle()
   }finally {compose.runOnIdle {shown.value=false};repository.retire();server.close();for(client in listOf(apiClient,artClient)){client.connectionPool.evictAll();client.dispatcher.executorService.shutdownNow()}}
  }
 }
 private var installed=false
 private val mount=mutableStateOf<@Composable ()->Unit>({})

 @Test fun fullRadarWindowWarmsUnseenOwnCoverBeforeSlowEntryWithoutRepeatTransfer() {
  val cert=HeldCertificate.Builder().addSubjectAlternativeName("localhost").addSubjectAlternativeName("coverartarchive.org").build()
  val trust=HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
  val server=MockWebServer().apply {useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory());start()}
  val apiClient=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
  val artClient=artworkClient(apiClient,server)
  val store=object:SessionStore {override fun load(endpoint:ApiEndpoint):SecretTokens?=null;override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){};override fun clear(){}}
  val session=AccountSession(ApiEndpoint.parse(server.url("/api/v1").toString()),store).apply {accept(beginIntent(),SecretTokens("synthetic-access","fixture-refresh","A"))}
  val repository=DiscoveryRepository(session,SoundQApi(session,apiClient),radarAdmitted=true)
  val shown=mutableStateOf(true)
  try {
   val view=repository.open()!!;repository.showRadar(view){true}
   val base=Json.parseToJsonElement(InstrumentationRegistry.getInstrumentation().context.assets.open("release-radar-wire.json").bufferedReader().use {it.readText()}).jsonObject
   val template=base.getValue("items").jsonArray.single().jsonObject
   fun id(n:Int)="%08x-1111-4111-8111-111111111111".format(n)
   val rows=(0 until 20).map {i->JsonObject(template+mapOf("title" to JsonPrimitive("Synthetic cover $i"),
    "recordingMbid" to JsonPrimitive(id(100+i)),"releaseGroupMbid" to JsonPrimitive(id(i+1))))}
   val coverage=JsonObject(base.getValue("coverage").jsonObject+listOf("knownTotal","retrieved","deduped","returned").associateWith {JsonPrimitive(rows.size)})
   val wire=JsonObject(base+mapOf("policyVersion" to JsonPrimitive("recording-radar-v2"),"items" to JsonArray(rows),"coverage" to coverage))
   val covers=rows.indices.associate {i->
    val pixels=Bitmap.createBitmap(24+i,24,Bitmap.Config.ARGB_8888).apply {eraseColor(android.graphics.Color.rgb(100+i*7,16,210-i*5))}
    val bytes=java.io.ByteArrayOutputStream();pixels.compress(Bitmap.CompressFormat.PNG,100,bytes);pixels.recycle()
    "/release-group/${id(i+1)}/front-250" to bytes.toByteArray()
   }
   val calls=ConcurrentHashMap<String,Int>()
   val reads=AtomicInteger()
   server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
    val path=request.url.encodedPath
    if(path=="/api/v1/me/discovery/releases"){reads.incrementAndGet();return MockResponse.Builder().body(wire.toString()).build()}
    val cover=covers[path] ?: return MockResponse.Builder().code(404).build()
    // A duplicate cannot satisfy the immediate-own-pixel oracle.
    return if(calls.merge(path,1,Int::plus)==1)MockResponse.Builder().body(Buffer().write(cover)).build()
    else MockResponse.Builder().code(503).build()
   }}
   repository.loadRadar(repository.claimRadar(view)!!)
   val page=repository.radar.value.page!!;assertEquals(20,page.songs.size)
   val draft=repository.state.value.draft
   val pool=RadarArtworkPool(reader={CaaArtworkRead(it,addressAllowed={address->address.isLoopbackAddress})})
   val scroll=radarFullListState()
   val surface=RadarArtworkRoute()
   compose.setContent {SoundQTheme {if(shown.value)LazyColumn(Modifier.height(216.dp).testTag("full-radar-window"),state=scroll) {
    items(page.songs,key={"radar:${it.recording.value}"}) {song->
     Box(Modifier.testTag("cover:${song.recording.value}")) {RadarArtwork(artClient,repository,view,page,song,draft,surface,pool,fullList=scroll)}
    }
   }}}
   fun visible()=compose.runOnIdle {scroll.layoutInfo.let {layout->layout.visibleItemsInfo.filter {
    it.offset<layout.viewportEndOffset&&it.offset+it.size>layout.viewportStartOffset
   }.map {it.index}}}
   val initial=visible();assertTrue(initial.size in 3..4)
   // The second unseen item distinguishes a viewport window from single-neighbor prefetch.
   val target=initial.last()+2
   val song=page.songs[target]
   val targetPath=java.net.URI(song.artwork!!.entryUrl).path
   compose.waitUntil(8000) {calls[targetPath]==1&&pool.resources()[1]==0}
   assertEquals("warm acquisition finishes while geometry is unchanged",initial,visible())
   assertFalse("no download at far end of full list",calls.containsKey(java.net.URI(page.songs.last().artwork!!.entryUrl).path))
   val list=compose.onNodeWithTag("full-radar-window")
   list.performTouchInput {down(center)}
   try {
    for(step in 0 until 42) {
     list.performTouchInput {moveBy(Offset(0f,-4.dp.toPx()),delayMillis=48)}
     if(target in visible()) {
      val raster=compose.onNodeWithTag("cover:${song.recording.value}",useUnmergedTree=true).captureToImage().toPixelMap()
      val pixel=raster[raster.width/2,raster.height/2]
      assertEquals((100+target*7)/255f,pixel.red,0.025f)
      assertEquals(16/255f,pixel.green,0.025f)
      assertEquals((210-target*5)/255f,pixel.blue,0.025f)
      assertEquals(1,calls[targetPath]);assertEquals(1,reads.get())
      return
     }
    }
    fail("slow pointer steps never entered warmed Radar row")
   } finally {list.performTouchInput {cancel()}}
  } finally {
   compose.runOnIdle {shown.value=false};compose.waitForIdle()
   repository.retire();server.close();for(client in listOf(apiClient,artClient)){client.connectionPool.evictAll();client.dispatcher.executorService.shutdownNow()}
  }
 }
}
