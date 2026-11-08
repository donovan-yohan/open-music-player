package com.soundq.android

import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import com.soundq.android.data.*
import com.soundq.android.data.trackdetails.*
import com.soundq.android.product.trackdetails.*
import com.soundq.designsystem.SoundQTheme
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Mounted production controls. Compiled into the instrumentation APK; no runtime claim. */
class AnalysisTempoControlsTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private fun analysis(revision:Long=3)=AnalysisDetail(revision,"analyzed",buildJsonObject {putJsonObject("bpm"){put("value",123.5)}},buildJsonObject{},buildJsonObject{})
    private fun tempo()=compose.onNodeWithContentDescription("Tempo BPM (30–300)")
    private fun click(label:String)=compose.onNodeWithText(label).performScrollTo().performClick()

    @Test fun tapsAndScalingEditLocallyUntilExplicitSaveAndRespectDisabledState() {
        val enabled=mutableStateOf(true)
        val saves=mutableListOf<AnalysisCorrection>()
        var clock=1000L
        compose.activityRule.scenario.onActivity {activity->activity.setContent {SoundQTheme {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                AnalysisCorrectionControls(analysis(),enabled.value,{clock}) {saves.add(it)}
            }
        }}}
        click("Correct analysis")
        click("Tap tempo")
        compose.runOnIdle {clock=1500L}
        click("Tap tempo")
        tempo().assertTextContains("120.0")
        click("Half BPM");tempo().assertTextContains("60.0")
        click("Double BPM");tempo().assertTextContains("120.0")
        compose.runOnIdle {assertTrue(saves.isEmpty());enabled.value=false}
        compose.onNodeWithText("Tap tempo").assertIsNotEnabled()
        compose.onNodeWithText("Half BPM").assertIsNotEnabled()
        compose.onNodeWithText("Double BPM").assertIsNotEnabled()
        compose.onNodeWithText("Save analysis correction").assertIsNotEnabled()
        compose.runOnIdle {enabled.value=true}
        click("Save analysis correction")
        compose.runOnIdle {assertEquals(listOf(AnalysisCorrection(bpm=120.0)),saves)}
        tempo().performScrollTo().performTextReplacement("200")
        click("Double BPM")
        compose.onNodeWithText("Result must be 30–300 BPM. The tempo draft is unchanged.").assertExists()
        tempo().assertTextContains("200")
        click("Save analysis correction")
        compose.runOnIdle {assertEquals(1,saves.size)}
        tempo().performScrollTo().performTextReplacement("125.25")
        click("Save analysis correction")
        compose.runOnIdle {assertEquals(125.25,saves.last().bpm!!,0.0)}
    }

    @Test fun sameTrackRevisionAndConflictReloadPreserveDirtyFieldsButDifferentTrackStartsEmpty() {
        val initial=TrackDetailsState(detail=TrackDetails(Track(TrackId(7),"First"),false,false),analysis=analysis())
        val state=mutableStateOf(initial)
        val saves=mutableListOf<DetailsAction.Analysis>()
        compose.activityRule.scenario.onActivity {activity->activity.setContent {SoundQTheme {
            TrackDetailsSheet(state.value,{_,action->if(action is DetailsAction.Analysis)saves.add(action)},{},{})
        }}}
        click("Correct analysis")
        tempo().performScrollTo().performTextReplacement("125.25")
        compose.runOnIdle {state.value=initial.copy(analysis=analysis(4),outcome=MutationOutcome.Refused)}
        tempo().assertTextContains("125.25")
        compose.runOnIdle {state.value=state.value.copy(analysis=analysis(5),outcome=MutationOutcome.Uncertain,reconciled=true)}
        tempo().assertTextContains("125.25")
        click("Save analysis correction")
        compose.runOnIdle {
            assertEquals(5,saves.single().observed.revision)
            assertEquals(125.25,saves.single().correction.bpm!!,0.0)
            state.value=initial.copy(detail=TrackDetails(Track(TrackId(8),"Second"),false,false))
        }
        click("Correct analysis")
        tempo().assert(hasText(""))
        compose.onNodeWithText("Tap at least twice to measure tempo.").assertExists()
    }
}
