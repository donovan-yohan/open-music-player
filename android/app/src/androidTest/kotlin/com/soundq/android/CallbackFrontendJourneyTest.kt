package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.media3.common.Player
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Real Compose row -> MediaController -> service -> native callback output.
 * Only account/HTTP source fixtures are substituted by ProductFixtureRunner. */
class CallbackFrontendJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private fun action(label:String,dialog:Boolean=false)=compose.onNode(
        hasContentDescription(label) and if(dialog)hasAnyAncestor(isDialog()) else !hasAnyAncestor(isDialog())
    )

    @Test fun libraryRowPlaysNativeThenPauseSeekAndQueueCommandsRemainUsable() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CallbackFrontendFixtureApplication
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("callback@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        compose.waitUntil(15000){app.graph.library.state.value.rows.size==3}
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        val scope=app.graph.session.capture()!!
        compose.waitUntil(10000){app.graph.jamAdmission.hostSession(scope)!=null&&model.playback.value.arrangementService.isNotBlank()}
        val hostSession=app.graph.jamAdmission.hostSession(scope)!!
        val beforeQueue=app.graph.jamAdmission.incarnation
        assertEquals(model.playback.value.arrangementService,hostSession.substringBefore(':'))
        try {
            val title="Fixture 1"
            compose.onNode(hasClickAction() and hasAnyDescendant(hasText(title)) and
                hasAnyDescendant(hasContentDescription("More for $title")),useUnmergedTree=true)
                .performScrollTo().performClick()
            compose.waitUntil(20000){model.playback.value.isPlaying&&model.playback.value.positionMs>=300}
            val playing=model.playback.value
            assertEquals(3,playing.queue.size)
            assertEquals(title,playing.title)
            assertEquals(3,playing.queue.map {it.occurrenceId}.distinct().size)
            assertNotEquals(beforeQueue,app.graph.jamAdmission.incarnation)
            assertEquals(hostSession,app.graph.jamAdmission.hostSession(scope))
            assertNull(playing.error)
            assertFalse(playing.canPlayMix)
            // The retained native service now advertises its real arrangement
            // admission command. Capability presence is not an audition or play.
            assertTrue(playing.canAuditionArrangement)
            // The real application factory uses JNI. extractNativeLibs=false maps
            // APK ranges, so /proc/maps need not contain the library filename.
            assertEquals("com.soundq.android.playback.nativeengine.NativeCallbackPlayer",app.callbackPlayer.javaClass.name)
            val diagnostics=app.callbackPlayer.javaClass.getDeclaredMethod("nativeDiagnostics")
                .apply { isAccessible=true }
            val native=org.json.JSONObject(diagnostics.invoke(app.callbackPlayer) as String)
            assertEquals(0,native.getInt("error"))
            assertTrue(native.getLong("renderedFrames")>0)
            assertTrue(native.getLong("nonSilentCallbacks")>0)
            assertEquals(1,native.getInt("openDecoders"))
            captureListeningStage("ordinary-library-playing")
            action("Pause").performClick()
            compose.waitUntil(10000){!model.playback.value.isPlaying&&!model.playback.value.preparing}
            val occurrence=model.playback.value.selectedOccurrence!!
            // Library and compact-player rows now both expose complete spoken identity.
            // The paused transport surface, not an arbitrary first matching row, opens Player.
            compose.onNode(hasContentDescription("$title, Synthetic ensemble") and hasClickAction() and
                SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.StateDescription,"Paused")).performClick()
            action("Playback position",true).performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.SetProgress){it(2000f/model.playback.value.durationMs)}
            compose.waitUntil(10000){model.playback.value.let {it.selectedOccurrence==occurrence&&!it.isPlaying&&it.positionMs in 1950..2050}}
            captureListeningStage("ordinary-full-player-paused-seek")
            action("Close Now playing",true).performClick()
            action("Open listening queue").performClick()
            compose.onNode(hasText("Queue") and hasAnyAncestor(isDialog())).assertIsDisplayed()
            assertEquals(playing.queue,model.playback.value.queue)
            assertEquals(occurrence,model.playback.value.selectedOccurrence)
            assertFalse(model.playback.value.isPlaying)
            captureListeningStage("ordinary-queue-preserves-paused-owner")
            action("Close Queue",true).performClick()
            action("Play").performClick()
            compose.waitUntil(10000){model.playback.value.isPlaying&&model.playback.value.positionMs>2200}
            compose.runOnIdle {model.controller.shuffle()}
            compose.waitUntil(10000){model.playback.value.shuffle}
            compose.runOnIdle {model.controller.repeat()}
            compose.waitUntil(10000){model.playback.value.repeat==Player.REPEAT_MODE_ALL}
            compose.runOnIdle {model.controller.next()}
            compose.waitUntil(15000){model.playback.value.selectedOccurrence!=occurrence&&model.playback.value.isPlaying}
            assertNull(model.playback.value.error)
            assertTrue(ProductTransportFixture.requests.any {it.startsWith("GET /media/")})
            assertEquals(hostSession,app.graph.jamAdmission.hostSession(scope))
            android.util.Log.i("SoundQCallbackFrontend","PASS library row -> callback native service; pause/seek/resume/shuffle/repeat/next")
        } finally {
            compose.runOnIdle {model.controller.pause()}
        }
    }
}
