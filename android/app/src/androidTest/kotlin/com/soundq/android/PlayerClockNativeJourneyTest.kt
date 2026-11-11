package com.soundq.android

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.playback.*
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Integration-owner continuation. CallbackFrontendFixtureRunner, real service,
 * MediaController, decoder and JNI cursor. Compilation is not runtime evidence. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class PlayerClockNativeJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun pausedDuplicateQueueClockSeeksOneAcceptedOccurrenceAndRejectsHeldOldOwner() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CallbackFrontendFixtureApplication
        val graph=app.graph
        compose.runOnIdle {graph.session.retire()}
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        val hash=java.security.MessageDigest.getInstance("SHA-256").digest((graph.endpoint.identity+"\u0000fixture-account").toByteArray()).joinToString(""){"%02x".format(it)}
        val saved=QueueSnapshot(graph.endpoint.identity,"fixture-account",listOf(
            SavedOccurrence("clock-a1",1,"Fixture 1","Synthetic ensemble",false,false,12000,QueueOrigin.Context),
            SavedOccurrence("clock-b",2,"Fixture 2","Synthetic ensemble",false,false,12000,QueueOrigin.Context),
            SavedOccurrence("clock-a2",1,"Fixture 1","Synthetic ensemble",false,false,12000,QueueOrigin.Context)
        ),1,3000)
        QueueSnapshotStore(graph.directory.resolve("queue-$hash.json")).write(saved)
        compose.onNodeWithContentDescription("Email").performTextInput("clock@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.waitUntil(15000){model.playback.value.clockAuthority?.owner?.selected=="clock-b"}
        val captured=compose.runOnIdle {model.playback.value}
        val native=app.callbackPlayer
        compose.onNode(hasContentDescription("Fixture 2, Synthetic ensemble") and SemanticsMatcher.expectValue(SemanticsProperties.StateDescription,"Paused")).performClick()
        compose.onNodeWithTag("player-clock-time").assertTextEquals("0:03 / 0:12")
        compose.onNodeWithContentDescription("Whole queue clock").performClick()
        compose.onNodeWithTag("player-clock-time").assertTextEquals("0:15 / 0:36")
        compose.runOnIdle {assertEquals("clock-b",native.currentMediaItem!!.mediaId);assertEquals(3000L,native.currentPosition);assertFalse(native.playWhenReady)}
        compose.onNodeWithTag("player-clock-progress").performSemanticsAction(SemanticsActions.SetProgress){it(.75f)}
        compose.waitUntil(20000){compose.runOnIdle {
            val observed=acknowledgedQueueObservation(model)
            observed.readback.acknowledged(3,"clock-a2")&&kotlin.math.abs(observed.projection.positionMs-3000)<=250&&
                kotlin.math.abs(native.currentPosition-3000)<=250&&!observed.projection.preparing
        }}
        compose.onNodeWithText("Seeking").assertDoesNotExist()
        compose.onNodeWithContentDescription("Current song clock").performClick()
        compose.onNodeWithTag("player-clock-time").assertTextEquals("0:03 / 0:12")
        var refused:Boolean?=null
        compose.runOnIdle {model.controller.seekClock(captured,PlayerClockMode.Queue,1000,{true}){refused=it}}
        compose.waitUntil(5000){refused!=null}
        compose.runOnIdle {assertEquals(false,refused);assertEquals("clock-a2",native.currentMediaItem!!.mediaId);assertFalse(native.playWhenReady);assertFalse(native.isPlaying)}
        compose.onNodeWithContentDescription("Close Now playing").performClick()
        compose.runOnIdle {assertEquals("clock-a2",model.playback.value.selectedOccurrence);assertFalse(model.playback.value.isPlaying)}
    }
}
