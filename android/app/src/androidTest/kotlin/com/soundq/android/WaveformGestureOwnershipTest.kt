package com.soundq.android

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.*
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import com.soundq.android.data.TrackId
import com.soundq.android.data.timeline.*
import com.soundq.android.product.timeline.TimelineLane
import com.soundq.android.product.timeline.waveformViewportGestures
import com.soundq.designsystem.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Real production lane recognizer mounted inside its production modal host. */
class WaveformGestureOwnershipTest {
    @get:Rule val compose=createComposeRule()
    private val clip=TimelineClip("first",7,"Gesture source",120000,0,120000,0,QueueSegment.Context)
    private val viewport=mutableStateOf(TimelineViewport(120000,400f,40.0,20000))
    private var writes=0
    private val edits=mutableListOf<TimelineEdit>()
    private var dismissed=0
    private var density=1f
    private fun mount(selected:Boolean=false,busy:Boolean=false) {
        val cache=WaveformCache()
        val wave=TrackWaveform(TrackId(7),"synthetic-input-fixture",120000,listOf(PeakTier("detail",FloatArray(120){-0.3f},FloatArray(120){0.6f})))
        compose.setContent {SoundQTheme {
            SoundQWorkspaceSheet("Gesture queue",{dismissed++}) {
                density=androidx.compose.ui.platform.LocalDensity.current.density
                Column(Modifier.weight(1f).fillMaxWidth()) {
                    TimelineLane(clip,1,selected,false,wave,viewport,remember {mutableLongStateOf(0)},SnapMode.Free,busy,
                        {},{EditDecision(true)},{writes++;edits.add(it)},cache::window,{}, {}, {})
                }
                Text("Transport unchanged")
            }
        }}
    }
    @Test fun unselectedLoadedBodyPansBothDirectionsWithoutEditingOrDismissal() {
        mount()
        val lane=compose.onNodeWithContentDescription("Waveform first")
        val before=compose.runOnIdle {viewport.value}
        lane.performTouchInput {swipe(Offset(width*.6f,height*.8f),Offset(width*.25f,height*.8f),400)}
        val later=compose.runOnIdle {viewport.value}
        assertTrue("Horizontal body drag must pan later",later.offsetMs>before.offsetMs)
        lane.performTouchInput {swipe(Offset(width*.25f,height*.8f),Offset(width*.6f,height*.8f),400)}
        compose.runOnIdle {assertTrue(viewport.value.offsetMs<later.offsetMs);assertEquals(before.visibleMs,viewport.value.visibleMs);assertEquals(0,writes);assertEquals(0,dismissed)}
        compose.onNodeWithText("Gesture queue").assertIsDisplayed()
    }
    @Test fun selectedLoadedBodyStillPansWithoutEditing() {
        mount(selected=true)
        val before=compose.runOnIdle {viewport.value}
        compose.onNodeWithContentDescription("Waveform first").performTouchInput {swipe(Offset(width*.6f,height*.8f),Offset(width*.25f,height*.8f),400)}
        compose.runOnIdle {assertTrue(viewport.value.offsetMs>before.offsetMs);assertEquals(0,writes);assertEquals(0,dismissed)}
    }
    @Test fun expandedAndCollapsedArtworkAndTitleContactsPanWithoutEditingOrDismissal() {
        mount()
        val lane=compose.onNodeWithContentDescription("Waveform first")
        for(expanded in listOf(false,true)) {
            if(expanded)compose.onNodeWithContentDescription("Expand Gesture source").performClick()
            for(artwork in listOf(true,false)) {
                val before=compose.runOnIdle {viewport.value}
                val body=lane.fetchSemanticsNode().boundsInRoot
                val title=compose.onNodeWithText("Gesture source",useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
                val point=if(artwork)Offset(20*density,24*density) else title.center-body.topLeft
                lane.performTouchInput {down(point);moveBy(Offset(-60f,0f));up()}
                compose.runOnIdle {assertTrue(viewport.value.offsetMs>before.offsetMs);assertEquals(0,writes);assertEquals(0,dismissed)}
            }
        }
    }
    @Test fun expandedCardArtworkAndTitleShareRealPinchWithoutDismissal() {
        mount()
        compose.onNodeWithContentDescription("Expand Gesture source").performClick()
        val before=compose.runOnIdle {viewport.value}
        compose.onNodeWithContentDescription("Waveform first").performTouchInput {
            down(0,Offset(20*density,24*density));down(1,Offset(150*density,24*density))
            repeat(6){step->moveTo(1,Offset((160+step*8)*density,24*density),delayMillis=16)}
            up(0);up(1)
        }
        compose.runOnIdle {assertTrue(viewport.value.visibleMs<before.visibleMs);assertEquals(0,writes);assertEquals(0,dismissed)}
    }
    @Test fun deliberateHoldPlacementCancelsThenCommitsExactlyOnce() {
        mount(selected=true)
        val before=compose.runOnIdle {viewport.value}
        val lane=compose.onNodeWithContentDescription("Waveform first")
        lane.performTouchInput {down(Offset(width*.5f,height*.8f));advanceEventTime(650);moveBy(Offset(80f,0f))}
        lane.assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.StateDescription,"Loaded · Preview timing edit"))
        lane.performTouchInput {cancel()}
        compose.runOnIdle {assertEquals(0,writes);assertEquals(before,viewport.value)}
        lane.performTouchInput {down(Offset(width*.5f,height*.8f));advanceEventTime(650);moveBy(Offset(80f,0f));up()}
        compose.runOnIdle {assertEquals(1,writes);assertEquals(EditKind.Placement,edits.single().kind);assertEquals("first",edits.single().original.occurrence);assertTrue(edits.single().candidate().globalStartMs>0);assertEquals(before,viewport.value);assertEquals(0,dismissed)}
    }
    @Test fun selectedTrimEdgesRemainDirectAndCancellable() {
        mount(selected=true)
        val lane=compose.onNodeWithContentDescription("Waveform first")
        compose.runOnIdle {viewport.value=viewport.value.copy(offsetMs=0)}
        lane.performTouchInput {down(Offset(4f,height*.8f));moveBy(Offset(80f,0f));cancel()}
        compose.runOnIdle {assertEquals(0,writes)}
        lane.performTouchInput {down(Offset(4f,height*.8f));moveBy(Offset(80f,0f));up()}
        compose.runOnIdle {assertEquals(1,writes);assertEquals(EditKind.TrimIn,edits.single().kind);assertTrue(edits.single().candidate().sourceInMs>0)}
        val end=compose.runOnIdle {
            viewport.value=viewport.value.copy(offsetMs=(120000-viewport.value.visibleMs).coerceAtLeast(0))
            viewport.value.x(120000)
        }
        lane.performTouchInput {down(Offset(end-4f,height*.8f));moveBy(Offset(-80f,0f));up()}
        compose.runOnIdle {assertEquals(2,writes);assertEquals(EditKind.TrimOut,edits.last().kind);assertTrue(edits.last().candidate().sourceOutMs<120000);assertEquals(0,dismissed)}
    }
    @Test fun realTwoPointerBodyPinchChangesSpanWithoutEditingOrDismissal() {
        mount()
        val lane=compose.onNodeWithContentDescription("Waveform first")
        val before=compose.runOnIdle {viewport.value}
        lane.performTouchInput {
            down(0,Offset(width*.35f,height*.8f));down(1,Offset(width*.65f,height*.8f))
            repeat(8) {step->
                moveTo(0,Offset(width*(.35f-.02f*(step+1)),height*.8f),delayMillis=16)
                moveTo(1,Offset(width*(.65f+.02f*(step+1)),height*.8f),delayMillis=16)
            }
            up(0);up(1)
        }
        compose.runOnIdle {assertTrue("Two-pointer separation must zoom",viewport.value.visibleMs<before.visibleMs);assertEquals(0,writes);assertEquals(0,dismissed)}
        compose.onNodeWithText("Gesture queue").assertIsDisplayed()
    }
    @Test fun twoPointersOnDifferentLanesShareOneZoomOwner() {
        val cache=WaveformCache()
        val wave=TrackWaveform(TrackId(7),"synthetic-input-fixture",120000,listOf(PeakTier("detail",FloatArray(120){-0.3f},FloatArray(120){0.6f})))
        compose.setContent {SoundQTheme {SoundQWorkspaceSheet("Gesture queue",{dismissed++}) {
            Column(Modifier.weight(1f).fillMaxWidth().testTag("stack").waveformViewportGestures(viewport)) {
                listOf(clip,clip.copy(occurrence="duplicate")).forEach {laneClip->
                    TimelineLane(laneClip,1,false,false,wave,viewport,remember {mutableLongStateOf(0)},SnapMode.Free,false,
                        {},{EditDecision(true)},{writes++;edits.add(it)},cache::window,{}, {}, {})
                }
            }
        }}}
        val first=compose.onNodeWithContentDescription("Waveform first").fetchSemanticsNode().boundsInRoot
        val second=compose.onNodeWithContentDescription("Waveform duplicate").fetchSemanticsNode().boundsInRoot
        val stack=compose.onNodeWithTag("stack")
        val origin=stack.fetchSemanticsNode().boundsInRoot.topLeft
        val before=compose.runOnIdle {viewport.value}
        stack.performTouchInput {
            val y1=first.bottom-first.height*.2f-origin.y
            val y2=second.bottom-second.height*.2f-origin.y
            down(0,Offset(width*.35f,y1));down(1,Offset(width*.65f,y2))
            repeat(8){step->
                moveTo(0,Offset(width*(.35f-.02f*(step+1)),y1),delayMillis=16)
                moveTo(1,Offset(width*(.65f+.02f*(step+1)),y2),delayMillis=16)
            }
            up(0);up(1)
        }
        compose.runOnIdle {assertTrue("Pinch spanning two lanes must change the shared viewport",viewport.value.visibleMs<before.visibleMs);assertEquals(0,writes);assertEquals(0,dismissed)}
    }
    @Test fun readOnlyBodyStillAllowsViewportNavigation() {
        mount(busy=true)
        val before=compose.runOnIdle {viewport.value}
        compose.onNodeWithContentDescription("Waveform first").performTouchInput {swipe(Offset(width*.6f,height*.8f),Offset(width*.25f,height*.8f),400)}
        compose.runOnIdle {assertTrue("Edit readiness must not disable read-only pan",viewport.value.offsetMs>before.offsetMs);assertEquals(0,writes);assertEquals(0,dismissed)}
    }
    @Test fun downwardBodyAtTopCannotDismissWorkspace() {
        mount()
        compose.onNodeWithContentDescription("Waveform first").performTouchInput {swipe(Offset(width*.5f,height*.8f),Offset(width*.5f,height*.8f+600f),500)}
        compose.onNodeWithText("Gesture queue").assertIsDisplayed()
        compose.runOnIdle {assertEquals(0,writes);assertEquals(0,dismissed)}
    }
}
