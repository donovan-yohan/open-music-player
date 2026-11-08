package com.soundq.android

import androidx.activity.ComponentActivity
import androidx.compose.runtime.*
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import com.soundq.android.playback.*
import com.soundq.android.product.FullPlayerClock
import com.soundq.designsystem.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Compiled native consuming contract. Run only on the integration owner's fixture device. */
class PlayerClockJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<ComponentActivity>()
    @Test fun seekReceiptSurvivesItsOwnRevisionButModeChangeCannotReplay() {
        val authority=PlaybackClockAuthority(ClockOwner("service",1,"queue",2,"b"),listOf(ClockSpan("b",20000)))
        val state=mutableStateOf(PlaybackProjection(connection=PlaybackProjection.Connection.Connected,selectedOccurrence="b",positionMs=5000,durationMs=20000,accountEpoch=1,arrangementService="service",sourceQueueIncarnation="queue",clockAuthority=authority))
        var completion:((Boolean)->Unit)?=null
        var commands=0
        compose.setContent {SoundQTheme {androidx.compose.foundation.layout.Column {FullPlayerClock(state.value) {_,_,_,valid,done->assertTrue(valid());commands++;completion=done}}}}
        compose.onNodeWithTag("player-clock-progress").performSemanticsAction(SemanticsActions.SetProgress){it(.5f)}
        compose.onNodeWithText("Seeking").assertIsDisplayed()
        compose.runOnIdle {state.value=state.value.copy(clockAuthority=authority.copy(owner=authority.owner.copy(revision=3)))}
        compose.onNodeWithText("Seeking").assertIsDisplayed()
        compose.runOnIdle {completion!!(false)}
        compose.onNodeWithText("Seek not confirmed. Try again.").assertIsDisplayed()
        compose.onNodeWithContentDescription("Whole queue clock").performClick()
        compose.onNodeWithContentDescription("Current song clock").performClick()
        compose.runOnIdle {assertEquals(1,commands)}
    }
    @Test fun expectedDestinationStaysSeekingUntilFailedReceipt()=destinationReceipt(false)
    @Test fun expectedDestinationStaysSeekingUntilSuccessfulReceipt()=destinationReceipt(true)
    private fun destinationReceipt(ok:Boolean) {
        val authority=PlaybackClockAuthority(ClockOwner("service",1,"queue",2,"b"),listOf(ClockSpan("a1",10000),ClockSpan("b",20000),ClockSpan("a2",10000)))
        val state=mutableStateOf(PlaybackProjection(connection=PlaybackProjection.Connection.Connected,selectedOccurrence="b",selectionIncarnation=10,positionMs=5000,durationMs=20000,accountEpoch=1,arrangementService="service",sourceQueueIncarnation="queue",clockAuthority=authority))
        var completion:((Boolean)->Unit)?=null
        var validity:(()->Boolean)?=null
        var requests=0
        compose.setContent {SoundQTheme {androidx.compose.foundation.layout.Column {
            FullPlayerClock(state.value) {p,m,pos,valid,done->
                assertTrue(valid());assertEquals(ClockDestination("a2",2500),projectPlayerClock(p,m).destination(pos))
                requests++;completion=done;validity=valid
            }
        }}}
        compose.onNodeWithContentDescription("Whole queue clock").performClick()
        compose.onNodeWithTag("player-clock-progress").performSemanticsAction(SemanticsActions.SetProgress){it(.8125f)}
        compose.onNodeWithText("Seeking").assertIsDisplayed()
        compose.runOnIdle {
            // onMediaItemTransition and publish can both retire the old controller selection.
            state.value=state.value.copy(selectedOccurrence="a2",selectionIncarnation=12,durationMs=10000,positionMs=2500,
                clockAuthority=authority.copy(owner=authority.owner.copy(selected="a2",revision=3)))
        }
        compose.onNodeWithText("Seeking").assertIsDisplayed()
        compose.onNodeWithTag("player-clock-progress").assertIsNotEnabled()
        compose.runOnIdle {assertTrue(validity!!());assertEquals(1,requests);completion!!(ok)}
        compose.onNodeWithText("Seeking").assertDoesNotExist()
        compose.onNodeWithTag("player-clock-progress").assertIsEnabled()
        if(ok)compose.onNodeWithText("Seek not confirmed. Try again.").assertDoesNotExist()
        else compose.onNodeWithText("Seek not confirmed. Try again.").assertIsDisplayed()
    }
    @Test fun expectedDestinationThenSameIdAbaRetiresHeldReceipt() {
        val authority=PlaybackClockAuthority(ClockOwner("service",1,"queue",2,"b"),listOf(ClockSpan("a1",10000),ClockSpan("b",20000),ClockSpan("a2",10000)))
        val state=mutableStateOf(PlaybackProjection(connection=PlaybackProjection.Connection.Connected,selectedOccurrence="b",selectionIncarnation=10,positionMs=5000,durationMs=20000,accountEpoch=1,arrangementService="service",sourceQueueIncarnation="queue",clockAuthority=authority))
        var completion:((Boolean)->Unit)?=null
        var validity:(()->Boolean)?=null
        compose.setContent {SoundQTheme {androidx.compose.foundation.layout.Column {FullPlayerClock(state.value) {_,_,_,v,d->validity=v;completion=d}}}}
        compose.onNodeWithContentDescription("Whole queue clock").performClick()
        compose.onNodeWithTag("player-clock-progress").performSemanticsAction(SemanticsActions.SetProgress){it(.8125f)}
        compose.runOnIdle {state.value=state.value.copy(selectedOccurrence="a2",selectionIncarnation=12,durationMs=10000,clockAuthority=authority.copy(owner=authority.owner.copy(selected="a2",revision=3)))}
        compose.onNodeWithText("Seeking").assertIsDisplayed()
        compose.runOnIdle {state.value=state.value.copy(selectionIncarnation=14)}
        compose.onNodeWithText("Seeking").assertDoesNotExist()
        compose.runOnIdle {assertFalse(validity!!());completion!!(false)}
        compose.onNodeWithText("Seek not confirmed. Try again.").assertDoesNotExist()
    }
    @Test fun modeChangesOnlyPresentationAndQueueSeekUsesExactSecondA() {
        val authority=PlaybackClockAuthority(ClockOwner("service",1,"queue",2,"b"),listOf(ClockSpan("a1",10000),ClockSpan("b",20000),ClockSpan("a2",10000)))
        val state=mutableStateOf(PlaybackProjection(connection=PlaybackProjection.Connection.Connected,selectedOccurrence="b",positionMs=5000,durationMs=20000,accountEpoch=1,arrangementService="service",sourceQueueIncarnation="queue",clockAuthority=authority))
        val requests=mutableListOf<ClockDestination>()
        var transport=0
        compose.setContent {SoundQTheme {SoundQFullPlayerContent("B","Artist",false,true,false,5000,20000,"b",{},{transport++},{transport++},{},clockContent={
            FullPlayerClock(state.value) {p,m,position,valid,done->assertTrue(valid());requests+=checkNotNull(projectPlayerClock(p,m).destination(position));done(true)}
        })}}
        compose.onNodeWithTag("player-clock-time").assertTextEquals("0:05 / 0:20")
        compose.onNodeWithContentDescription("Whole queue clock").performClick().assertIsSelected()
        compose.onNodeWithTag("player-clock-time").assertTextEquals("0:15 / 0:40")
        compose.runOnIdle {assertEquals(0,transport);assertTrue(requests.isEmpty());assertEquals(5000L,state.value.positionMs)}
        compose.onNodeWithTag("player-clock-progress").performSemanticsAction(SemanticsActions.SetProgress){it(0.8125f)}
        compose.runOnIdle {assertEquals(listOf(ClockDestination("a2",2500)),requests);assertEquals(0,transport)}
        compose.onNodeWithContentDescription("Current song clock").performClick()
        compose.onNodeWithTag("player-clock-time").assertTextEquals("0:05 / 0:20")
        compose.runOnIdle {state.value=state.value.copy(clockAuthority=null)}
        compose.onNodeWithContentDescription("Whole queue clock").performClick()
        compose.onNodeWithTag("player-clock-time").assertTextEquals("— / —")
        compose.onNodeWithTag("player-clock-progress").assertIsNotEnabled()
        compose.onNodeWithText("Queue clock unavailable").assertIsDisplayed()
    }
}
