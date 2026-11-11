package com.soundq.designsystem

import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.*
import androidx.compose.ui.geometry.Offset
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
class PlaybackSpeedPanelTest {
    @get:Rule val compose=createComposeRule()

    @Test fun centreOriginMappingQuantisationAndCopy() {
        for((min,max) in listOf(0.5 to 2.0,0.75 to 1.5)) {
            assertEquals(1.0,SoundQSpeedScale.rateAt(0.5f,min,max),0.0)
            assertEquals(0.5f,SoundQSpeedScale.fractionOf(1.0,min,max))
            assertEquals(min,SoundQSpeedScale.rateAt(0f,min,max),0.0);assertEquals(max,SoundQSpeedScale.rateAt(1f,min,max),0.0)
        }
        assertEquals(1.35,SoundQSpeedScale.quantise(1.3401,0.5,2.0),0.0)
        assertEquals(1.0,SoundQSpeedScale.snapped(1.03),0.0);assertEquals(1.05,SoundQSpeedScale.snapped(1.05),0.0)
        assertEquals(listOf("1.0x","1.5x","1.25x","0.75x","2.0x","0.5x"),listOf(1.0,1.5,1.25,0.75,2.0,0.5).map(SoundQSpeedScale::label))
        assertEquals("1.5 times",SoundQSpeedScale.spoken(1.5));assertEquals("1 times",SoundQSpeedScale.spoken(1.0))
    }

    private fun mount(accepted:MutableState<Double>,requested:MutableState<Double?>,requests:MutableList<Double>,resets:MutableList<Unit>,
                      state:MutableState<SoundQSpeedPanelState> = mutableStateOf(SoundQSpeedPanelState.Ready),identity:MutableState<String> = mutableStateOf("a"),
                      rejected:MutableState<Double?> = mutableStateOf(null)) {
        compose.setContent {SoundQTheme {Column {
            SoundQPlaybackSpeedPanel(accepted.value,requested.value,0.5,2.0,state.value,null,{requests.add(it)},{resets.add(Unit)},identity=identity.value,rejected=rejected.value)
        }}}
    }

