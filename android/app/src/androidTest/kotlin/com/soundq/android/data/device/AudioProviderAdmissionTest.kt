package com.soundq.android.data.device

import android.content.ContentValues
import android.os.Environment
import android.provider.MediaStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CancellationException

/** Real app-owned provider reads, no media permission or direct catalog publication. */
@RunWith(AndroidJUnit4::class)
@androidx.test.filters.SdkSuppress(minSdkVersion=29)
class AudioProviderAdmissionTest {
    private val instrumentation=InstrumentationRegistry.getInstrumentation()
    private val context get()=instrumentation.targetContext
    private fun digest(bytes:ByteArray)=MessageDigest.getInstance("SHA-256").digest(bytes).joinToString(""){"%02x".format(it)}
    private fun withSource(bytes:ByteArray, body:(android.net.Uri)->Unit) {
        val resolver=context.contentResolver
        val uri=checkNotNull(resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME,"soundq-proof-${UUID.randomUUID()}.flac")
            put(MediaStore.MediaColumns.MIME_TYPE,"audio/flac")
            put(MediaStore.MediaColumns.RELATIVE_PATH,Environment.DIRECTORY_DOWNLOADS+"/SoundQ qualification")
            put(MediaStore.MediaColumns.IS_PENDING,1)
        }))
        var primary:Throwable?=null
        try {
            resolver.openOutputStream(uri,"w")!!.use {it.write(bytes)}
            assertEquals(1,resolver.update(uri,ContentValues().apply {put(MediaStore.MediaColumns.IS_PENDING,0)},null,null))
            body(uri)
        } catch(failure:Throwable){primary=failure;throw failure}
        finally {try {assertEquals(1,resolver.delete(uri,null,null))}catch(cleanup:Throwable){if(primary!=null)primary.addSuppressed(cleanup)else throw cleanup}}
    }
    @Test fun hashOnlyProviderReadAcknowledgesExactBytesWithoutAStage() {
        val bytes=instrumentation.context.assets.open("local-audio/tone.flac").use {it.readBytes()}
        withSource(bytes) {uri->
            val access=AndroidAudioAccess(context)
            val before=context.cacheDir.listFiles()!!.map {it.name}.toSet()
            val expected=AudioContentProof(bytes.size.toLong(),digest(bytes))
            assertEquals(expected,access.proof(uri.toString()){true})
            assertEquals(before,context.cacheDir.listFiles()!!.map {it.name}.toSet())
            val stage=File.createTempFile("proof-control-",".flac",context.cacheDir)
            try {
                assertEquals(expected,access.copy(uri.toString(),stage){true})
                assertArrayEquals(bytes,stage.readBytes())
                assertEquals(expected,access.proof(uri.toString()){true})
                assertArrayEquals(bytes,context.contentResolver.openInputStream(uri)!!.use {it.readBytes()})
            } finally {assertTrue(stage.delete())}
        }
    }
    @Test fun healthySelectionSurvivesAnUnavailablePreviouslySelectedFile() {
        val app=context.applicationContext as com.soundq.android.FixtureApplication
        instrumentation.runOnMainSync {app.graph.session.retire()}
        fun await(message:String, ready:()->Boolean) {
            val deadline=System.nanoTime()+java.util.concurrent.TimeUnit.SECONDS.toNanos(30)
            while(System.nanoTime()<deadline){if(ready())return;Thread.sleep(20)}
            assertTrue(message,ready())
        }
        await("Signed-out provider catalog ready") {app.graph.phoneAudio.state.value.ready&&app.graph.session.state.value is com.soundq.android.data.AuthState.SignedOut}
        val version=app.graph.session.version()
        val bytes=instrumentation.context.assets.open("local-audio/tone.flac").use {it.readBytes()}
        fun select(uri:android.net.Uri) {
            app.graph.phoneAudio.selected(uri,android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION,false){app.graph.session.owns(version)}
            await("Healthy selected file acknowledged despite unavailable sibling") {app.graph.phoneAudio.state.value.snapshot?.files?.any {f->f.available&&f.aliases.any {it.locator.value==uri.toString()}}==true}
        }
        withSource(bytes) {select(it)} // Deletes only the first owned source, retaining its real catalog grant.
        withSource(bytes) {uri->
            select(uri)
            assertArrayEquals(bytes,context.contentResolver.openInputStream(uri)!!.use {it.readBytes()})
        }
    }
    /** The indexed scan and a file grant reach one MediaStore row through different collections. */
    @Test fun oneMediaStoreRowHasOneIdentityThroughEachRoute() {
        val bytes=instrumentation.context.assets.open("local-audio/tone.flac").use {it.readBytes()}
        withSource(bytes) {uri->
            val access=AndroidAudioAccess(context)
            assertTrue("Audio index read access required",access.indexedAllowed())
            val id=android.content.ContentUris.parseId(uri)
            var indexed:AudioAccessObservation?=null
            val deadline=System.nanoTime()+java.util.concurrent.TimeUnit.SECONDS.toNanos(30)
            while(indexed==null&&System.nanoTime()<deadline) {
                indexed=access.discover(emptyList(),{true}).observations.singleOrNull {android.net.Uri.parse(it.locator).lastPathSegment==id.toString()}
                if(indexed==null)Thread.sleep(100)
            }
            val listed=checkNotNull(indexed) {"Audio index never listed the item"}
            val granted=access.metadata(uri,uri.toString())
            android.util.Log.i("SoundQIdentity","indexed=${listed.locator} granted=${granted.locator} key=${granted.providerObject} former=${granted.aliases-granted.providerObject}")
            assertNotEquals(listed.locator,granted.locator)
            assertEquals(listed.providerObject,granted.providerObject)
            assertEquals(setOf(listed.providerObject),listed.aliases)
            // The file grant's earlier key stays provable so stored rows under it fold into this one.
            assertEquals(1,(granted.aliases-granted.providerObject).size)
            assertTrue((granted.aliases-granted.providerObject).single().contains(uri.toString()))
        }
    }
    @Test fun emptyMissingAndRetiredProviderReadsAreRefused() {
        val access=AndroidAudioAccess(context)
        withSource(byteArrayOf()) {uri->
            try {access.proof(uri.toString()){true};fail("Empty provider source must be refused")}catch(_:IllegalArgumentException){}
        }
        val bytes=instrumentation.context.assets.open("local-audio/tone.flac").use {it.readBytes()}
        var removed:android.net.Uri?=null
        withSource(bytes) {uri->
            removed=uri
            try {access.proof(uri.toString()){false};fail("Retired provider read must be refused")}catch(_:CancellationException){}
            assertArrayEquals(bytes,context.contentResolver.openInputStream(uri)!!.use {it.readBytes()})
        }
        try {access.proof(checkNotNull(removed).toString()){true};fail("Missing provider source must be refused")}catch(_:java.io.FileNotFoundException){}
    }
}
