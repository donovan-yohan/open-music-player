package com.soundq.android

import android.content.ContentValues
import android.os.Environment
import android.provider.MediaStore
import android.view.accessibility.AccessibilityEvent
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.AuthState
import com.soundq.android.playback.PlaybackProjection
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList

/** Mounted production root + real service + original acquisition/decoder refusal.
 * Only a generated original is created and retired after concrete drain. No supplied eligibility/error or test player. */
@androidx.test.filters.SdkSuppress(minSdkVersion=29)
class RootFailureFeedbackJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private val context get()=instrumentation.targetContext
    private fun capture(name:String) {
        val bitmap=checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        try {
            val directory=File(context.filesDir,"song-actions-captures").apply {mkdirs()}
            File(directory,"$name.png").outputStream().use {assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it))}
        } finally {bitmap.recycle()}
    }
    @Test fun realPhoneDecoderFailureToastsOnceAcrossPanelsAndExplicitRetryWorks() {
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.runOnIdle {model.graph.session.retire();model.controller.pause();model.controller.clear()}
        compose.waitUntil(15_000) {
            model.graph.session.state.value is AuthState.SignedOut && model.graph.phoneAudio.state.value.ready &&
                model.playback.value.connection==PlaybackProjection.Connection.Connected
        }
        compose.runOnIdle {assertEquals(Lifecycle.State.RESUMED,compose.activity.lifecycle.currentState)}
        val version=model.graph.session.version()
        val baseline=model.playback.value.failureRevision
        assertNull(model.playback.value.error)
        val events=CopyOnWriteArrayList<String>()
        instrumentation.uiAutomation.setOnAccessibilityEventListener {event ->
            if(event.eventType==AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED && event.className?.toString()=="android.widget.Toast" && event.packageName?.toString()==context.packageName) {
                val text=event.text.joinToString(" ")
                events.add(text);android.util.Log.i("SoundQRootFailureFixture","native Toast $text")
            }
        }
        val name="soundq-failure-${UUID.randomUUID()}.wav"
        val resolver=context.contentResolver
        val uri=checkNotNull(resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME,name);put(MediaStore.MediaColumns.MIME_TYPE,"audio/wav")
            put(MediaStore.MediaColumns.RELATIVE_PATH,Environment.DIRECTORY_DOWNLOADS+"/SoundQ failure qualification")
            put(MediaStore.MediaColumns.IS_PENDING,1)
        }))
        var expectedOriginal:ByteArray?=null
        var ref:com.soundq.android.playback.PlaybackRef.Device?=null
        var primary:Throwable?=null
        try {
            val frames=32000
            val bytes=ByteBuffer.allocate(44+frames*2).order(ByteOrder.LITTLE_ENDIAN).apply {
                put("RIFF".toByteArray()).putInt(36+frames*2).put("WAVEfmt ".toByteArray()).putInt(16)
                // Valid WAV, deliberately above the original-reader's supported 192 kHz ceiling.
                // The catalog can prove/retain it; real native acquisition must reject its decoded format.
                putShort(1).putShort(1).putInt(384000).putInt(768000).putShort(2).putShort(16)
                put("data".toByteArray()).putInt(frames*2);repeat(frames){putShort(if(it%16<8)4000 else -4000)}
            }.array()
            expectedOriginal=bytes
            resolver.openOutputStream(uri,"w")!!.use {it.write(bytes)}
            assertEquals(1,resolver.update(uri,ContentValues().apply {put(MediaStore.MediaColumns.IS_PENDING,0)},null,null))
            val row=model.graph.phoneAudio.awaitIndexed(uri)
            val target=model.graph.phoneAudio.reference(row).also {ref=it}
            // Select through the canonical service without preparing. Prove its real local owner first.
            compose.runOnIdle {model.controller.enqueueDevice(target,false) {model.graph.session.owns(version)}}
            compose.waitUntil(15_000) {model.playback.value.selectedDeviceOwner?.let {it.ref==target&&it.version==version&&it.occurrence==model.playback.value.selectedOccurrence}==true}
            compose.runOnIdle {
                assertNull(model.playback.value.error);assertEquals(baseline,model.playback.value.failureRevision)
                assertTrue(model.playback.value.localOnly);assertEquals(Lifecycle.State.RESUMED,compose.activity.lifecycle.currentState)
            }
            compose.waitUntil(15_000) {!model.graph.phoneAudio.state.value.refreshing && model.graph.phoneAudio.observed(target)!=null}
            assertTrue(model.graph.phoneAudio.originalDescriptorsDrained(row.id.value.toString()))
            android.util.Log.i("SoundQRootFailureFixture","before prepare ${model.playback.value}")
            compose.runOnIdle {model.controller.playDevice(target) {model.graph.session.owns(version)}}
            try {compose.waitUntil(15_000) {model.playback.value.failureRevision>baseline && model.playback.value.error!=null}}catch(error:Throwable) {
                val c=compose.runOnIdle {model.controller.javaClass.getDeclaredField("controller").apply {isAccessible=true}.get(model.controller) as androidx.media3.session.MediaController}
                val actual=compose.runOnIdle {"state=${c.playbackState} playWhenReady=${c.playWhenReady} isPlaying=${c.isPlaying} error=${c.playerError}"}
                android.util.Log.e("SoundQRootFailureFixture","after refusal wait projection=${model.playback.value} actual=$actual")
                capture("root-refusal-boundary");throw error
            }
            val failed=model.playback.value
            assertEquals(target,failed.selectedDeviceOwner?.ref)
            assertEquals(version,failed.selectedDeviceOwner?.version)
            compose.waitUntil(10_000) {events.size==1}
            assertEquals(failed.error,events.single())
            capture("root-native-toast")
            val revision=failed.failureRevision
            repeat(2) {
                compose.onNodeWithContentDescription("${failed.title}, ${failed.artist}").performClick()
                compose.onNodeWithContentDescription("Close Now playing").performClick()
            }
            val end=System.nanoTime()+4_000_000_000L
            while(System.nanoTime()<end) {
                compose.runOnIdle {assertEquals(revision,model.playback.value.failureRevision);assertEquals(1,events.size)}
                Thread.sleep(50) // Bounded negative observation, not a readiness barrier.
            }
            // A deliberate retry re-enters the real preparation path and creates a new error episode.
            compose.runOnIdle {model.controller.toggle()}
            compose.waitUntil(15_000) {model.playback.value.failureRevision>revision}
            compose.waitUntil(10_000) {events.size==2}
            assertEquals(model.playback.value.error,events.last())
            capture("root-native-toast-retry")
            android.util.Log.i("SoundQRootFailureFixture","baseline=$baseline first=$revision retry=${model.playback.value.failureRevision} events=${events.size} localVersion=$version")
        } catch(error:Throwable) {primary=error;throw error}
        finally {
            instrumentation.uiAutomation.setOnAccessibilityEventListener(null)
            try {
                ref?.let {target ->
                    assertTrue(kotlinx.coroutines.runBlocking {model.controller.retirePhoneFile(target,version) {model.graph.session.owns(version)}})
                }
                compose.runOnIdle {model.controller.pause();model.controller.clear()}
                compose.waitUntil(15_000) {model.graph.phoneAudio.originalDescriptorsDrained(ref?.id)}
                expectedOriginal?.let {assertArrayEquals(it,resolver.openInputStream(uri)!!.use {input->input.readBytes()})}
                assertEquals(1,resolver.delete(uri,null,null))
            } catch(cleanup:Throwable) {if(primary!=null)primary.addSuppressed(cleanup) else throw cleanup}
        }
    }
}
