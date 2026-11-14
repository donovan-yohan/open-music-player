package com.soundq.android

import android.content.ContentValues
import android.os.Environment
import android.provider.MediaStore
import android.view.KeyEvent
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.ComposeTestRule
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.AuthState
import com.soundq.android.data.offline.DownloadStatus
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

/** Ordinary Filters entry; shared by retained journeys that previously toggled the removed checkbox. */
internal fun ComposeTestRule.selectLibrarySource(source:String) {
    onNodeWithContentDescription("Refine library").performClick()
    onNodeWithText("Source").performScrollTo().assertIsDisplayed()
    onNodeWithText(source).performScrollTo().performClick()
    onNodeWithText("Apply refinement").performScrollTo().performClick()
    waitForIdle()
}

/** NOT RUN in the source phase. ProductFixtureRunner; min API30; caller owns access/device setup.
 * The access-off case requires access denied. The mixed corpus case requires all-files access allowed.
 * Uses only test-owned phone bytes and fixture-server downloads, never personal originals or playback. */
@androidx.test.filters.SdkSuppress(minSdkVersion=30)
class LibrarySourceFilterJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private val graph get()=(instrumentation.targetContext.applicationContext as FixtureApplication).graph
    private fun click(label:String)=compose.onNodeWithText(label).performScrollTo().performClick()
    private fun filters(){compose.onNodeWithContentDescription("Refine library").performClick();compose.onNodeWithText("Source").performScrollTo().assertIsDisplayed()}
    private fun back(){instrumentation.sendKeyDownUpSync(KeyEvent.KEYCODE_BACK);compose.waitForIdle()}
    private fun noPhoneNotice(){for(text in listOf("File access is off","Allow file access","Finding audio on this phone","No audio found on this phone"))compose.onNodeWithText(text).assertDoesNotExist()}
    private fun sourceSelected(source:String){filters();compose.onNodeWithText(source).assertIsSelected();click("Cancel")}

    @Test fun signedOutServerEmptyIsClearableAndCancelBackResetKeepAppliedSource() {
        assertFalse("Runner must deny all files access for this method",Environment.isExternalStorageManager())
        compose.runOnIdle {graph.session.retire()}
        compose.waitUntil(15000){graph.session.state.value is AuthState.SignedOut&&graph.phoneAudio.state.value.ready}
        compose.onNodeWithContentDescription("Local files").assertDoesNotExist()
        sourceSelected("All")
        filters();click("Server");click("Cancel");sourceSelected("All")
        filters();click("Local");back();sourceSelected("All")
        compose.selectLibrarySource("Server")
        compose.onNodeWithText("No matching tracks").assertIsDisplayed();noPhoneNotice()
        captureListeningStage("source-server-accountless-empty")
        filters();captureListeningStage("source-server-sheet");click("Cancel")
        // Preserve the prior saveable UI lifetime across Activity recreation.
        compose.activityRule.scenario.recreate()
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Refine library").fetchSemanticsNodes().isNotEmpty()}
        sourceSelected("Server")
        filters();click("Reset refinement");click("Cancel");sourceSelected("Server")
        filters();click("Reset refinement");click("Apply refinement");sourceSelected("All")
        compose.selectLibrarySource("Server");click("Clear refinement");sourceSelected("All")
        compose.selectLibrarySource("Local")
        compose.onNodeWithText("File access is off").assertIsDisplayed()
        compose.onNodeWithText("Allow file access").assertIsDisplayed()
        click("Clear refinement");sourceSelected("All")
        compose.runOnIdle {assertFalse(graph.controller.state.value.isPlaying);assertTrue(graph.controller.state.value.queue.isEmpty())}
    }

    @Test fun mixedCorpusServerDownloadAndPhoneComposeWithoutQueueOrOriginalMutation() {
        assertTrue("Runner must allow all files access for this method",Environment.isExternalStorageManager())
        compose.signInThroughSettings("source-filter@example.test","test-only-password"){graph.session.state.value is AuthState.SignedIn}
        compose.waitUntil(15000){graph.library.state.value.let {!it.loading&&it.rows.size==3}}
        val context=instrumentation.targetContext;val resolver=context.contentResolver
        val uri=checkNotNull(resolver.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME,"soundq-source-${UUID.randomUUID()}.wav")
            put(MediaStore.MediaColumns.MIME_TYPE,"audio/wav")
            put(MediaStore.MediaColumns.RELATIVE_PATH,Environment.DIRECTORY_MUSIC+"/SoundQ source qualification")
            put(MediaStore.MediaColumns.IS_PENDING,1)
        }))
        // No embedded title: the unique filename also gives this row a unique visible identity
        // among the AVD's retained synthetic fixtures. Never delete those fixtures to isolate a test.
        val bytes=ByteBuffer.allocate(44+16000).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()).putInt(36+16000).put("WAVEfmt ".toByteArray()).putInt(16)
            putShort(1).putShort(1).putInt(8000).putInt(16000).putShort(2).putShort(16)
            put("data".toByteArray()).putInt(16000)
        }.array()
        var primary:Throwable?=null
        try {
            resolver.openOutputStream(uri,"w")!!.use {it.write(bytes)}
            assertEquals(1,resolver.update(uri,ContentValues().apply {put(MediaStore.MediaColumns.IS_PENDING,0)},null,null))
            val version=graph.session.version()
            val phone=graph.phoneAudio.awaitIndexed(uri,{graph.session.owns(version)})
            val title=phone.metadata.displayTitle
            val row=hasText(title) and hasClickAction() and !hasSetTextAction()
            captureListeningStage("source-before-download")
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasContentDescription("More for Fixture 1"))
            compose.onNodeWithContentDescription("More for Fixture 1").performClick()
            click("Download to device")
            compose.waitUntil(20000){graph.downloads.state.value.rows.any {it.track.id.value==1L&&it.status==DownloadStatus.Complete}}
            back()
            val queue=graph.controller.state.value.queue
            compose.selectLibrarySource("All")
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(row);compose.onNode(row).assertIsDisplayed()
            captureListeningStage("source-all-mixed")
            compose.selectLibrarySource("Server");noPhoneNotice();compose.onNode(row).assertDoesNotExist()
            compose.onNodeWithContentDescription("More for Fixture 1").assertExists()
            compose.onNodeWithContentDescription("More for Fixture 2").assertExists()
            captureListeningStage("source-server-mixed")
            compose.selectLibrarySource("Local")
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasContentDescription("More for Fixture 1"))
            compose.onAllNodesWithContentDescription("More for Fixture 1").assertCountEquals(1)
            compose.onNodeWithContentDescription("More for Fixture 2").assertDoesNotExist()
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(row);compose.onNode(row).assertIsDisplayed()
            captureListeningStage("source-local-mixed")
            // Clearing text does not reset Source.
            compose.onNodeWithContentDescription("Library search query").performTextReplacement("no source match")
            compose.onNodeWithContentDescription("Search library").performClick()
            compose.waitUntil(15000){graph.library.state.value.let {!it.loading&&it.query.text=="no source match"}}
            compose.onNodeWithContentDescription("Clear library search").performClick();sourceSelected("Local")
            filters();click("Recently played");click("Apply refinement")
            sourceSelected("Local")
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(row);compose.onNode(row).assertIsDisplayed()
            compose.runOnIdle {assertEquals(queue,graph.controller.state.value.queue);assertFalse(graph.controller.state.value.isPlaying)}
            assertArrayEquals(bytes,resolver.openInputStream(uri)!!.use {it.readBytes()})
            compose.runOnIdle {graph.session.retire()}
            compose.waitUntil(15000){graph.session.state.value is AuthState.SignedOut&&graph.phoneAudio.state.value.ready}
            compose.selectLibrarySource("Server");compose.onNodeWithText("No matching tracks").assertIsDisplayed();noPhoneNotice()
            click("Clear refinement");sourceSelected("All")
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(row);compose.onNode(row).assertIsDisplayed()
        }catch(failure:Throwable){primary=failure;throw failure}
        finally {
            try {assertEquals(1,resolver.delete(uri,null,null))}
            catch(cleanup:Throwable){if(primary!=null)primary.addSuppressed(cleanup)else throw cleanup}
        }
    }
}
