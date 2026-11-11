package com.soundq.android

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Real Activity queue -> captured route -> actual controller -> fixture-backed Media3 service. */
class QueueReorderJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun nativeDragPreservesPreviewThenInsertsAndUndoStaysPaused() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("queue-synthetic@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.waitUntil(10000){app.graph.session.capture()!=null&&app.graph.library.state.value.rows.size>=3}
        val libraryTrack=hasClickAction() and hasAnyDescendant(hasText("Fixture 1")) and hasAnyDescendant(hasContentDescription("More for Fixture 1"))
        compose.onNode(libraryTrack,useUnmergedTree=true).performClick()
        compose.waitUntil(15000){model.playback.value.queue.size>=3&&model.playback.value.canPlay}
        compose.runOnIdle {model.controller.pause()}
        compose.onNodeWithContentDescription("Open listening queue").performClick()
        compose.showSourceListeningQueue()
        val original=compose.runOnIdle {model.playback.value}
        val order=original.queue.map {it.occurrenceId}
        // Observe the app's actual MediaController, not a reducer or a replacement route.
        // Metadata/source refreshes can repeat a timeline with the same order; retain
        // occurrence-order transitions independently from those non-reorder callbacks.
        val controller=compose.runOnIdle {
            model.controller.javaClass.getDeclaredField("controller").apply {isAccessible=true}
                .get(model.controller) as androidx.media3.session.MediaController
        }
        val transitions=mutableListOf<List<String>>()
        var observed=order
        val listener=object:androidx.media3.common.Player.Listener {
            override fun onTimelineChanged(timeline:androidx.media3.common.Timeline,reason:Int) {
                val next=(0 until controller.mediaItemCount).map {controller.getMediaItemAt(it).mediaId}
                if(next!=observed) {transitions.add(next);observed=next}
            }
        }
        compose.runOnIdle {controller.addListener(listener)}
        try {
            val first=compose.onNodeWithContentDescription("Reorder Fixture 1")
            val third=compose.onNodeWithContentDescription("Reorder Fixture 3")
            val from=first.fetchSemanticsNode().boundsInRoot
            val to=third.fetchSemanticsNode().boundsInRoot
            val listBounds=compose.onNode(hasScrollToNodeAction() and hasAnyDescendant(hasContentDescription("Reorder Fixture 1")),useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
            val nativeRoot=first.fetchSemanticsNode().root as ViewRootForTest
            val rowHeight=(to.center.y-from.center.y)/2f
            val ruleYs=(0..2).map {index->(from.center.y+rowHeight*(index+.5f)-2).toInt()}
            var border:Int?=null
            fun gridFrame(stage:String) {
                compose.runOnIdle {
                    val view=nativeRoot.view
                    val bitmap=android.graphics.Bitmap.createBitmap(view.width,view.height,android.graphics.Bitmap.Config.ARGB_8888)
                    try {
                        view.draw(android.graphics.Canvas(bitmap))
                        java.io.File(compose.activity.filesDir,"queue-grid-$stage.png").outputStream().use {assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it))}
                        val left=kotlin.math.ceil(listBounds.left).toInt();val right=kotlin.math.floor(listBounds.right).toInt()
                        val ink=border ?: bitmap.getPixel((left+right)/2,ruleYs.first()).also {border=it}
                        for(y in ruleYs)for(x in left until right)assertEquals("$stage lost stationary queue border at ($x,$y)",ink,bitmap.getPixel(x,y))
                    } finally {bitmap.recycle()}
                }
            }
            compose.mainClock.autoAdvance=false
            gridFrame("before-drag")
            first.performTouchInput {down(center);moveBy(Offset(0f,to.center.y-from.center.y+to.height/2))}
            repeat(3) {compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
            first.assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.StateDescription,"Moving to position 3"))
            val previewTop=first.fetchSemanticsNode().boundsInRoot.top
            assertTrue("Native lifted row must pass the insertion target before release",previewTop>to.bottom-from.height+1f)
            gridFrame("lifted")
            android.util.Log.i("QueueReorderJourney","admitted Moving3 previewTop=$previewTop targetTop=${to.bottom-from.height} original=$order")
            compose.runOnIdle {
                assertEquals(order,model.playback.value.queue.map {it.occurrenceId})
                assertEquals(original.selectedOccurrence,model.playback.value.selectedOccurrence)
                assertFalse(model.playback.value.isPlaying)
                assertTrue("Preview must not publish an order transition",transitions.isEmpty())
            }
            first.performTouchInput {up()};compose.mainClock.advanceTimeByFrame()
            compose.waitForIdle();gridFrame("settling-start")
            repeat(3){compose.mainClock.advanceTimeByFrame();compose.waitForIdle();gridFrame("settling-$it")}
            compose.runOnIdle {assertEquals(order,model.playback.value.queue.map {it.occurrenceId})}
            android.util.Log.i("QueueReorderJourney","settle boundary ${model.playback.value}")
            compose.mainClock.advanceTimeBy(1000);compose.mainClock.autoAdvance=true
            val inserted=order.toMutableList().apply {add(2,removeAt(0))}
            // Observe timeline/projection and Undo independently within the original one deadline.
            var loggedInsertion=false
            compose.waitUntil(10000){
                val projection=model.playback.value
                val ordered=projection.queue.map {it.occurrenceId}==inserted
                if(ordered&&!loggedInsertion) {android.util.Log.i("QueueReorderJourney","inserted projection $projection");loggedInsertion=true}
                ordered&&projection.canUndo
            }
            android.util.Log.i("QueueReorderJourney","Undo available ${model.playback.value}")
            gridFrame("committed")
            assertEquals(original.selectedOccurrence,model.playback.value.selectedOccurrence)
            assertFalse(model.playback.value.isPlaying)
            compose.runOnIdle {
                assertEquals(listOf(inserted),transitions)
                assertEquals(inserted,(0 until controller.mediaItemCount).map {controller.getMediaItemAt(it).mediaId})
                assertEquals(original.selectedOccurrence,controller.currentMediaItem?.mediaId)
                assertFalse(controller.isPlaying);assertFalse(controller.playWhenReady)
            }
            first.assertIsFocused()
            compose.onNodeWithContentDescription("Queue actions").performClick()
            compose.onNodeWithText("Undo queue change").performClick()
            compose.waitUntil(10000){model.playback.value.queue.map {it.occurrenceId}==order&&!model.playback.value.canUndo}
            compose.runOnIdle {
                assertFalse(model.playback.value.isPlaying)
                assertEquals(original.selectedOccurrence,model.playback.value.selectedOccurrence)
                assertEquals("Only insertion then Undo may change the native occurrence order",listOf(inserted,order),transitions)
                assertEquals(order,(0 until controller.mediaItemCount).map {controller.getMediaItemAt(it).mediaId})
                assertEquals(original.selectedOccurrence,controller.currentMediaItem?.mediaId)
                assertFalse(controller.isPlaying);assertFalse(controller.playWhenReady)
                android.util.Log.i("QueueReorderJourney","verified insertion and paused Undo transitions=$transitions projection=${model.playback.value}")
            }
        } finally {compose.runOnIdle {controller.removeListener(listener)}}
    }
}
