package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import com.soundq.android.data.timeline.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** User-facing overlap contract over the same callback output as ordinary listening. */
class NativeOverlapJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun overlappingWaveformDraftCanPlayBothSourcesOnTheUnifiedNativeOutput() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CallbackFrontendFixtureApplication
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("overlap@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.waitUntil(15000){model.library.value.rows.size==3}
        compose.onNode(hasClickAction() and hasAnyDescendant(hasText("Fixture 1")) and
            hasAnyDescendant(hasContentDescription("More for Fixture 1")),useUnmergedTree=true).performClick()
        try {
            compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.positionMs>300}
            compose.runOnIdle {model.controller.pause();model.controller.seek(0)}
            compose.waitUntil(10000){!model.playback.value.isPlaying&&model.playback.value.positionMs<=100}
            compose.waitUntil(10000){model.timeline.value.document.clips.size==3}
            val before=compose.runOnIdle {model.timeline.value.document}
            val second=before.clips[1]
            runBlocking(Dispatchers.IO) {
                assertTrue(model.graph.timeline.commit(TimelineEdit(before.revision,second,EditKind.Placement,0)){true})
            }
            val edited=compose.runOnIdle {model.timeline.value.document}
            assertEquals(0L,edited.clips[1].globalStartMs)
            assertTrue(edited.clips[0].globalEndMs>edited.clips[1].globalStartMs)
            assertFalse(model.playback.value.isPlaying)
            assertTrue("Native session must admit waveform arrangement playback before Play is offered",model.playback.value.canAuditionArrangement)
            compose.onNodeWithContentDescription("Open listening queue").performClick()
            compose.onNodeWithText("Waveforms").performClick()
            compose.onNode(hasContentDescription("Play") and hasAnyAncestor(isDialog())).assertIsEnabled().performClick()
            val method=app.callbackPlayer.javaClass.getDeclaredMethod("nativeDiagnostics").apply {isAccessible=true}
            compose.waitUntil(15000){
                val native=org.json.JSONObject(method.invoke(app.callbackPlayer) as String)
                val decks=native.getJSONArray("decks")
                (0 until decks.length()).count {decks.getJSONObject(it).let {d->d.getBoolean("ready")&&d.getBoolean("playing")}}>=2&&model.playback.value.isPlaying
            }
            assertTrue(model.playback.value.isPlaying)
            val output=java.io.File(app.filesDir,"native-overlap").apply {mkdirs()}
            val playing=org.json.JSONObject(method.invoke(app.callbackPlayer) as String)
            assertTrue(playing.getBoolean("schedulePlaying"))
            assertEquals(0,playing.getInt("scheduleError"))
            assertTrue(playing.getLong("nonSilentCallbacks")>0)
            val started=playing.getLong("globalFrame")
            compose.waitUntil(10000){org.json.JSONObject(method.invoke(app.callbackPlayer) as String).getLong("globalFrame")>started+256}
            val firstId=edited.clips.first().occurrence
            val lane=compose.onNodeWithContentDescription("Waveform $firstId")
            compose.waitUntil(15000){lane.fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.StateDescription].startsWith("Loaded")}
            val root=lane.fetchSemanticsNode().root as ViewRootForTest
            compose.runOnIdle {
                val bitmap=android.graphics.Bitmap.createBitmap(root.view.width,root.view.height,android.graphics.Bitmap.Config.ARGB_8888)
                try {root.view.draw(android.graphics.Canvas(bitmap));java.io.File(output,"stack.png").outputStream().use {assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it))}}
                finally {bitmap.recycle()}
            }
            compose.onNode(hasContentDescription("Pause") and hasAnyAncestor(isDialog())).performClick()
            compose.waitUntil(10000){!org.json.JSONObject(method.invoke(app.callbackPlayer) as String).getBoolean("schedulePlaying")&&!model.playback.value.isPlaying}
            val paused=org.json.JSONObject(method.invoke(app.callbackPlayer) as String)
            val pausedFrame=paused.getLong("globalFrame")
            val callbacks=paused.getLong("renderedFrames")
            compose.waitUntil(10000){org.json.JSONObject(method.invoke(app.callbackPlayer) as String).getLong("renderedFrames")>callbacks+512}
            assertEquals("Pause freezes native graph while callbacks continue",pausedFrame,org.json.JSONObject(method.invoke(app.callbackPlayer) as String).getLong("globalFrame"))
            compose.runOnIdle {model.controller.seekArrangement(model.playback.value.arrangement!!.identity,2000)}
            compose.waitUntil(10000){model.playback.value.positionMs in 1999..2001&&!model.playback.value.isPlaying}
            // Public Media3 Stop exits audition coherently. It must not leave an
            // accepted synthetic row which ordinary explicit Play cannot prepare.
            compose.runOnIdle {app.callbackPlayer.stop()}
            compose.waitUntil(10000){model.playback.value.arrangement==null&&model.playback.value.queue.size==3&&!model.playback.value.isPlaying}
            compose.waitUntil(10000){org.json.JSONObject(method.invoke(app.callbackPlayer) as String).getLong("scheduleRevision")==0L}
            compose.runOnIdle {assertFalse(app.callbackPlayer.playWhenReady)}
            compose.onNode(hasContentDescription("Play") and hasAnyAncestor(isDialog())).assertIsEnabled().performClick()
            compose.waitUntil(15000){model.playback.value.arrangement!=null&&model.playback.value.isPlaying&&org.json.JSONObject(method.invoke(app.callbackPlayer) as String).let {native->
                val decks=native.getJSONArray("decks")
                (0 until decks.length()).count {decks.getJSONObject(it).getBoolean("playing")}>=2
            }}
            compose.onNode(hasContentDescription("Pause") and hasAnyAncestor(isDialog())).performClick()
            compose.waitUntil(10000){!model.playback.value.isPlaying}
            compose.onNodeWithContentDescription("Queue actions").performClick()
            compose.onNodeWithText("Return to source queue").performClick()
            compose.waitUntil(10000){model.playback.value.arrangement==null&&model.playback.value.queue.size==3}
            assertFalse(model.playback.value.isPlaying)
            compose.onNodeWithContentDescription("Close Queue").performClick()
            compose.onNodeWithContentDescription("Play").performClick()
            compose.waitUntil(15000){model.playback.value.isPlaying&&org.json.JSONObject(method.invoke(app.callbackPlayer) as String).let {it.getLong("scheduleRevision")==0L&&it.getJSONArray("decks").getJSONObject(0).getBoolean("playing")}}
            java.io.File(output,"playing.json").writeText(playing.toString(2))
            java.io.File(output,"result.json").writeText(org.json.JSONObject().put("twoNativeDecksPlaying",true).put("globalClockAdvanced",true).put("pauseFrozeGlobalClock",true).put("globalSeekMs",2000).put("stopRestoredSourcesPaused",true).put("explicitPlayReappliedGraph",true).put("returnedToOrdinarySamePlayer",true).toString(2))
        } finally {compose.runOnIdle {model.controller.pause()}}
    }
}
