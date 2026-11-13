package com.soundq.android

import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.Rect
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.AuthState
import com.soundq.android.data.deviceaudio.DeviceAudio
import com.soundq.android.playback.PlaybackProjection
import com.soundq.android.playback.PlaybackRef
import com.soundq.android.product.ProductViewModel
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Ordinary production root, service, menu and external Files. Only packaged generated originals. */
@androidx.test.filters.SdkSuppress(minSdkVersion=29)
class NativeSongActionsJourneyTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private val app get() = context.applicationContext as CallbackFrontendFixtureApplication
    private val output get() = File(context.filesDir, "native-song-actions-captures").apply { mkdirs() }
    private val longA = "Native QA A unselected original with a deliberately overflowing title for static text comparison"
    private val longB = "Native QA B selected original with a deliberately overflowing title for continuous native marquee motion"
    private var query = ""
    private val artistA = "Unselected synthetic ensemble with an intentionally overflowing artist identity"
    private val artistB = "Selected synthetic ensemble with an intentionally overflowing artist identity"
    private data class Original(val uri: Uri, val row: DeviceAudio, val bytes: ByteArray, val path: String) {
        val id get() = row.id.value.toString()
    }
    private data class Crop(val label: String, val rect: Rect)
    private fun <T> main(block: () -> T): T {
        var value: Result<T>? = null
        instrumentation.runOnMainSync { value = runCatching(block) }
        return value!!.getOrThrow()
    }
    private fun await(message: String, seconds: Long = 15, ready: () -> Boolean) {
        val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(seconds)
        while (System.nanoTime() < end) { if (ready()) return; Thread.sleep(20) }
        assertTrue(message, ready())
    }
    private fun native(): JSONObject = JSONObject(app.callbackPlayer.javaClass.getDeclaredMethod("nativeDiagnostics").apply { isAccessible = true }.invoke(app.callbackPlayer) as String)
    private fun deck(): JSONObject? {
        val identity = main { app.callbackPlayer.javaClass.getDeclaredField("ordinaryIdentity").apply { isAccessible = true }.getLong(app.callbackPlayer) }
        val decks = native().getJSONArray("decks")
        return (0 until decks.length()).map { decks.getJSONObject(it) }.singleOrNull { identity > 0 && it.getLong("identity") == identity }
    }
    private fun hasIdentity(identity: Long): Boolean = native().getJSONArray("decks").let { ds -> (0 until ds.length()).any { ds.getJSONObject(it).getLong("identity") == identity } }
    private fun capture(name: String) {
        val image = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        try { File(output, "$name.png").outputStream().use { assertTrue(image.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
        finally { image.recycle() }
    }
    private fun tree(node: AccessibilityNodeInfo?): String {
        if (node == null) return "<no active root>"
        return buildString {
            append("${node.packageName} ${node.className} text=${node.text} desc=${node.contentDescription}\n")
            repeat(node.childCount) { append(tree(node.getChild(it))) }
        }
    }
    private fun shell(command: String): String = android.os.ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command)).bufferedReader().use { it.readText() }
    private fun withOriginals(body: (ProductViewModel, List<Original>, Long) -> Unit) {
        val model = compose.runOnIdle { ViewModelProvider(compose.activity)[ProductViewModel::class.java] }
        compose.runOnIdle { model.graph.session.retire(); model.controller.pause(); model.controller.clear() }
        compose.waitUntil(15_000) { model.graph.session.state.value is AuthState.SignedOut && model.graph.phoneAudio.state.value.ready && model.playback.value.connection == PlaybackProjection.Connection.Connected }
        val version = model.graph.session.version()
        val owned = mutableListOf<Uri>(); val originals = mutableListOf<Original>()
        val folder = "SoundQ native QA ${UUID.randomUUID()}"
        query = "soundq-native-${UUID.randomUUID().toString().take(8)}"
        var primary: Throwable? = null
        try {
            for ((asset, title, artist) in listOf(Triple("a.mp3",longA,artistA), Triple("b.mp3",longB,artistB), Triple("c.mp3","Native QA C","Trio"))) {
                val name = "$query-${asset.removeSuffix(".mp3")}.mp3"
                val r = context.contentResolver
                val uri = checkNotNull(r.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME,name);put(MediaStore.MediaColumns.MIME_TYPE,"audio/mpeg")
                    put(MediaStore.MediaColumns.RELATIVE_PATH,Environment.DIRECTORY_DOWNLOADS+"/"+folder)
                    put(MediaStore.MediaColumns.IS_PENDING,1)
                })).also(owned::add)
                val bytes = instrumentation.context.assets.open("native-song-actions/$asset").use { it.readBytes() }
                r.openOutputStream(uri,"w")!!.use { it.write(bytes) }
                assertEquals(1,r.update(uri,ContentValues().apply {put(MediaStore.MediaColumns.IS_PENDING,0)},null,null))
                @Suppress("DEPRECATION") val path = r.query(uri,arrayOf(MediaStore.MediaColumns.DATA),null,null,null)!!.use {check(it.moveToFirst());it.getString(0)}
                val scanned = java.util.concurrent.CountDownLatch(1)
                val scannedUri = java.util.concurrent.atomic.AtomicReference<Uri?>()
                android.media.MediaScannerConnection.scanFile(context,arrayOf(path),arrayOf("audio/mpeg")) {_,result->scannedUri.set(result);scanned.countDown()}
                assertTrue(scanned.await(10,TimeUnit.SECONDS))
                assertEquals(android.content.ContentUris.parseId(uri),android.content.ContentUris.parseId(checkNotNull(scannedUri.get())))
                r.query(uri,arrayOf(MediaStore.MediaColumns.IS_PENDING,MediaStore.MediaColumns.DISPLAY_NAME,MediaStore.Audio.Media.TITLE,MediaStore.Audio.Media.ARTIST),null,null,null)!!.use {
                    check(it.moveToFirst());assertEquals(0,it.getInt(0));assertEquals(name,it.getString(1));assertEquals(title,it.getString(2));assertEquals(artist,it.getString(3))
                }
                val row = model.graph.phoneAudio.awaitIndexed(uri,accept={it.metadata.filename==name && it.metadata.title==title && it.metadata.artist==artist})
                originals += Original(uri,row,bytes,path)
                android.util.Log.i("SoundQNativeActionsFixture","owned $uri path=$path metadata=${row.metadata}")
            }
            compose.waitUntil(15_000) {!model.graph.phoneAudio.state.value.refreshing && originals.all {model.graph.phoneAudio.observed(model.graph.phoneAudio.reference(it.row))!=null}}
            compose.onNodeWithContentDescription("Library search query").performTextReplacement(query)
            compose.onNodeWithContentDescription("Search library").performClick()
            body(model,originals,version)
        } catch(error: Throwable) {
            primary=error
            runCatching {File(output,"failure-resource-state.json").writeText(JSONObject().put("native",runCatching {native()}.getOrNull()).put("projection",model.playback.value.toString()).put("phone",model.graph.phoneAudio.state.value.toString()).toString(2))}.exceptionOrNull()?.let(error::addSuppressed)
            runCatching {capture("failure-${if(originals.size==3)"workload" else "setup"}");File(output,"failure-ui.txt").writeText(tree(instrumentation.uiAutomation.rootInActiveWindow))}.exceptionOrNull()?.let(error::addSuppressed)
            throw error
        } finally {
            var cleanup: Throwable? = null
            fun attempt(block: () -> Unit): Boolean = try {block();true} catch(error: Throwable) {if(cleanup==null)cleanup=error else cleanup!!.addSuppressed(error);false}
            val retired = mutableSetOf<Uri>()
            originals.forEach { original ->
                if(attempt { assertTrue("Concrete original retirement ${original.uri}",runBlocking {model.controller.retirePhoneFile(model.graph.phoneAudio.reference(original.row),version) {model.graph.session.owns(version)}}) }) retired += original.uri
            }
            val empty=attempt {
                main {model.controller.pause();model.controller.clear()}
                await("Actual service queue empty") {main {app.callbackPlayer.mediaItemCount==0}}
            }
            owned.forEach {uri -> attempt {
                check(empty && (originals.none {it.uri==uri} || uri in retired)) {"Retain original after retirement refusal $uri"}
                await("Concrete descriptors drained $uri") {model.graph.phoneAudio.originalDescriptorsDrained(originals.singleOrNull {it.uri==uri}?.id)}
                context.contentResolver.delete(uri,null,null)
                assertFalse(context.contentResolver.query(uri,arrayOf(MediaStore.MediaColumns._ID),null,null,null)?.use {it.moveToFirst()} ?: false)
                android.util.Log.i("SoundQNativeActionsFixture","retired/drained/deleted $uri")
            } }
            // Remove only this empty generated folder. Never recursively remove anything.
            attempt {originals.firstOrNull()?.let {val dir=File(it.path).parentFile!!; if(dir.exists())assertTrue("Empty owned folder",dir.delete())}}
            cleanup?.let {if(primary!=null)primary.addSuppressed(it) else throw it}
        }
    }
    private fun play(model: ProductViewModel, original: Original) {
        compose.onNode(hasContentDescription("${original.row.metadata.displayTitle}, ${original.row.metadata.artist}, Phone file",substring=true) and hasClickAction()).performScrollTo().performClick()
        await("Real selected native playback") { model.playback.value.isPlaying && deck()?.getLong("positionMs")?.let {it>300}==true }
        assertEquals(model.graph.phoneAudio.reference(original.row),model.playback.value.selectedDeviceOwner?.ref)
        assertEquals(1,main {app.callbackPlayer.mediaItemCount})
    }
    private fun crop(label: String, tag: String, text: String): Crop {
        val node=compose.onNode(hasTestTag(tag) and hasText(text),useUnmergedTree=true).assertIsDisplayed().fetchSemanticsNode()
        val view=(node.root as ViewRootForTest).view
        val location=main {IntArray(2).also {view.getLocationOnScreen(it)}}
        val b=node.boundsInRoot
        return Crop(label,Rect(kotlin.math.ceil(b.left).toInt()+location[0],kotlin.math.ceil(b.top).toInt()+location[1],kotlin.math.floor(b.right).toInt()+location[0],kotlin.math.floor(b.bottom).toInt()+location[1]))
    }
    private fun motion(model: ProductViewModel, phase: String) {
        val crops=listOf(crop("row-title","media-title",longB),crop("row-artist","media-artist",artistB),crop("compact-title","compact-title",longB),crop("compact-artist","compact-artist",artistB),crop("unselected-title","media-title",longA),crop("unselected-artist","media-artist",artistA),crop("fitting-title","media-title","Native QA C"),crop("fitting-artist","media-artist","Trio"))
        val samples=JSONArray();val hashes=crops.associate {it.label to mutableSetOf<String>()}
        val layoutFacts=JSONArray()
        for((tag,text) in listOf("media-title" to longB,"media-artist" to artistB,"compact-title" to longB,"compact-artist" to artistB)) {
            val node=compose.onNode(hasTestTag(tag) and hasText(text),useUnmergedTree=true).fetchSemanticsNode()
            val layouts=mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
            main {node.config[androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult].action!!(layouts)}
            val view=(node.root as ViewRootForTest).view
            layoutFacts.put(JSONObject().put("tag",tag).put("maxWidth",layouts.single().layoutInput.constraints.maxWidth).put("textWidth",layouts.single().size.width).put("windowFocused",main {view.hasWindowFocus()}).put("viewWidth",view.width))
        }
        File(output,"$phase-layout.json").writeText(layoutFacts.toString(2))
        capture("$phase-whole")
        repeat(22) {index ->
            // The rule owns Compose's frame clock: wall time alone leaves every
            // marquee frozen. Drive a frame, then inspect actual Android pixels,
            // with independent wall-time/native-cursor observations below.
            compose.mainClock.advanceTimeBy(250)
            compose.waitForIdle()
            val image=checkNotNull(instrumentation.uiAutomation.takeScreenshot())
            try {
                crops.forEach {crop ->
                    val r=crop.rect;check(r.left>=0 && r.top>=0 && r.right<=image.width && r.bottom<=image.height && r.width()>0 && r.height()>0)
                    val part=Bitmap.createBitmap(image,r.left,r.top,r.width(),r.height())
                    try {
                        val data=java.io.ByteArrayOutputStream().also {assertTrue(part.compress(Bitmap.CompressFormat.PNG,100,it))}.toByteArray()
                        File(output,"$phase-${crop.label}-${index.toString().padStart(2,'0')}.png").writeBytes(data)
                        hashes.getValue(crop.label).add(java.security.MessageDigest.getInstance("SHA-256").digest(data).joinToString("") {"%02x".format(it)})
                    } finally {part.recycle()}
                }
                samples.put(JSONObject().put("sample",index).put("composeClockMs",compose.mainClock.currentTime).put("elapsedRealtimeMs",android.os.SystemClock.elapsedRealtime()).put("native",deck()).put("projectionPositionMs",model.playback.value.positionMs))
            } finally {image.recycle()}
            Thread.sleep(250) // Bounded drawn-motion observation, never a readiness condition.
        }
        File(output,"$phase-motion.json").writeText(JSONObject().put("crops",JSONArray(crops.map {JSONObject().put("label",it.label).put("rect",JSONArray(listOf(it.rect.left,it.rect.top,it.rect.right,it.rect.bottom)))})).put("samples",samples).put("uniquePngCounts",JSONObject(hashes.mapValues {it.value.size})).toString(2))
        for((label,values) in hashes)if(label.startsWith("row-") || label.startsWith("compact-"))assertTrue("$phase $label must visibly move",values.size>5)else assertEquals("$phase $label remains static",1,values.size)
    }
    @Test fun actualFileBrowserReturnPreservesBAndMountedSelectedTextMoves() = withOriginals {model,originals,_ ->
        val (a,b,_)=originals
        val priorAutoAdvance=compose.mainClock.autoAdvance
        compose.waitUntil(15_000) {compose.onAllNodesWithContentDescription("More for ${b.row.metadata.displayTitle}").fetchSemanticsNodes().size==1}
        compose.onNodeWithContentDescription("More for ${b.row.metadata.displayTitle}").assertIsDisplayed()
        // Pinned ui-test cancels infinite animations while autoAdvance=true.
        // Disable that policy before the real selection composes its marquee.
        compose.mainClock.autoAdvance=false
        try {
            play(model,b)
            repeat(4) {compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
            motion(model,"playing")
            compose.onNodeWithContentDescription("Pause").performClick()
            await("Pause acknowledged") {!model.playback.value.isPlaying && deck()?.optBoolean("playing")==false}
            repeat(4) {compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
            motion(model,"paused-current")
        } finally {compose.mainClock.autoAdvance=priorAutoAdvance}
        compose.onNodeWithContentDescription("Play").performClick()
        await("Resume advances") {model.playback.value.isPlaying && deck()?.getLong("positionMs")?.let {it>1500}==true}
        val before=checkNotNull(deck());val selected=model.playback.value.selectedOccurrence
        val source=model.playback.value.sourceQueueIncarnation
        compose.onNodeWithContentDescription("More for ${a.row.metadata.displayTitle}").performScrollTo().performClick()
        compose.onNodeWithText("Open in file browser").performScrollTo().performClick()
        // The sheet's real rememberCoroutineScope owns capture/open. Pump its
        // scheduler while awaiting the external window; wall-time polling alone
        // cannot resume an IO completion on the Compose test dispatcher.
        compose.waitUntil(10_000) {
            val root=instrumentation.uiAutomation.rootInActiveWindow
            root?.packageName?.toString()=="com.google.android.documentsui" && tree(root).let {
                it.contains(File(a.path).parentFile!!.name) && it.contains(File(a.path).name)
            }
        }
        val external=tree(instrumentation.uiAutomation.rootInActiveWindow)
        val activities=shell("dumpsys activity activities")
        File(output,"external-files-ui.txt").writeText(external)
        File(output,"external-activity.txt").writeText(activities)
        capture("external-files-containing-folder")
        assertTrue("Actual Files activity",activities.lines().any {it.contains("topResumedActivity=") && it.contains("u0 com.google.android.documentsui/com.android.documentsui.files.FilesActivity ")})
        assertTrue("Exact containing folder visible",external.contains(File(a.path).parentFile!!.name))
        assertTrue("Exact generated filename visible",external.contains(File(a.path).name))
        // Stock Files traverses the generated folder, Download and storage root.
        // A single Back was an overly strict fixture assumption, not the contract.
        data class ReturnWindow(val pkg: String?, val activity: String?, val folder: String?, val resumed: Boolean) {
            fun json() = JSONObject().put("package",pkg).put("topResumedActivity",activity).put("folder",folder).put("soundqResumed",resumed)
        }
        fun window(): ReturnWindow {
            val root=instrumentation.uiAutomation.rootInActiveWindow
            val hierarchy=tree(root)
            return ReturnWindow(root?.packageName?.toString(),shell("dumpsys activity activities").lines().firstOrNull {it.contains("topResumedActivity=")},
                Regex("text=Files (?:in|on) (.+?) desc=").find(hierarchy)?.groupValues?.get(1),
                main {compose.activity.lifecycle.currentState==Lifecycle.State.RESUMED})
        }
        fun returned(w: ReturnWindow) = w.pkg==context.packageName && w.activity?.contains("u0 ${context.packageName}/com.soundq.android.MainActivity ")==true && w.resumed
        val maxBack=4 // Predeclared finite bound for this two-level Download fixture.
        val returnStarted=android.os.SystemClock.elapsedRealtime()
        val returnDeadline=returnStarted+10_000 // One aggregate allowance, not ten seconds per Back.
        val backPath=JSONArray()
        fun receipt() = File(output,"external-back-path.json").writeText(JSONObject().put("maxBack",maxBack).put("allowanceMs",10_000).put("startedElapsedRealtimeMs",returnStarted).put("steps",backPath).toString(2))
        var current=window()
        backPath.put(JSONObject().put("action","initial").put("observed",current.json()));receipt()
        var backCount=0
        while(!returned(current) && backCount<maxBack && android.os.SystemClock.elapsedRealtime()<returnDeadline) {
            assertEquals("Back traversal stays in actual stock Files", "com.google.android.documentsui",current.pkg)
            assertTrue("Back traversal stays in actual Files activity",current.activity?.contains("u0 com.google.android.documentsui/com.android.documentsui.files.FilesActivity ")==true)
            assertNotNull("Positive current folder before Back",current.folder)
            val prior=current
            val step=JSONObject().put("action","GLOBAL_ACTION_BACK").put("number",++backCount).put("before",prior.json()).put("elapsedRealtimeMs",android.os.SystemClock.elapsedRealtime())
            backPath.put(step);receipt()
            assertTrue(instrumentation.uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK))
            var progressed=false
            while(android.os.SystemClock.elapsedRealtime()<returnDeadline) {
                current=window()
                step.put("observed",current.json());receipt()
                assertTrue("Refuse unrelated package or launcher during Back traversal",current.pkg==null || current.pkg=="com.google.android.documentsui" || current.pkg==context.packageName)
                progressed=returned(current) || (current.pkg==prior.pkg && current.activity==prior.activity && current.folder!=null && current.folder!=prior.folder)
                if(progressed)break
                Thread.sleep(20)
            }
            assertTrue("Back must positively change folder or return to resumed SoundQ within aggregate allowance",progressed)
            File(output,"external-back-$backCount-ui.txt").writeText(tree(instrumentation.uiAutomation.rootInActiveWindow))
            capture("external-back-$backCount")
        }
        assertTrue("Bounded ordinary Back traversal returns to SoundQ",returned(current))
        compose.onNodeWithContentDescription("Library search query").assertTextContains(query)
        compose.onNodeWithContentDescription("More for ${a.row.metadata.displayTitle}").assertIsDisplayed()
        assertEquals(selected,model.playback.value.selectedOccurrence);assertEquals(source,model.playback.value.sourceQueueIncarnation)
        await("B advances with same real identity and generation") {deck()?.let {it.getLong("identity")==before.getLong("identity") && it.getLong("generation")==before.getLong("generation") && it.getLong("positionMs")>before.getLong("positionMs")+1000}==true}
        assertTrue(model.playback.value.isPlaying)
        File(output,"external-return.json").writeText(JSONObject().put("before",before).put("after",deck()).put("selectedOccurrence",selected).put("sourceQueueIncarnation",source).toString(2))
        capture("returned-soundq-continuing-B")
    }
    @Test fun serverSheetSpeedEditForALeavesPlayingBUntouchedThenAAppliesSavedRate() {
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.runOnIdle {model.graph.session.retire();model.controller.pause();model.controller.clear()}
        compose.waitUntil(15_000) {model.graph.session.state.value is AuthState.SignedOut}
        compose.signInThroughSettings("native-song-actions@example.test","test-only-password") {model.graph.session.state.value is AuthState.SignedIn}
        compose.waitUntil(15_000) {model.library.value.rows.size==3 && !model.library.value.loading}
        // Phone history legitimately precedes the server rows in this installed fixture.
        // Filter through the ordinary root search so the real server rows are mounted.
        compose.onNodeWithContentDescription("Library search query").performTextReplacement("Fixture")
        compose.onNodeWithContentDescription("Search library").performClick()
        compose.waitUntil(15_000) {!model.library.value.loading}
        fun row(title:String)=hasClickAction() and hasAnyDescendant(hasText(title)) and hasAnyDescendant(hasContentDescription("More for $title"))
        var primary:Throwable?=null
        try {
            compose.onNode(row("Fixture 2"),useUnmergedTree=true).performScrollTo().performClick()
            compose.waitUntil(15_000) {model.playback.value.isPlaying && model.playback.value.title=="Fixture 2" && deck()?.getLong("positionMs")?.let {it>300}==true}
            compose.runOnIdle {model.controller.pause()}
            compose.waitUntil(10_000) {!model.playback.value.isPlaying}
            compose.onNodeWithContentDescription("More for Fixture 1").performScrollTo().performClick()
            compose.onNodeWithText("Playback speed").performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("Open in file browser").assertDoesNotExist()
            compose.onNodeWithText("Delete file").assertDoesNotExist()
            capture("server-song-actions-no-local-file-actions")
            compose.onNodeWithText("Playback speed").performClick()
            compose.waitUntil(10_000) {compose.onAllNodesWithText("Reset to normal").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("Reset to normal").performScrollTo().performClick()
            compose.waitUntil(10_000) {compose.onAllNodesWithText("Saved for this song").fetchSemanticsNodes().isNotEmpty()}
            // Existing TLS MP3 is exactly 12 s. Keep B paused during editor setup,
            // then finish the save-only measurement inside its real remaining duration.
            compose.runOnIdle {model.controller.toggle()}
            compose.waitUntil(10_000) {model.playback.value.isPlaying && deck()?.getBoolean("playing")==true}
            val before=checkNotNull(deck());val selected=model.playback.value.selectedOccurrence
            val source=model.playback.value.sourceQueueIncarnation
            assertTrue("12-second fixture retains continuity headroom",before.getLong("positionMs")<4000)
            compose.onNodeWithContentDescription("Playback speed").performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.SetProgress) {assertTrue(it(1.5f))}
            compose.waitUntil(10_000) {compose.onAllNodes(hasTestTag("player-speed-accepted") and hasText("1.5x")).fetchSemanticsNodes().isNotEmpty() && compose.onAllNodesWithText("Saved for this song").fetchSemanticsNodes().isNotEmpty()}
            await("B advances untouched during server A speed save",5) {deck()?.getLong("positionMs")?.let {it>before.getLong("positionMs")+1200}==true}
            val after=checkNotNull(deck())
            assertEquals(before.getLong("identity"),after.getLong("identity"));assertEquals(before.getLong("generation"),after.getLong("generation"))
            assertEquals(before.getDouble("rate"),after.getDouble("rate"),0.0)
            assertEquals(selected,model.playback.value.selectedOccurrence);assertEquals(source,model.playback.value.sourceQueueIncarnation);assertTrue(model.playback.value.isPlaying)
            compose.runOnIdle {model.controller.pause()}
            capture("server-A-saved-while-B-unchanged")
            compose.onNodeWithContentDescription("Close Fixture 1").performClick()
            compose.onNode(row("Fixture 1"),useUnmergedTree=true).performScrollTo().performClick()
            compose.waitUntil(15_000) {model.playback.value.title=="Fixture 1" && model.playback.value.isPlaying && deck()?.getDouble("rate")==1.5}
            File(output,"server-speed-isolation.json").writeText(JSONObject().put("fixtureDurationMs",12000).put("beforeB",before).put("afterB",after).put("selectedB",selected).put("sourceB",source).put("selectedA",model.playback.value.selectedOccurrence).put("afterA",deck()).toString(2))
            capture("server-A-starts-saved-rate")
        } catch(error:Throwable) {
            primary=error
            runCatching {capture("server-failure");File(output,"server-failure-state.json").writeText(JSONObject().put("native",native()).put("projection",model.playback.value.toString()).toString(2))}.exceptionOrNull()?.let(error::addSuppressed)
            throw error
        } finally {
            try {main {model.controller.pause();model.controller.clear()};await("Server native queue drained") {main {app.callbackPlayer.mediaItemCount==0 && (app.callbackPlayer as com.soundq.android.playback.nativeengine.NativeCallbackPlayer).preparationSettled} && model.graph.phoneAudio.originalDescriptorsDrained(null)}}
            catch(cleanup:Throwable) {if(primary!=null)primary.addSuppressed(cleanup) else throw cleanup}
        }
    }
    @Test fun deletingCurrentlyPlayingSingleOriginalRetiresNativeBeforeUnlinkAndPreservesOtherOriginals() = withOriginals {model,originals,_ ->
        val (a,b,c)=originals
        play(model,a)
        val before=checkNotNull(deck());val identity=before.getLong("identity")
        compose.onNodeWithContentDescription("More for ${a.row.metadata.displayTitle}").performScrollTo().performClick()
        compose.onNodeWithText("Delete file").performScrollTo().performClick()
        compose.onNodeWithText("Delete file from phone?").assertIsDisplayed()
        assertArrayEquals(a.bytes,context.contentResolver.openInputStream(a.uri)!!.use {it.readBytes()})
        capture("current-A-delete-confirmation")
        val deletionTrace=JSONArray()
        compose.onAllNodesWithText("Delete file").onLast().performClick()
        await("Confirmed current original deletion and native retirement",30) {
            val exists=File(a.path).exists();val assigned=hasIdentity(identity)
            val drained=model.graph.phoneAudio.originalDescriptorsDrained(a.id)
            val settled=main {(app.callbackPlayer as com.soundq.android.playback.nativeengine.NativeCallbackPlayer).preparationSettled}
            deletionTrace.put(JSONObject().put("elapsedRealtimeMs",android.os.SystemClock.elapsedRealtime()).put("originalExists",exists).put("identityAssigned",assigned).put("descriptorsDrained",drained).put("preparationSettled",settled).put("native",native()))
            if(!exists) {assertFalse("No unlink before actual native identity retirement",assigned);assertTrue("No unlink before original descriptor drain",drained);assertTrue("No unlink before preparation jobs drain",settled)}
            !exists && !assigned && drained && settled && main {app.callbackPlayer.mediaItemCount==0}
        }
        assertEquals(0,native().getInt("openDecoders"))
        compose.waitUntil(15_000) {compose.onAllNodesWithText("Delete file from phone?").fetchSemanticsNodes().isEmpty()}
        assertFalse(context.contentResolver.query(a.uri,arrayOf(MediaStore.MediaColumns._ID),null,null,null)?.use {it.moveToFirst()} ?: false)
        assertFalse(model.playback.value.isPlaying)
        assertArrayEquals(b.bytes,context.contentResolver.openInputStream(b.uri)!!.use {it.readBytes()})
        assertArrayEquals(c.bytes,context.contentResolver.openInputStream(c.uri)!!.use {it.readBytes()})
        val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(3)
        val observations=JSONArray()
        while(System.nanoTime()<end) {
            assertFalse("A never outputs or progresses after native retirement",hasIdentity(identity))
            assertTrue(model.graph.phoneAudio.originalDescriptorsDrained(a.id))
            assertEquals(0,main {app.callbackPlayer.mediaItemCount});assertFalse(model.playback.value.isPlaying)
            observations.put(native());Thread.sleep(100)
        }
        File(output,"current-A-retirement.json").writeText(JSONObject().put("before",before).put("retiredIdentity",identity).put("deletionTrace",deletionTrace).put("descriptorsDrained",true).put("providerOriginalAbsent",true).put("unrelatedOriginalsByteIdentical",true).put("observations",observations).toString(2))
        capture("current-A-deleted-native-retired")
    }
}
