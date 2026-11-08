package com.soundq.android

import androidx.activity.compose.setContent
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import com.soundq.android.data.*
import com.soundq.android.data.trackdetails.*
import com.soundq.android.product.trackdetails.TrackDetailsSheet
import com.soundq.designsystem.SoundQTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Real production presentation. Device execution is reserved for the integration owner. */
class TrackDetailsFactsJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private fun click(label:String)=compose.onNodeWithText(label).performScrollTo().performClick()
    @Test fun fullFactsAndSameNamedRecordingsStayDistinctThroughExplicitConfirmation() {
        val first=MatchSuggestion(RecordingMbid("12345678-1234-1234-1234-123456789abc"),"Same song","Same artist",album="Studio edition",durationMs=185000)
        val second=MatchSuggestion(RecordingMbid("12345678-1234-1234-1234-123456789def"),"Same song","Same artist",album="Live edition",durationMs=245000)
        val detail=TrackDetails(Track(TrackId(7),"Full song title","Same artist","My album",185000),true,false,"flac · 48000 Hz",suggestions=listOf(first,second),sourceUrl="https://www.youtube.com/watch?v=exact-source")
        val actions=mutableListOf<DetailsAction>()
        compose.activityRule.scenario.onActivity {it.setContent {SoundQTheme {TrackDetailsSheet(TrackDetailsState(detail=detail),{observed,action->assertSame(detail,observed);actions.add(action)},{},{})}}}
        compose.onNodeWithText("Duration").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("3:05").assertExists()
        compose.onNodeWithText("Year").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText(detail.sourceUrl!!).performScrollTo().assertIsDisplayed()
        click("Verification & matching")
        compose.onNodeWithText("Studio edition").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Live edition").performScrollTo().assertIsDisplayed()
        compose.onNodeWithContentDescription("Verify Same song, recording ${second.recording.value}").performScrollTo().performClick()
        compose.runOnIdle {assertTrue(actions.isEmpty())}
        compose.onNodeWithText("Confirm matching change").performClick()
        compose.runOnIdle {assertEquals(DetailsAction.Verification(VerificationAction.Confirm(second)),actions.single())}
    }
}
