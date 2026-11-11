package com.soundq.android

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.playback.TempoPreviewPhase
import com.soundq.android.playback.nativeengine.NativeCallbackPlayer
import com.soundq.android.product.ProductViewModel
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Registered under PrecisionBpmLiveFixtureRunner. Real service/controller/JNI/output, ordinary BPM sheet. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class PrecisionBpmLiveJourneyTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private fun click(text:String) = compose.onNode(hasText(text) and hasClickAction()).performScrollTo().performClick()
    private fun control() = compose.onNodeWithTag("precision-bpm-surface")
    private fun type(value:String) {
        control().performClick()
        compose.onNodeWithContentDescription("Type BPM").performTextReplacement(value)
        compose.onNodeWithContentDescription("Type BPM").performImeAction()
    }
    @Test fun ordinarySheetPreviewsRestoresAndSavesMatchingRenderedGenerationWithoutRestart() {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as PrecisionBpmLiveFixtureApplication
        compose.waitUntil(10_000) { compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithContentDescription("Email").performTextInput("precision-live@example.test")
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
        val native = app.callbackPlayer as NativeCallbackPlayer
        fun diagnostics() = JSONObject(native.nativeDiagnostics())
        val durable = compose.runOnIdle { model.timeline.value.document }
        val install = compose.runOnIdle { model.playback.value.arrangement!!.identity.install }
        val source = durable.clips.first()
        val origin = compose.runOnIdle { model.graph.timeline.tempoSource(source)!!.sourceBpm }
        val schedule = compose.runOnIdle { diagnostics().getLong("scheduleRevision") }
        val openedAt = compose.runOnIdle { diagnostics().getLong("globalFrame") }
        val output = File(app.filesDir,"precision-bpm-live-journey.json")
        val evidence = JSONObject().put("nativeSchedule",schedule).put("install",install)
        try {
            evidence.put("beforeOpen",diagnostics())
            compose.openWaveformBpm("Tempo 1")
            evidence.put("afterOpen",diagnostics())
            compose.waitUntil(10_000) { model.playback.value.tempoPreview?.phase == TempoPreviewPhase.Ready }
            assertTrue(model.playback.value.isPlaying)
            control().performTouchInput {
                val from=Offset(width*.2f,height*.65f)
                swipe(from,Offset(from.x,from.y-32f),200)
            }
            compose.waitUntil(15_000) { model.playback.value.tempoPreview?.let { it.phase==TempoPreviewPhase.Applied&&it.appliedBpm>origin }==true }
            val first = model.playback.value.tempoPreview!!
            assertEquals(first.desiredTag,first.appliedTag)
            assertEquals(first.appliedTag,model.playback.value.performanceDecks[source.occurrence]!!.tempoGeneration)
            assertEquals(durable,model.timeline.value.document)
            assertTrue(model.playback.value.isPlaying)
            click("Cancel")
            compose.waitUntil(15_000) { model.playback.value.tempoPreview?.phase==TempoPreviewPhase.Restored }
            assertEquals(origin,model.playback.value.tempoPreview!!.appliedBpm,0.0001)
            assertTrue(model.playback.value.tempoPreview!!.appliedTag>first.appliedTag)
            assertEquals(durable,model.timeline.value.document)
            assertTrue(model.playback.value.isPlaying)
            assertEquals(schedule,diagnostics().getLong("scheduleRevision"))
            assertTrue(diagnostics().getLong("globalFrame")>openedAt)
            compose.openWaveformBpm("Tempo 1")
            compose.waitUntil(10_000) { model.playback.value.tempoPreview?.phase==TempoPreviewPhase.Ready }
            type("132.25")
            compose.waitUntil(15_000) { model.playback.value.tempoPreview?.let {it.phase==TempoPreviewPhase.Applied&&it.appliedBpm==132.25}==true }
            val applied = model.playback.value.tempoPreview!!
            val cursorBeforeSave = diagnostics().getLong("globalFrame")
            val seekBeforeSave = diagnostics().optLong("seekCount",-1)
            click("Save BPM")
            compose.waitUntil(10_000) { model.timeline.value.document.playbackTempos.singleOrNull()?.playbackBpm==132.25 }
            compose.waitUntil(10_000) { model.playback.value.arrangement?.document==model.timeline.value.document }
            assertTrue(model.playback.value.isPlaying)
            assertEquals(install,model.playback.value.arrangement!!.identity.install)
            val after=diagnostics()
            assertEquals(schedule,after.getLong("scheduleRevision"))
            assertEquals(applied.appliedTag,after.getLong("tempoApplied"))
            assertTrue(after.getLong("globalFrame")>=cursorBeforeSave)
            if(seekBeforeSave>=0)assertEquals(seekBeforeSave,after.getLong("seekCount"))
            assertEquals(durable.clips.map {Triple(it.globalStartMs,it.sourceInMs,it.sourceOutMs)},model.timeline.value.document.clips.map {Triple(it.globalStartMs,it.sourceInMs,it.sourceOutMs)})
            assertEquals(durable.clips.map {it.fadeInMs to it.fadeOutMs},model.timeline.value.document.clips.map {it.fadeInMs to it.fadeOutMs})
            assertTrue(model.timeline.value.canUndo)
            evidence.put("result","PASS").put("previewTag",first.appliedTag).put("saveTag",applied.appliedTag).put("after",after)
        } catch(failure:Throwable) {
            evidence.put("failure",failure.toString()).put("native",diagnostics()).put("preview",model.playback.value.tempoPreview?.toString())
                .put("playing",model.playback.value.isPlaying).put("canPerform",model.playback.value.canPerformArrangement)
                .put("acceptedDocumentMatches",model.playback.value.arrangement?.document==model.timeline.value.document)
                .put("tempoSource",model.graph.timeline.tempoSource(source)?.toString())
            try {
                val roots=compose.onAllNodes(isRoot(),useUnmergedTree=true)
                evidence.put("semantics",(0 until roots.fetchSemanticsNodes().size).joinToString("\n") { roots[it].printToString(maxDepth=30) })
                evidence.put("playerPreview",native.tempoPreviewState?.toString())
            }
            catch(diagnostic:Throwable) { failure.addSuppressed(diagnostic) }
            throw failure
        }
        finally {output.writeText(evidence.toString(2));compose.runOnIdle {model.controller.pause()}}
    }
}
