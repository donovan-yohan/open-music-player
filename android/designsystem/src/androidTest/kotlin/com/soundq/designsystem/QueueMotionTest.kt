package com.soundq.designsystem

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Compiled mounted native acceptance cases. Execution requires the parent's Android lane. */
class QueueMotionTest {
    @get:Rule val compose=createComposeRule()
    private fun rows(count:Int=5)=List(count) {QueueRowVisual("occ-$it","Entry $it",if(it==1)"A taller artist description which wraps onto several lines at enlarged text" else "Artist",it==0)}
    private fun grip(i:Int)=compose.onNodeWithContentDescription("Reorder Entry $i")
    private fun mount(reduced:Boolean=false,large:Boolean=false,count:Int=5,revision:MutableState<Int> = mutableStateOf(1),shown:MutableState<Boolean> = mutableStateOf(true),onMove:(String,Int)->Unit) {
        compose.setContent {
            val density=LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density,if(large)2f else 1f)) {
                SoundQTheme(reducedMotion=reduced) {
                    if(shown.value)Box(Modifier.width(320.dp)) {SoundQOccurrenceQueue(rows(count),{error("Grip must never select")},onMove,{},revision=revision.value)}
                }
            }
        }
    }
    private fun startDownward() {
        val from=grip(0).fetchSemanticsNode().boundsInRoot
        val to=grip(2).fetchSemanticsNode().boundsInRoot
        grip(0).performTouchInput {down(center);moveBy(Offset(0f,to.center.y-from.center.y+to.height/2))}
        // Native pilot: the same delivered move is still Position 1 at the frozen frame,
        // then Moving 3 with translated geometry after composition/layout frames.
        repeat(3) {compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
        grip(0).assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.StateDescription,"Moving to position 3"))
    }
    @Test fun touchReleaseIsInsertionAndWaitsForAnimationCompletion() {
        val moves=mutableListOf<Pair<String,Int>>()
        mount {id,to->moves.add(id to to)}
        compose.mainClock.autoAdvance=false
        startDownward()
        grip(0).assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.StateDescription,"Moving to position 3"))
        grip(0).performTouchInput {up()}
        compose.mainClock.advanceTimeByFrame()
        assertTrue(moves.isEmpty())
        compose.mainClock.advanceTimeBy(1000)
        compose.waitForIdle()
        assertEquals(listOf("occ-0" to 2),moves)
    }
    /** Positively observe the displayed row move inside animateTo, not just a pending command. */
    private fun enterDisplayedSettle(moves:List<Pair<String,Int>>):Float {
        val origin=grip(0).fetchSemanticsNode().boundsInRoot
        val destination=grip(2).fetchSemanticsNode().boundsInRoot
        val targetTop=destination.bottom-origin.height
        startDownward()
        val releasedTop=grip(0).fetchSemanticsNode().boundsInRoot.top
        assertTrue("Fixture must release beyond its insertion target",releasedTop>targetTop+1f)
        grip(0).performTouchInput {up()}
        var progressed=false
        repeat(6) {
            if(!progressed) {
                compose.mainClock.advanceTimeByFrame();compose.waitForIdle()
                val top=grip(0).fetchSemanticsNode().boundsInRoot.top
                progressed=top<releasedTop-0.5f&&top>targetTop+0.5f
            }
        }
        assertTrue("Displayed lifted row must positively enter incomplete settle animateTo",progressed)
        grip(0).assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.StateDescription,"Settling to position 3"))
        assertTrue(moves.isEmpty())
        return targetTop
    }
    private fun rejectedSameGripDuringDisplayedSettle(cancelled:Boolean) {
        val moves=mutableListOf<Pair<String,Int>>()
        mount {id,to->moves.add(id to to)}
        compose.mainClock.autoAdvance=false
        val targetTop=enterDisplayedSettle(moves)
        val before=grip(0).fetchSemanticsNode().boundsInRoot.top
        val clock=compose.mainClock.currentTime
        // Each move crosses canonical 8dp slop; zero event delay keeps the first
        // animation's clock frozen. Native input still travels through the real detector.
        grip(0).performTouchInput {
            down(center)
            moveBy(Offset(0f,-16.dp.toPx()),delayMillis=0)
            moveBy(Offset(0f,-8.dp.toPx()),delayMillis=0)
            if(cancelled)cancel(delayMillis=0) else up()
        }
        compose.waitForIdle()
        assertEquals("Rejected gesture must not advance the animation test clock",clock,compose.mainClock.currentTime)
        grip(0).assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.StateDescription,"Settling to position 3"))
        assertEquals("Rejected terminal must preserve currently displayed lifted owner",before,grip(0).fetchSemanticsNode().boundsInRoot.top,0.5f)
        assertTrue(moves.isEmpty())
        compose.mainClock.advanceTimeByFrame();compose.waitForIdle()
        val progressed=grip(0).fetchSemanticsNode().boundsInRoot.top
        assertTrue("The same displayed animation must continue toward its insertion target",progressed<before-0.1f&&progressed>targetTop)
        assertTrue("No command while displayed settle is incomplete",moves.isEmpty())
        // Keep the command boundary under a frame-by-frame oracle. If the old
        // completion ran behind a replacement Animatable, its final displayed
        // position would stay beyond target despite a command being published.
        var previous=progressed
        repeat(30) {
            if(moves.isEmpty()) {
                compose.mainClock.advanceTimeByFrame();compose.waitForIdle()
                val top=grip(0).fetchSemanticsNode().boundsInRoot.top
                if(moves.isEmpty()) {
                    assertTrue("Displayed settle must not reverse or be replaced",top<=previous+0.5f)
                    assertTrue(top>=targetTop-0.5f)
                } else assertEquals("Last displayed frame must have reached target before command",targetTop,previous,0.75f)
                previous=top
            }
        }
        assertEquals(listOf("occ-0" to 2),moves)
        compose.mainClock.advanceTimeBy(1000);compose.waitForIdle()
        assertEquals("Settle dispatch remains exactly once",listOf("occ-0" to 2),moves)
    }
    @Test fun rejectedSameGripUpCannotReplaceDisplayedSettlingAnimation() {
        rejectedSameGripDuringDisplayedSettle(cancelled=false)
    }
    @Test fun rejectedSameGripCancelCannotRetireDisplayedSettlingAnimation() {
        rejectedSameGripDuringDisplayedSettle(cancelled=true)
    }
    @Test fun acceptedPointerCancelAndReversalNeverCommit() {
        val moves=mutableListOf<Pair<String,Int>>()
        mount {id,to->moves.add(id to to)}
        compose.mainClock.autoAdvance=false
        startDownward();grip(0).performTouchInput {cancel()}
        compose.mainClock.advanceTimeBy(1000);compose.waitForIdle();assertTrue(moves.isEmpty())
        val from=grip(0).fetchSemanticsNode().boundsInRoot
        val to=grip(2).fetchSemanticsNode().boundsInRoot
        // Cross the measured third midpoint strictly, then reverse the exact delivered distance.
        // Center equality is not an insertion crossing in QueueDragSession.follow.
        val crossing=to.center.y-from.center.y+to.height/2
        grip(0).performTouchInput {down(center);moveBy(Offset(0f,crossing))}
        repeat(3) {compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
        grip(0).assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.StateDescription,"Moving to position 3"))
        assertTrue("Measured lifted center must strictly cross third midpoint",grip(0).fetchSemanticsNode().boundsInRoot.center.y>to.center.y)
        grip(0).performTouchInput {moveBy(Offset(0f,-crossing))}
        repeat(3) {compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
        grip(0).assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.StateDescription,"Moving to position 1"))
        grip(0).performTouchInput {up()}
        compose.mainClock.advanceTimeBy(1000);compose.waitForIdle();assertTrue(moves.isEmpty())
    }
    @Test fun firstEscapeCancelsHeldSettleWithoutDismissingQueue() {
        val moves=mutableListOf<Pair<String,Int>>()
        mount {id,to->moves.add(id to to)}
        compose.mainClock.autoAdvance=false
        startDownward();grip(0).performTouchInput {up()}
        compose.mainClock.advanceTimeByFrame()
        grip(0).performKeyInput {pressKey(Key.Escape)}
        compose.mainClock.advanceTimeBy(1000);compose.waitForIdle()
        assertTrue(moves.isEmpty());grip(0).assertExists()
    }
    @Test fun modalFirstEscapeCancelsThenSecondEscapeDismisses() {
        var open by mutableStateOf(true);var dismissed=0
        val moves=mutableListOf<Pair<String,Int>>()
        compose.setContent {SoundQTheme {if(open) {
            val gesture=remember {QueueGestureState()}
            SoundQSheet("Queue",{dismissed++;open=false},queueGesture=gesture) {
                SoundQOccurrenceQueue(rows(3),{}, {id,to->moves.add(id to to)}, {},gestureState=gesture)
            }
        }}}
        compose.waitForIdle();compose.mainClock.autoAdvance=false
        startDownward();grip(0).performTouchInput {up()};compose.mainClock.advanceTimeByFrame()
        grip(0).performKeyInput {pressKey(Key.Escape)}
        compose.mainClock.advanceTimeBy(1000);compose.waitForIdle()
        assertTrue(moves.isEmpty());assertEquals(0,dismissed);grip(0).assertExists()
        grip(0).performKeyInput {pressKey(Key.Escape)}
        compose.mainClock.advanceTimeBy(1000);compose.waitForIdle()
        assertEquals(1,dismissed)
    }
    @Test fun revisionAndUnmountRetireHeldSettle() {
        val moves=mutableListOf<Pair<String,Int>>();val revision=mutableStateOf(1);val shown=mutableStateOf(true)
        mount(revision=revision,shown=shown) {id,to->moves.add(id to to)}
        compose.mainClock.autoAdvance=false
        startDownward();grip(0).performTouchInput {up()};compose.mainClock.advanceTimeByFrame()
        compose.runOnIdle {revision.value++};compose.mainClock.advanceTimeBy(1000);compose.waitForIdle()
        assertTrue(moves.isEmpty())
        startDownward();grip(0).performTouchInput {up()};compose.mainClock.advanceTimeByFrame()
        compose.runOnIdle {shown.value=false};compose.mainClock.advanceTimeBy(1000);compose.waitForIdle()
        assertTrue(moves.isEmpty())
    }
    @Test fun reducedMotionEnlargedRowsRemainMeasuredAndCommitOnce() {
        val moves=mutableListOf<Pair<String,Int>>()
        mount(reduced=true,large=true,count=3) {id,to->moves.add(id to to)}
        val from=grip(0).fetchSemanticsNode().boundsInRoot
        val next=grip(1).fetchSemanticsNode().boundsInRoot
        assertTrue(next.center.y>from.center.y)
        grip(0).performTouchInput {down(center);moveBy(Offset(0f,next.center.y-from.center.y+next.height/2));up()}
        compose.waitForIdle();assertEquals(1,moves.size);assertEquals("occ-0",moves.single().first)
    }
    @Test fun heldEdgeScrollMovesWithoutAdditionalMoveEventsAndCancelStopsIt() {
        val moves=mutableListOf<Pair<String,Int>>()
        mount(count=30) {id,to->moves.add(id to to)}
        compose.mainClock.autoAdvance=false
        val from=grip(0).fetchSemanticsNode().boundsInRoot
        grip(0).performTouchInput {down(center);moveBy(Offset(0f,450.dp.toPx()-from.center.y))}
        val before=grip(0).fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.StateDescription]
        compose.mainClock.advanceTimeBy(1200)
        val after=grip(0).fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.StateDescription]
        assertNotEquals(before,after)
        grip(0).performTouchInput {cancel()};compose.mainClock.advanceTimeBy(1000)
        assertTrue(moves.isEmpty())
    }
    @Test fun accessibilityBoundariesAndKeyboardRestoreMovedGripAfterSnapshot() {
        var authoritative by mutableStateOf(rows(3));val intents=mutableListOf<QueueMoveIntent>()
        compose.setContent {SoundQTheme {SoundQOccurrenceQueue(authoritative,{}, {_,_->}, {},onReorder={intent ->
            intents.add(intent);authoritative=intent.insertedOrder().map {id->authoritative.first {it.occurrence==id}};true
        })}}
        val actions=grip(0).fetchSemanticsNode().config[SemanticsActions.CustomActions]
        assertFalse(actions.any {it.label=="Move earlier"});assertTrue(actions.any {it.label=="Move later"})
        grip(0).performSemanticsAction(SemanticsActions.RequestFocus)
        grip(0).performKeyInput {keyDown(Key.AltLeft);pressKey(Key.DirectionDown);keyUp(Key.AltLeft)}
        compose.waitForIdle();assertEquals(1,intents.size)
        assertEquals(listOf("occ-1","occ-0","occ-2"),authoritative.map {it.occurrence})
        grip(0).assertIsFocused()
    }
}
