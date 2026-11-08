package com.soundq.android

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.timeline.*
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Ordinary Queue UI and real service/JNI. Synthetic WAV only; no personal account. */
class WaveformResumeJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()

    private fun queuePlay()=compose.onNode(hasContentDescription("Play") and hasAnyAncestor(isDialog()))

    @Test fun pointerRulerAndBodyDragThenPlayRetainReleasedSourceAndGlobalCursor() {
        val graph=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication).graph
        try {
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("waveform-pointer@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onNodeWithContentDescription("Password").performImeAction()
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            compose.waitUntil(10000){model.library.value.rows.size==3}
            compose.onNode(hasText("Fixture 1") and hasClickAction() and hasAnyDescendant(hasContentDescription("More for Fixture 1"))).performClick()
            compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.positionMs>0}
            compose.onNodeWithContentDescription("Pause").performClick()
            compose.runOnIdle {model.controller.seek(1750)}
            compose.waitUntil(10000){!model.playback.value.isPlaying&&model.playback.value.positionMs in 1700L..1800L&&model.timeline.value.document.clips.size==3}
            val before=model.timeline.value.document
            val clip=before.clips.single {it.occurrence==model.playback.value.selectedOccurrence}
            assertEquals(before.clips.first().occurrence,clip.occurrence)
            compose.onNodeWithContentDescription("Open listening queue").performClick()
            compose.onNodeWithText("Waveforms").performClick()
            val ruler=compose.onNodeWithContentDescription("Global timeline ruler")
            val lane=compose.onNodeWithContentDescription("Waveform ${clip.occurrence}")
            // Fixture analysis is deliberately absent (404): failure must settle, not
            // strand pointer ownership in Loading. Loaded real data is also admissible.
            compose.waitUntil(10000){
                val nodes=compose.onAllNodesWithContentDescription("Waveform ${clip.occurrence}").fetchSemanticsNodes()
                nodes.singleOrNull()?.config?.getOrNull(SemanticsProperties.StateDescription) in
                    listOf("Loaded · Accepted timing","Unavailable · Accepted timing")
            }
            lane.assertIsDisplayed()
            val width=ruler.fetchSemanticsNode().boundsInRoot.width
            assertEquals(width,lane.fetchSemanticsNode().boundsInRoot.width,1f)
            // Match the one-time mounted WaveformOverview fit using actual measured
            // width and authoritative clip extents, not a fixed dp or screen size.
            val shown=before.clips.take(2)
            val origin=shown.minOf {it.globalStartMs}
            val end=shown.maxOf {it.globalEndMs}
            val viewport=TimelineViewport(before.clips.maxOf {it.globalEndMs},width,
                width.toDouble()*1000/(end-origin),origin)
            fun rulerDrag(from:Float,to:Float):Long {
                val expected=viewport.time(width*to)
                ruler.performTouchInput {swipe(Offset(width*from,height*0.5f),Offset(width*to,height*0.5f),300)}
                return expected
            }
            val releasedGlobal=rulerDrag(0.10f,0.15f)
            assertTrue(releasedGlobal in clip.globalStartMs until clip.globalEndMs)
            val releasedSource=clip.sourceAt(releasedGlobal)
            compose.waitUntil(10000){!model.playback.value.isPlaying&&kotlin.math.abs(model.playback.value.positionMs-releasedSource)<=100}
            assertEquals(before,model.timeline.value.document)
            assertNull(model.playback.value.arrangement)

            // y=80% is BELOW the 8dp + 48dp identity overlay in the 96dp lane.
            // x=45% starts inside the first clip; x=55% moves it, not an edge trim.
            assertTrue(viewport.time(width*0.45f) in clip.globalStartMs until clip.globalEndMs)
            lane.performTouchInput {swipe(Offset(width*0.45f,height*0.80f),Offset(width*0.55f,height*0.80f),300)}
            val placement=clip.globalStartMs+viewport.time(width*0.55f)-viewport.time(width*0.45f)
            compose.waitUntil(10000){
                val document=model.timeline.value.document
                document.revision!=before.revision&&document.clips.single {it.occurrence==clip.occurrence}.globalStartMs==placement
            }
            val accepted=model.timeline.value.document
            val moved=accepted.clips.single {it.occurrence==clip.occurrence}
            assertEquals(clip.sourceInMs,moved.sourceInMs)
            assertEquals(clip.sourceOutMs,moved.sourceOutMs)
            assertEquals(before.clips.drop(1),accepted.clips.drop(1))
            assertFalse(model.playback.value.isPlaying)
            assertTrue(kotlin.math.abs(model.playback.value.positionMs-releasedSource)<=100)
            val expectedResume=moved.globalAt(releasedSource)
            val mapped=WaveformResumeObservation.run(model,accepted,releasedSource,expectedResume,
                "pointer-body-mapped-source",20000) {queuePlay().performClick()}
            assertEquals(accepted,model.timeline.value.document)
            assertEquals(placement,model.timeline.value.document.clips.single {it.occurrence==clip.occurrence}.globalStartMs)

            // Separate unchanged installed-arrangement resume. Keep the actual
            // pointer ruler release; the observer does not issue a replacement seek.
            val installed=mapped.identity
            val installedReleased=rulerDrag(0.25f,0.30f)
            compose.waitUntil(10000){!model.playback.value.isPlaying&&kotlin.math.abs(model.playback.value.positionMs-installedReleased)<=100}
            val resumed=WaveformResumeObservation.run(model,accepted,installedReleased,installedReleased,
                "pointer-installed-ruler",10000,installed) {queuePlay().performClick()}
            assertEquals(installed,resumed.identity)
            assertEquals(installed,model.playback.value.arrangement!!.identity)
            assertEquals(accepted,model.timeline.value.document)
        } finally {graph.session.retire()}
    }

    /** Independent accessibility/direct-commit control; not pointer evidence. */
    @Test fun rulerScrubAndPlacementThenPlayRetainSourceAndInstalledGlobalCursor() {
        val graph=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication).graph
        try {
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("waveform-resume@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onNodeWithContentDescription("Password").performImeAction()
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            compose.waitUntil(10000){model.library.value.rows.size==3}
            compose.onNode(hasText("Fixture 1") and hasClickAction() and hasAnyDescendant(hasContentDescription("More for Fixture 1"))).performClick()
            compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.positionMs>0}
            compose.onNodeWithContentDescription("Pause").performClick()
            compose.runOnIdle {model.controller.seek(1750)}
            compose.waitUntil(10000){!model.playback.value.isPlaying&&model.playback.value.positionMs in 1700L..1800L&&model.timeline.value.document.clips.size==3}
            compose.onNodeWithContentDescription("Open listening queue").performClick()
            compose.onNodeWithText("Waveforms").performClick()
            val actions=compose.onNodeWithContentDescription("Global timeline ruler").fetchSemanticsNode().config[SemanticsActions.CustomActions]
            compose.runOnIdle {assertTrue(actions.single {it.label=="Seek one second later"}.action())}
            compose.waitUntil(10000){model.playback.value.positionMs in 2700L..2800L}
            val sourceDocument=model.timeline.value.document
            compose.runOnIdle {
                assertTrue(graph.timeline.commit(TimelineEdit(sourceDocument.revision,sourceDocument.clips.first(),EditKind.Placement,500)){true})
            }
            val movedDocument=model.timeline.value.document
            assertEquals(500L,movedDocument.clips.first().globalStartMs)
            assertEquals(sourceDocument.clips.first().sourceInMs,movedDocument.clips.first().sourceInMs)
            assertEquals(sourceDocument.clips.first().sourceOutMs,movedDocument.clips.first().sourceOutMs)
            assertEquals(sourceDocument.clips.drop(1),movedDocument.clips.drop(1))
            val mapped=WaveformResumeObservation.run(model,movedDocument,2750,3250,
                "accessibility-source-mapped",20000) {queuePlay().performClick()}
            val identity=mapped.identity
            compose.runOnIdle {model.controller.seekArrangement(identity,1900)}
            compose.waitUntil(10000){model.playback.value.positionMs in 1850L..1950L&&!model.playback.value.isPlaying}
            compose.runOnIdle {
                val document=model.timeline.value.document
                assertTrue(graph.timeline.commit(TimelineEdit(document.revision,document.clips.first(),EditKind.Placement,700)){true})
            }
            val reinstalledDocument=model.timeline.value.document
            assertEquals(700L,reinstalledDocument.clips.first().globalStartMs)
            assertEquals(movedDocument.clips.first().sourceInMs,reinstalledDocument.clips.first().sourceInMs)
            assertEquals(movedDocument.clips.first().sourceOutMs,reinstalledDocument.clips.first().sourceOutMs)
            assertEquals(movedDocument.clips.drop(1),reinstalledDocument.clips.drop(1))
            val reinstalled=WaveformResumeObservation.run(model,reinstalledDocument,1900,1900,
                "direct-reinstall-global",20000) {queuePlay().performClick()}
            assertNotEquals(identity,reinstalled.identity)
            // Independent full unchanged-install resume. Read the acknowledged
            // paused cursor, not a delayed/extrapolated projection position.
            val before=reinstalled.pausedMs
            val install=reinstalled.identity
            val unchanged=WaveformResumeObservation.run(model,reinstalledDocument,before,before,
                "direct-unchanged-install",10000,install) {queuePlay().performClick()}
            assertEquals(install,unchanged.identity)
            assertEquals(install,model.playback.value.arrangement!!.identity)
            assertEquals(reinstalledDocument,model.timeline.value.document)
        } finally {graph.session.retire()}
    }
}
