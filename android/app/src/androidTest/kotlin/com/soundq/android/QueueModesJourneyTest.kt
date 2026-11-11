package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.media3.common.Player
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.playback.*
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Ordinary fixture login -> service startup restore -> paused mode save -> explicit Play.
 * Compiled only in this lane; no process-death, shuffle-order or device acceptance claim. */
class QueueModesJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun scopedSavedQueueRestoresPausedModesAndSavesModeOnlyActions() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val graph=app.graph
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        val account="fixture-account"
        val hash=java.security.MessageDigest.getInstance("SHA-256").digest((graph.endpoint.identity+"\u0000"+account).toByteArray()).joinToString(""){"%02x".format(it)}
        val file=graph.directory.resolve("queue-$hash.json")
        val saved=QueueSnapshot(graph.endpoint.identity,account,listOf(
            SavedOccurrence("modes-context",1,"Fixture one","Fixture",false,false,12000,QueueOrigin.Context),
            SavedOccurrence("modes-manual",1,"Fixture duplicate","Fixture",true,false,12000,QueueOrigin.Manual)
        ),1,2300,true,SavedRepeatMode.All)
        file.writeText(saved.encode())
        compose.onNodeWithContentDescription("Email").performTextInput("modes@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        try {
            compose.waitUntil(15000){model.playback.value.queue.size==2&&model.playback.value.shuffle&&model.playback.value.repeat==Player.REPEAT_MODE_ALL}
            val restored=model.playback.value
            assertFalse(restored.isPlaying);assertFalse(restored.preparing)
            assertEquals(saved.items.map {it.occurrence},restored.queue.map {it.occurrenceId})
            assertEquals("modes-manual",restored.selectedOccurrence)
            compose.runOnIdle {model.controller.shuffle()}
            compose.waitUntil(10000){QueueSnapshot.decode(file.readText(),graph.endpoint.identity,account)?.shuffleEnabled==false}
            compose.runOnIdle {model.controller.repeat()}
            compose.waitUntil(10000){QueueSnapshot.decode(file.readText(),graph.endpoint.identity,account)?.loopMode==SavedRepeatMode.One}
            assertFalse(model.playback.value.isPlaying)
            compose.runOnIdle {model.controller.toggle()}
            compose.waitUntil(15000){model.playback.value.isPlaying}
            assertEquals("modes-manual",model.playback.value.selectedOccurrence)
        }finally {compose.runOnIdle {model.controller.pause()}}
    }
}
