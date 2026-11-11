package com.soundq.android

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import com.soundq.android.data.TrackId
import com.soundq.android.data.timeline.*
import com.soundq.android.product.timeline.TimelineLane
import com.soundq.android.product.timeline.TimelineGuides
import com.soundq.designsystem.SoundQ
import com.soundq.designsystem.SoundQTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Compact real lane composition, independent of network/account/transport. */
class CompactWaveformStackJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<ComponentActivity>()
    @Test fun trackIdentityOverlaysCompactTouchingWaveformBodies() {
        val clips=listOf(
            TimelineClip("a",1,"First track",10000,0,10000,0,QueueSegment.Context),
            TimelineClip("b",2,"Second track",10000,0,10000,0,QueueSegment.Context))
        val cache=WaveformCache()
        val viewport=mutableStateOf(TimelineViewport(10000,360f,36.0))
        var playheadInk=0
        compose.setContent {SoundQTheme {
            val progress=remember {mutableLongStateOf(1000)}
            playheadInk=SoundQ.colors.playhead.toArgb()
            Box(Modifier.width(360.dp).height(192.dp)) {
            Column(Modifier.width(360.dp)) {
                clips.forEachIndexed {index,clip->
                    val wave=remember {TrackWaveform(TrackId(clip.track),"component",10000,listOf(PeakTier("detail",FloatArray(100){-0.3f},FloatArray(100){0.6f})))}
                    TimelineLane(clip,1,false,false,wave,viewport,progress,SnapMode.Free,false,
                        {},{EditDecision(true)},{},cache::window,{}, {}, {},laneNumber=index+1)
                }
            }
            TimelineGuides(viewport,progress,remember {mutableStateOf(null)},TimelineDocument(1,clips),false,Modifier.matchParentSize())
            }
        }}
        val first=compose.onNodeWithContentDescription("Waveform a").fetchSemanticsNode().boundsInRoot
        val second=compose.onNodeWithContentDescription("Waveform b").fetchSemanticsNode().boundsInRoot
        val identity=compose.onNodeWithText("1 · First track",substring=true,useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
        val density=compose.activity.resources.displayMetrics.density
        assertTrue("Identity belongs over the waveform, not in a separate strip",identity.top>=first.top&&identity.bottom<=first.bottom)
        assertEquals("Waveform bodies must touch without inter-row headers",first.bottom,second.top,1f)
        assertEquals("Default complete lane stays at 96dp",96*density,first.height,1f)
        compose.onNodeWithContentDescription("More for First track").assertHasClickAction()
        // The foreground guide must remain visible through identity backing and
        // the shared lane edge. This is attached native View paint, not PixelCopy.
        val guide=compose.onNodeWithContentDescription("Shared timeline playhead").fetchSemanticsNode()
        val bounds=guide.boundsInRoot
        val view=(guide.root as ViewRootForTest).view
        compose.runOnIdle {
            val bitmap=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
            try {
                view.draw(Canvas(bitmap))
                // TimelineViewport coordinates are already physical pixels, not dp.
                val x=(bounds.left+viewport.value.x(1000)).toInt()
                listOf(first.top+16*density,first.bottom-1,second.top+1,second.top+16*density,second.bottom-2).forEach {y ->
                    assertTrue("Shared guide must paint above row identity and across row boundaries",
                        (x-1..x+1).any {px->bitmap.getPixel(px,y.toInt())==playheadInk})
                }
            } finally {bitmap.recycle()}
        }
    }
}
