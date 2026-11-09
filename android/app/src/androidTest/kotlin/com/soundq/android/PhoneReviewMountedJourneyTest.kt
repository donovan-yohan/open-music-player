package com.soundq.android

import android.content.ContentValues
import android.content.Intent
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

/** Actual MainActivity, production Compose shell/controller, test-owned provider original.
 * Synthetic runner only; no real account, remote write, alternate Player or fake server ID. */
class PhoneReviewMountedJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private fun model():ProductViewModel {
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.runOnIdle {model.graph.session.retire()}
        compose.waitUntil(15000){model.graph.session.state.value is AuthState.SignedOut&&model.graph.phoneAudio.state.value.ready&&compose.onAllNodesWithContentDescription("Library search query").fetchSemanticsNodes().isNotEmpty()}
        return model
    }
    private fun capture(name:String) {
        val i=InstrumentationRegistry.getInstrumentation();val bitmap=i.uiAutomation.takeScreenshot()
        val out=java.io.File(i.targetContext.filesDir,"pr533-review-captures").apply {mkdirs()}
        try {java.io.File(out,"$name.png").outputStream().use {assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it))}}finally{bitmap.recycle()}
    }
    private fun withPhoneOriginal(model:ProductViewModel,body:(String)->Unit) {
        val resolver=InstrumentationRegistry.getInstrumentation().targetContext.contentResolver
        val name="soundq-review-${UUID.randomUUID()}.wav"
        val uri=checkNotNull(resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME,name);put(MediaStore.MediaColumns.MIME_TYPE,"audio/wav")
            put(MediaStore.MediaColumns.RELATIVE_PATH,Environment.DIRECTORY_DOWNLOADS+"/SoundQ review qualification");put(MediaStore.MediaColumns.IS_PENDING,1)
        }))
        try {
            val rate=16000;val frames=rate*30;val size=frames*2
            val bytes=ByteBuffer.allocate(44+size).order(ByteOrder.LITTLE_ENDIAN).apply {
                put("RIFF".toByteArray()).putInt(36+size).put("WAVEfmt ".toByteArray()).putInt(16)
                putShort(1).putShort(1).putInt(rate).putInt(rate*2).putShort(2).putShort(16).put("data".toByteArray()).putInt(size)
                repeat(frames){putShort((kotlin.math.sin(it*2*Math.PI*223/rate)*4000).toInt().toShort())}
            }.array()
            resolver.openOutputStream(uri,"w")!!.use {it.write(bytes)}
            assertEquals(1,resolver.update(uri,ContentValues().apply {put(MediaStore.MediaColumns.IS_PENDING,0)},null,null))
            model.graph.phoneAudio.selected(uri,Intent.FLAG_GRANT_READ_URI_PERMISSION,false){true}
            compose.waitUntil(15000){model.graph.phoneAudio.state.value.snapshot?.files?.any {it.available&&it.metadata.filename==name}==true}
            body(name)
        }finally {
            compose.runOnIdle {model.controller.pause();model.controller.clear()}
            assertEquals(1,resolver.delete(uri,null,null))
        }
    }
    @Test fun signedOutSharedLinkOpensAccountInsteadOfInvisibleImportPanel() {
        val model=model()
        withPhoneOriginal(model) { name->
        assertTrue(model.graph.incomingShares.receive("https://www.youtube.com/watch?v=abcdefghijk",null))
        try {
            compose.waitUntil(5000){compose.onAllNodesWithContentDescription("Review shared link").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Review shared link").performClick()
            compose.onNodeWithText("Settings").assertExists()
            capture("shared-link-account")
            compose.onNodeWithText("Back to Library").performScrollTo().performClick()
            compose.onNodeWithText("Settings").assertDoesNotExist()
            compose.onNodeWithContentDescription("Library search query").performTextReplacement(name)
            compose.onNodeWithContentDescription("Search library").performClick()
            compose.onNode(hasText(name) and hasClickAction() and !hasSetTextAction()).performScrollTo().assertIsDisplayed().performClick()
            compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.positionMs>100}
            assertEquals(name,model.playback.value.title)
            capture("shared-link-dismissed-phone-playing")
        }finally{model.graph.incomingShares.state.value?.let(model.graph.incomingShares::dismiss)}
        }
    }
    @Test fun signedOutEmptyQueryClearRefinementResetsVisibleLocalQuery() {
        val model=model()
        withPhoneOriginal(model) { name->
        compose.onNodeWithContentDescription("Library search query").performTextReplacement("soundq-no-match-${UUID.randomUUID()}")
        compose.onNodeWithContentDescription("Search library").performClick()
        compose.onNodeWithText("No matching tracks").assertExists()
        capture("empty-local-search")
        compose.onNodeWithText("Clear refinement").performClick()
        compose.onNodeWithContentDescription("Library search query").assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.EditableText,androidx.compose.ui.text.AnnotatedString("")))
        compose.onNodeWithText("No matching tracks").assertDoesNotExist()
        val ownedRow=hasText(name) and hasClickAction() and !hasSetTextAction()
        compose.onNode(hasScrollToIndexAction()).performScrollToNode(ownedRow)
        compose.onNode(ownedRow).assertIsDisplayed()
        capture("search-cleared-owned-row")
        }
    }
    @Test fun phoneQueueWaveformsCannotStealPrimaryPlay() {
        val model=model();val context=InstrumentationRegistry.getInstrumentation().targetContext;val resolver=context.contentResolver
        val name="soundq-review-${UUID.randomUUID()}.wav"
        val uri=checkNotNull(resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME,name);put(MediaStore.MediaColumns.MIME_TYPE,"audio/wav")
            put(MediaStore.MediaColumns.RELATIVE_PATH,Environment.DIRECTORY_DOWNLOADS+"/SoundQ review qualification");put(MediaStore.MediaColumns.IS_PENDING,1)
        }))
        try {
            val rate=16000;val frames=rate*30;val size=frames*2
            val bytes=ByteBuffer.allocate(44+size).order(ByteOrder.LITTLE_ENDIAN).apply {
                put("RIFF".toByteArray()).putInt(36+size).put("WAVEfmt ".toByteArray()).putInt(16)
                putShort(1).putShort(1).putInt(rate).putInt(rate*2).putShort(2).putShort(16).put("data".toByteArray()).putInt(size)
                repeat(frames){putShort((kotlin.math.sin(it*2*Math.PI*223/rate)*4000).toInt().toShort())}
            }.array()
            resolver.openOutputStream(uri,"w")!!.use {it.write(bytes)}
            resolver.update(uri,ContentValues().apply {put(MediaStore.MediaColumns.IS_PENDING,0)},null,null)
            model.graph.phoneAudio.selected(uri,Intent.FLAG_GRANT_READ_URI_PERMISSION,false){true}
            compose.waitUntil(15000){model.graph.phoneAudio.state.value.snapshot?.files?.any {it.available&&it.metadata.filename==name}==true}
            val row=model.graph.phoneAudio.state.value.snapshot!!.files.single {it.metadata.filename==name}
            compose.runOnIdle {model.controller.playDevice(model.graph.phoneAudio.reference(row)){true}}
            compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.positionMs>100}
            compose.runOnIdle {model.controller.pause()}
            compose.waitUntil(5000){!model.playback.value.isPlaying&&!model.playback.value.preparing}
            compose.onNodeWithContentDescription("Open listening queue").performClick()
            compose.onNodeWithText("Waveforms").performClick()
            compose.onNodeWithText("List").assertIsSelected()
            compose.onNodeWithText("Waveforms").assertIsNotSelected()
            capture("phone-queue-list")
            compose.onNode(hasContentDescription("Play") and hasAnyAncestor(isDialog())).assertIsEnabled().performClick()
            compose.waitUntil(10000){model.playback.value.isPlaying}
            compose.onNodeWithText("Arrangement playback unavailable").assertDoesNotExist()
            capture("phone-queue-playing")
        }finally {
            compose.runOnIdle {model.controller.pause();model.controller.clear()}
            assertEquals(1,resolver.delete(uri,null,null))
        }
    }
}
