package com.soundq.android

import android.graphics.Bitmap
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.window.DialogWindowProvider
import androidx.lifecycle.ViewModelProvider
import androidx.media3.common.ForwardingPlayer
import androidx.media3.session.MediaSession
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import com.soundq.android.data.timeline.EditKind
import com.soundq.android.data.timeline.TimelineEdit
import com.soundq.android.performance.WindowInteractionRecorder

import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Explicitly authorized live read/playback. Uses saved native credentials, never a fixture login. */
class ProductionListeningJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()

    @Test fun savedAccountCompactEditorPlaysOverlapAndZoomsOnNativeOutput() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        assertEquals("true",InstrumentationRegistry.getArguments().getString("soundqAuthorizedLivePlayback"))
        val authorizedEndpoint=checkNotNull(InstrumentationRegistry.getArguments().getString("soundqAuthorizedApiBase"))
        assertEquals(authorizedEndpoint,BuildConfig.OMP_API_BASE_URL)
        val app=instrumentation.targetContext.applicationContext
        assertEquals(SoundQApplication::class.java,app.javaClass)
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.waitUntil(15000){model.library.value.rows.size>=2}
        val title=compose.runOnIdle {model.library.value.rows.first().title}
        val row=hasClickAction() and hasAnyDescendant(hasText(title)) and hasAnyDescendant(hasContentDescription("More for $title"))
        compose.onNode(row,useUnmergedTree=true).performScrollTo().performClick()
        var restoreEdit=false
        var originalPlacement=0L
        var editedOccurrence:String?=null
        try {
            compose.waitUntil(30000){model.playback.value.isPlaying&&model.playback.value.positionMs>300}
            val start=compose.runOnIdle {model.playback.value.positionMs}
            compose.waitUntil(10000){model.playback.value.isPlaying&&model.playback.value.positionMs>start+250}
            val native=compose.runOnIdle {
                val sessions=MediaSession::class.java.getDeclaredField("SESSION_ID_TO_SESSION_MAP").apply {isAccessible=true}.get(null) as Map<*,*>
                var player=(sessions.values.single() as MediaSession).player
                var depth=0
                while(player is ForwardingPlayer){check(depth++<8);player=player.wrappedPlayer}
                assertEquals("com.soundq.android.playback.nativeengine.NativeCallbackPlayer",player.javaClass.name)
                org.json.JSONObject(player.javaClass.getDeclaredMethod("nativeDiagnostics").apply {isAccessible=true}.invoke(player) as String)
            }
            assertEquals(0,native.getInt("error"))
            assertTrue(native.getLong("renderedFrames")>0)
            assertTrue(native.getLong("nonSilentCallbacks")>0)
            compose.runOnIdle {model.controller.pause()}
            compose.waitUntil(10000){!model.playback.value.isPlaying&&!model.playback.value.preparing}
            // Default focused cohort and explicit ordinary Library-context cohort.
            // Both retain full source extents; neither manually trims around EOF.
            val libraryContext=InstrumentationRegistry.getArguments().getString("soundqUseLibraryContext")=="true"
            if(!libraryContext) {
                compose.runOnIdle {model.controller.playContext(model.library.value.rows.take(2),0)}
                compose.waitUntil(30000){model.playback.value.queue.size==2&&model.playback.value.isPlaying}
                compose.runOnIdle {model.controller.pause()}
                compose.waitUntil(10000){!model.playback.value.isPlaying&&!model.playback.value.preparing}
            }
            compose.onNodeWithContentDescription("Open listening queue").performClick()
            compose.onNodeWithText("Waveforms").performClick()
            val ids=compose.runOnIdle {model.playback.value.queue.take(2).map {it.occurrenceId}}
            assertEquals(2,ids.size)
            compose.waitUntil(30000){ids.all {id->
                val nodes=compose.onAllNodesWithContentDescription("Waveform $id",useUnmergedTree=true).fetchSemanticsNodes()
                nodes.size==1&&nodes.single().config.getOrNull(SemanticsProperties.StateDescription)?.startsWith("Loaded ·")==true
            }}
            val lanes=ids.map {id->compose.onNodeWithContentDescription("Waveform $id").assertIsDisplayed().fetchSemanticsNode()}
            val density=compose.activity.resources.displayMetrics.density
            lanes.forEach {assertEquals(96*density,it.boundsInRoot.height,1f)}
            assertEquals(lanes[0].boundsInRoot.bottom,lanes[1].boundsInRoot.top,1f)
            val root=lanes.first().root as ViewRootForTest
            val original=compose.runOnIdle {model.timeline.value.document}
            val incoming=original.clips[1]
            originalPlacement=incoming.globalStartMs;editedOccurrence=incoming.occurrence
            compose.runOnIdle {
                assertTrue(model.graph.timeline.commit(TimelineEdit(original.revision,incoming,EditKind.Placement,original.clips[0].globalStartMs)){true})
                restoreEdit=true
            }
            compose.waitForIdle()

            compose.onNode(hasContentDescription("Play") and hasAnyAncestor(isDialog())).assertIsEnabled().performClick()
            fun diagnostics():org.json.JSONObject=compose.runOnIdle {
                val sessions=MediaSession::class.java.getDeclaredField("SESSION_ID_TO_SESSION_MAP").apply {isAccessible=true}.get(null) as Map<*,*>
                var player=(sessions.values.single() as MediaSession).player
                while(player is ForwardingPlayer)player=player.wrappedPlayer
                org.json.JSONObject(player.javaClass.getDeclaredMethod("nativeDiagnostics").apply {isAccessible=true}.invoke(player) as String)
            }
            try {
                compose.waitUntil(30000){model.playback.value.arrangement!=null&&model.playback.value.isPlaying&&diagnostics().let {j->
                    val decks=j.getJSONArray("decks")
                    j.getBoolean("schedulePlaying")&&j.getInt("scheduleError")==0&&(0 until decks.length()).count {decks.getJSONObject(it).getBoolean("playing")}>=2
                }}
            } finally {
                val phase=org.json.JSONObject().put("arrangementAccepted",model.playback.value.arrangement!=null)
                    .put("playing",model.playback.value.isPlaying).put("preparing",model.playback.value.preparing)
                    .put("sourceCount",original.clips.size).put("native",diagnostics())
                    .put("visibleRefusal",compose.onAllNodesWithText("Could not play arrangement").fetchSemanticsNodes().isNotEmpty())
                File(instrumentation.targetContext.filesDir,"production-listening").apply {mkdirs()}.resolve("apply-phase.json").writeText(phase.toString(2))
            }
            val overlap=diagnostics()
            val frame=overlap.getLong("globalFrame")
            compose.waitUntil(10000){diagnostics().getLong("globalFrame")>frame+256}
            assertTrue(overlap.getLong("nonSilentCallbacks")>0)
            compose.onNode(hasContentDescription("Pause") and hasAnyAncestor(isDialog())).performClick()
            compose.waitUntil(10000){!model.playback.value.isPlaying&&!diagnostics().getBoolean("schedulePlaying")}
            fun visibleRange():String=compose.onAllNodes(SemanticsMatcher("Visible timeline range"){node->node.config.getOrNull(SemanticsProperties.Text)?.any {it.text.matches(Regex("\\d+:\\d{2}–\\d+:\\d{2}"))}==true},useUnmergedTree=true).fetchSemanticsNodes().single().config[SemanticsProperties.Text].single().text
            val beforeZoom=visibleRange()
            var recorder:WindowInteractionRecorder?=null
            compose.runOnIdle {
                var parent:android.view.ViewParent?=root.view.parent
                while(parent!=null&&parent !is DialogWindowProvider)parent=parent.parent
                val window=(parent as? DialogWindowProvider)?.window ?: error("Queue dialog window unavailable")
                recorder=WindowInteractionRecorder(window).also {it.start()}
            }
            try {
                repeat(3){compose.onNodeWithContentDescription("Zoom in").performClick();compose.waitForIdle()}
                assertNotEquals("Real viewport must zoom",beforeZoom,visibleRange())
                repeat(3){compose.onNodeWithContentDescription("Zoom out").performClick();compose.waitForIdle()}
                assertEquals(beforeZoom,visibleRange())
                compose.onNodeWithContentDescription("Waveform ${ids.first()}").performTouchInput {
                    down(0,Offset(width*0.25f,height*0.8f));down(1,Offset(width*0.45f,height*0.8f))
                    moveTo(0,Offset(width*0.15f,height*0.8f));moveTo(1,Offset(width*0.55f,height*0.8f))
                    up(0);up(1)
                }
                compose.waitForIdle()
                assertNotEquals("Two-pointer gesture must change viewport",beforeZoom,visibleRange())
            } finally {compose.runOnIdle {
                val output=File(instrumentation.targetContext.filesDir,"production-listening").apply {mkdirs()}
                recorder?.write(File(output,"zoom-window.json"));recorder?.close()
            }}
            compose.runOnIdle {
                assertTrue(compose.activity.window.attributes.flags and android.view.WindowManager.LayoutParams.FLAG_SECURE==0)
                val view=root.view
                val bitmap=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
                try {
                    view.draw(android.graphics.Canvas(bitmap))
                    val output=File(instrumentation.targetContext.filesDir,"production-listening").apply {mkdirs()}
                    File(output,"waveforms.png").outputStream().use {assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG,100,it))}
                    val receipt=org.json.JSONObject().put("savedNativeAccount",true).put("productionEndpoint",true)
                        .put("nativePlayer",true).put("renderedFrames",native.getLong("renderedFrames"))
                        .put("nonSilentCallbacks",native.getLong("nonSilentCallbacks")).put("advancingPosition",true)
                        .put("loadedVisibleWaveforms",2).put("compactRowsDp",96).put("overlapNativeDecks",2).put("arrangementSourceCount",original.clips.size).put("ordinaryLibraryContext",libraryContext)
                        .put("overlapGlobalClockAdvanced",true).put("overlapNonSilentCallbacks",overlap.getLong("nonSilentCallbacks"))
                        .put("buttonZoomRoundTrip",true).put("twoPointerZoomChangedViewport",true).put("pausedAtCompletion",!model.playback.value.isPlaying)
                    File(output,"result.json").writeText(receipt.toString(2))
                } finally {bitmap.recycle()}
            }
        } finally {
            compose.runOnIdle {model.controller.pause()}
            if(restoreEdit) {
                compose.runOnIdle {if(model.playback.value.arrangement!=null)model.controller.returnToSources()}
                compose.waitUntil(15000){model.playback.value.arrangement==null}
                compose.runOnIdle {
                    val current=model.timeline.value.document
                    val clip=current.clips.single {it.occurrence==editedOccurrence}
                    assertTrue(model.graph.timeline.commit(TimelineEdit(current.revision,clip,EditKind.Placement,originalPlacement)){true})
                }
            }
        }
    }
}
