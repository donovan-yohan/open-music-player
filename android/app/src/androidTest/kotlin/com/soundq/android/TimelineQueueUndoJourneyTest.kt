package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.timeline.*
import com.soundq.android.product.ProductViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Real mounted queue remove/Undo and persisted feature owner. Compiled only, no runtime claim. */
class TimelineQueueUndoJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun mountedQueueUndoRestoresExactEditedOccurrenceThenNextSaveReloadsItsTiming() {
        val graph=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication).graph
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("timeline-queue-synthetic@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.waitUntil(10000){graph.session.capture()!=null&&graph.library.state.value.rows.size>=2}
        compose.runOnIdle {
            val rows=graph.library.state.value.rows.take(2)
            graph.rememberTracks(rows);model.controller.playContext(rows,0);model.controller.pause()
        }
        compose.waitUntil(10000){model.playback.value.queue.size==2&&graph.timeline.state.value.document.clips.size==2}
        val order=compose.runOnIdle {model.playback.value.queue.map {it.occurrenceId}}
        fun edit(id:String,kind:EditKind,value:Long)=runBlocking(Dispatchers.IO) {
            val d=graph.timeline.state.value.document
            assertTrue(graph.timeline.commit(TimelineEdit(d.revision,d.clips.single {it.occurrence==id},kind,value)){true})
        }
        edit(order.last(),EditKind.TrimIn,2000);edit(order.last(),EditKind.TrimOut,8000);edit(order.last(),EditKind.Placement,3000)
        val accepted=graph.timeline.state.value.document.clips.last()
        compose.onNodeWithContentDescription("Open listening queue").performClick()
        compose.onNodeWithText("Waveforms").performClick()
        compose.onNodeWithContentDescription("Waveform ${order.last()}").assertExists()
        compose.onNode(hasContentDescription("More for Fixture 2") and hasAnyAncestor(isDialog())).performClick()
        compose.onNodeWithText("Remove from queue").performClick()
        compose.waitUntil(10000){model.playback.value.queue.map {it.occurrenceId}==order.take(1)&&graph.timeline.state.value.document.clips.map {it.occurrence}==order.take(1)}
        compose.onNodeWithContentDescription("Queue actions").performClick()
        compose.onNodeWithText("Undo queue change").performClick()
        compose.waitUntil(10000){model.playback.value.queue.map {it.occurrenceId}==order&&graph.timeline.state.value.document.clips.map {it.occurrence}==order}
        assertEquals(accepted,graph.timeline.state.value.document.clips.last())
        assertFalse(model.playback.value.isPlaying)
        edit(order.first(),EditKind.TrimOut,9000)
        val scope=graph.session.capture()!!
        val sources=model.playback.value.queue.map {TimelineSource(it.occurrenceId,it.trackId,it.title,it.durationMs,if(it.manual)QueueSegment.Manual else QueueSegment.Context)}
        runBlocking(Dispatchers.IO) {
            val reloaded=TimelineRepository(graph.session,java.io.File(graph.directory,"timeline")){_,_,_,_->error("No analysis")}
            reloaded.observe(scope,sources)
            assertEquals(accepted,reloaded.state.value.document.clips.last())
        }
    }
}
