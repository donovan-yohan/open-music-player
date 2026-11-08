package com.soundq.android

import android.util.Log
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Isolate pause before any catalog/playlist action. Exact equality, no seek or tolerance. */
class PausedPositionSettlementTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun optimisticPauseSnapshotIsNotTheSettledServiceBaselineAndSettledPositionDoesNotMove() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        app.graph.session.retire()
        try {
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("pause@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){app.graph.library.state.value.rows.isNotEmpty()}
            compose.onNode(hasText("Fixture 1") and hasClickAction() and hasAnyDescendant(hasContentDescription("More for Fixture 1"))).performScrollTo().performClick()
            compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.positionMs>0}
            val optimistic=compose.runOnIdle {model.controller.pause();model.playback.value}
            val settlement=compose.settledPausedPlayback(model)
            val settled=settlement.projection
            Log.i("SoundQPauseProof","optimisticMs=${optimistic.positionMs};settledMs=${settled.positionMs};beforeAnyFeatureAction=true")
            assertEquals(optimistic.queue,settled.queue);assertEquals(optimistic.selectedOccurrence,settled.selectedOccurrence)
            // Cross two real 500ms projection timer publications without new playback commands.
            Thread.sleep(1200)
            compose.runOnIdle {assertActualPausedUnchanged(settlement)}
            val after=compose.runOnIdle {model.playback.value}
            assertEquals(settled.queue,after.queue);assertEquals(settled.selectedOccurrence,after.selectedOccurrence)
            assertEquals(settled.positionMs,after.positionMs);assertFalse(after.isPlaying)
        } finally {app.graph.session.retire()}
    }
}
