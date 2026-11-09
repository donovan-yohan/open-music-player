package com.soundq.android

import android.content.ContentValues
import android.content.Intent
import android.os.Environment
import android.provider.MediaStore
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.artwork.PhoneArtwork
import com.soundq.designsystem.SoundQTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.UUID

/** Real repository, retriever, composition and raster. Only caller eligibility is held.
 * A row composed behind Settings must load its original cover when it becomes current. */
class PhoneArtworkAdmissionTest {
    @get:Rule val compose=createComposeRule()
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
        var primary:Throwable?=null
        try {
            instrumentation.context.assets.open("local-audio/embedded-cover.flac").use {input->resolver.openOutputStream(uri,"w")!!.use {input.copyTo(it)}}
            resolver.update(uri,ContentValues().apply {put(MediaStore.MediaColumns.IS_PENDING,0)},null,null)
            val version=graph.session.version()
            graph.phoneAudio.selected(uri,Intent.FLAG_GRANT_READ_URI_PERMISSION,false){graph.session.owns(version)}
            compose.waitUntil(15000){graph.phoneAudio.state.value.snapshot?.files?.any {f->f.available&&f.aliases.any {it.locator.value==uri.toString()}}==true}
            val row=graph.phoneAudio.state.value.snapshot!!.files.single {f->f.available&&f.aliases.any {it.locator.value==uri.toString()}}
            val ref=graph.phoneAudio.reference(row)
            compose.setContent {SoundQTheme {Box(Modifier.size(72.dp).testTag("owned cover")) {PhoneArtwork(graph,ref,72.dp,{eligible.value})}}}
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
            compose.waitUntil(10000){painted()}
            assertTrue("The same mounted row must paint its actual embedded cover without remounting",painted())
            compose.runOnIdle {eligible.value=false}
            compose.waitForIdle();assertFalse("Retired caller must stop painting",painted())
        }catch(failure:Throwable){primary=failure;throw failure}
        finally {try {eligible.value=false;assertEquals(1,resolver.delete(uri,null,null))}catch(cleanup:Throwable){if(primary!=null)primary.addSuppressed(cleanup)else throw cleanup}}
    }
}
