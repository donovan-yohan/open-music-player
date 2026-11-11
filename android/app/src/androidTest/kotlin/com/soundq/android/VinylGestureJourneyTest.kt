package com.soundq.android

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
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

/** Actual lane gesture arbitration. Audio/sample acceptance is a separate integrated journey. */
class VinylGestureJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<ComponentActivity>()
    @Test fun armedBodyKeepsFractionalSignedMovesOutOfDraftAndOverlaysOutOfAudio() {
        val clip=TimelineClip("vinyl",1,"Vinyl fixture",10000,0,10000,0,QueueSegment.Context)
        val cache=WaveformCache()
        val viewport=mutableStateOf(TimelineViewport(10000,400f,1000.0))
        val rates=mutableListOf<Double>()
        var begins=0;var finishes=0;var commits=0;var selections=0;var cancelled=false
        compose.setContent {SoundQTheme {
            Column(Modifier.width(400.dp)) {
                val wave=remember {TrackWaveform(TrackId(1),"gesture-fixture",10000,listOf(PeakTier("detail",FloatArray(100){-0.3f},FloatArray(100){0.6f})))}
                TimelineLane(clip,1,false,false,wave,viewport,remember {mutableLongStateOf(1000)},SnapMode.Free,false,
                    {selections++},{EditDecision(true)},{commits++},cache::window,{}, {}, {},
                    scratch=WaveformScratch(true,true,1.0,"Ready",{}, {begins++;true},{rate,_->rates.add(rate)},{_,cancel->finishes++;cancelled=cancel},{1000.0}))
            }
        }}
        val body=compose.onNodeWithContentDescription("Waveform vinyl")
        body.performTouchInput {down(Offset(width*0.4f,height*0.8f));advanceEventTime(10);moveBy(Offset(0.5f,0f));advanceEventTime(10);moveBy(Offset(-1f,0f));up()}
        compose.runOnIdle {
            assertEquals(1,begins);assertEquals(1,finishes);assertEquals(0,commits)
            assertTrue(rates.any {it>0});assertTrue(rates.any {it<0});assertFalse(cancelled)
        }
        compose.onNodeWithContentDescription("More for Vinyl fixture").performTouchInput {click()}
        compose.runOnIdle {assertEquals(1,begins);assertTrue(selections>0);assertEquals(0,commits)}
    }
}
