package com.soundq.android

import android.content.ComponentName
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.AuthState
import com.soundq.android.playback.PlaybackRef
import com.soundq.android.playback.SoundQLibraryService
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Parent-authorized runtime only. Real provider -> repository -> canonical service ->
 * Android codec/SQP1 -> native callback output; never an alternate test player.
 * ProductFixtureRunner supplies only private synthetic setup, not phone playback bytes.
 * This source is compiled by the product gate; compilation is NOT runtime acceptance.
 */
@RunWith(AndroidJUnit4::class)
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@androidx.test.filters.SdkSuppress(minSdkVersion=29)
class PhoneLocalServiceJourneyTest {
    private val instrumentation=InstrumentationRegistry.getInstrumentation()
    private fun <T> main(block:()->T):T {var result:Result<T>?=null;instrumentation.runOnMainSync {result=runCatching(block)};return result!!.getOrThrow()}
    private fun await(message:String,ready:()->Boolean) {
        val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(30)
        while(System.nanoTime()<deadline){if(ready())return;Thread.sleep(20)}
        assertTrue(message,ready())
    }
    @Test fun signedOutPhoneFilePreparesAndAdvancesInCanonicalServiceWithoutNetworkOrServerId() {
        val context=instrumentation.targetContext
        val app=context.applicationContext as FixtureApplication
        main {app.graph.session.retire()}
        await("Accepted signed-out local catalog") {app.graph.session.state.value is AuthState.SignedOut&&app.graph.phoneAudio.state.value.ready}
        val version=app.graph.session.version()
        val before=ProductTransportFixture.requests.toList()
        val bytes=wave()
        val resolver=context.contentResolver
        val values=ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME,"soundq-synthetic-${UUID.randomUUID()}.wav")
            put(MediaStore.MediaColumns.MIME_TYPE,"audio/wav")
            put(MediaStore.MediaColumns.RELATIVE_PATH,Environment.DIRECTORY_DOWNLOADS+"/SoundQ qualification")
            put(MediaStore.MediaColumns.IS_PENDING,1)
        }
        val uri=checkNotNull(resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,values))
        var controller:MediaController?=null
        var future:com.google.common.util.concurrent.ListenableFuture<MediaController>?=null
        var primary:Throwable?=null
        try {
            resolver.openOutputStream(uri,"w")!!.use {it.write(bytes)}
            resolver.update(uri,ContentValues().apply {put(MediaStore.MediaColumns.IS_PENDING,0)},null,null)
            app.graph.phoneAudio.selected(uri,Intent.FLAG_GRANT_READ_URI_PERMISSION,false){app.graph.session.owns(version)}
            await("Provider file acknowledged") {app.graph.phoneAudio.state.value.snapshot?.files?.any {f->f.available&&f.aliases.any {it.locator.value==uri.toString()}}==true}
            val row=app.graph.phoneAudio.state.value.snapshot!!.files.single {f->f.available&&f.aliases.any {it.locator.value==uri.toString()}}
            val ref=app.graph.phoneAudio.reference(row)
            future=main {MediaController.Builder(context,SessionToken(context,ComponentName(context,SoundQLibraryService::class.java))).buildAsync()}
            controller=requireNotNull(future).get(15,TimeUnit.SECONDS)
            val c=requireNotNull(controller)
            main {
                val request=MediaItem.Builder().setMediaId("device:${ref.id}").setRequestMetadata(MediaItem.RequestMetadata.Builder().setExtras(Bundle().apply {putString("playbackRef",ref.wire())}).build()).build()
                c.setMediaItems(listOf(request),0,0);c.prepare();c.play()
            }
            await("Real native source advancement") {main {c.isPlaying&&c.duration>0&&c.currentPosition>100}}
            main {
                val extra=c.currentMediaItem!!.mediaMetadata.extras!!
                assertEquals(ref,PlaybackRef.read(extra.getString("playbackRef")))
                assertFalse("Phone source must not acquire a server TrackId",extra.containsKey("trackId"))
                c.pause()
            }
            await("Native pause") {main {!c.isPlaying&&!c.playWhenReady}}
            await("Service-qualified local recency") {app.graph.phoneAudio.state.value.snapshot?.history?.any {it.key==com.soundq.android.data.deviceaudio.HistoryKey.Device(row.id)&&it.playedAtEpochMs!=null}==true}
            assertArrayEquals(bytes,resolver.openInputStream(uri)!!.use {it.readBytes()})
            assertEquals("Phone playback must not send descriptor, upload, tags or progress requests",before,ProductTransportFixture.requests.toList())
            assertNull(app.graph.session.capture())
        }catch(failure:Throwable){primary=failure;throw failure}
        finally {
            try {
                controller?.let {main {it.pause();it.stop()}}
                future?.let {main {MediaController.releaseFuture(it)}}
                assertEquals("Delete only this test-owned MediaStore item",1,resolver.delete(uri,null,null))
            }catch(cleanup:Throwable){if(primary!=null)primary.addSuppressed(cleanup)else throw cleanup}
        }
    }
    private fun wave():ByteArray {
        val rate=16000;val frames=rate*3;val bytes=frames*2
        return ByteBuffer.allocate(44+bytes).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()).putInt(36+bytes).put("WAVEfmt ".toByteArray()).putInt(16)
            putShort(1).putShort(1).putInt(rate).putInt(rate*2).putShort(2).putShort(16).put("data".toByteArray()).putInt(bytes)
            repeat(frames){i->putShort((kotlin.math.sin(i*2*Math.PI*223/rate)*4000).toInt().toShort())}
        }.array()
    }
}
