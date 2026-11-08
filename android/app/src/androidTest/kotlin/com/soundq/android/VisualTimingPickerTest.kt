package com.soundq.android

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.platform.ViewRootForTest
import com.soundq.android.data.TrackId
import com.soundq.android.data.timeline.*
import com.soundq.android.product.timeline.*
import com.soundq.designsystem.SoundQTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Mounted production timing controls; synthetic admitted peaks, no playback or analyzer accuracy claim. */
class VisualTimingPickerTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private val clip=TimelineClip("visual-occurrence",7,"Visual timing",10000,1000,9000,0,QueueSegment.Context)
    private fun wave(key:String="source")=TrackWaveform(TrackId(7),key,10000,
        listOf(PeakTier("fixture",FloatArray(100){-.2f-(it%8)*.07f},FloatArray(100){.3f+(it%7)*.07f})),
        beats=(0..10000 step 500).map(Int::toLong),downbeats=(0..10000 step 2000).map(Int::toLong),suggestedBpm=120.0)

    @Test fun visualBeatAndGroupPicksRemainIndependentWithoutTimestampFields() {
        val source=wave()
        val selected=mutableStateOf<SourceTimingPick?>(null)
        compose.activity.setContentForTiming {
            SourceTimingPicker("Reference",clip,source,selected.value,true,lifetime=1){selected.value=it}
        }
        compose.onAllNodes(hasSetTextAction()).assertCountEquals(1)
        compose.onNodeWithText("Source BPM").performTextInput("120")
        compose.runOnIdle {assertNull(selected.value?.phaseGrid(clip,source))}
        val anchor=compose.onNodeWithContentDescription("Choose beat anchor")
        anchor.performTouchInput {click(Offset(width*.2f,height*.5f))}
        compose.runOnIdle {assertEquals(2000L,selected.value?.anchorMs);assertNull(selected.value?.groupOriginMs)}
        compose.onNodeWithText("Group origin").performClick()
        compose.onNodeWithContentDescription("Choose group origin").performTouchInput {click(Offset(width*.4f,height*.5f))}
        compose.runOnIdle {
            assertEquals(2000L,selected.value?.anchorMs)
            assertEquals(4000L,selected.value?.groupOriginMs)
            assertEquals(500L,selected.value?.phaseGrid(clip,source)?.periodMs)
        }
        compose.onNodeWithText("Leave group origin unknown").performClick()
        compose.runOnIdle {assertNull(selected.value?.groupOriginMs);assertEquals(2000L,selected.value?.anchorMs)}
        capture("visual-source-picker",compose.onNodeWithContentDescription("Choose group origin"))
    }

    @Test fun cancelledAndSourceReplacedContactsCannotPublishAnOldPick() {
        val source=mutableStateOf(wave())
        val picks=mutableListOf<Long>()
        compose.activity.setContentForTiming {SourceMarkerPicker("Choose beat",clip,source.value,null,true,lifetime=1){picks.add(it)}}
        val picker=compose.onNodeWithContentDescription("Choose beat")
        picker.performTouchInput {down(Offset(width*.2f,height*.5f));moveBy(Offset(width*.1f,0f));cancel()}
        compose.runOnIdle {assertTrue(picks.isEmpty())}
        picker.performTouchInput {down(Offset(width*.2f,height*.5f));moveBy(Offset(width*.1f,0f))}
        compose.runOnIdle {source.value=wave("replacement")}
        picker.performTouchInput {up()}
        compose.runOnIdle {assertTrue(picks.isEmpty())}
        picker.performTouchInput {click(Offset(width*.5f,height*.5f))}
        compose.runOnIdle {assertEquals(listOf(5000L),picks)}
    }

    @Test fun visualPlacementUsesARealContactAndRetiresCancelledPreview() {
        val placement=mutableStateOf(0L)
        val commits=mutableListOf<Long>()
        compose.activity.setContentForTiming {
            TimelinePlacementPicker(clip,wave(),placement.value,true,lifetime=1){placement.value=it;commits.add(it)}
        }
        val picker=compose.onNodeWithContentDescription("Clip placement waveform")
        picker.performTouchInput {down(Offset(width*.1f,height*.5f));moveBy(Offset(width*.2f,0f));cancel()}
        compose.runOnIdle {assertEquals(0L,placement.value);assertTrue(commits.isEmpty())}
        picker.performTouchInput {swipe(Offset(width*.1f,height*.5f),Offset(width*.3f,height*.5f),400)}
        compose.runOnIdle {assertEquals(1,commits.size);assertTrue(placement.value>0)}
        compose.onAllNodes(hasSetTextAction()).assertCountEquals(0)
    }

    private fun MainActivity.setContentForTiming(content:@androidx.compose.runtime.Composable ()->Unit) {
        compose.runOnUiThread {setContent {SoundQTheme {Surface(Modifier.fillMaxSize()){Column {content()}}}}}
    }
    private fun capture(name:String,node:SemanticsNodeInteraction) {
        val root=node.fetchSemanticsNode().root as ViewRootForTest
        compose.runOnIdle {
            assertTrue(compose.activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE==0)
            val view=root.view
            val image=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
            try {view.draw(Canvas(image));File(compose.activity.filesDir,"$name.png").outputStream().use {assertTrue(image.compress(Bitmap.CompressFormat.PNG,100,it))}}
            finally {image.recycle()}
        }
    }
}
