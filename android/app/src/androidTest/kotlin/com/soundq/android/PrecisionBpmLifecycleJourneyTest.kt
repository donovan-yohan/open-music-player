package com.soundq.android

import androidx.activity.compose.setContent
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.timeline.*
import com.soundq.android.playback.*
import com.soundq.android.playback.nativeengine.NativeCallbackPlayer
import com.soundq.android.product.ProductViewModel
import com.soundq.android.product.timeline.WaveformBpmEditor
import com.soundq.designsystem.SoundQTheme
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Registered AndroidJUnit4 test. Run with PrecisionBpmLiveFixtureRunner (120-second input).
 * Actual ordinary route, MainActivity lifecycle, service/controller/JNI and source-generation ACKs.
 * The second case mounts the same production editor with a held wave read and delayed projection.
 * No shared sheet/precision component or original journey assertions are replaced. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class PrecisionBpmLifecycleJourneyTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private fun control() = compose.onNodeWithTag("precision-bpm-surface")
    private fun click(text:String) = compose.onNode(hasText(text) and hasClickAction()).performScrollTo().performClick()
    private fun type(value:String) {
        control().performClick()
        compose.onNodeWithContentDescription("Type BPM").performTextReplacement(value)
        compose.onNodeWithContentDescription("Type BPM").performImeAction()
    }
    private fun start():Pair<PrecisionBpmLiveFixtureApplication,ProductViewModel> {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as PrecisionBpmLiveFixtureApplication
        compose.runOnIdle {app.graph.session.retire()}
        compose.waitUntil(10_000) { compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithContentDescription("Email").performTextInput("precision-lifecycle@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onNodeWithContentDescription("Password").performImeAction()
        val model = compose.runOnIdle { ViewModelProvider(compose.activity)[ProductViewModel::class.java] }
        compose.waitUntil(15_000) { model.library.value.rows.size == 2 }
        compose.onNode(hasText("Tempo 1") and hasClickAction() and hasAnyDescendant(hasContentDescription("More for Tempo 1"))).performClick()
        compose.waitUntil(15_000) { app.callbackCreated && model.playback.value.isPlaying && model.timeline.value.document.clips.size == 2 }
        compose.onNodeWithContentDescription("Pause").performClick()
        compose.onNodeWithContentDescription("Open listening queue").performClick()
        compose.onNodeWithText("Waveforms").performClick()
        compose.onNode(hasContentDescription("Play") and hasAnyAncestor(isDialog())).performClick()
        compose.waitUntil(15_000) { model.playback.value.arrangement != null && model.playback.value.isPlaying && model.playback.value.canPerformArrangement }
        return app to model
    }
    private fun ready(model:ProductViewModel,previous:TempoPreviewLease?=null):TempoPreviewLease {
        compose.waitUntil(10_000) { model.playback.value.tempoPreview?.let { it.phase==TempoPreviewPhase.Ready && it.lease!=previous }==true }
        return model.playback.value.tempoPreview!!.lease
    }
    private fun applied(model:ProductViewModel,bpm:Double):TempoPreviewState {
        compose.waitUntil(15_000) { model.playback.value.tempoPreview?.let { it.phase==TempoPreviewPhase.Applied && kotlin.math.abs(it.appliedBpm-bpm)<0.00001 && it.appliedTag==it.desiredTag && it.appliedTag>0 }==true }
        val state=model.playback.value.tempoPreview!!
        assertEquals(state.appliedTag,model.playback.value.performanceDecks[state.lease.target.occurrence]!!.tempoGeneration)
        return state
    }
    private fun closed() = compose.onNodeWithTag("precision-bpm-surface").assertDoesNotExist()

    @Test fun activeOrdinarySheetPauseRestoresMatchingSourceThenRequiresFreshOpenAndRetiresOnTransport() {
        val (app,model)=start()
        val native=app.callbackPlayer as NativeCallbackPlayer
        val document=compose.runOnIdle {model.timeline.value.document}
        val clip=document.clips.first()
        val origin=compose.runOnIdle {model.graph.timeline.tempoSource(clip)!!.sourceBpm}
        val before=JSONObject(native.nativeDiagnostics())
        val evidence=JSONObject().put("before",before)
        try {
            compose.openWaveformBpm("Tempo 1")
            val firstLease=ready(model)
            type("132.25")
            val preview=applied(model,132.25)
            assertEquals(document,model.timeline.value.document)
            assertTrue(model.playback.value.isPlaying)
            evidence.put("activeLease",firstLease.toString()).put("activeTag",preview.appliedTag)
            // STARTED sends the real ON_PAUSE without disposing MainActivity's route composition.
            compose.activityRule.scenario.moveToState(Lifecycle.State.STARTED)
            compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
            compose.waitUntil(15_000) { model.playback.value.tempoPreview?.let { it.lease==firstLease && it.phase==TempoPreviewPhase.Restored && it.appliedTag>preview.appliedTag && kotlin.math.abs(it.appliedBpm-origin)<0.00001 }==true }
            closed()
            val restored=model.playback.value.tempoPreview!!
            assertEquals(restored.desiredTag,restored.appliedTag)
            assertEquals(firstLease.source,restored.lease.source)
            assertEquals(restored.appliedTag,model.playback.value.performanceDecks[clip.occurrence]!!.tempoGeneration)
            assertEquals(document,model.timeline.value.document)
            assertTrue(model.playback.value.isPlaying)
            assertEquals(before.getLong("scheduleRevision"),JSONObject(native.nativeDiagnostics()).getLong("scheduleRevision"))
            // A fresh foreground open gets a different capability and reaches audible generation.
            compose.openWaveformBpm("Tempo 1")
            val freshLease=ready(model,firstLease)
            type("126.5");applied(model,126.5)
            compose.runOnIdle {model.controller.pause()}
            compose.waitUntil(10_000) {model.playback.value.tempoPreview?.let {it.lease==freshLease && it.phase==TempoPreviewPhase.Retired}==true}
            compose.waitUntil(5_000) {compose.onAllNodesWithTag("precision-bpm-surface").fetchSemanticsNodes().isEmpty()}
            closed()
            assertEquals(document,model.timeline.value.document)
            compose.runOnIdle {model.controller.toggle()}
            compose.waitUntil(10_000) {model.playback.value.isPlaying && model.playback.value.canPerformArrangement}
            closed() // resume never silently reopens/reacquires
            compose.openWaveformBpm("Tempo 1")
            val newest=ready(model,freshLease)
            type("123.5");applied(model,123.5)
            // Service/controller-owned restoration also retires the still-mounted editor.
            compose.runOnIdle {model.controller.cancelTempo(newest)}
            compose.waitUntil(15_000) {model.playback.value.tempoPreview?.let {it.lease==newest && it.phase==TempoPreviewPhase.Restored}==true}
            compose.waitUntil(5_000) {compose.onAllNodesWithTag("precision-bpm-surface").fetchSemanticsNodes().isEmpty()}
            closed()
            assertEquals(document,model.timeline.value.document)
            evidence.put("result","PASS").put("restoredTag",restored.appliedTag).put("freshLease",freshLease.toString()).put("newestLease",newest.toString()).put("after",JSONObject(native.nativeDiagnostics()))
        } catch(failure:Throwable) {evidence.put("failure",failure.toString()).put("preview",model.playback.value.tempoPreview?.toString()).put("native",JSONObject(native.nativeDiagnostics()));throw failure}
        finally {File(app.filesDir,"precision-bpm-lifecycle-journey.json").writeText(evidence.toString(2));compose.runOnIdle {model.controller.pause()}}
    }

    @Test fun mountedEditorBeginsWhenPlayingProjectionArrivesAfterHeldWaveRead() {
        val (app,model)=start()
        val document=compose.runOnIdle {model.timeline.value.document}
        val clip=document.clips.first()
        val scope=model.graph.session.capture()!!
        val wave=CompletableDeferred<TrackWaveform?>()
        val reading=java.util.concurrent.atomic.AtomicBoolean(false)
        val dismissed=java.util.concurrent.atomic.AtomicInteger(0)
        // Test-only publication boundary. The adapter and service remain the real production ones.
        // Stop just the periodic projection publisher, not playback, so readiness can be held.
        val tickField=ControllerProjection::class.java.getDeclaredField("tick").apply {isAccessible=true}
        val handlerField=ControllerProjection::class.java.getDeclaredField("handler").apply {isAccessible=true}
        val mutableField=ControllerProjection::class.java.getDeclaredField("mutable").apply {isAccessible=true}
        val handler=handlerField.get(model.controller) as android.os.Handler
        val tick=tickField.get(model.controller) as Runnable
        val native=app.callbackPlayer as NativeCallbackPlayer
        val performanceChanged=compose.runOnIdle {native.onPerformanceChanged}
        @Suppress("UNCHECKED_CAST") val published=mutableField.get(model.controller) as MutableStateFlow<PlaybackProjection>
        val accepted=compose.runOnIdle {native.onPerformanceChanged=null;handler.removeCallbacks(tick);published.value}
        val hidden=accepted.copy(isPlaying=false,canPerformArrangement=false)
        try {
            compose.runOnIdle {published.value=hidden}
            compose.activityRule.scenario.onActivity {activity->activity.setContent {SoundQTheme {
                var open by remember {mutableStateOf(true)}
                if(open)WaveformBpmEditor(document,clip,model.graph.timeline,scope,{true},{reading.set(true);wave.await()},
                    {dismissed.incrementAndGet();open=false},controller=model.controller)
                else Text("BPM editor closed")
            }}}
            compose.waitUntil(5_000) {reading.get()}
            val actualWave=model.graph.timeline.waveform(scope,com.soundq.android.data.TrackId(clip.track),clip.sourceDurationMs,valid={true})
            assertNotNull(actualWave)
            compose.runOnIdle {wave.complete(actualWave)}
            compose.waitUntil(5_000) {compose.onAllNodesWithTag("precision-bpm-surface").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("Draft only. Save applies on the next Play.").assertExists()
            assertNull(model.playback.value.tempoPreview)
            assertTrue(JSONObject((app.callbackPlayer as NativeCallbackPlayer).nativeDiagnostics()).getBoolean("schedulePlaying"))
            // The input and captured document are unchanged. Only authoritative readiness publishes.
            compose.runOnIdle {native.onPerformanceChanged=performanceChanged;published.value=accepted}
            val lease=ready(model)
            compose.onNodeWithText("Live preview. Save keeps playback running; Cancel restores accepted BPM.").assertExists()
            type("132.25");applied(model,132.25)
            assertEquals(document,model.timeline.value.document)
            click("Cancel")
            compose.waitUntil(15_000) {model.playback.value.tempoPreview?.let {it.lease==lease && it.phase==TempoPreviewPhase.Restored}==true}
            compose.waitUntil(5_000) {dismissed.get()==1}
            closed()
        } finally {compose.runOnIdle {native.onPerformanceChanged=performanceChanged;handler.post(tick);model.controller.pause()}}
    }
}
