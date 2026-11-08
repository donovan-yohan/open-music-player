package com.soundq.android

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.unit.Density
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import com.soundq.designsystem.swipeQueueGeometry
import org.json.JSONArray
import org.json.JSONObject
import soundq.design.generated.SoundQComposeTokens as T
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import com.soundq.android.playback.QueueOrigin
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Ordinary mounted ProductApp Library. Physical haptics/performance are not inferred. */
class LibraryRowRevealJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private val observations=JSONArray()
    private val decisive=JSONObject()
    private fun queueObservation(stage:String,model:ProductViewModel):AcknowledgedQueueObservation {
        var value:AcknowledgedQueueObservation?=null
        InstrumentationRegistry.getInstrumentation().runOnMainSync {value=acknowledgedQueueObservation(model)}
        return checkNotNull(value).also {decisive.put(stage,it.diagnostic)}
    }
    private fun awaitAcknowledgedQueue(stage:String,model:ProductViewModel,size:Int,selected:String?):com.soundq.android.playback.PlaybackProjection {
        var accepted:AcknowledgedQueueObservation?=null
        compose.waitUntil(10000) {
            val value=queueObservation(stage+"-last",model)
            value.readback.acknowledged(size,selected).also {if(it)accepted=value}
        }
        return checkNotNull(accepted).also {decisive.put(stage+"-acknowledged",it.diagnostic)}.projection
    }
    private fun row(title:String)=compose.onNode(hasClickAction() and hasAnyDescendant(hasText(title)) and
        hasAnyDescendant(hasContentDescription("More for $title")),useUnmergedTree=true)
    private fun showRow(title:String):SemanticsNodeInteraction {
        compose.onNode(hasScrollToNodeAction()).performScrollToNode(hasContentDescription("More for $title"))
        compose.onNodeWithContentDescription("More for $title").assertIsDisplayed().assertIsEnabled()
        return row(title).assertIsDisplayed().assertIsEnabled()
    }
    private fun swipeOwner(title:String)=compose.onNode(SemanticsMatcher("stationary queue owner for $title") {
        it.config.getOrNull(SemanticsActions.CustomActions)?.any {action->action.label=="Reveal actions for $title"}==true
    },useUnmergedTree=true)
    private fun phase(title:String,value:String)=swipeOwner(title).assert(hasStateDescription(value))
    /** Full native ProductApp root: browse, bottom navigation and current player together. */
    private fun nativeFrame(stage:String,title:String) {
        val root=row(title).fetchSemanticsNode().root as ViewRootForTest
        compose.runOnIdle {
            val view=root.view
            assertTrue("Native root must have bounded positive raster geometry",view.width>0&&view.height>0&&view.width.toLong()*view.height<=16_000_000L)
            val image=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
            try {
                view.draw(Canvas(image))
                File(compose.activity.filesDir,"swipe-library-$stage.png").outputStream().use {
                    assertTrue(image.compress(Bitmap.CompressFormat.PNG,100,it))
                }
            } finally {image.recycle()}
        }
    }
    private fun observe(stage:String,model:ProductViewModel) {
        val value=model.playback.value
        observations.put(JSONObject().put("stage",stage).put("queue",JSONArray(value.queue.map {it.occurrenceId}))
            .put("selected",value.selectedOccurrence).put("playing",value.isPlaying))
    }
    private fun reveal(title:String) {
        showRow(title).performTouchInput {down(Offset(width*0.7f,center.y));moveBy(Offset(-T.MOTION_ROW_REVEAL.toPx(),0f),delayMillis=300);up()}
    }
    @Test fun ordinaryLibraryRevealManualActionsAndNativeOwnership() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val graph=app.graph
        var primary:Throwable?=null
        var held=false
        var observedModel:ProductViewModel?=null
        try {
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("reveal@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        compose.waitUntil(10000){graph.library.state.value.rows.size==3}
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        observedModel=model
        val title="Fixture 1"
        // A real list drag remains vertical. Horizontal intent does not own this pointer.
        showRow(title).performTouchInput {swipeUp()}
        showRow(title)
        nativeFrame("populated",title)
        val before=model.playback.value
        val writes=ProductTransportFixture.requests.count {it.endsWith("/like")}
        observe("before-gestures",model)
        // Partial and reverse settle closed without invoking any action.
        row(title).performTouchInput {down(Offset(width*0.7f,center.y));moveBy(Offset(-T.MOTION_ROW_REVEAL.toPx()*0.25f,0f),delayMillis=300);up()}
        compose.onNode(hasStateDescription("Actions closed") and hasAnyDescendant(hasText(title)),useUnmergedTree=true).assertExists()
        compose.waitForIdle();assertEquals(writes,ProductTransportFixture.requests.count {it.endsWith("/like")})
        row(title).performTouchInput {down(Offset(width*0.7f,center.y));val travel=T.MOTION_ROW_REVEAL.toPx();moveBy(Offset(-travel,0f),delayMillis=300);moveBy(Offset(travel*0.9f,0f),delayMillis=50);up()}
        compose.waitForIdle();assertEquals(before.queue,model.playback.value.queue)
        // Positive accepted gesture cancellation restores the starting closed state.
        row(title).performTouchInput {down(Offset(width*0.7f,center.y));moveBy(Offset(-T.MOTION_ROW_REVEAL.toPx()*0.8f,0f),delayMillis=200);cancel()}
        compose.waitForIdle();assertEquals(before.queue,model.playback.value.queue)
        // Freeze at actual Animatable completion, not a nominal sleep.
        compose.mainClock.autoAdvance=false
        reveal(title)
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithContentDescription("Like $title",useUnmergedTree=true).assertIsNotEnabled()
        // Synchronize on the instrumentation thread while Compose advances the animation.
        compose.mainClock.autoAdvance=true
        compose.waitForIdle()
        phase(title,"Actions open")
        compose.onNodeWithContentDescription("Like $title",useUnmergedTree=true).assertIsEnabled()
        observe("settled-actions-enabled",model)
        assertEquals(before.queue,model.playback.value.queue)
        // Open front closes. A separate new pointer sequence activates the mounted row.
        row(title).performTouchInput {click(center)}
        compose.waitForIdle();assertEquals(before.queue,model.playback.value.queue)
        row(title).performClick()
        compose.waitUntil(15000){model.playback.value.queue.size==3&&model.playback.value.isPlaying}
        compose.runOnIdle {model.controller.pause()}
        compose.waitUntil(10000){!model.playback.value.isPlaying}
        val paused=model.playback.value
        reveal(title)
        compose.onNodeWithContentDescription("Like $title").performClick()
        compose.waitUntil(10000){graph.library.state.value.rows.first().liked==true&&graph.library.state.value.mutations.values.none {it==com.soundq.android.data.MutationOutcome.Pending}}
        assertEquals(writes+1,ProductTransportFixture.requests.count {it.endsWith("/like")})
        assertEquals(paused.queue,model.playback.value.queue);assertFalse(model.playback.value.isPlaying)
        reveal(title)
        nativeFrame("revealed-tray",title)
        compose.onNodeWithContentDescription("Add $title to listening queue").performClick()
        queueObservation("explicit-add-immediate",model)
        val queued=awaitAcknowledgedQueue("explicit-add",model,paused.queue.size+1,paused.selectedOccurrence)
        assertEquals(paused.selectedOccurrence,queued.selectedOccurrence)
        assertFalse(queued.isPlaying)
        assertEquals(1,queued.queue.count {it.manual&&it.origin==QueueOrigin.Manual})
        assertEquals(queued.queue.size,queued.queue.map {it.occurrenceId}.distinct().size)
        observe("manual-like-and-queue",model)
        showRow(title)
        val bounds=swipeOwner(title).fetchSemanticsNode().boundsInRoot
        val density=Density(compose.activity.resources.displayMetrics.density)
        val (arm,travel)=with(density) {
            val height=bounds.height.toDp()
            val geometry=swipeQueueGeometry(height,true)
            assertTrue(geometry.fits(bounds.width.toDp()))
            geometry.arm.toPx() to geometry.maximum.toPx()
        }
        observations.put(JSONObject().put("stage","measured-geometry").put("bounds",bounds.toString())
            .put("density",density.density).put("armPx",arm).put("travelPx",travel))
        // A held armed pointer cannot enqueue. Retreat before Up disarms it.
        held=true
        swipeOwner(title).performTouchInput {down(Offset(width-1f,center.y));moveBy(Offset(-travel,0f),delayMillis=300)}
        phase(title,"Release to queue")
        compose.onNodeWithContentDescription("Add $title to listening queue",useUnmergedTree=true)
            .assertIsDisplayed().assertIsSelected().assertIsNotEnabled().assert(hasStateDescription("Release to queue"))
        nativeFrame("filled-armed",title)
        assertEquals(queued.queue,model.playback.value.queue);observe("armed-before-retreat",model)
        swipeOwner(title).performTouchInput {moveBy(Offset(travel,0f),delayMillis=100)}
        phase(title,"Revealing actions")
        held=false;swipeOwner(title).performTouchInput {up()}
        compose.waitForIdle();phase(title,"Actions closed")
        assertEquals(queued.queue,model.playback.value.queue);observe("retreat-release-no-queue",model)
        held=true
        swipeOwner(title).performTouchInput {down(Offset(width-1f,center.y));moveBy(Offset(-travel,0f),delayMillis=300)}
        phase(title,"Release to queue");assertEquals(queued.queue,model.playback.value.queue)
        observe("armed-before-cancel",model)
        held=false;swipeOwner(title).performTouchInput {cancel()}
        compose.waitForIdle();phase(title,"Actions closed")
        assertEquals(queued.queue,model.playback.value.queue);observe("armed-cancel-no-queue",model)
        // A new genuine full-left release admits exactly one occurrence, never autoplay.
        held=true
        swipeOwner(title).performTouchInput {down(Offset(width-1f,center.y));moveBy(Offset(-travel,0f),delayMillis=300)}
        phase(title,"Release to queue")
        compose.onNodeWithContentDescription("Add $title to listening queue",useUnmergedTree=true)
            .assertIsDisplayed().assertIsSelected().assertIsNotEnabled().assert(hasStateDescription("Release to queue"))
        assertEquals(queued.queue,model.playback.value.queue);observe("armed-before-up",model)
        held=false;swipeOwner(title).performTouchInput {up()}
        queueObservation("full-left-immediate",model)
        val quick=awaitAcknowledgedQueue("full-left",model,queued.queue.size+1,queued.selectedOccurrence)
        assertEquals(queued.selectedOccurrence,quick.selectedOccurrence);assertFalse(quick.isPlaying)
        assertEquals(2,quick.queue.count {it.manual&&it.trackId==1L})
        compose.waitForIdle();phase(title,"Actions closed")
        nativeFrame("post-release",title)
        assertEquals(queued.queue.size+1,model.playback.value.queue.size)
        assertEquals(quick.queue.size,quick.queue.map {it.occurrenceId}.distinct().size)
        observe("once-after-release-no-autoplay",model)
        // More remains reachable, and a retained capability cannot borrow a renewed query.
        showRow(title)
        compose.onNodeWithContentDescription("More for $title").assertIsDisplayed().assertIsEnabled().performClick()
        compose.onNode(hasText("Add to listening queue") and hasClickAction()).performScrollTo().assertIsDisplayed().assertIsEnabled()
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
        val captured=compose.runOnIdle {graph.library.captureTrack(graph.library.state.value.rows.first())!!}
        compose.runOnIdle {model.refine(graph.library.state.value.query.copy(text="Fixture 2"))}
        compose.waitUntil(10000){graph.library.state.value.query.text=="Fixture 2"&&!graph.library.state.value.loading}
        compose.runOnIdle {assertFalse(model.enqueueLibrary(captured,{true}));assertFalse(model.likeLibrary(captured,{true}))}
        assertEquals(quick.queue,model.playback.value.queue)
        observe("stale-capture-refused",model)
        } catch(error:Throwable) {primary=error;throw error}
        finally {
            fun terminal(action:()->Unit) {
                try {action()} catch(error:Throwable) {primary?.addSuppressed(error) ?: run {primary=error}}
            }
            terminal {
                compose.mainClock.autoAdvance=true
                if(held){held=false;swipeOwner("Fixture 1").performTouchInput {cancel()}}
            }
            terminal {observedModel?.let {queueObservation("terminal",it)}}
            terminal {
                java.io.File(app.filesDir,"library-queue-diagnostic.json").writeText(JSONObject()
                    .put("phases",observations).put("decisive",decisive).put("failure",primary?.javaClass?.simpleName).toString())
            }
            primary?.let {throw it}
        }
    }
}
