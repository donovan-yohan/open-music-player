package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.Density
import com.soundq.designsystem.swipeQueueGeometry
import org.json.JSONArray
import org.json.JSONObject
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import android.content.ComponentName
import com.soundq.android.data.offline.DownloadStatus
import com.soundq.android.data.preferences.SwipeQueue
import com.soundq.android.playback.*
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.TimeUnit

/** Mounted completed device-copy queue. No acoustic/performance claim. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class DownloadsQueueJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private fun click(label:String){
        val target=hasText(label) and hasClickAction()
        compose.onNode(target).performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()
    }
    @Test fun mountedCompletedRowFullLeftAndExplicitQueueStayLocalAndDoNotStart() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val graph=(context.applicationContext as FixtureApplication).graph
        val phases=JSONArray()
        var primary:Throwable?=null
        var held=false
        var heldOwner:SemanticsNodeInteraction?=null
        try {
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("synthetic-queue@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        click("Sign in")
        compose.waitUntil(10000){graph.library.state.value.rows.size==3}
        val model=compose.runOnIdle{ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.waitUntil(10000){model.playback.value.connection==PlaybackProjection.Connection.Connected}
        compose.onNode(hasScrollToNodeAction()).performScrollToNode(hasContentDescription("More for Fixture 1"))
        compose.onNodeWithContentDescription("More for Fixture 1").assertIsDisplayed().assertIsEnabled().performClick()
        click("Download to device");click("Open Downloads")
        compose.waitUntil(15000){model.downloads.value.rows.singleOrNull()?.status==DownloadStatus.Complete}
        val completed=model.downloads.value.rows.single()
        val completedScope=graph.session.capture()!!
        assertTrue(graph.downloads.validateComplete(completedScope,completed))
        phases.put(JSONObject().put("stage","completed-owned-local-artifact").put("bytes",completed.bytes))
        assertTrue(graph.swipeQueuePreferences.setMode(graph.swipeQueuePreferences.capture()!!,SwipeQueue.PlayNext){true})
        val future=compose.runOnIdle{MediaController.Builder(context,SessionToken(context,ComponentName(context,SoundQLibraryService::class.java))).buildAsync()}
        val controller=future.get(10,TimeUnit.SECONDS)
        try {
            // Empty signed-in playback permits independent Connect registration. Drain and
            // explicitly disconnect that owner before measuring device-queue-only egress.
            kotlinx.coroutines.runBlocking(kotlinx.coroutines.Dispatchers.IO){graph.presence.disconnect()}
            val before=ProductTransportFixture.requests.size
            val shortcut=SemanticsMatcher("Downloads queue action") {node->node.config.getOrNull(SemanticsActions.CustomActions)?.any{it.label=="Add Fixture 1 to listening queue"}==true}
            compose.onNode(hasScrollToNodeAction()).performScrollToNode(shortcut)
            val owner=compose.onNode(shortcut).assertIsDisplayed().assertIsEnabled()
            heldOwner=owner
            val bounds=owner.fetchSemanticsNode().boundsInRoot
            val density=Density(compose.activity.resources.displayMetrics.density)
            val travel=with(density) {
                val height=bounds.height.toDp()
                val geometry=swipeQueueGeometry(height,false)
                assertTrue(geometry.fits(bounds.width.toDp()))
                geometry.maximum.toPx()
            }
            phases.put(JSONObject().put("stage","measured-full-left").put("bounds",bounds.toString())
                .put("density",density.density).put("travelPx",travel))
            val initial=model.playback.value
            held=true
            owner.performTouchInput {down(Offset(width-1f,center.y));moveBy(Offset(-travel,0f),delayMillis=300)}
            owner.assert(hasStateDescription("Release to queue"))
            compose.onNodeWithContentDescription("Add Fixture 1 to listening queue",useUnmergedTree=true)
                .assertIsDisplayed().assertIsSelected().assertIsNotEnabled().assert(hasStateDescription("Release to queue"))
            assertEquals(initial.queue,model.playback.value.queue)
            phases.put(JSONObject().put("stage","armed-queue-unchanged-before-up").put("queueSize",initial.queue.size))
            held=false;owner.performTouchInput {up()}
            compose.waitUntil(10000){model.playback.value.queue.size==1}
            compose.runOnIdle {
                assertFalse(controller.playWhenReady);assertFalse(controller.isPlaying);assertEquals(Player.STATE_IDLE,controller.playbackState)
                assertTrue(controller.getMediaItemAt(0).mediaMetadata.extras!!.getBoolean("localOnly"));assertNull(controller.getMediaItemAt(0).mediaMetadata.artworkUri)
            }
            phases.put(JSONObject().put("stage","released-local-only-idle").put("queueSize",model.playback.value.queue.size))
            compose.onNode(hasScrollToNodeAction()).performScrollToNode(hasContentDescription("More for Fixture 1"))
            compose.onNodeWithContentDescription("More for Fixture 1").assertIsDisplayed().assertIsEnabled().performClick()
            click("Queue")
            compose.waitUntil(10000){model.playback.value.queue.size==2}
            compose.runOnIdle {
                assertNotEquals(controller.getMediaItemAt(0).mediaId,controller.getMediaItemAt(1).mediaId)
                assertFalse(controller.playWhenReady);assertEquals(0L,controller.currentPosition)
                for(i in 0..1)assertTrue(controller.getMediaItemAt(i).mediaMetadata.extras!!.getBoolean("localOnly"))
            }
            assertEquals(2,model.playback.value.queue.map {it.occurrenceId}.distinct().size)
            phases.put(JSONObject().put("stage","explicit-queue-distinct-local-only-no-autoplay").put("queueSize",model.playback.value.queue.size))
            // Exact source terminal refusal after admitted queue loses its artifact.
            val scope=graph.session.capture()!!;val row=graph.downloads.state.value.rows.single()
            assertTrue(graph.downloads.remove(scope,listOf(row)))
            val uri=android.net.Uri.parse("soundq://track/1/compiled-queue-loss")
            val grants=java.util.concurrent.ConcurrentHashMap<String,MediaGrant>()
            grants[uri.toString()]=MediaGrant(scope,row.track.id,true)
            val source=SignedAudioDataSource(graph,grants)
            try {assertTrue(runCatching {source.open(androidx.media3.datasource.DataSpec.Builder().setUri(uri).build())}.exceptionOrNull() is com.soundq.android.data.SafeFailure)}finally{source.close()}
            assertTrue("local queue must send no remote requests: ${ProductTransportFixture.requests.drop(before)}",ProductTransportFixture.requests.drop(before).isEmpty())
            phases.put(JSONObject().put("stage","artifact-loss-terminal-refusal-zero-remote-requests"))
        } finally {compose.runOnIdle{controller.release()}}
        } catch(error:Throwable) {primary=error;throw error}
        finally {
            try {if(held){held=false;heldOwner?.performTouchInput {cancel()}}}
            catch(error:Throwable) {if(primary!=null)primary.addSuppressed(error)else {primary=error;throw error}}
            finally {
                try {java.io.File(context.filesDir,"downloads-queue-diagnostic.json").writeText(JSONObject().put("phases",phases).put("failure",primary?.toString()).toString())}
                catch(error:Throwable) {if(primary!=null)primary.addSuppressed(error)else throw error}
            }
        }
    }
}
