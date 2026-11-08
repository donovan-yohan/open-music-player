package com.soundq.android

import androidx.activity.compose.setContent
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import com.soundq.android.data.*
import com.soundq.android.data.trackdetails.*
import com.soundq.android.product.trackdetails.TrackDetailsSheet
import com.soundq.designsystem.SoundQTheme
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Mounted ordinary production sheet. Compiled only. Device/IME acceptance belongs to parent. */
class W7DetailsPresentationTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private fun click(label:String)=compose.onNodeWithText(label).performScrollTo().performClick()
    private fun analysis(revision:Long=3)=AnalysisDetail(revision,"analyzed",buildJsonObject {putJsonObject("bpm"){put("value",124)}},buildJsonObject{},buildJsonObject{})
    @Test fun metadataKeepsDraftAcrossAbsentAndUncertainReloadThenDiscardsToRequestedDestination() {
        val detail=TrackDetails(Track(TrackId(7),"First","Artist","Album"),true,false,"flac")
        val initial=TrackDetailsState(detail=detail,analysis=analysis())
        val state=mutableStateOf(initial);val actions=mutableListOf<DetailsAction>();var closed=0;var reads=0
        compose.activityRule.scenario.onActivity {it.setContent {SoundQTheme {TrackDetailsSheet(state.value,{_,action->actions.add(action)},{reads++},{closed++})}}}
        click("Edit metadata")
        compose.onNodeWithContentDescription("Title").performTextReplacement("Personal")
        compose.onNodeWithContentDescription("Title").performTextInputSelection(androidx.compose.ui.text.TextRange(2,5))
        compose.runOnIdle {state.value=initial.copy(detail=null,error=SafeFailure.Reason.Network)}
        compose.onNodeWithContentDescription("Title").assertTextContains("Personal")
        compose.runOnIdle {state.value=initial.copy(detail=detail.copy(),outcome=MutationOutcome.Uncertain,reconciled=true)}
        compose.onNodeWithContentDescription("Title").assertTextContains("Personal")
        click("Reload song details")
        compose.runOnIdle {assertEquals(1,reads);assertTrue(actions.isEmpty())}
        compose.onNodeWithContentDescription("Close Edit metadata").performScrollTo().performClick()
        compose.onNodeWithText("Keep editing").performClick()
        compose.onNodeWithContentDescription("Title").assertTextContains("Personal")
        compose.onNodeWithContentDescription("Back to Song details").performScrollTo().performClick()
        compose.onNodeWithText("Discard").performClick()
        compose.onNodeWithText("Source quality").assertExists()
        compose.runOnIdle {assertEquals(0,closed);assertTrue(actions.isEmpty())}
        click("Edit metadata")
        compose.onNodeWithContentDescription("Title").assertTextContains("First")
        compose.onNodeWithContentDescription("Title").performTextReplacement("Discard close")
        compose.onNodeWithContentDescription("Close Edit metadata").performScrollTo().performClick()
        compose.onNodeWithText("Discard").performClick()
        compose.runOnIdle {assertEquals(1,closed);assertTrue(actions.isEmpty())}
    }
    @Test fun correctionDisclosureResetCancelAndSingleSaveUseLatestAcceptedRevision() {
        val detail=TrackDetails(Track(TrackId(7),"First"),false,false)
        val state=mutableStateOf(TrackDetailsState(detail=detail,analysis=analysis()))
        val actions=mutableListOf<DetailsAction>()
        compose.activityRule.scenario.onActivity {it.setContent {SoundQTheme {TrackDetailsSheet(state.value,{_,action->actions.add(action)},{},{})}}}
        click("Correct analysis")
        compose.onNodeWithContentDescription("Beat anchor (source ms)").assertDoesNotExist()
        click("Timing & phrasing")
        compose.onNodeWithContentDescription("Beat anchor (source ms)").performTextReplacement("17")
        compose.onNodeWithContentDescription("Tempo BPM (30–300)").performScrollTo().performTextReplacement("125")
        click("Reset analysis corrections")
        compose.onNodeWithText("Cancel reset").performClick()
        compose.runOnIdle {assertTrue(actions.isEmpty());state.value=state.value.copy(analysis=null,analysisAbsent=true)}
        compose.onNodeWithContentDescription("Tempo BPM (30–300)").assertTextContains("125")
        compose.onNodeWithText("Save analysis correction").assertIsNotEnabled()
        compose.runOnIdle {state.value=state.value.copy(analysis=analysis(5),analysisAbsent=false,outcome=MutationOutcome.Refused)}
        compose.onNodeWithContentDescription("Tempo BPM (30–300)").assertTextContains("125")
        click("Save analysis correction")
        compose.onNodeWithText("Save analysis correction").assertIsNotEnabled()
        compose.runOnIdle {
            val action=actions.single() as DetailsAction.Analysis
            assertEquals(5,action.observed.revision);assertEquals(AnalysisCorrection(bpm=125.0,anchorMs=17),action.correction)
        }
    }
}
