package com.soundq.android

import android.app.Instrumentation
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.AuthState
import com.soundq.android.data.preferences.Appearance
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

/** Real MainActivity and Library route. All files access is the only phone-audio grant; changing it kills the app
 * process, so the runner sets it with `appops` between methods and passes fixture names as instrumentation arguments.
 * Fixtures that MediaStore has not indexed are placed by the runner on the lower filesystem (`/data/media/0`), which
 * an app cannot do. The upgrade cases start from a store and URI grant an older build's pickers left behind. */
@androidx.test.filters.SdkSuppress(minSdkVersion=30)
class LocalAudioAccessJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private val packageName get()=instrumentation.targetContext.packageName
    private fun arg(name:String)=checkNotNull(InstrumentationRegistry.getArguments().getString(name)) {"Missing instrumentation argument $name"}

    private fun model(fileAccess:Boolean):ProductViewModel {
        assertEquals("Runner must set all files access=$fileAccess",fileAccess,Environment.isExternalStorageManager())
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.runOnIdle {model.graph.session.retire()}
        compose.waitUntil(15000){model.graph.session.state.value is AuthState.SignedOut&&model.graph.phoneAudio.state.value.let {it.ready&&!it.refreshing}&&
            compose.onAllNodesWithContentDescription("Library search query").fetchSemanticsNodes().isNotEmpty()}
        return model
    }
    private fun accessOff()=model(fileAccess=false)
    /** No media permission is requested or held: all files access alone lists and plays phone audio. */
    private fun noMediaPermission() {
        @Suppress("DEPRECATION") val requested=instrumentation.targetContext.packageManager.getPackageInfo(packageName,PackageManager.GET_PERMISSIONS).requestedPermissions.orEmpty().toSet()
        assertFalse(requested.toString(),"android.permission.READ_MEDIA_AUDIO" in requested)
        if(Build.VERSION.SDK_INT>=33)assertEquals(PackageManager.PERMISSION_DENIED,instrumentation.targetContext.checkSelfPermission("android.permission.READ_MEDIA_AUDIO"))
        if(Build.VERSION.SDK_INT>=30)assertFalse("android.permission.READ_EXTERNAL_STORAGE" in requested)
    }
    private val noPickerCopy=listOf("Add folder","Open audio file","Choose file again","Available for this session","Manage local audio")
    private fun noPickerActions()=noPickerCopy.forEach {compose.onAllNodes(hasText(it,substring=true)).assertCountEquals(0)}
    private fun appearance(model:ProductViewModel,choice:Appearance) {
        compose.waitUntil(10000){model.graph.appearancePreferences.state.value.ready}
        assertTrue(model.graph.appearancePreferences.setChoice(model.graph.appearancePreferences.capture()!!,choice){true})
        compose.waitUntil(5000){model.graph.appearancePreferences.state.value.choice==choice}
        // Let the recomposed theme and system bars reach a drawn frame before a system screenshot.
        compose.waitForIdle();Thread.sleep(1000);compose.waitForIdle()
    }
    private fun capture(name:String) {
        val bitmap=instrumentation.uiAutomation.takeScreenshot()
        val out=java.io.File(instrumentation.targetContext.filesDir,"local-access-captures").apply {mkdirs()}
        try {java.io.File(out,"$name.png").outputStream().use {assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it))}}finally{bitmap.recycle()}
    }
    private fun resumed():Boolean {var state=Lifecycle.State.INITIALIZED;instrumentation.runOnMainSync {state=compose.activity.lifecycle.currentState};return state.isAtLeast(Lifecycle.State.RESUMED)}
    private fun waitFor(timeoutMs:Long,condition:()->Boolean):Boolean {
        val end=System.currentTimeMillis()+timeoutMs
        while(System.currentTimeMillis()<end){if(condition())return true;Thread.sleep(100)}
        return condition()
    }
    private fun withMusicOriginal(body:(String)->Unit) {
        val resolver=instrumentation.targetContext.contentResolver
        val name="soundq-access-${UUID.randomUUID()}.wav"
        val uri=checkNotNull(resolver.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME,name);put(MediaStore.MediaColumns.MIME_TYPE,"audio/wav")
            put(MediaStore.MediaColumns.RELATIVE_PATH,Environment.DIRECTORY_MUSIC+"/SoundQ access qualification");put(MediaStore.MediaColumns.IS_PENDING,1)
        }))
        try {
            val rate=16000;val frames=rate*5;val size=frames*2
            val bytes=ByteBuffer.allocate(44+size).order(ByteOrder.LITTLE_ENDIAN).apply {
                put("RIFF".toByteArray()).putInt(36+size).put("WAVEfmt ".toByteArray()).putInt(16)
                putShort(1).putShort(1).putInt(rate).putInt(rate*2).putShort(2).putShort(16).put("data".toByteArray()).putInt(size)
                repeat(frames){putShort((kotlin.math.sin(it*2*Math.PI*223/rate)*4000).toInt().toShort())}
            }.array()
            resolver.openOutputStream(uri,"w")!!.use {it.write(bytes)}
            assertEquals(1,resolver.update(uri,ContentValues().apply {put(MediaStore.MediaColumns.IS_PENDING,0)},null,null))
            body(name)
        } finally {assertEquals(1,resolver.delete(uri,null,null))}
    }
    private fun localFilesShowsAccessOff(hidden:String?=null) {
        compose.onNodeWithContentDescription("Local files").performClick()
        compose.onNodeWithText("File access is off").assertIsDisplayed()
        compose.onNodeWithText("Allow file access").assertIsDisplayed()
        hidden?.let {compose.onAllNodes(hasText(it,substring=true)).assertCountEquals(0)}
        compose.onNodeWithText("No matching tracks").assertDoesNotExist()
    }
    private fun rowAppears(model:ProductViewModel,stem:String) {
        val row=hasText(stem,substring=true) and hasClickAction() and !hasSetTextAction()
        // The Library is lazy: scroll toward the row so an off-viewport item is composed before it is judged absent.
        try {compose.waitUntil(60000){runCatching {compose.onNode(hasScrollToIndexAction()).performScrollToNode(row)}.isSuccess&&compose.onAllNodes(row).fetchSemanticsNodes().isNotEmpty()}}
        catch(timeout:androidx.compose.ui.test.ComposeTimeoutException) {
            val phone=model.graph.phoneAudio.state.value
            fail("Row $stem absent: ready=${phone.ready} access=${phone.permission} refreshing=${phone.refreshing} scan=${phone.scan} message=${phone.message} "+
                "files=${phone.snapshot?.files?.filter {it.available}?.map {it.metadata.filename}}")
        }
    }
    private fun openLocalAudioSettings() {
        compose.onNodeWithContentDescription("Settings").performClick()
        compose.onNode(hasText("Local audio") and hasClickAction()).performScrollTo().performClick()
        compose.onNode(hasText("Local audio") and isHeading()).assertIsDisplayed()
    }

    @Test fun allowFileAccessLaunchesAllFilesAccessSettings() {
        val model=accessOff()
        localFilesShowsAccessOff()
        appearance(model,Appearance.Light);capture("access-off-light")
        appearance(model,Appearance.Dark);capture("access-off-dark")
        appearance(model,Appearance.System)
        val launched=java.util.concurrent.atomic.AtomicReference<Intent?>()
        val monitor=object:Instrumentation.ActivityMonitor() {
            override fun onStartActivity(intent:Intent):Instrumentation.ActivityResult? =
                if(intent.action==Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION){launched.set(intent);Instrumentation.ActivityResult(0,null)}else null
        }
        instrumentation.addMonitor(monitor)
        try {
            compose.onNodeWithText("Allow file access").performClick()
            assertTrue("Allow file access did not request the all files access page",waitFor(5000){launched.get()!=null})
            assertEquals("package:$packageName",launched.get()!!.dataString)
        } finally {instrumentation.removeMonitor(monitor)}
        // Settings > Local audio offers the same single action (Local files off so only Settings shows it).
        compose.onNodeWithContentDescription("Local files").performClick()
        openLocalAudioSettings()
        compose.onNode(hasText("File access") and hasText("Off")).assertIsDisplayed()
        compose.onNodeWithText("Allow file access").performScrollTo().assertIsDisplayed()
        compose.onAllNodes(hasText("Allow file access")).assertCountEquals(1)
        noPickerActions()
        appearance(model,Appearance.Light);capture("settings-access-off-light")
        appearance(model,Appearance.Dark);capture("settings-access-off-dark")
        appearance(model,Appearance.System)
    }

    /** Leaves the real system page in front; the runner then grants with appops, which restarts the app. */
    @Test fun allowFileAccessOpensTheSystemPage() {
        accessOff()
        localFilesShowsAccessOff()
        compose.onNodeWithText("Allow file access").performClick()
        assertTrue("Allow file access did not open system UI",waitFor(10000){!resumed()})
    }

    /** After the runner grants all files access: the cold start rescans and lists audio from the Download root
     * and from a folder MediaStore had not indexed. */
    @Test fun afterFileAccessGrantLocalFilesListsSharedStorageAudio() {
        val downloadStem=arg("downloadStem");val unindexedStem=arg("unindexedStem");val unindexedPath=arg("unindexedPath")
        val model=model(fileAccess=true)
        noMediaPermission()
        compose.onNodeWithContentDescription("Local files").performClick()
        for(stem in listOf(downloadStem,unindexedStem))rowAppears(model,stem)
        noPickerActions()
        compose.onNodeWithText("File access is off").assertDoesNotExist()
        compose.onNodeWithText("Allow file access").assertDoesNotExist()
        @Suppress("DEPRECATION") val data=MediaStore.MediaColumns.DATA
        val indexed=instrumentation.targetContext.contentResolver.query(MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL),arrayOf(data),"$data=?",arrayOf(unindexedPath),null)!!.use {it.count}
        assertEquals("The walk asked MediaStore to index the unlisted file",1,indexed)
        capture("access-granted-rows")
        openLocalAudioSettings()
        compose.onNode(hasText("File access") and hasText("Allowed")).assertIsDisplayed()
        compose.onNodeWithText("Allow file access").assertDoesNotExist()
        compose.waitUntil(60000){!model.graph.phoneAudio.state.value.refreshing&&compose.onAllNodes(hasText("Songs")).fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithText("Scan again").performScrollTo().assertIsDisplayed()
        noPickerActions()
        capture("settings-access-on")
        appearance(model,Appearance.Light);capture("settings-access-on-light")
        appearance(model,Appearance.Dark);capture("settings-access-on-dark")
        appearance(model,Appearance.System)
    }

    @Test fun undecodablePhoneFileStaysVisibleAsUnplayableAfterTap() {
        assertTrue("Runner must allow all files access",Environment.isExternalStorageManager())
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.runOnIdle {model.graph.session.retire()}
        compose.waitUntil(15000){model.graph.session.state.value is AuthState.SignedOut&&model.graph.phoneAudio.state.value.ready}
        val resolver=instrumentation.targetContext.contentResolver
        val stem="soundq-protected-${UUID.randomUUID()}"
        // Encrypted/protected bytes behind an audio extension, as a sync client's private cache can leave in Music/.
        val uri=checkNotNull(resolver.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME,"$stem.mp3");put(MediaStore.MediaColumns.MIME_TYPE,"audio/mpeg")
            put(MediaStore.MediaColumns.RELATIVE_PATH,Environment.DIRECTORY_MUSIC+"/Spotify/Synced files");put(MediaStore.MediaColumns.IS_PENDING,1)
        }))
        try {
            resolver.openOutputStream(uri,"w")!!.use {it.write(java.util.Random(7).let {r->ByteArray(256*1024).also(r::nextBytes)})}
            assertEquals(1,resolver.update(uri,ContentValues().apply {put(MediaStore.MediaColumns.IS_PENDING,0)},null,null))
            compose.runOnIdle {model.graph.phoneAudio.refresh()}
            compose.waitUntil(30000){model.graph.phoneAudio.state.value.snapshot?.files?.any {it.available&&it.metadata.filename=="$stem.mp3"}==true}
            compose.onNodeWithContentDescription("Local files").performClick()
            val row=hasText(stem,substring=true) and hasClickAction() and !hasSetTextAction()
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(row)
            compose.onNode(row).performClick()
            compose.waitUntil(20000){model.playback.value.error!=null}
            compose.waitUntil(10000){compose.onAllNodes(hasText("Can’t play this file")).fetchSemanticsNodes().isNotEmpty()}
            // The row remains in Local files with an honest label instead of vanishing.
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasText(stem,substring=true) and hasClickAction() and !hasSetTextAction())
            compose.onNodeWithText("Can’t play this file").assertIsDisplayed()
            capture("unplayable-phone-file")
        } finally {
            compose.runOnIdle {model.controller.pause();model.controller.clear()}
            assertEquals(1,resolver.delete(uri,null,null))
        }
    }

    /** After the upgrade, with all files access: startup released the picker grant; the picked file the provider
     * proves is the audio-index row keeps its row id, recency and resume; unproven picker rows and their state are
     * gone, never shown as unavailable. Runs twice across a restart: the migration is idempotent. */
    @Test fun upgradeReleasesPickerGrantsAndFoldsOrDropsTheirRows() {
        val pickedId=java.util.UUID.fromString(arg("pickedId"));val stem=arg("pickedStem")
        val dropped=arg("droppedIds").split(',').map(java.util.UUID::fromString)
        val playedAt=arg("playedAt").toLong();val resumeMs=arg("resumeMs").toLong()
        val model=model(fileAccess=true)
        val resolver=instrumentation.targetContext.contentResolver
        assertTrue("Startup releases every persisted URI grant: ${resolver.persistedUriPermissions.map {it.uri}}",waitFor(10000){resolver.persistedUriPermissions.isEmpty()})
        val phone=model.graph.phoneAudio
        compose.waitUntil(120000){phone.state.value.let {!it.refreshing&&it.scan?.complete==true}}
        val snapshot=phone.state.value.snapshot!!
        val picked=snapshot.files.single {it.id.value==pickedId}
        assertTrue(picked.available)
        assertEquals("$stem.mp3",picked.metadata.filename)
        assertTrue(picked.objectId.objectId,picked.objectId.objectId.startsWith("media:"))
        assertEquals(listOf(com.soundq.android.data.deviceaudio.GrantKind.INDEXED),snapshot.grants.map {it.kind})
        assertEquals(1,snapshot.files.count {it.metadata.filename=="$stem.mp3"})
        assertTrue(snapshot.files.none {it.id.value in dropped})
        val history=snapshot.history.single {it.key==com.soundq.android.data.deviceaudio.HistoryKey.Device(picked.id)}
        assertEquals(playedAt,history.playedAtEpochMs)
        assertEquals(resumeMs,history.bookmark?.takeIf {it.owner==picked.owner}?.positionMs)
        assertTrue(snapshot.history.none {(it.key as? com.soundq.android.data.deviceaudio.HistoryKey.Device)?.id?.value in dropped})
        // The store itself no longer holds picker grants or the dropped rows.
        val stored=java.io.File(model.graph.directory,"phone-listening.v1.json").readText()
        for(gone in listOf("\"FILE\"","\"FOLDER\"")+dropped.map {it.toString()})assertFalse(gone,stored.contains(gone))
        compose.onNodeWithContentDescription("Local files").performClick()
        rowAppears(model,stem)
        // The folded row keeps its resume point.
        compose.onAllNodes(hasText(stem,substring=true) and hasText("Resume at 0:${"%02d".format(resumeMs/1000)}",substring=true)).assertCountEquals(1)
        capture("upgrade-folded-row")
        // All tracks also lists unavailable phone rows: none are left from the pickers.
        compose.onNodeWithContentDescription("Local files").performClick()
        compose.waitForIdle()
        compose.onAllNodes(hasText("Unavailable",substring=true)).assertCountEquals(0)
        compose.onAllNodes(hasText(stem,substring=true) and hasClickAction() and !hasSetTextAction()).assertCountEquals(1)
        noPickerActions()
        capture("upgrade-all-tracks")
    }

    /** Capture only: what Local files shows on the first start after the upgrade (the RED run uses the older app). */
    @Test fun upgradeLocalFilesAsShown() {
        val model=model(fileAccess=true)
        compose.waitUntil(120000){model.graph.phoneAudio.state.value.let {!it.refreshing&&it.scan!=null}}
        compose.onNodeWithContentDescription("Local files").performClick()
        compose.waitForIdle();Thread.sleep(500)
        capture("upgrade-local-files")
        compose.onNodeWithContentDescription("Local files").performClick()
        compose.waitForIdle();Thread.sleep(500)
        capture("upgrade-all-tracks")
        android.util.Log.i("SoundQUpgrade","rows=${model.graph.phoneAudio.state.value.snapshot?.files?.map {it.metadata.filename to it.available}} grants=${model.graph.phoneAudio.state.value.snapshot?.grants?.map {it.kind to it.state}} persisted=${instrumentation.targetContext.contentResolver.persistedUriPermissions.map {it.uri}}")
    }
}
