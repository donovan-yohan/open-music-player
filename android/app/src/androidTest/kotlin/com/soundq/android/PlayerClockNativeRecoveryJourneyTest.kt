package com.soundq.android

import android.graphics.Bitmap
import android.os.SystemClock
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.media3.common.Player
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.playback.*
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Owned callback fixture only: real service, MediaController, TLS MP3 and JNI.
 * Held network data is the controlled boundary; native receipt and UI are not replaced. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class PlayerClockNativeRecoveryJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()

    @Test fun heldRealDecoderFailureKeepsDestinationFeedback()=heldDestination(false)
    @Test fun heldRealDecoderExpiryKeepsDestinationFeedback()=heldDestination(true)

    private fun start(rows:List<SavedOccurrence>,selected:Int):Pair<CallbackFrontendFixtureApplication,ProductViewModel> {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CallbackFrontendFixtureApplication
        check(BuildConfig.APPLICATION_ID.startsWith("com.soundq.android.dev.goal"))
        val graph=app.graph
        compose.runOnIdle {graph.session.retire()}
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.waitUntil(5000){graph.crossfadePreferences.state.value.ready}
        compose.runOnIdle {assertTrue(graph.crossfadePreferences.setSeconds(requireNotNull(graph.crossfadePreferences.capture()),0){true})}
        val hash=java.security.MessageDigest.getInstance("SHA-256").digest((graph.endpoint.identity+"\u0000fixture-account").toByteArray()).joinToString(""){"%02x".format(it)}
        QueueSnapshotStore(graph.directory.resolve("queue-$hash.json")).write(QueueSnapshot(graph.endpoint.identity,"fixture-account",rows,selected,3000))
        compose.onNodeWithContentDescription("Email").performTextInput("clock@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.waitUntil(15000){model.playback.value.clockAuthority?.owner?.selected==rows[selected].occurrence}
        compose.onNode(hasContentDescription("Fixture 2, Synthetic ensemble") and SemanticsMatcher.expectValue(SemanticsProperties.StateDescription,"Paused")).performClick()
        return app to model
    }

    private fun row(occurrence:String,id:Long)=SavedOccurrence(occurrence,id,"Fixture $id","Synthetic ensemble",false,false,12000,QueueOrigin.Context)
    private fun screenshot(label:String) {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val directory=instrumentation.targetContext.filesDir.resolve("listening-20261105").apply {mkdirs()}
        val image=requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        try {directory.resolve("$label.png").outputStream().use {check(image.compress(Bitmap.CompressFormat.PNG,100,it))}}finally {image.recycle()}
    }
    private fun observation(label:String,app:CallbackFrontendFixtureApplication,model:ProductViewModel,extra:JSONObject=JSONObject()) {
        val result=compose.runOnIdle {
            val native=app.callbackPlayer;val p=model.playback.value
            extra.put("selectedOccurrence",p.selectedOccurrence).put("projectedCount",p.queue.size)
                .put("playerCount",native.mediaItemCount).put("playerIndex",native.currentMediaItemIndex)
                .put("playerPositionMs",native.currentPosition).put("playWhenReady",native.playWhenReady)
                .put("isPlaying",native.isPlaying).put("queueTimingAvailable",projectPlayerClock(p,PlayerClockMode.Queue).totalMs!=null)
        }
        InstrumentationRegistry.getInstrumentation().targetContext.filesDir.resolve("listening-20261105/$label.json").writeText(result.toString(2))
    }

    private fun heldDestination(expire:Boolean) {
        // Each hold uses a source not used by another case, avoiding a cache hit
        // without clearing data or changing the production cache implementation.
        val id=if(expire)72L else 71L
        val (app,model)=start(listOf(row("clock-a1",id),row("clock-b",2),row("clock-a2",id)),1)
        val native=app.callbackPlayer
        val fallback=ProductTransportFixture.server.dispatcher
        val entered=CountDownLatch(1);val release=CountDownLatch(1);val destination=CountDownLatch(1)
        val label=if(expire)"clock-native-expiry" else "clock-native-failure"
        val listener=object:Player.Listener {
            override fun onMediaItemTransition(item:androidx.media3.common.MediaItem?,reason:Int) {if(item?.mediaId=="clock-a2")destination.countDown()}
        }
        ProductTransportFixture.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath=="/media/$id.mp3") {
                    entered.countDown()
                    check(release.await(25,TimeUnit.SECONDS)){"Owned native media hold exceeded its deadline"}
                    if(!expire)return MockResponse.Builder().code(503).build()
                }
                return fallback.dispatch(request)
            }
        }
        // Arm actual source/selection observation first, without a recurring
        // main-looper sampler. Observe mounted semantics after actuation returns.
        compose.runOnIdle {native.addListener(listener);assertFalse(native.playWhenReady)}
        try {
            compose.onNodeWithContentDescription("Whole queue clock").performClick()
            val started=SystemClock.elapsedRealtime()
            compose.onNodeWithTag("player-clock-progress").performSemanticsAction(SemanticsActions.SetProgress){it(.75f)}
            assertTrue("Real target source was not requested",entered.await(5,TimeUnit.SECONDS))
            assertTrue("Native destination was not selected",destination.await(5,TimeUnit.SECONDS))
            compose.onNodeWithText("Seeking").assertIsDisplayed()
            compose.onNodeWithTag("player-clock-progress").assertIsNotEnabled()
            screenshot("$label-pending")
            observation("$label-pending",app,model,JSONObject().put("heldSourceEntered",true).put("pendingRendered",true).put("nativeReceiptSuccessClaimed",false))
            if(!expire)release.countDown()
            compose.waitUntil(15000){compose.onAllNodesWithText("Seek not confirmed. Try again.").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("Seek not confirmed. Try again.").assertIsDisplayed()
            compose.onNodeWithText("Seeking").assertDoesNotExist()
            val elapsed=SystemClock.elapsedRealtime()-started
            if(expire)assertTrue("Native expiry settled before its actual deadline",elapsed>=8000)
            compose.runOnIdle {assertEquals("clock-a2",native.currentMediaItem!!.mediaId);assertFalse(native.playWhenReady);assertFalse(native.isPlaying)}
            screenshot("$label-failed")
            observation(label,app,model,JSONObject().put("elapsedMs",elapsed).put("heldSourceEntered",true).put("pendingAndFailedRendered",true).put("nativeReceiptSuccessClaimed",false))
        }finally {
            release.countDown()
            ProductTransportFixture.server.dispatcher=fallback
            compose.runOnIdle {native.removeListener(listener)}
        }
    }

    @Test fun logical1001NativeQueueKeepsWholeClockInverseAndPlannedFadeSongFallback() {
        val rows=(0 until 1001).map {row("logical-clock-$it",if(it==1000)2 else 1)}
        val (app,model)=start(rows,1000)
        val native=app.callbackPlayer
        compose.runOnIdle {assertEquals(rows.size,native.mediaItemCount);assertEquals(rows.size,model.playback.value.queue.size);assertFalse(native.playWhenReady)}
        compose.onNodeWithContentDescription("Whole queue clock").performClick()
        val total=rows.size*12000L
        compose.runOnIdle {assertEquals(total,projectPlayerClock(model.playback.value,PlayerClockMode.Queue).totalMs)}
        val target=750*12000L+3500
        compose.onNodeWithTag("player-clock-progress").performSemanticsAction(SemanticsActions.SetProgress){it(target.toFloat()/total)}
        compose.waitUntil(20000){compose.runOnIdle {native.currentMediaItem?.mediaId==rows[750].occurrence&&kotlin.math.abs(native.currentPosition-3500)<=250&&!model.playback.value.preparing}}
        compose.onNodeWithText("Seeking").assertDoesNotExist()
        compose.onNodeWithText("Seek not confirmed. Try again.").assertDoesNotExist()
        screenshot("clock-native-logical1001");observation("clock-native-logical1001",app,model,JSONObject().put("nativeCursorReceiptSettled",true))
        val preferences=app.graph.crossfadePreferences
        try {
            compose.runOnIdle {assertTrue(preferences.setSeconds(requireNotNull(preferences.capture()),3){true})}
            compose.waitUntil(5000){model.playback.value.clockAuthority?.spans==null}
            compose.onNodeWithText("Queue clock unavailable").assertIsDisplayed()
            compose.onNodeWithContentDescription("Current song clock").performClick()
            compose.onNodeWithTag("player-clock-time").assertTextEquals("0:03 / 0:12")
            compose.runOnIdle {assertFalse(native.playWhenReady);assertFalse(native.isPlaying);assertEquals(rows[750].occurrence,native.currentMediaItem!!.mediaId)}
            screenshot("clock-native-planned-fade-song");observation("clock-native-planned-fade-song",app,model)
        }finally {compose.runOnIdle {assertTrue(preferences.setSeconds(requireNotNull(preferences.capture()),0){true})}}
    }
}
