package com.soundq.android

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import com.soundq.android.data.TrackId
import com.soundq.android.data.timeline.*
import com.soundq.android.product.timeline.TimelineLane
import com.soundq.designsystem.SoundQTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Compiled native gesture journey. Execution requires separate admitted device runtime. */
class TimelineGestureJourneyTest {
    @get:Rule val compose=createComposeRule()
    @Test fun admittedHorizontalPreviewCancelsThenCommitsOneDurableOccurrenceEdit() {
        var writes=0
        val owner=TimelineOwner({null},{writes++})
        owner.observe(listOf(TimelineSource("W1",7,"Fixture waveform",10000,QueueSegment.Context)))
        val document=mutableStateOf(owner.state.value.document)
        val cache=WaveformCache()
        val viewport=mutableStateOf(TimelineViewport(30000,400f,40.0,0))
        val wave=TrackWaveform(TrackId(7),"synthetic-analysis-test-only",10000,listOf(PeakTier("detail",FloatArray(32){-0.3f},FloatArray(32){0.6f})))
        compose.setContent {
            SoundQTheme {

                val progress=remember {mutableLongStateOf(0)}
                val clip=document.value.clips.single()
                Column(Modifier.width(400.dp)) {
                    TimelineLane(clip,document.value.revision,false,true,wave,viewport,progress,SnapMode.Free,false,{},owner::preview,
                        {assertTrue(owner.commit(it));document.value=owner.state.value.document},cache::window,{}, {}, {})
                }
            }
        }
        val lane=compose.onNodeWithContentDescription("Waveform W1")
        val sourceMiddle=compose.runOnIdle {viewport.value.x(5000)}
        lane.performTouchInput {down(Offset(sourceMiddle,height*0.8f));moveBy(Offset(60f,0f))}
        compose.waitForIdle()
        lane.assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.StateDescription,"Loaded · Preview timing edit"))
        compose.runOnIdle {assertEquals(0,writes);assertEquals(0L,owner.state.value.document.clips.single().globalStartMs)}
        lane.performTouchInput {cancel()}
        compose.runOnIdle {assertEquals(0,writes)}
        lane.performTouchInput {down(Offset(sourceMiddle,height*0.8f));moveBy(Offset(80f,0f));up()}
        compose.waitForIdle()
        compose.runOnIdle {assertEquals(1,writes);assertTrue(owner.state.value.document.clips.single().globalStartMs>0);assertTrue(owner.state.value.canUndo)}
    }
}
