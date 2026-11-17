package com.soundq.android

import android.graphics.Bitmap
import androidx.compose.runtime.*
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import com.soundq.android.data.discovery.*
import com.soundq.android.product.discovery.*
import com.soundq.designsystem.SoundQTheme
import kotlinx.serialization.json.*
import mockwebserver3.*
import okhttp3.*
import okhttp3.tls.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.net.*
import java.util.concurrent.TimeUnit
import javax.net.SocketFactory

/** SOURCE ONLY in this release: not SDK-compiled or executed. Uses no downloaded CAA asset bytes.
 * Mounts the released Radar composable + real repository/parser/BitmapFactory/Canvas, not full screens.
 */
class RadarArtworkImageTest {
 @get:Rule val compose=createComposeRule()
 @Test fun syntheticPngAndJpegPaintThenAcceptedPageReplacementRefusesOldPixels() {
  for(format in listOf(Bitmap.CompressFormat.PNG,Bitmap.CompressFormat.JPEG)) {
   val cert=HeldCertificate.Builder().addSubjectAlternativeName("localhost").addSubjectAlternativeName("coverartarchive.org").addSubjectAlternativeName("archive.org").addSubjectAlternativeName("dn711103.ca.archive.org").build()
   val trust=HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
   val server=MockWebServer().apply {useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory());start()}
   val apiClient=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
   val sockets=object:SocketFactory() {
    override fun createSocket():Socket=object:Socket(){override fun connect(endpoint:SocketAddress,timeout:Int){super.connect(InetSocketAddress(InetAddress.getLoopbackAddress(),server.port),timeout)}}
    override fun createSocket(h:String,p:Int)=error("unexpected overload")
    override fun createSocket(h:String,p:Int,l:InetAddress,lp:Int)=error("unexpected overload")
    override fun createSocket(h:InetAddress,p:Int)=error("unexpected overload")
    override fun createSocket(h:InetAddress,p:Int,l:InetAddress,lp:Int)=error("unexpected overload")
   }
   val artClient=apiClient.newBuilder().socketFactory(sockets).dns {listOf(InetAddress.getLoopbackAddress())}.build()
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
   try {
    // Each format uses the SAME composition; one test content root is installed below only once.
    mount.value={SoundQTheme {if(shown.value)Box(Modifier.testTag("radar-art")){RadarArtwork(artClient,repository,view,page,song,draft,view,pool)}}}
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
}
