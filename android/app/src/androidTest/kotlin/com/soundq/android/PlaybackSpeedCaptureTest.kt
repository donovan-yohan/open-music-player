package com.soundq.android

import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import com.soundq.designsystem.*
import soundq.design.generated.SoundQAppearance
import org.junit.Rule
import org.junit.Test

/** System screenshots of the shipped full-player host + speed panel (real designsystem
 * composition, fixture copy). Behaviour/audio acceptance lives in PlaybackSpeedJourneyTest. */
class PlaybackSpeedCaptureTest {
    @get:Rule val compose=createComposeRule()

    private data class Frame(val name:String,val dark:Boolean,val accepted:Double,val expanded:Boolean,
        val state:SoundQSpeedPanelState=SoundQSpeedPanelState.Ready,val requested:Double?=null,val rejected:Double?=null,val reason:String?=null)

    @Test fun captureSpeedControlStates() {
        val frames=listOf(
            Frame("speed-light-closed",false,1.5,false),
            Frame("speed-light-accepted",false,1.5,true),
            Frame("speed-dark-accepted",true,1.25,true),
            Frame("speed-dark-pending",true,1.0,true,SoundQSpeedPanelState.Pending,requested=1.35),
            Frame("speed-light-rejected",false,1.0,true,SoundQSpeedPanelState.Rejected,rejected=1.5),
            Frame("speed-dark-unavailable",true,1.0,true,SoundQSpeedPanelState.Unavailable,reason="Speed is set by the Mix while it plays."),
        )
        val current=mutableStateOf(frames.first())
        compose.setContent {
            val f=current.value
            SoundQTheme(appearance=if(f.dark)SoundQAppearance.Dark else SoundQAppearance.Light) {
                key(f.name) {
                    SoundQFullPlayer("Ep. 212 — The quiet art of mastering","Signal Path (local file)",true,true,false,
                        892_000,2_890_000,"capture",{},{},{},{},canPrevious=true,canNext=true,onShuffle={},onRepeat={},onDevices={},onInfo={},
                        speedCell=SoundQSpeedCell(f.accepted,f.state!=SoundQSpeedPanelState.Unavailable,f.expanded) {},
                        speedContent={SoundQPlaybackSpeedPanel(f.accepted,f.requested,0.5,2.0,f.state,f.reason,{},{},rejected=f.rejected)})
                }
            }
        }
        for(frame in frames) {
            compose.runOnIdle {current.value=frame}
            compose.onNodeWithTag("player-speed-cell").assertExists()
            if(frame.expanded)compose.onNodeWithTag("player-speed-panel").assertIsDisplayed()
            compose.waitForIdle()
            captureListeningStage(frame.name)
        }
    }
}
