package com.soundq.android

import android.graphics.Bitmap
import androidx.compose.runtime.*
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import com.soundq.android.data.*
import com.soundq.android.product.artwork.*
import com.soundq.designsystem.SoundQTheme
import mockwebserver3.*
import okhttp3.OkHttpClient
import okhttp3.tls.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** SDK-compiled only in this lane. Mounts actual Library consumer, not full ProductApp or system artwork. */
class LibraryArtworkImageTest {
    @get:Rule val compose=createComposeRule()
    @Test fun actualAndroidDecodePaintAndRowReplacementFallback() {
        val cert=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val trust=HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        val server=MockWebServer().apply {useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory());start()}
        val client=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).build()
        val store=object:SessionStore {override fun load(endpoint:ApiEndpoint):SecretTokens?=null;override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){};override fun clear(){}}
        val session=AccountSession(ApiEndpoint.parse(server.url("/api/v1").toString()),store)
        session.accept(session.beginIntent(),SecretTokens("synthetic-access","synthetic-refresh","A"))
        val track=Track(TrackId(1),"Owned art",artwork=server.url("/owned.png").toString())
        val repository=LibraryRepository(session,{_,_,_->LibraryPage(listOf(track),1,20,0)},{_,_,_->})
        repository.refine(LibraryQuery())
        val captured=repository.captureTrack(track)!!
        val source=Bitmap.createBitmap(1537,769,Bitmap.Config.ARGB_8888).apply {eraseColor(android.graphics.Color.MAGENTA)}
        val output=java.io.ByteArrayOutputStream();source.compress(Bitmap.CompressFormat.PNG,100,output);source.recycle()
        val bytes=output.toByteArray()
        val decoded=decodeLibraryArtwork(bytes)!!
        assertTrue(decoded.width<=192&&decoded.height<=192);assertTrue(decoded.allocationByteCount<=147456)
        server.enqueue(MockResponse.Builder().code(200).body(Buffer().write(bytes)).build())
        val loader=LibraryArtwork(session,client)
        val capture=mutableStateOf<com.soundq.android.data.playlists.LibraryTrackCapture?>(captured)
        try {
            compose.setContent {SoundQTheme {Box(Modifier.testTag("art-slot")){LibraryRowArtwork(loader,capture.value){true}}}}
            compose.waitUntil(5000) {
                val image=compose.onNodeWithTag("art-slot").captureToImage().toPixelMap()
                image[image.width/2,image.height/2]==androidx.compose.ui.graphics.Color.Magenta
            }
            val request=server.takeRequest(2,java.util.concurrent.TimeUnit.SECONDS)!!
            assertNull(request.headers["Authorization"])
            compose.runOnIdle {capture.value=null}
            val fallback=compose.onNodeWithTag("art-slot").captureToImage().toPixelMap()
            assertNotEquals(androidx.compose.ui.graphics.Color.Magenta,fallback[fallback.width/2,fallback.height/2])
        } finally {loader.close();server.close();client.connectionPool.evictAll();client.dispatcher.executorService.shutdownNow()}
    }
}
