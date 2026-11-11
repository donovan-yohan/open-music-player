package com.soundq.designsystem

import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.*
import androidx.compose.ui.semantics.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[34])
class SharedSeekRepairTest {
    @get:Rule val compose=createComposeRule()

    @Test fun unknownDurationRetainsRealElapsedAndDoesNotClaimZeroTotalOrProgress() {
        val duration=mutableLongStateOf(0L);val position=mutableLongStateOf(65000L)
        val seeks=mutableListOf<Long>()
        compose.setContent {SoundQTheme {Column {SoundQSeek(position.longValue,duration.longValue,"same",{seeks.add(it)})}}}
        compose.onNodeWithText("1:05 / —").assertIsDisplayed()
        val slider=compose.onNodeWithContentDescription("Playback position")
        slider.assertIsNotEnabled().assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription,"Duration unavailable"))
        slider.assert(SemanticsMatcher.expectValue(SemanticsProperties.ProgressBarRangeInfo,ProgressBarRangeInfo.Indeterminate))
        slider.performTouchInput {click()}
        compose.runOnIdle {assertTrue(seeks.isEmpty());duration.longValue=-1;position.longValue=66000}
        compose.onNodeWithText("1:06 / —").assertIsDisplayed()
        compose.runOnIdle {duration.longValue=120000}
        slider.assertIsEnabled().performSemanticsAction(SemanticsActions.SetProgress) {it(0.5f)}
        compose.runOnIdle {assertEquals(listOf(60000L),seeks)}
    }

    @Test fun losingDurationDuringHeldSeekRetiresDraftWithoutCommittingAZeroSeek() {
        val duration=mutableLongStateOf(100000L);val seeks=mutableListOf<Long>()
        compose.setContent {SoundQTheme {Column {SoundQSeek(12000,duration.longValue,"same",{seeks.add(it)})}}}
        val slider=compose.onNodeWithContentDescription("Playback position")
        slider.performTouchInput {down(center);moveTo(androidx.compose.ui.geometry.Offset(width*0.75f,center.y))}
        compose.runOnIdle {duration.longValue=0}
        slider.performTouchInput {up()}
        compose.onNodeWithText("0:12 / —").assertIsDisplayed()
        compose.runOnIdle {assertTrue(seeks.isEmpty());duration.longValue=100000}
        compose.onNodeWithText("0:12 / 1:40").assertIsDisplayed()
    }
}
