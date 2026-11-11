package com.soundq.android

import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Mounted ordinary Activity -> HTTPS API -> service -> actual ExoPlayer WAV decoding. */
class ProductJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    // The Library row owns a nested More action; compact metadata has no nested control.
    // A title alone is not unique when retained playback also shows the same track.
    private val libraryTrack=hasText("Fixture 1") and hasClickAction() and
        hasAnyDescendant(hasContentDescription("More for Fixture 1"))
    private val compactTrack=hasText("Fixture 1") and hasClickAction() and
        !hasAnyDescendant(hasContentDescription("More for Fixture 1"))
    private fun captureMountedStage(name:String) {
        compose.waitForIdle()
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val directory=File(instrumentation.targetContext.getExternalFilesDir(null),"mounted-journey").also {check(it.mkdirs()||it.isDirectory)}
        val bitmap=checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        try {File(directory,"$name.png").outputStream().use {check(bitmap.compress(Bitmap.CompressFormat.PNG,100,it))}}
        finally {bitmap.recycle()}
    }
    @Test fun signInLibraryLikeListenSeekOccurrenceQueueAndLogout() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("synthetic@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        val loginBefore=ProductTransportFixture.requests.size
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        compose.waitUntil(10000){ProductTransportFixture.requests.drop(loginBefore).contains("POST /api/v1/auth/login")&&app.graph.session.capture()!=null&&compose.onAllNodes(libraryTrack).fetchSemanticsNodes().size==1}
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.onNodeWithContentDescription("More for Fixture 1").performClick()
        val likeBefore=ProductTransportFixture.requests.size
        compose.onNodeWithText("Like",useUnmergedTree=true).performClick()
        compose.waitUntil(10000){
            ProductTransportFixture.requests.drop(likeBefore).contains("POST /api/v1/library/tracks/1/like")&&
                ProductTransportFixture.requests.drop(likeBefore).contains("GET /api/v1/library")&&
                ProductTransportFixture.liked&&app.graph.library.state.value.rows.any {it.id.value==1L&&it.liked==true}
        }
        val mediaBefore=ProductTransportFixture.requests.size
        compose.onNode(libraryTrack).performClick()
        compose.waitUntil(15000){ProductTransportFixture.requests.drop(mediaBefore).any {it.startsWith("GET /media/")}&&model.playback.value.isPlaying&&model.playback.value.positionMs>0}
        compose.waitUntil(15000){compose.onAllNodesWithContentDescription("Pause").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Pause").performClick()
        compose.onNode(compactTrack).performClick()
        compose.onNodeWithText("Now playing").assertExists()
        compose.onNodeWithContentDescription("Playback position").performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.SetProgress){it(0.25f)}
        compose.waitUntil(10000){!model.playback.value.isPlaying&&model.playback.value.positionMs in 2900L..3100L}
        captureMountedStage("full-player-seek-paused")
        compose.onNodeWithText("Open listening queue").performClick()
        compose.showSourceListeningQueue()
        compose.onNodeWithText("Listening queue").assertExists()
        compose.onNodeWithContentDescription("Reorder Fixture 1").assertExists()
        captureMountedStage("listening-queue")
        compose.onNodeWithContentDescription("Close Queue").performClick()
        compose.onNodeWithContentDescription("More for Fixture 1").performClick()
        compose.onNodeWithText("Add to listening queue").performClick()
        compose.onNodeWithContentDescription("Open listening queue").performClick()
        compose.showSourceListeningQueue()
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Reorder Fixture 1").fetchSemanticsNodes().size==2}
        val duplicates=model.playback.value.queue.filter {it.trackId==1L}
        assertEquals(2,duplicates.size)
        assertEquals(2,duplicates.map {it.occurrenceId}.toSet().size)
        captureMountedStage("listening-queue-duplicates")
        compose.onNodeWithContentDescription("Close Queue").performClick()
        compose.onNodeWithContentDescription("Account and preview information").performClick()
        val logoutBefore=ProductTransportFixture.requests.size
        compose.onNodeWithText("Sign out").performClick()
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()&&app.graph.session.capture()==null&&model.playback.value.queue.isEmpty()&&ProductTransportFixture.requests.drop(logoutBefore).contains("POST /api/v1/auth/logout")}
        assertNull(app.graph.session.capture())
        assertTrue(model.playback.value.queue.isEmpty())
        assertTrue(ProductTransportFixture.requests.drop(likeBefore).contains("POST /api/v1/library/tracks/1/like"))
    }
    @Test fun registrationUsesNativeFieldsAndAcceptedSession() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        app.graph.session.retire()
        compose.waitUntil(10000){compose.onAllNodesWithText("Create account").filter(hasClickAction()).fetchSemanticsNodes().isNotEmpty()}
        compose.onAllNodesWithText("Create account").filterToOne(hasClickAction()).performClick()
        compose.onNodeWithContentDescription("Username").performTextInput("Synthetic User")
        compose.onNodeWithContentDescription("Email").performTextInput("new-synthetic@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onNodeWithContentDescription("Confirm password").performTextInput("test-only-password")
        val registerBefore=ProductTransportFixture.requests.size
        compose.onAllNodesWithText("Create account").filterToOne(hasClickAction()).performScrollTo().performClick()
        compose.waitUntil(10000){app.graph.session.capture()!=null&&ProductTransportFixture.requests.drop(registerBefore).contains("POST /api/v1/auth/register")}
        assertTrue(ProductTransportFixture.requests.drop(registerBefore).contains("POST /api/v1/auth/register"))
        app.graph.session.retire()
    }
}
