package com.soundq.android

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import com.soundq.android.data.TrackId
import com.soundq.android.data.timeline.*
import com.soundq.android.product.timeline.*
import com.soundq.designsystem.SoundQTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Real lane hit testing, including the painted title rather than semantic clicks. */
class TimelineIdentityTouchJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<ComponentActivity>()
    private val title="Painted identity"
    private val viewport=mutableStateOf(TimelineViewport(60000,400f,40.0))
    private var writes=0
    private var bpmOpens=0
    private var selections=0
    private var active:(()->Unit)?=null
    private var held:Float?=null
    private val owner=TimelineOwner({null},{writes++})
    private val body get()=compose.onNodeWithContentDescription("Waveform identity")
    private val info get()=compose.onNodeWithContentDescription("More for $title")
    private val bpm get()=compose.onNodeWithContentDescription("Playback BPM for $title")

    private fun mount(startMs:Long=0,selected:Boolean=false,scratch:WaveformScratch?=null) {
        owner.observe(listOf(TimelineSource("identity",7,title,10000,QueueSegment.Context)))
        if(startMs!=0L)assertTrue(owner.commit(TimelineEdit(owner.state.value.document.revision,owner.state.value.document.clips.single(),EditKind.Placement,startMs)))
        writes=0
        val document=mutableStateOf(owner.state.value.document)
        val cache=WaveformCache()
        val wave=TrackWaveform(TrackId(7),"identity-touch-fixture",10000,listOf(PeakTier("detail",FloatArray(64){-0.3f},FloatArray(64){0.6f})))
        compose.setContent {SoundQTheme(reducedMotion=true) {
            Column(Modifier.width(360.dp)) {
                TimelineLane(document.value.clips.single(),document.value.revision,selected,false,wave,viewport,
                    remember {mutableLongStateOf(0)},SnapMode.Free,false,{selections++},owner::preview,
                    {assertTrue(owner.commit(it));document.value=owner.state.value.document},cache::window,
                    {active=it},{held=it},{},onBpm={bpmOpens++},scratch=scratch)
            }
        }}
        compose.waitForIdle()
        compose.runOnIdle {viewport.value=viewport.value.copy(pixelsPerSecond=viewport.value.widthPx/10.0)}
        compose.waitForIdle()
    }

    private fun bounds(node:SemanticsNodeInteraction)=node.fetchSemanticsNode().boundsInRoot
    private fun local(point:Offset)=point-bounds(body).topLeft
    private fun identityPoint():Offset=local(bounds(compose.onNodeWithText("1 · $title",useUnmergedTree=true)).center)
    private fun assertAccepted() {
        body.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription,"Loaded · Accepted timing"))
        compose.runOnIdle {assertNull(active);assertNull(held)}
    }
    private fun assertNoInfo()=compose.onNodeWithText("Clip 1",useUnmergedTree=true).assertDoesNotExist()

    @Test fun dragStartingOnPaintedIdentityCommitsOneUndoablePlacement() {
        mount()
        val start=identityPoint()
        body.performTouchInput {down(start);moveBy(Offset(width*0.2f,0f))}
        body.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription,"Loaded · Preview timing edit"))
        compose.runOnIdle {assertNotNull(active);assertEquals(0,writes)}
        assertNoInfo()
        body.performTouchInput {up()}
        compose.runOnIdle {assertEquals(1,writes);assertEquals(2000L,owner.state.value.document.clips.single().globalStartMs);assertTrue(owner.state.value.canUndo);assertEquals(0,bpmOpens)}
        assertAccepted()
    }

    @Test fun capturedBodyDragCrossesIdentityAndActionPaintWithoutOpeningControls() {
        mount()
        val start=identityPoint()
        val infoCenter=local(bounds(info).center)
        val bpmCenter=local(bounds(bpm).center)
        body.performTouchInput {
            down(start.copy(y=height*0.8f));moveBy(Offset(60f,0f))
            moveTo(start+Offset(60f,0f));moveTo(infoCenter);moveTo(bpmCenter);up()
        }
        compose.runOnIdle {assertEquals(1,writes);assertEquals(0,bpmOpens)}
        assertNoInfo()
        assertAccepted()
    }

    @Test fun acceptedIdentityDragCancelDoesNotWriteAndFreshGestureCommits() {
        mount()
        val start=identityPoint()
        body.performTouchInput {down(start);moveBy(Offset(width*0.2f,0f))}
        body.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription,"Loaded · Preview timing edit"))
        compose.runOnIdle {assertNotNull(active)}
        body.performTouchInput {cancel()}
        assertAccepted()
        compose.runOnIdle {assertEquals(0,writes);assertEquals(0L,owner.state.value.document.clips.single().globalStartMs);assertFalse(owner.state.value.canUndo)}
        assertNoInfo()
        body.performTouchInput {down(start);moveBy(Offset(width*0.2f,0f));up()}
        compose.runOnIdle {assertEquals(1,writes);assertTrue(owner.state.value.canUndo)}
    }

    @Test fun emptyTimelineUnderPaintedIdentityPansWithoutEditingClip() {
        mount(startMs=20000)
        val before=viewport.value.offsetMs
        val start=identityPoint()
        body.performTouchInput {down(start);moveBy(Offset(-60f,0f));up()}
        compose.runOnIdle {assertTrue(viewport.value.offsetMs>before);assertEquals(0,writes);assertEquals(20000L,owner.state.value.document.clips.single().globalStartMs);assertEquals(0,bpmOpens)}
        assertNoInfo()
        assertAccepted()
    }

    @Test fun actionDownsDraggedOntoIdentityNeverBecomeBodyEdits() {
        mount()
        val finish=identityPoint()
        for(control in listOf(bpm,info)) {
            val start=local(bounds(control).center)
            body.performTouchInput {down(start);moveTo(finish);up()}
            compose.runOnIdle {assertEquals(0,writes);assertEquals(0,bpmOpens);assertEquals(0,selections)}
            assertNoInfo()
            assertAccepted()
        }
    }

    @Test fun explicitInfoAndBpmHaveSeparateFullTargetsAndTitleTapOnlySelects() {
        mount()
        info.assertWidthIsEqualTo(48.dp).assertHeightIsEqualTo(48.dp)
        bpm.assertWidthIsEqualTo(112.dp).assertHeightIsEqualTo(48.dp)
        val identityPaint=compose.onNode(SemanticsMatcher.keyIsDefined(SemanticsProperties.HideFromAccessibility) and hasAnyDescendant(hasText("1 · $title")),useUnmergedTree=true)
        identityPaint.assertWidthIsEqualTo(176.dp).assertHeightIsEqualTo(48.dp)
        body.assert(SemanticsMatcher.expectValue(SemanticsProperties.ContentDescription,listOf("Waveform identity","1 · $title")))
        val identity=bounds(compose.onNodeWithText("1 · $title",useUnmergedTree=true))
        val infoBounds=bounds(info)
        val bpmBounds=bounds(bpm)
        assertFalse(identity.overlaps(infoBounds));assertFalse(infoBounds.overlaps(bpmBounds))
        val density=compose.activity.resources.displayMetrics.density
        assertEquals(8*density,infoBounds.top-bounds(body).top,1f)
        assertEquals(infoBounds.top,bpmBounds.top,1f)
        body.assertHeightIsEqualTo(96.dp)
        val start=identityPoint()
        body.performTouchInput {click(start)}
        compose.runOnIdle {assertEquals(1,selections);assertEquals(0,writes);assertEquals(0,bpmOpens)}
        assertNoInfo()
        bpm.performTouchInput {click()}
        compose.runOnIdle {assertEquals(1,bpmOpens);assertEquals(0,writes)}
        info.performTouchInput {click()}
        compose.onNodeWithText("Clip 1",useUnmergedTree=true).assertIsDisplayed()
        compose.onNodeWithText("Edit clip timing").assertIsDisplayed()
        compose.runOnIdle {assertEquals(1,bpmOpens);assertEquals(0,writes)}
    }

    @Test fun selectedTrimInCanStartUnderPaintedIdentity() {
        mount(selected=true)
        val label=bounds(compose.onNodeWithText("1 · $title",useUnmergedTree=true))
        // The title backing starts at 8dp. Use its leftmost painted glyph above the trim target.
        val start=local(Offset(label.left+1f,label.center.y))
        body.performTouchInput {down(start);moveBy(Offset(width*0.15f,0f));up()}
        compose.runOnIdle {assertEquals(1,writes);assertEquals(1500L,owner.state.value.document.clips.single().sourceInMs);assertEquals(0L,owner.state.value.document.clips.single().globalStartMs)}
        assertNoInfo()
    }

    @Test fun selectedTrimOutCanStartUnderPaintedIdentityAfterViewportPan() {
        mount(selected=true)
        compose.runOnIdle {
            val v=viewport.value
            viewport.value=v.copy(pixelsPerSecond=v.widthPx/5.0,offsetMs=9750)
        }
        compose.waitForIdle()
        val label=bounds(compose.onNodeWithText("1 · $title",useUnmergedTree=true))
        val start=local(Offset(label.left+1f,label.center.y))
        body.performTouchInput {down(start);moveBy(Offset(-width*0.1f,0f));up()}
        compose.runOnIdle {assertEquals(1,writes);assertEquals(9500L,owner.state.value.document.clips.single().sourceOutMs);assertEquals(0L,owner.state.value.document.clips.single().sourceInMs)}
        assertNoInfo()
    }

    @Test fun armedScratchStartsOnPaintedIdentityCancelsAndLeavesTimingUntouched() {
        var begins=0;var finishes=0;var cancelled=false
        val rates=mutableListOf<Double>()
        mount(scratch=WaveformScratch(true,true,1.0,"Ready",{},{begins++;true},{rate,_->rates+=rate},{_,cancel->finishes++;cancelled=cancel},{1000.0}))
        val start=identityPoint()
        body.performTouchInput {down(start);advanceEventTime(10);moveBy(Offset(10f,0f));advanceEventTime(10);moveBy(Offset(-20f,0f))}
        compose.runOnIdle {assertEquals(1,begins);assertTrue(rates.any {it>0});assertTrue(rates.any {it<0})}
        body.performTouchInput {cancel()}
        compose.runOnIdle {assertEquals(1,finishes);assertTrue(cancelled);assertEquals(0,writes);assertEquals(0,bpmOpens)}
        assertNoInfo()
        // Explicit controls stay out of audio even while scratch is armed.
        bpm.performTouchInput {click()}
        info.performTouchInput {click()}
        compose.runOnIdle {assertEquals(1,begins);assertEquals(1,bpmOpens)}
    }
}
