package com.soundq.android

import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.os.Environment
import android.provider.MediaStore
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.artwork.PhoneArtwork
import com.soundq.android.product.artwork.ArtworkPaint
import com.soundq.designsystem.SoundQTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.flow.MutableStateFlow

/** Real repository, retriever, composition and raster. Only caller eligibility is held.
 * A row composed behind Settings must load its original cover when it becomes current. */
class PhoneArtworkAdmissionTest {
    @get:Rule val compose=createAndroidComposeRule<ComponentActivity>()
    @Test fun retainedPhoneArtworkLoadsWhenItsCallerBecomesCurrent() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val context=instrumentation.targetContext
        val graph=(context.applicationContext as FixtureApplication).graph
        val resolver=context.contentResolver
        val uri=requireNotNull(resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME,"soundq-owned-cover-${UUID.randomUUID()}.flac")
            put(MediaStore.MediaColumns.MIME_TYPE,"audio/flac")
            put(MediaStore.MediaColumns.RELATIVE_PATH,Environment.DIRECTORY_DOWNLOADS+"/SoundQ qualification")
            put(MediaStore.MediaColumns.IS_PENDING,1)
        }))
        val eligible=mutableStateOf(false)
        val reads=AtomicInteger()
        val decoded=AtomicBoolean()
        var primary:Throwable?=null
        try {
            instrumentation.context.assets.open("local-audio/embedded-cover.flac").use {input->resolver.openOutputStream(uri,"w")!!.use {input.copyTo(it)}}
            resolver.update(uri,ContentValues().apply {put(MediaStore.MediaColumns.IS_PENDING,0)},null,null)
            val version=graph.session.version()
            val row=graph.phoneAudio.awaitIndexed(uri,{graph.session.owns(version)})
            val ref=graph.phoneAudio.reference(row)
            compose.setContent {SoundQTheme {Box(Modifier.size(72.dp).testTag("owned cover")) {
                PhoneArtwork(graph,ref,72.dp,{eligible.value},onReadCompleted={success->decoded.set(success);reads.incrementAndGet()})
            }}}
            fun painted():Boolean {
                val pixels=compose.onNodeWithTag("owned cover").captureToImage().toPixelMap()
                val red=pixels[pixels.width/4,pixels.height/4]
                val green=pixels[pixels.width*3/4,pixels.height/4]
                val blue=pixels[pixels.width/4,pixels.height*3/4]
                val yellow=pixels[pixels.width*3/4,pixels.height*3/4]
                return red.red>.7f&&red.green<.4f&&green.green>.6f&&green.red<.4f&&blue.blue>.7f&&blue.red<.4f&&yellow.red>.8f&&yellow.green>.6f
            }
            compose.waitForIdle();assertFalse("Ineligible caller must not paint cover",painted())
            compose.runOnIdle {eligible.value=true}
            fun awaitRead(number:Int) {
                // The IO observer runs before the composition publishes pixels. Wait for
                // the real raster too, but let a failed or duplicate read fail immediately.
                compose.waitUntil(10000) {
                    val completed=reads.get()
                    completed>=number&&(completed!=number||!decoded.get()||painted())
                }
                assertEquals(number,reads.get());assertTrue(decoded.get())
            }
            awaitRead(1)
            assertTrue("The same mounted row must paint its actual embedded cover without remounting",painted())
            compose.runOnIdle {eligible.value=false}
            compose.waitForIdle();assertFalse("Retired caller must stop painting",painted())
            val scenario=compose.activityRule.scenario
            scenario.moveToState(Lifecycle.State.STARTED)
            scenario.moveToState(Lifecycle.State.RESUMED)
            compose.waitForIdle();assertFalse("Resume alone does not restore caller read access",painted())
            assertEquals(1,reads.get())
            compose.runOnIdle {eligible.value=true}
            awaitRead(2)
            assertTrue("Restored caller access must decode and paint in the retained slot",painted())
            // The test rule only discovers RESUMED roots. Pin the real attached
            // View and measured slot before the pause and draw that same View on main.
            val cover=compose.onNodeWithTag("owned cover").fetchSemanticsNode()
            val view=(cover.root as ViewRootForTest).view
            val bounds=cover.boundsInRoot
            fun redAtCover():Int {
                var pixel=0
                instrumentation.runOnMainSync {
                    check(view.isAttachedToWindow)
                    val bitmap=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
                    try {
                        view.draw(Canvas(bitmap))
                        pixel=bitmap.getPixel((bounds.left+bounds.width/4).toInt(),(bounds.top+bounds.height/4).toInt())
                    } finally {bitmap.recycle()}
                }
                return pixel
            }
            fun originalRed(pixel:Int)=Color.red(pixel)>178&&Color.green(pixel)<102
            assertTrue("The measured ARGB sample must see the original before pause",originalRed(redAtCover()))
            scenario.moveToState(Lifecycle.State.STARTED)
            assertEquals(Lifecycle.State.STARTED,scenario.state)
            val background=redAtCover()
            assertFalse("Actual Activity pause retires the original even while the caller remains eligible",originalRed(background))
            assertEquals(2,reads.get())
            scenario.moveToState(Lifecycle.State.RESUMED)
            awaitRead(3)
            assertTrue("A fresh Activity visit must decode and paint the same original",painted())
            writeThumbnailObservation("phone-recovery","reads=${reads.get()}\nactivityPause=$background\n")
        }catch(failure:Throwable){primary=failure;throw failure}
        finally {try {eligible.value=false;assertEquals(1,resolver.delete(uri,null,null))}catch(cleanup:Throwable){if(primary!=null)primary.addSuppressed(cleanup)else throw cleanup}}
    }

    @Test fun artworkPaintRerecordsWhenObservedAdmissionRetiresRetainedArgb() {
        fun solid()=Bitmap.createBitmap(8,8,Bitmap.Config.ARGB_8888).apply {eraseColor(Color.MAGENTA)}
        val retained=solid()
        val mounted=AtomicBoolean(true)
        val pixels=MutableStateFlow<Bitmap?>(retained)
        val live=AtomicBoolean(true)
        val admitted=mutableStateOf(true)
        val getterCalls=AtomicInteger()
        val bitmap={getterCalls.incrementAndGet();pixels.value.takeIf {admitted.value&&live.get()}}
        compose.setContent {SoundQTheme {Box(Modifier.size(72.dp).testTag("argb-control")) {
            ArtworkPaint(pixels,bitmap,mounted,72.dp)
        }}}
        val slot=hasTestTag("argb-control")
        fun raster()=requireNotNull(thumbnailRaster(compose,compose.onNode(slot),slot,1f) {pixel,_,_->pixel==Color.MAGENTA})
        val positive=raster()
        assertTrue(positive.sampled>100);assertEquals(positive.sampled,positive.matching)
        // Re-record on an independent bitmap publication to test live refusal, not a cached display list.
        val beforeLive=getterCalls.get()
        compose.runOnIdle {live.set(false);pixels.value=solid()}
        val liveRefusal=raster()
        assertEquals(0,liveRefusal.matching);assertTrue(getterCalls.get()>beforeLive)
        compose.runOnIdle {live.set(true);pixels.value=retained}
        assertEquals(positive.sampled,raster().matching)
        // No bitmap publication or remount: reading admission in the draw invalidates the recorded cover.
        val beforeObserved=getterCalls.get()
        compose.runOnIdle {admitted.value=false}
        val observedRefusal=raster()
        assertEquals(0,observedRefusal.matching);assertTrue(getterCalls.get()>beforeObserved)
        assertSame(retained,pixels.value)
        compose.runOnIdle {admitted.value=true}
        assertEquals(positive.sampled,raster().matching)
        writeThumbnailObservation("argb-control","positive=$positive\nliveRefusal=$liveRefusal\nobservedRefusal=$observedRefusal\n")
    }
}
