package com.soundq.android

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Real Activity queue -> captured route -> actual controller -> fixture-backed Media3 service. */
class QueuePanelAdmissionTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun realPanelReportsMovingBeforeRelease() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("queue-synthetic@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.waitUntil(10000){app.graph.session.capture()!=null&&app.graph.library.state.value.rows.size>=3}
        val libraryTrack=hasText("Fixture 1") and hasClickAction() and hasAnyDescendant(hasContentDescription("More for Fixture 1"))
        compose.onNode(libraryTrack).performClick()
        compose.waitUntil(15000){model.playback.value.queue.size>=3&&model.playback.value.canPlay}
        compose.runOnIdle {model.controller.pause()}
        compose.onNodeWithContentDescription("Open listening queue").performClick()
        val original=compose.runOnIdle {model.playback.value}
        val order=original.queue.map {it.occurrenceId}
        val first=compose.onNodeWithContentDescription("Reorder Fixture 1")
        val third=compose.onNodeWithContentDescription("Reorder Fixture 3")
        val from=first.fetchSemanticsNode().boundsInRoot
        val to=third.fetchSemanticsNode().boundsInRoot
        compose.mainClock.autoAdvance=false
        first.performTouchInput {down(center);moveBy(Offset(0f,to.center.y-from.center.y+to.height/2))}
        repeat(3) {compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
        first.assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.StateDescription,"Moving to position 3"))
        val before=compose.mainClock.currentTime
        val lifted=first.fetchSemanticsNode().boundsInRoot.top
        assertTrue("Real app row must be displayed past measured insertion target",lifted>to.bottom-from.height+1f)
        compose.runOnIdle {
            assertEquals(order,model.playback.value.queue.map {it.occurrenceId})
            assertEquals(original.selectedOccurrence,model.playback.value.selectedOccurrence)
            assertFalse(model.playback.value.isPlaying)
        }
        first.performTouchInput {cancel(delayMillis=0)}
        assertEquals("Explicit cancel must keep animation clock frozen",before,compose.mainClock.currentTime)
        compose.mainClock.advanceTimeBy(1000);compose.waitForIdle()
        first.assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.StateDescription,"Position 1 of 3"))
        assertEquals(from.top,first.fetchSemanticsNode().boundsInRoot.top,0.5f)
        compose.runOnIdle {
            assertEquals(order,model.playback.value.queue.map {it.occurrenceId})
            assertEquals(original.selectedOccurrence,model.playback.value.selectedOccurrence)
            assertFalse(model.playback.value.isPlaying)
            android.util.Log.i("QueuePanelAdmission","Real panel Moving3 lifted=$lifted, cancel restored=${from.top}; projection=${model.playback.value}")
        }
    }
}
