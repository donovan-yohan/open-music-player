package com.soundq.android

import android.graphics.Bitmap
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.media3.session.MediaSession
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Actual app composition and TLS analysis acquisition. No replacement player or waveform renderer. */
class MobileWorkspaceJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private val track=hasClickAction() and hasAnyDescendant(hasText("Fixture 1")) and
        hasAnyDescendant(hasContentDescription("More for Fixture 1"))

    private fun capture(node:SemanticsNodeInteraction,name:String) {
        compose.waitForIdle()
        val view=(node.fetchSemanticsNode().root as ViewRootForTest).view
        compose.runOnIdle {
            assertTrue(compose.activity.window.attributes.flags and android.view.WindowManager.LayoutParams.FLAG_SECURE==0)
            val bitmap=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
            try {
                view.draw(android.graphics.Canvas(bitmap))
                val target=InstrumentationRegistry.getInstrumentation().targetContext
                val output=File(target.filesDir,"mobile-workspace").apply {mkdirs()}
                File(output,"$name.png").outputStream().use {assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG,100,it))}
            } finally {bitmap.recycle()}
        }
    }

    @Test fun libraryBottomNavigationQueueCommitAndTwoLoadedWaveformsStayUsable() {
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("workspace@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.waitUntil(15000){model.library.value.rows.size==3}
        val home=compose.onNodeWithText("Home",useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
        val discover=compose.onNodeWithText("Discover",useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
        val playlist=compose.onNodeWithText("Playlists",useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
        val first=compose.onNode(track,useUnmergedTree=true)
        assertTrue("Root navigation belongs below content",home.top>first.fetchSemanticsNode().boundsInRoot.bottom)
        assertEquals(home.top,discover.top,1f);assertEquals(home.top,playlist.top,1f)
        compose.onNodeWithText("Native listening preview · Library, collections, Home, history, source search, imports and sequential audio. Other SoundQ workflows are not yet included.").assertDoesNotExist()
        capture(first,"library")
        first.performClick()
        compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.positionMs>300}
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CallbackFrontendFixtureApplication
        assertEquals("com.soundq.android.playback.nativeengine.NativeCallbackPlayer",app.callbackPlayer.javaClass.name)
        val diagnostics=app.callbackPlayer.javaClass.getDeclaredMethod("nativeDiagnostics").apply {isAccessible=true}
        val native=org.json.JSONObject(diagnostics.invoke(app.callbackPlayer) as String)
        assertEquals(0,native.getInt("error"))
        assertTrue(native.getLong("renderedFrames")>0)
        assertTrue(native.getLong("nonSilentCallbacks")>0)
        assertEquals(1,native.getInt("openDecoders"))
        compose.runOnIdle {model.controller.pause()}
        compose.waitUntil(10000){!model.playback.value.isPlaying&&!model.playback.value.preparing}
        val original=compose.runOnIdle {model.playback.value.queue.map {it.occurrenceId}}
        val selected=model.playback.value.selectedOccurrence
        compose.onNodeWithContentDescription("Open listening queue").performClick()
        val grip=compose.onNodeWithContentDescription("Reorder Fixture 1")
        val destination=compose.onNodeWithContentDescription("Reorder Fixture 3")
        capture(grip,"queue-list")
        val from=grip.fetchSemanticsNode().boundsInRoot
        val to=destination.fetchSemanticsNode().boundsInRoot
        compose.mainClock.autoAdvance=false
        try {
            grip.performTouchInput {down(center);moveBy(Offset(0f,to.center.y-from.center.y+to.height/2))}
            repeat(3){compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
            grip.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription,"Moving to position 3"))
            assertEquals(original,model.playback.value.queue.map {it.occurrenceId})
            grip.performTouchInput {up()}
            compose.mainClock.advanceTimeBy(1000)
        } finally {compose.mainClock.autoAdvance=true}
        val expected=original.toMutableList().apply {add(2,removeAt(0))}
        fun serviceOrder():List<String> {
            val sessions=MediaSession::class.java.getDeclaredField("SESSION_ID_TO_SESSION_MAP").apply {isAccessible=true}.get(null) as Map<*,*>
            val player=(sessions.values.single() as MediaSession).player
            return (0 until player.mediaItemCount).map {player.getMediaItemAt(it).mediaId}
        }
        compose.waitUntil(10000){compose.runOnIdle {model.playback.value.queue.map {it.occurrenceId}==expected&&serviceOrder()==expected}}
        assertEquals(selected,model.playback.value.selectedOccurrence)
        assertFalse(model.playback.value.isPlaying)
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Reorder Fixture 1").assertIsFocused().assertIsDisplayed()
        val firstAfter=compose.onNodeWithContentDescription("Reorder Fixture 2").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        assertEquals("Visible reorder must preserve list origin, not top-align the moved row",from.top,firstAfter.top,1f)
        compose.onNodeWithContentDescription("Close Queue").performClick()
        compose.onNodeWithContentDescription("Open listening queue").performClick()
        compose.runOnIdle {assertEquals(expected,serviceOrder());assertEquals(expected,model.playback.value.queue.map {it.occurrenceId})}
        capture(compose.onNodeWithContentDescription("Reorder Fixture 1"),"queue-reordered")
        compose.onNodeWithText("Waveforms").performClick()
        val a=compose.onNodeWithContentDescription("Waveform ${expected[0]}")
        val b=compose.onNodeWithContentDescription("Waveform ${expected[1]}")
        compose.waitUntil(15000){
            val nodes=compose.onAllNodes(hasContentDescription("Waveform ${expected[0]}") or hasContentDescription("Waveform ${expected[1]}"),useUnmergedTree=true).fetchSemanticsNodes()
            nodes.size==2&&nodes.all {it.config.getOrNull(SemanticsProperties.StateDescription)?.contains("Loaded",ignoreCase=true)==true}
        }
        a.assertIsDisplayed();b.assertIsDisplayed()
        val ab=a.fetchSemanticsNode().boundsInRoot
        val bb=b.fetchSemanticsNode().boundsInRoot
        val density=compose.activity.resources.displayMetrics.density
        assertEquals("Complete waveform rows must remain compact",96*density,ab.height,1f)
        assertEquals("Every row uses the same compact height",ab.height,bb.height,1f)
        assertEquals("Waveform bodies touch without intervening identity strips",ab.bottom,bb.top,1f)
        assertTrue(ProductTransportFixture.requests.contains("GET /api/v1/tracks/2/analysis"))
        assertTrue(ProductTransportFixture.requests.contains("GET /api/v1/tracks/3/analysis"))
        capture(a,"queue-waveforms")
        compose.onNodeWithText("Apply explicitly to audition a frozen mixed revision using downloaded sources. Later edits do not change the playing snapshot. Ruler release seeks paused.").assertDoesNotExist()
        compose.onNodeWithText("No peaks have been fabricated.",substring=true).assertDoesNotExist()
    }
}
