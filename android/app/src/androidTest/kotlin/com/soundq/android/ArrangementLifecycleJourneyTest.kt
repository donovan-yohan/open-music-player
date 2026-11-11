package com.soundq.android

import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.timeline.*
import com.soundq.android.product.ProductViewModel
import com.soundq.android.product.timeline.TimelinePanel
import com.soundq.designsystem.SoundQTheme
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.CoroutineContext

/** Actual MainActivity STOP/RESUME with a retained production TimelinePanel.
 * This lane compiles it. The exclusive native owner must execute it. */
class ArrangementLifecycleJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private class HeldDispatcher:CoroutineDispatcher() {
        private val queued=java.util.concurrent.ConcurrentLinkedQueue<Runnable>()
        override fun dispatch(context:CoroutineContext,block:Runnable){queued.add(block)}
        fun drain(){while(true)(queued.poll() ?: return).run()}
    }
    @Test fun unenrolledActivityStopRetiresMountedApplySaveAndGetButNotAcceptedPlayback() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        val graph=app.graph
        graph.session.retire()
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("arrangement-lifetime@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        compose.waitUntil(10000){graph.library.state.value.rows.isNotEmpty()}
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        val account=graph.session.capture()!!
        assertFalse("This regression requires no local-unlock enrollment",graph.localUnlock.state.value.enrolled)
        val track=graph.library.state.value.rows.first()
        compose.runOnIdle {graph.rememberTracks(listOf(track));model.controller.playContext(listOf(track),0,true);model.controller.pause()}
        compose.waitUntil(10000){model.playback.value.queue.size==1&&model.timeline.value.document.clips.size==1}
        val latest=AtomicReference<()->Boolean>()
        val mounted=java.util.concurrent.atomic.AtomicBoolean(false)
        val identity=AtomicReference<Any>()
        compose.activityRule.scenario.onActivity {activity->activity.setContent {SoundQTheme {
            val retained=remember {Any()}
            DisposableEffect(Unit){mounted.set(true);identity.set(retained);onDispose{mounted.set(false)}}
            Column {Text("Retained arrangement lifetime fixture");TimelinePanel(model,null,{}, {true},{latest.set(it)})}
        }}}
        compose.waitForIdle()
        val held=latest.get();assertTrue(held());val retained=identity.get()
        val document=model.timeline.value.document
        val request=graph.timeline.captureAudition(account,document,held)!!
        assertTrue(graph.timeline.installAudition(request,account,document){})
        val dispatcher=HeldDispatcher();val parent=Job();val jobs=CoroutineScope(parent)
        val original=ProductTransportFixture.server.dispatcher
        val wire=java.util.concurrent.atomic.AtomicInteger(0)
        ProductTransportFixture.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(r:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
            if(r.url.encodedPath.startsWith("/api/v1/mix-plans"))wire.incrementAndGet()
            return original.dispatch(r)
        }}
        try {
            val save=graph.arrangementSave.save(account,document,"Arrangement",held)!!
            val job=graph.arrangementSave.schedule(jobs,save,dispatcher)!!
            compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
            assertTrue(mounted.get());assertSame(retained,identity.get());assertTrue(graph.session.current(account));assertFalse(held())
            compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
            compose.waitForIdle();assertTrue(latest.get()());assertFalse("Old request cannot revive",held())
            var plays=0
            assertFalse(graph.timeline.completeAudition(request,account,document){plays++});assertEquals(0,plays)
            // Still never entered: exact scheduled cancellation must release, not
            // strand busy or invent uncertain remote creation.
            job.cancel();dispatcher.drain();assertTrue(job.isCompleted)
            assertFalse(graph.arrangementSave.state.value.busy);assertFalse(graph.arrangementSave.state.value.blocked)
            assertEquals(0,wire.get())
            // An uncancelled queued Save must also refuse after real STOP even
            // though its composition scope survived. Entered writes stay blocked
            // conservatively; lifecycle loss is never evidence of remote failure.
            val stoppedSave=graph.arrangementSave.save(account,document,"Arrangement",latest.get())!!
            val stoppedJob=graph.arrangementSave.schedule(jobs,stoppedSave,dispatcher)!!
            compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
            dispatcher.drain();assertTrue(stoppedJob.isCompleted)
            assertFalse(graph.arrangementSave.state.value.busy);assertTrue(graph.arrangementSave.state.value.blocked)
            assertEquals(0,wire.get())
            compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED);compose.waitForIdle()
            val get=graph.arrangementSave.readback(account,java.util.UUID.randomUUID().toString(),document,latest.get())!!
            val read=graph.arrangementSave.schedule(jobs,get,dispatcher)!!
            compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
            // Unlike the Save cancellation control, execute GET after STOP. Native
            // lifecycle admission refuses dispatch but still clears its marker.
            dispatcher.drain();assertTrue(read.isCompleted);assertFalse(graph.arrangementSave.state.value.busy)
            assertEquals(0,wire.get())
            compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED);compose.waitForIdle()
            val fresh=latest.get();assertTrue(fresh())
            val accepted=graph.timeline.captureAudition(account,document,fresh)!!
            assertTrue(graph.timeline.installAudition(accepted,account,document){})
            assertTrue(graph.timeline.completeAudition(accepted,account,document){plays++})
            compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
            assertEquals("Admission cleanup must not undo accepted playback",1,plays)
            assertTrue(mounted.get());assertSame(retained,identity.get())
        } finally {
            parent.cancel();dispatcher.drain()
            compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
            ProductTransportFixture.server.dispatcher=original
            graph.session.retire()
        }
    }
}
