package com.soundq.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import com.soundq.android.data.TrackId
import com.soundq.android.data.timeline.*
import com.soundq.android.product.chronologicalTimeline
import com.soundq.android.product.TimelineDocumentIdentity
import com.soundq.android.product.timeline.TimelineLane
import com.soundq.designsystem.SoundQTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Real lazy relocation + production lane recognizer. Compiled here; device execution is separately leased. */
class ChronologicalTimelineJourneyTest {
    @get:Rule val compose=createComposeRule()
    @Test fun repeatedCrossingsKeepOriginalPointerAndCancelBeforeOneUndoableCommit() {
        var writes=0
        val owner=TimelineOwner({null},{writes++})
        owner.observe(listOf(TimelineSource("a",1,"A",20000,QueueSegment.Manual),TimelineSource("b",7,"Duplicate",20000,QueueSegment.Manual),TimelineSource("c",7,"Duplicate",20000,QueueSegment.Manual)))
        val document=mutableStateOf(owner.state.value.document)
        val original=document.value;val b=original.clips[1]
        var candidate by mutableStateOf<TimelineDocument?>(null)
        val viewport=mutableStateOf(TimelineViewport(70000,360f,6.0,0))
        val cache=WaveformCache()
        compose.setContent {SoundQTheme {
            val d=document.value;val projection=chronologicalTimeline(d,candidate)
            LazyColumn(Modifier.width(360.dp).height(375.dp).testTag("chronological-stack")) {
                items(projection.clips,key={it.occurrence}) {shown->
                    val clip=d.clips.single {it.occurrence==shown.occurrence}
                    val wave=remember(clip.track){TrackWaveform(TrackId(clip.track),"declared-component-fixture",20000,listOf(PeakTier("detail",FloatArray(32){-.3f},FloatArray(32){.6f})))}
                    TimelineLane(clip,d.revision,false,false,wave,viewport,remember {mutableLongStateOf(0)},SnapMode.Free,false,
                        {},owner::preview,{assertSame(b,it.original);assertTrue(owner.commit(it));document.value=owner.state.value.document},cache::window,{}, {}, {},
                        phaseDocument=projection.shown,phaseIsPreview=candidate!=null,
                        onPhasePreview={edit->candidate=edit?.let {d.edited(it)}} ,captureKey=TimelineDocumentIdentity(d),
                        modifier=Modifier.animateItem())
                }
            }
        }}
        compose.runOnIdle {viewport.value=viewport.value.copy(pixelsPerSecond=viewport.value.widthPx/60.0)}
        val stack=compose.onNodeWithTag("chronological-stack")
        val body=compose.onNodeWithContentDescription("Waveform b")
        val stackBounds=stack.fetchSemanticsNode().boundsInRoot
        val bounds=body.fetchSemanticsNode().boundsInRoot
        val y=bounds.top-stackBounds.top+bounds.height*.2f
        val width=stackBounds.width
        val start=Offset(width*25f/60f,y)
        compose.mainClock.autoAdvance=false
        stack.performTouchInput {down(start);advanceEventTime(650);moveTo(Offset(width*55f/60f,y))}
        repeat(20){compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
        compose.runOnIdle {assertEquals(listOf("a","c","b"),chronologicalTimeline(original,candidate).clips.map {it.occurrence});assertSame(original,document.value);assertEquals(0,writes)}
        stack.performTouchInput {moveTo(Offset(width*15f/60f,y))}
        repeat(20){compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
        compose.runOnIdle {assertEquals(listOf("a","b","c"),chronologicalTimeline(original,candidate).clips.map {it.occurrence})}
        stack.performTouchInput {moveTo(Offset(width*55f/60f,y))}
        repeat(20){compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
        stack.performTouchInput {cancel()}
        compose.mainClock.advanceTimeBy(500);compose.waitForIdle()
        compose.runOnIdle {assertNull(candidate);assertSame(original,document.value);assertEquals(0,writes);assertFalse(owner.state.value.canUndo)}
        stack.performTouchInput {down(start);advanceEventTime(650);moveTo(Offset(width*55f/60f,y));up()}
        compose.mainClock.advanceTimeBy(500);compose.mainClock.autoAdvance=true;compose.waitForIdle()
        compose.runOnIdle {
            assertEquals(1,writes);assertTrue(owner.state.value.canUndo)
            assertEquals(listOf("a","b","c"),document.value.clips.map {it.occurrence})
            assertEquals(listOf("a","c","b"),chronologicalTimeline(document.value).clips.map {it.occurrence})
            assertEquals(50000L,document.value.clips[1].globalStartMs)
            assertTrue(owner.undo());assertEquals(original.clips,owner.state.value.document.clips)
        }
    }
}