    @Test fun dragCommitsOnceOnReleaseAndHeaderKeepsAccepted() {
        val accepted=mutableStateOf(1.0);val requested=mutableStateOf<Double?>(null)
        val requests=mutableListOf<Double>();val resets=mutableListOf<Unit>()
        val state=mutableStateOf(SoundQSpeedPanelState.Ready)
        mount(accepted,requested,requests,resets,state)
        val slider=compose.onNodeWithTag("player-speed-slider")
        slider.performTouchInput {down(center);moveTo(Offset(width*0.6f,center.y));moveTo(Offset(width*0.75f,center.y))}
        compose.onNodeWithTag("player-speed-accepted").assertTextEquals("1.0x")
        compose.runOnIdle {assertTrue("no per-frame requests",requests.isEmpty())}
        slider.performTouchInput {up()}
        compose.runOnIdle {assertEquals(1,requests.size);assertTrue(requests.single() in 1.4..1.6);assertTrue(resets.isEmpty())}
        // Pending: header still accepted, hollow needle, Applying status.
        compose.runOnIdle {requested.value=requests.single();state.value=SoundQSpeedPanelState.Pending}
        compose.onNodeWithTag("player-speed-accepted").assertTextEquals("1.0x")
        compose.onNodeWithTag("player-speed-status").assertTextContains("Applying",substring=true)
        slider.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription,"1 times, applying ${SoundQSpeedScale.spoken(requests.single())}"))
    }

    @Test fun shortcutIsSingleRequestAndNormalShortcutIsReset() {
        val accepted=mutableStateOf(1.5);val requested=mutableStateOf<Double?>(null)
        val requests=mutableListOf<Double>();val resets=mutableListOf<Unit>()
        mount(accepted,requested,requests,resets)
        compose.onNodeWithTag("player-speed-shortcut-1.5x").assertIsSelected().performClick() // already accepted: no-op
        compose.onNodeWithTag("player-speed-shortcut-1.25x").performClick()
        compose.onNodeWithContentDescription("Normal speed, 1 times. Resets this track").performClick()
        compose.runOnIdle {assertEquals(listOf(1.25),requests);assertEquals(1,resets.size)}
        val actions=compose.onNodeWithTag("player-speed-slider").fetchSemanticsNode().config[SemanticsActions.CustomActions]
        assertEquals(listOf("Reset to normal speed"),actions.map {it.label})
    }

    @Test fun accessibilityAdjustDebouncesToOneLatestRequest() {
        val accepted=mutableStateOf(1.0);val requested=mutableStateOf<Double?>(null)
        val requests=mutableListOf<Double>();val resets=mutableListOf<Unit>()
        compose.mainClock.autoAdvance=false
        mount(accepted,requested,requests,resets)
        val slider=compose.onNodeWithTag("player-speed-slider")
        slider.performSemanticsAction(SemanticsActions.SetProgress) {it(1.1f)}
        compose.mainClock.advanceTimeBy(200)
        slider.performSemanticsAction(SemanticsActions.SetProgress) {it(1.2f)}
        compose.mainClock.advanceTimeBy(200)
        compose.runOnIdle {assertTrue(requests.isEmpty())}
        compose.mainClock.advanceTimeBy(600)
        compose.runOnIdle {assertEquals(listOf(1.2),requests)}
    }

    @Test fun accessibilityReportsTheDraftSoStepsAccumulate() {
        val accepted=mutableStateOf(1.0);val requested=mutableStateOf<Double?>(null)
        val requests=mutableListOf<Double>();val resets=mutableListOf<Unit>()
        compose.mainClock.autoAdvance=false
        mount(accepted,requested,requests,resets)
        val slider=compose.onNodeWithTag("player-speed-slider")
        slider.performSemanticsAction(SemanticsActions.SetProgress) {it(1.05f)}
        // A few frames (well inside the 500 ms debounce) for the action's state write to recompose.
        repeat(6) {compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
        // The next accessibility step starts from the draft, not from accepted 1.0x.
        slider.assert(SemanticsMatcher("current is draft") {node->node.config[SemanticsProperties.ProgressBarRangeInfo].current==1.05f})
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription,"1 times, selecting 1.05 times"))
        compose.onNodeWithTag("player-speed-accepted").assertTextEquals("1.0x")
        compose.mainClock.advanceTimeBy(600)
        compose.runOnIdle {assertEquals(listOf(1.05),requests)}
    }

    @Test fun unavailableOwnerWithoutRangeRendersCentredAndFinite() {
        assertEquals(0.5f,SoundQSpeedScale.fractionOf(1.0,1.0,1.0))
        assertEquals(1.0,SoundQSpeedScale.rateAt(0.2f,1.0,1.0),0.0)
        compose.setContent {SoundQTheme {Column {
            SoundQPlaybackSpeedPanel(1.0,null,1.0,1.0,SoundQSpeedPanelState.Unavailable,"Speed follows the Jam host.",{},{})
        }}}
        compose.onNodeWithTag("player-speed-slider").assertIsNotEnabled()
            .assert(SemanticsMatcher("finite range info") {node->node.config[SemanticsProperties.ProgressBarRangeInfo].current.isFinite()})
        compose.onNodeWithTag("player-speed-status").assertTextEquals("Speed follows the Jam host.")
    }

    @Test fun rejectionAndUnavailableAreExplicitAndIdentityRetiresDraft() {
        val accepted=mutableStateOf(1.0);val requested=mutableStateOf<Double?>(null);val rejected=mutableStateOf<Double?>(1.5)
        val state=mutableStateOf(SoundQSpeedPanelState.Rejected);val identity=mutableStateOf("a")
        val requests=mutableListOf<Double>();val resets=mutableListOf<Unit>()
        mount(accepted,requested,requests,resets,state,identity,rejected)
        compose.onNodeWithTag("player-speed-status").assertTextEquals("Couldn't change speed to 1.5x. Still playing at 1.0x.")
        // Held draft for track A cannot commit into track B.
        val slider=compose.onNodeWithTag("player-speed-slider")
        slider.performTouchInput {down(center);moveTo(Offset(width*0.9f,center.y))}
        compose.runOnIdle {identity.value="b";state.value=SoundQSpeedPanelState.Ready;rejected.value=null}
        slider.performTouchInput {up()}
        compose.runOnIdle {assertTrue(requests.isEmpty())}
        compose.runOnIdle {state.value=SoundQSpeedPanelState.Unavailable}
        slider.assertIsNotEnabled().assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription,"Unavailable. Speed changes aren't available for this track."))
        compose.onNodeWithTag("player-speed-shortcut-1.25x").assertIsNotEnabled()
    }

    @Test fun utilitiesOrderQueueSpeedDevicesInfoAndCellShowsAccepted() {
        var toggles=0
        compose.setContent {SoundQTheme {Column {
            SoundQPlayerUtilities({},{},{},speed=SoundQSpeedCell(1.5,true,false) {toggles++})
        }}}
        val labels=compose.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsProperties.ContentDescription)).fetchSemanticsNodes()
            .map {it.config[SemanticsProperties.ContentDescription].single()}
        assertEquals(listOf("Open listening queue","Playback speed","Connected devices","Song details"),labels)
        compose.onNodeWithContentDescription("Playback speed").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription,"1.5 times, collapsed"))
            .assertHeightIsAtLeast(androidx.compose.ui.unit.Dp(48f)).performClick()
        compose.onNodeWithText("1.5x").assertExists()
        compose.runOnIdle {assertEquals(1,toggles)}
    }
}
