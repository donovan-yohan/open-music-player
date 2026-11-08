package com.soundq.designsystem

import android.util.Log
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Minimal attached queue; no app, transport, controller, or direct gesture reducer. */
class QueueNativeInputPilot {
    @get:Rule val compose=createComposeRule()
    private fun grip(i:Int)=compose.onNodeWithContentDescription("Reorder Entry $i")
    private fun record(label:String):Pair<String,Float> {
        val node=grip(0).fetchSemanticsNode()
        val state=node.config[SemanticsProperties.StateDescription]
        val top=node.boundsInRoot.top
        Log.i("QueueNativePilot","$label clock=${compose.mainClock.currentTime} state=$state bounds=${node.boundsInRoot}")
        return state to top
    }
    private fun frame() {compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
    @Test fun compareFrozenSingleMoveWithFramedSlopCrossing() {
        val moves=mutableListOf<Pair<String,Int>>()
        compose.setContent {SoundQTheme {Box(Modifier.width(320.dp)) {
            SoundQOccurrenceQueue(List(5) {QueueRowVisual("occ-$it","Entry $it",if(it==1)"A taller artist description which wraps onto several lines at enlarged text" else "Artist",it==0)}, {}, {id,to->moves.add(id to to)}, {})
        }}}
        compose.waitForIdle();compose.mainClock.autoAdvance=false
        val from=grip(0).fetchSemanticsNode().boundsInRoot
        val to=grip(2).fetchSemanticsNode().boundsInRoot
        val delta=to.center.y-from.center.y+to.height/2
        val target=to.bottom-from.height
        grip(0).performTouchInput {down(center);moveBy(Offset(0f,delta))}
        val frozen=record("single-frozen")
        repeat(3) {frame()}
        val admitted=record("single-framed")
        assertEquals("Moving to position 3",admitted.first)
        assertTrue("Admitted displayed row overshoots insertion target",admitted.second>target+1f)
        assertTrue(moves.isEmpty())
        grip(0).performTouchInput {cancel()};repeat(3) {frame()}
        assertTrue(moves.isEmpty());assertEquals(from.top,record("cancelled").second,0.5f)
        grip(0).performTouchInput {down(center);moveBy(Offset(0f,16.dp.toPx()))}
        repeat(3) {frame()}
        record("slop-crossed")
        grip(0).performTouchInput {moveBy(Offset(0f,delta-16.dp.toPx()))}
        repeat(3) {frame()}
        val staged=record("staged-framed")
        assertEquals(admitted.first,staged.first)
        assertEquals(admitted.second,staged.second,0.5f)
        assertTrue(moves.isEmpty())
        grip(0).performTouchInput {up()};frame()
        record("released")
        assertTrue(moves.isEmpty())
        compose.mainClock.advanceTimeBy(1000);compose.waitForIdle()
        assertEquals(listOf("occ-0" to 2),moves)
        record("completed")
        Log.i("QueueNativePilot","frozen=$frozen admitted=$admitted staged=$staged dispatch=$moves")
    }
}
