package com.soundq.android

import android.content.ContentValues
import android.os.Environment
import android.provider.MediaStore
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.AuthState
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

/** Production Library -> captured local-song menu. Only generated, test-owned originals are mutated. */
@androidx.test.filters.SdkSuppress(minSdkVersion=29)
class SongActionsJourneyTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun model(): ProductViewModel {
        val value = compose.runOnIdle { ViewModelProvider(compose.activity)[ProductViewModel::class.java] }
        compose.runOnIdle { value.graph.session.retire() }
        compose.waitUntil(15_000) { value.graph.session.state.value is AuthState.SignedOut && value.graph.phoneAudio.state.value.ready }
        return value
    }
    private fun withOriginal(body: (ProductViewModel, android.net.Uri, String, ByteArray) -> Unit) {
        val model = model()
        val name = "soundq-actions-${UUID.randomUUID()}.wav"
        val resolver = context.contentResolver
        val uri = checkNotNull(resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, "audio/wav")
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/SoundQ actions qualification")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }))
        val frames = 16_000 * 2
        val bytes = ByteBuffer.allocate(44 + frames * 2).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()).putInt(36 + frames * 2).put("WAVEfmt ".toByteArray()).putInt(16)
            putShort(1).putShort(1).putInt(16_000).putInt(32_000).putShort(2).putShort(16).put("data".toByteArray()).putInt(frames * 2)
            repeat(frames) { putShort((kotlin.math.sin(it * 2 * Math.PI * 223 / 16_000) * 4000).toInt().toShort()) }
        }.array()
        var originalId:String?=null
        var primary:Throwable?=null
        try {
            resolver.openOutputStream(uri, "w")!!.use { it.write(bytes) }
            assertEquals(1, resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null))
            fun providerFacts():String=resolver.query(uri,arrayOf(MediaStore.MediaColumns.IS_PENDING,MediaStore.MediaColumns.DISPLAY_NAME,MediaStore.Audio.Media.TITLE),null,null,null)!!.use {c->
                check(c.moveToFirst());"pending=${c.getInt(0)} display=${c.getString(1)} title=${c.getString(2)}"
            }
            fun scanGeneratedOriginal() {
                @Suppress("DEPRECATION") val path=resolver.query(uri,arrayOf(MediaStore.MediaColumns.DATA),null,null,null)!!.use {check(it.moveToFirst());it.getString(0)}
                val scanned=java.util.concurrent.CountDownLatch(1)
                val result=java.util.concurrent.atomic.AtomicReference<android.net.Uri?>()
                android.media.MediaScannerConnection.scanFile(context,arrayOf(path),arrayOf("audio/wav")) {_,indexed->result.set(indexed);scanned.countDown()}
                assertTrue(scanned.await(10,java.util.concurrent.TimeUnit.SECONDS))
                assertEquals(android.content.ContentUris.parseId(uri),android.content.ContentUris.parseId(checkNotNull(result.get())))
            }
            if(InstrumentationRegistry.getArguments().getString("pendingPublicationControl")=="true") {
                // Controlled real provider rename/scan, not a claim about the historical scanner schedule.
                fun renameAndScan(display:String) {
                    assertEquals(1,resolver.update(uri,ContentValues().apply {put(MediaStore.MediaColumns.DISPLAY_NAME,display)},null,null))
                    scanGeneratedOriginal()
                }
                val stagingName="soundq-staging-${UUID.randomUUID()}.wav"
                renameAndScan(stagingName)
                model.graph.phoneAudio.refresh()
                compose.waitUntil(15_000) {model.graph.phoneAudio.state.value.snapshot?.files?.any {it.metadata.filename==stagingName}==true}
                android.util.Log.i("SoundQMenuFixture","controlled staging title positively published $stagingName")
                renameAndScan(name)
            }
            scanGeneratedOriginal()
            val finalizedTitle=resolver.query(uri,arrayOf(MediaStore.MediaColumns.IS_PENDING,MediaStore.MediaColumns.DISPLAY_NAME,MediaStore.Audio.Media.TITLE),null,null,null)!!.use {
                check(it.moveToFirst());assertEquals(0,it.getInt(0));assertEquals(name,it.getString(1))
                it.getString(2).also {title->assertFalse(title.startsWith(".pending-"))}
            }
            android.util.Log.i("SoundQMenuFixture","finalized update ${providerFacts()}")
            val row = model.graph.phoneAudio.awaitIndexed(uri,accept={it.metadata.filename==name && it.metadata.title==finalizedTitle})
            originalId=row.id.value.toString()
            android.util.Log.i("SoundQMenuFixture","captured ${row.metadata} provider=${providerFacts()} refreshing=${model.graph.phoneAudio.state.value.refreshing}")
            assertEquals("Index must publish finalized provider filename before selector capture",name,row.metadata.filename)
            assertEquals("Index must publish finalized provider title before selector capture",finalizedTitle,row.metadata.title)
            compose.onNodeWithContentDescription("Library search query").performTextReplacement(name)
            compose.onNodeWithContentDescription("Search library").performClick()
            android.util.Log.i("SoundQMenuFixture","selector=${row.metadata.displayTitle} current=${model.graph.phoneAudio.state.value.snapshot?.files?.singleOrNull {it.id==row.id}?.metadata} provider=${providerFacts()}")
            try {compose.onNodeWithContentDescription("More for ${row.metadata.displayTitle}").performScrollTo().performClick()}catch(error:Throwable) {
                android.util.Log.e("SoundQMenuFixture",compose.onRoot(useUnmergedTree=true).printToString());throw error
            }
            body(model, uri, row.metadata.displayTitle, bytes)
        } catch(error:Throwable) {primary=error;throw error}
        finally {
            try {
                compose.runOnIdle { model.controller.pause(); model.controller.clear() }
                compose.waitUntil(15_000) {model.graph.phoneAudio.originalDescriptorsDrained(originalId)}
                resolver.delete(uri, null, null) // Only after this generated original's concrete descriptor drain.
            } catch(cleanup:Throwable) {if(primary!=null)primary.addSuppressed(cleanup) else throw cleanup}
        }
    }
    private fun capture(name: String) {
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        try {
            val directory = java.io.File(context.filesDir, "song-actions-captures").apply { mkdirs() }
            java.io.File(directory, "$name.png").outputStream().use { assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)) }
        } finally { bitmap.recycle() }
    }
    @Test fun originalMenuHasFileAndSpeedActionsAndCancelPreservesOriginal() = withOriginal { _, uri, _, bytes ->
        compose.onNodeWithText("Playback speed").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Open in file browser").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Delete file").performScrollTo().assertIsDisplayed()
        capture("local-actions")
        compose.onNodeWithText("Delete file").performClick()
        compose.onNodeWithText("Delete file from phone?").assertIsDisplayed()
        capture("delete-confirmation")
        compose.onNodeWithText("Cancel").performClick()
        assertArrayEquals(bytes, context.contentResolver.openInputStream(uri)!!.use { it.readBytes() })
    }
    @Test fun nonplayingSongSpeedSavesWithoutStartingPlayback() = withOriginal { model, _, _, _ ->
        val before = model.playback.value
        compose.onNodeWithText("Playback speed").performScrollTo().performClick()
        // These generated bytes intentionally share the content-keyed preference with prior runs.
        // Establish a different accepted value through the real editor before exercising 1.5x.
        compose.waitUntil(10_000) {compose.onAllNodesWithText("Reset to normal").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithText("Reset to normal").performScrollTo().performClick()
        compose.waitUntil(10_000) {compose.onAllNodesWithText("Saved for this song").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Playback speed").performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.SetProgress) { assertTrue(it(1.5f)) }
        // SetProgress is a debounced draft. A reset's old Saved message cannot acknowledge it.
        compose.waitUntil(10_000) {
            compose.onAllNodes(hasTestTag("player-speed-accepted") and hasText("1.5x")).fetchSemanticsNodes().isNotEmpty() &&
                compose.onAllNodesWithText("Saved for this song").fetchSemanticsNodes().isNotEmpty()
        }
        assertEquals(before.selectedOccurrence, model.playback.value.selectedOccurrence)
        assertFalse(model.playback.value.isPlaying)
        capture("saved-song-speed")
        compose.onNodeWithContentDescription("Back to song actions").performClick()
        compose.onNodeWithText("1.5x").assertExists()
    }
    @Test fun changedOriginalAfterConfirmationIsNotDeleted() = withOriginal { _, uri, _, bytes ->
        compose.onNodeWithText("Delete file").performScrollTo().performClick()
        compose.onNodeWithText("Delete file from phone?").assertIsDisplayed()
        val replacement = bytes.copyOf().apply { this[lastIndex] = (this[lastIndex].toInt() xor 1).toByte() }
        context.contentResolver.openOutputStream(uri, "w")!!.use { it.write(replacement) }
        compose.onAllNodesWithText("Delete file").onLast().performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText("File changed. Nothing was deleted.").fetchSemanticsNodes().isNotEmpty() }
        assertArrayEquals(replacement, context.contentResolver.openInputStream(uri)!!.use { it.readBytes() })
    }
    @Test fun confirmedDeleteRemovesOnlyOriginalAndReconcilesLibrary() = withOriginal { model, uri, title, _ ->
        compose.onNodeWithText("Delete file").performScrollTo().performClick()
        compose.onNodeWithText("Delete file from phone?").assertIsDisplayed()
        compose.onAllNodesWithText("Delete file").onLast().performClick()
        compose.waitUntil(15_000) {
            model.graph.phoneAudio.state.value.snapshot?.files?.none { it.available && it.metadata.displayTitle == title } == true &&
                compose.onAllNodesWithText("Delete file from phone?").fetchSemanticsNodes().isEmpty()
        }
        assertFalse(context.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns._ID), null, null, null)?.use { it.moveToFirst() } ?: false)
        capture("file-deleted")
    }
}
