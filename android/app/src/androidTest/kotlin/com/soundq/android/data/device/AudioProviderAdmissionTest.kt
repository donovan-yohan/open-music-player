package com.soundq.android.data.device

import android.content.ContentValues
import android.os.Environment
import android.provider.MediaStore
import com.soundq.android.awaitIndexed
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CancellationException

/** Real provider reads, no media permission or direct catalog publication. Index-listing cases need all files access. */
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
    /** A deleted earlier original does not keep a later one out of the Library. Needs all files access (runner appops). */
    @Test fun healthyIndexedFileSurvivesAnUnavailableEarlierFile() {
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
        withSource(bytes) {app.graph.phoneAudio.awaitIndexed(it,{app.graph.session.owns(version)})} // Deleted afterwards; its row stays known.
        withSource(bytes) {uri->
            app.graph.phoneAudio.awaitIndexed(uri,{app.graph.session.owns(version)})
            assertArrayEquals(bytes,context.contentResolver.openInputStream(uri)!!.use {it.readBytes()})
        }
    }
    /** Older builds' file and folder pickers keyed a MediaStore item by the route they reached it through. With all
     * files access the real provider proves those keys name the audio-index row; unproven keys stay unmapped. */
    @androidx.test.filters.SdkSuppress(minSdkVersion=30)
    @Test fun pickerKeysOfAnIndexedItemAreProvedAndOthersAreNot() {
        val bytes=instrumentation.context.assets.open("local-audio/tone.flac").use {it.readBytes()}
        withSource(bytes) {uri->
            val access=AndroidAudioAccess(context)
            assertTrue("Runner must allow all files access",access.storageAllowed())
            val id=android.content.ContentUris.parseId(uri)
            var indexed:AudioAccessObservation?=null
            val deadline=System.nanoTime()+java.util.concurrent.TimeUnit.SECONDS.toNanos(30)
            while(indexed==null&&System.nanoTime()<deadline) {
                indexed=access.discover({true}).observations.singleOrNull {it.locator.endsWith("/audio/media/$id")}
                if(indexed==null)Thread.sleep(100)
            }
            val listed=checkNotNull(indexed) {"Audio index never listed the item"}
            @Suppress("DEPRECATION") val data=MediaStore.MediaColumns.DATA
            val (path,generation)=context.contentResolver.query(uri,arrayOf(data,MediaStore.MediaColumns.GENERATION_ADDED),null,null,null)!!.use {it.moveToFirst();it.getString(0) to it.getLong(1)}
            @Suppress("DEPRECATION") val primary=Environment.getExternalStorageDirectory().path
            assertTrue(path.startsWith("$primary/"))
            // The keys a file grant on the Downloads collection, a folder grant and a downloads document produced.
            val fileGrant="media:${MediaStore.getVersion(context,"external")}:$uri:$generation"
            val folderGrant="document:com.android.externalstorage.documents:primary:${path.removePrefix("$primary/")}"
            val downloadsDocument="document:com.android.providers.downloads.documents:raw:$path"
            val replaced="media:${MediaStore.getVersion(context,"external")}:$uri:${generation+1}"
            val elsewhere="document:com.android.externalstorage.documents:primary:Music/soundq-absent-${UUID.randomUUID()}.flac"
            val cloud="document:com.google.android.apps.docs.storage:acc=1;doc=encoded"
            val proven=access.provenIndexKeys(listOf(fileGrant,folderGrant,downloadsDocument,replaced,elsewhere,cloud,listed.providerObject))
            android.util.Log.i("SoundQIdentity","index=${listed.providerObject} proven=$proven")
            assertEquals(mapOf(fileGrant to listed.providerObject,folderGrant to listed.providerObject,downloadsDocument to listed.providerObject),proven)
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
