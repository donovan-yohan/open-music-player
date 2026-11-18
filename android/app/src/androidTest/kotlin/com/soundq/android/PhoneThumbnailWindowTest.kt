package com.soundq.android

import android.content.ContentValues
import android.graphics.Color
import android.os.Environment
import android.os.Looper
import android.provider.MediaStore
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.artwork.PhoneArtwork
import com.soundq.designsystem.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Exact native cache-window helper and actual PhoneArtwork/MediaMetadataRetriever/BitmapFactory.
 * Only test-owned embedded-cover.flac is inserted; no production copy/cache or image stand-in.
 * The caller's foreground/read-eligibility predicate matches the native phone-row boundary.
 */
class PhoneThumbnailWindowTest {
    @get:Rule val compose=createComposeRule()
    private class Owner:LifecycleOwner {
        val registry=LifecycleRegistry(this)
        override val lifecycle:Lifecycle get()=registry
    }
    private fun ownQuadrant(pixel:Int,x:Float,y:Float):Boolean = when {
        y<.5f&&x<.5f->Color.red(pixel)>178&&Color.green(pixel)<102
        y<.5f->Color.green(pixel)>153&&Color.red(pixel)<102
        x<.5f->Color.blue(pixel)>178&&Color.red(pixel)<102
        // The light raised/fallback color is high in red and green too. Require
        // the original's yellow chroma so fallback cannot score as a retained cover.
        else->Color.red(pixel)>204&&Color.green(pixel)>153&&Color.blue(pixel)<128
    }
    @Test fun nativeWindowCompletesUnseenOriginalThenPaintsRetainedQuadrantsAtSlowEntry() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val context=instrumentation.targetContext
        val graph=(context.applicationContext as FixtureApplication).graph
        val resolver=context.contentResolver
        val uri=requireNotNull(resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME,"soundq-owned-window-${UUID.randomUUID()}.flac")
            put(MediaStore.MediaColumns.MIME_TYPE,"audio/flac")
            put(MediaStore.MediaColumns.RELATIVE_PATH,Environment.DIRECTORY_DOWNLOADS+"/SoundQ qualification")
            put(MediaStore.MediaColumns.IS_PENDING,1)
        }))
        val owner=Owner();val eligible=mutableStateOf(true);val mounted=mutableStateOf(true)
        val completed=AtomicInteger();val decoded=AtomicBoolean();val farCompleted=AtomicInteger();val ranOnMain=AtomicBoolean()
        val retiredChecks=AtomicInteger()
        var state:LazyListState?=null
        var contentSet=false
        var primary:Throwable?=null
        try {
            instrumentation.context.assets.open("local-audio/embedded-cover.flac").use {input->resolver.openOutputStream(uri,"w")!!.use {input.copyTo(it)}}
            assertEquals(1,resolver.update(uri,ContentValues().apply {put(MediaStore.MediaColumns.IS_PENDING,0)},null,null))
            val version=graph.session.version()
            val row=graph.phoneAudio.awaitIndexed(uri,{graph.session.owns(version)})
            val ref=graph.phoneAudio.reference(row)
            val requestsBefore=ProductTransportFixture.server.requestCount
            instrumentation.runOnMainSync {owner.registry.currentState=Lifecycle.State.RESUMED}
            compose.setContent {SoundQTheme {CompositionLocalProvider(LocalLifecycleOwner provides owner) {
                if(mounted.value) {
                    val scroll=rememberSoundQThumbnailListState()
                    SideEffect {state=scroll}
                    LazyColumn(Modifier.width(320.dp).height(288.dp).testTag("phone-window"),state=scroll) {
                        items(40,key={"phone-$it"}) {index->SoundQThumbnailItem(scroll,"phone-$index") {
                            Box(Modifier.fillMaxWidth().height(72.dp)) {
                                Box(Modifier.size(72.dp).testTag("phone-cover-$index")) {
                                    if(index==5||index==20)PhoneArtwork(graph,ref,72.dp,
                                        {
                                            val resumed=owner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
                                            if(index==5&&!resumed)retiredChecks.incrementAndGet()
                                            eligible.value&&resumed
                                        },
                                        onReadCompleted={success->
                                            // Observation fires AFTER native extraction/decode and release,
                                            // BEFORE the production source-valid publication continuation.
                                            if(index==5){decoded.set(success);ranOnMain.set(Looper.myLooper()==Looper.getMainLooper());completed.incrementAndGet()}
                                            else farCompleted.incrementAndGet()
                                        })
                                    else SoundQArtworkSlot()
                                }
                            }
                        }}
                    }
                }
            }}}
            contentSet=true
            val list=compose.onNodeWithTag("phone-window")
            compose.waitUntil(10000){completed.get()>0}
            compose.waitForIdle() // At-rest publication/layout settlement, never entry-image readiness.
            assertTrue("The unseen native original must decode successfully",decoded.get())
            assertFalse("Original extraction must not run on main",ranOnMain.get())
            val atRest=compose.runOnIdle {requireNotNull(state).layoutInfo.let {info->
                info.visibleItemsInfo.filter {it.offset<info.viewportEndOffset&&it.offset+it.size>info.viewportStartOffset}.map {it.index}
            }}
            assertFalse("Extraction completed with target still geometrically offscreen",5 in atRest)
            assertTrue("Target must lie inside one measured native viewport ahead",atRest.max()<5&&5<=atRest.max()+atRest.size)
            assertEquals("Exactly one original extraction before entry",1,completed.get())
            assertEquals("Far consumer must not extract the original",0,farCompleted.get())
            assertNull("No target pixels intersect the real viewport at rest",thumbnailRaster(compose,list,hasTestTag("phone-cover-5"),1f,::ownQuadrant))
            captureListeningStage("phone-lookahead-unseen-extracted")
            val first=slowThumbnailEntry(compose,list,hasTestTag("phone-cover-5"),24f*thumbnailDensity(),::ownQuadrant)
            writeThumbnailObservation("phone-lookahead-first","atRest=$atRest\ncompleted=${completed.get()}\nfarCompleted=${farCompleted.get()}\nfirst=$first\n")
            captureListeningStage("phone-lookahead-first-entry")
            assertTrue("Own visible quadrants must already paint at FIRST meaningful entry: $first",
                first.sampled>100&&first.quadrants.containsAll(setOf(0,1))&&first.matching>=first.sampled*.9f)
            assertEquals("First entry must reuse the completed native extraction",1,completed.get())
            val four=slowThumbnailEntry(compose,list,hasTestTag("phone-cover-5"),72f*.8f*thumbnailDensity(),::ownQuadrant)
            assertEquals("The first 80% entry must expose all four own quadrants",setOf(0,1,2,3),four.quadrants)
            assertTrue("All retained own quadrant pixels, without an image-ready wait: $four",four.sampled>100&&four.matching>=four.sampled*.9f)
            assertEquals("Continued slow entry must not re-extract",1,completed.get())
            // Real lifecycle retirement plus the same caller foreground predicate used by phone rows.
            compose.runOnIdle {owner.registry.currentState=Lifecycle.State.STARTED}
            compose.waitForIdle()
            val beforeRaster=retiredChecks.get()
            var legacyYellowMatches=0
            val background=requireNotNull(thumbnailRaster(compose,list,hasTestTag("phone-cover-5"),24f*thumbnailDensity()) {pixel,x,y->
                if(x>=.5f&&y>=.5f&&Color.red(pixel)>204&&Color.green(pixel)>153)legacyYellowMatches++
                ownQuadrant(pixel,x,y)
            })
            writeThumbnailObservation("phone-background","lifecycle=${owner.lifecycle.currentState}\nflow=${owner.lifecycle.currentStateFlow.value}\ncallerChecksBeforeRaster=$beforeRaster\ncallerChecksAfterRaster=${retiredChecks.get()}\nlegacyYellowMatches=$legacyYellowMatches\nbackground=$background\n")
            assertTrue("Background caller must paint fallback, not retained originals",background.matching<background.sampled*.1f)
            // Retire caller read access, then restore foreground alone: no new extraction/enrichment.
            compose.runOnIdle {eligible.value=false;owner.registry.currentState=Lifecycle.State.RESUMED}
            compose.waitForIdle()
            val refused=requireNotNull(thumbnailRaster(compose,list,hasTestTag("phone-cover-5"),24f*thumbnailDensity(),::ownQuadrant))
            assertTrue("Retired caller access must remain fallback on foreground return",refused.matching<refused.sampled*.1f)
            assertEquals(1,completed.get());assertEquals(0,farCompleted.get())
            assertEquals("Original-only thumbnail must not perform remote enrichment",requestsBefore,ProductTransportFixture.server.requestCount)
            val fallback=requireNotNull(thumbnailRaster(compose,list,hasTestTag("phone-cover-4"),24f*thumbnailDensity(),::ownQuadrant))
            assertEquals("The neighboring known fallback must not classify as the original",0,fallback.matching)
            writeThumbnailObservation("phone-lookahead","atRest=$atRest\nfirst=$first\nfour=$four\nbackground=$background\nrefused=$refused\ncompleted=${completed.get()}\nfarCompleted=${farCompleted.get()}\nremoteRequestsDelta=${ProductTransportFixture.server.requestCount-requestsBefore}\n")
            captureListeningStage("phone-lookahead-retired")
        }catch(failure:Throwable){primary=failure;throw failure}
        finally {
            var cleanupFailure:Throwable?=null
            try {
                if(contentSet) {
                    compose.runOnIdle {eligible.value=false;mounted.value=false;owner.registry.currentState=Lifecycle.State.DESTROYED}
                    compose.waitForIdle()
                } else instrumentation.runOnMainSync {owner.registry.currentState=Lifecycle.State.DESTROYED}
            }catch(cleanup:Throwable){cleanupFailure=cleanup}
            try {assertEquals("Delete only this fixture-owned MediaStore item",1,resolver.delete(uri,null,null))}
            catch(cleanup:Throwable){if(cleanupFailure!=null)cleanupFailure.addSuppressed(cleanup)else cleanupFailure=cleanup}
            cleanupFailure?.let {if(primary!=null)primary.addSuppressed(it)else throw it}
        }
    }
}
