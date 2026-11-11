package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.playback.*
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Fixture-only journey for the integration device owner. Never run against a live account.
 * Assembled/compiled and executed status must be reported separately. */
class OrdinaryQueueRecoveryJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()

    @Test fun duplicateOccurrenceMoveRemoveClearAndUndoKeepPausedCursor() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val graph=app.graph
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        val account="fixture-account"
        val hash=java.security.MessageDigest.getInstance("SHA-256").digest((graph.endpoint.identity+"\u0000"+account).toByteArray()).joinToString(""){"%02x".format(it)}
        val saved=QueueSnapshot(graph.endpoint.identity,account,listOf(
            SavedOccurrence("ordinary-a-first",1,"Fixture 1","Fixture",false,false,12000,QueueOrigin.Context),
            SavedOccurrence("ordinary-b",2,"Fixture 2","Fixture",false,false,12000,QueueOrigin.Context),
            SavedOccurrence("ordinary-a-second",1,"Fixture 1","Fixture",false,false,12000,QueueOrigin.Context)
        ),2,4300)
        graph.directory.resolve("queue-$hash.json").writeText(saved.encode())
        compose.onNodeWithContentDescription("Email").performTextInput("ordinary-queue@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.waitUntil(15000){model.playback.value.connection==PlaybackProjection.Connection.Connected&&model.playback.value.queue.size==3}
        val order=saved.items.map{it.occurrence}
        val selected=order.last()
        fun awaitOrder(expected:List<String>,selection:String?=selected,cursor:Long=4300) {
            compose.waitUntil(15000) {compose.runOnIdle {
                val observed=acknowledgedQueueObservation(model)
                observed.readback.acknowledged(expected.size,selection)&&observed.projection.queue.map{it.occurrenceId}==expected&&
                    (selection==null||observed.projection.positionMs==cursor)
            }}
        }
        fun undo() {
            compose.waitUntil(10000){model.playback.value.canUndo}
            compose.onNodeWithContentDescription("Queue actions").performClick()
            compose.onNodeWithText("Undo queue change").performClick()
            awaitOrder(order)
        }
        awaitOrder(order)
        compose.onNodeWithContentDescription("Open listening queue").performClick()
        compose.runOnIdle {model.controller.moveTo(order.first(),2)}
        awaitOrder(listOf(order[1],order[2],order[0]))
        undo()
        compose.runOnIdle {model.controller.remove(order.first())}
        awaitOrder(order.drop(1))
        undo()
        compose.onNodeWithContentDescription("Queue actions").performClick()
        compose.onNodeWithText("Clear listening queue").performClick()
        compose.onNodeWithText("Keep queue").performClick()
        awaitOrder(order)
        compose.onNodeWithContentDescription("Queue actions").performClick()
        compose.onNodeWithText("Clear listening queue").performClick()
        compose.onNodeWithText("Clear queue",substring=false).performClick()
        awaitOrder(emptyList(),null)
        undo()
        compose.runOnIdle {
            assertEquals(listOf(1L,2L,1L),model.playback.value.queue.map{it.trackId})
            assertEquals(selected,model.playback.value.selectedOccurrence)
            assertEquals(4300L,model.playback.value.positionMs)
            assertFalse(model.playback.value.isPlaying)
        }
    }
}
