package com.soundq.android

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import com.soundq.designsystem.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Real Compose viewport/focus checks. Service acceptance is covered by MobileWorkspaceJourneyTest. */
class QueueViewportJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<ComponentActivity>()

    @Test fun visibleMoveKeepsOriginAndOffscreenMoveStillRevealsFocusedGrip() {
        val original=List(12){QueueRowVisual("occ-$it","Entry $it","Artist",false)}
        var rows by mutableStateOf(original)
        var accepted=0
        compose.setContent {SoundQTheme {
            Box(Modifier.width(360.dp).height(320.dp)) {
                SoundQOccurrenceQueue(rows,{}, {_,_->}, {},bounded=true,onReorder={intent->
                    accepted++;rows=intent.insertedOrder().map {id->rows.single {it.occurrence==id}};true
                })
            }
        }}
        val first=compose.onNodeWithContentDescription("Reorder Entry 0")
        val origin=first.fetchSemanticsNode().boundsInRoot.top
        fun moveLater() {
            val actions=first.fetchSemanticsNode().config[SemanticsActions.CustomActions]
            compose.runOnIdle {assertTrue(actions.single {it.label=="Move later"}.action())}
            compose.waitForIdle()
        }
        moveLater()
        assertEquals("A visible move must not top-align the moved row",origin,
            compose.onNodeWithContentDescription("Reorder Entry 1").fetchSemanticsNode().boundsInRoot.top,1f)
        first.assertIsFocused().assertIsDisplayed()
        // Each accepted next-row command is ordinary accessibility intent. Once
        // the moved row would leave the bounded viewport, focus must reveal it.
        repeat(6){moveLater();first.assertIsFocused().assertIsDisplayed()}
        assertEquals(7,accepted)
        assertEquals("occ-0",rows[7].occurrence)
        assertEquals("Position 8 of 12",first.fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.StateDescription])
    }
}
