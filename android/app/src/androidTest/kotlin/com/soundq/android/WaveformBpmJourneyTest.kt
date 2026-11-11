package com.soundq.android

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.WindowManager
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.media3.common.Player
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.TrackId
import com.soundq.android.data.timeline.*
import com.soundq.android.playback.*
import com.soundq.android.playback.nativeengine.NativeCallbackPlayer
import com.soundq.android.product.ProductViewModel
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs

/** Normal phone Queue/Waveforms -> numeric BPM -> Auto -> ordinary Play. No repository setup edits. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class WaveformBpmJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private fun click(text:String)=compose.onNode(hasText(text) and hasClickAction()).performScrollTo().performClick()
    private fun field(label:String)=compose.onNode(hasText(label) and hasSetTextAction())
    private fun playbackInput():SemanticsNodeInteraction {
        if(compose.onAllNodesWithContentDescription("Type BPM").fetchSemanticsNodes().isEmpty())
            compose.onNodeWithTag("precision-bpm-surface").performClick()
        return compose.onNodeWithContentDescription("Type BPM")
    }
    private fun queuePlay()=compose.onNode(hasContentDescription("Play") and hasAnyAncestor(isDialog()))
    private fun auto()=compose.onNodeWithContentDescription("Auto BPM crossfade")
    private fun bpm(title:String)=compose.onNodeWithContentDescription("More for $title")

    @Test fun generatedAnalysisNumericBpmAutoOnOffSavePlayProducesRealKeylockReceipts() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val app=instrumentation.targetContext.applicationContext as WaveformBpmFixtureApplication
        val graph=app.graph
        val evidence=JSONObject().put("fixture","generated 12-second WAV; generated analysis suggestions, no authored override")
        var primary:Throwable?=null
        try {
            app.sourceAnalysis.forEach {(id,raw)->
                val wave=AnalysisWaveformJson.parse(Json.parseToJsonElement(raw).jsonObject,TrackId(id),12000)
                assertNull(wave.tempoTiming);assertNull(wave.phaseTiming);assertNotNull(wave.suggestedBpm)
            }
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("bpm-mobile@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onNodeWithContentDescription("Password").performImeAction()
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            compose.waitUntil(10000){model.library.value.rows.size==2}
            val facts=model.library.value.analysis.toMap()
            compose.onNode(hasText("Tempo 1") and hasClickAction() and hasAnyDescendant(hasContentDescription("More for Tempo 1"))).performClick()
            compose.waitUntil(15000){app.callbackCreated&&model.playback.value.isPlaying&&model.timeline.value.document.clips.size==2}
            compose.onNodeWithContentDescription("Pause").performClick()
            compose.onNodeWithContentDescription("Open listening queue").performClick()
            compose.onNodeWithText("Waveforms").performClick()
            auto().assertIsDisplayed().assertIsOff()
            compose.onNodeWithText("Transition controls").assertDoesNotExist()
            compose.waitUntil(10000){model.graph.timeline.tempoSource(model.timeline.value.document.clips.first())?.sourceBpm==120.0}
            compose.openWaveformBpm("Tempo 1")
            compose.waitUntil(10000){compose.onAllNodesWithTag("precision-bpm-surface").fetchSemanticsNodes().isNotEmpty()}
            field("Beat anchor milliseconds").assertDoesNotExist()
            compose.onNodeWithText("Confirm source timing").assertDoesNotExist()
            compose.onNodeWithText("Confirm source BPM").assertDoesNotExist()
            compose.onNodeWithText("Original: 120 BPM").assertIsDisplayed()
            val untouched=model.timeline.value.document
            playbackInput().performTextReplacement("900")
            compose.onNodeWithText("Save BPM").assertIsNotEnabled()
            compose.onNodeWithText("Enter a BPM from",substring=true).assertExists()
            assertEquals(untouched,model.timeline.value.document)
            compose.onNodeWithContentDescription("Reset to original 120.00 BPM").performClick()
            compose.waitUntil(3000) { compose.onAllNodesWithTag("precision-bpm-surface").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithTag("precision-bpm-surface").assertTextContains("120.00")
            playbackInput().performTextReplacement("121.25")
            raster("bpm-decimal-sheet",compose.onNodeWithContentDescription("Type BPM"))
            click("Save BPM")
            compose.waitUntil(10000){model.timeline.value.document.playbackTempos.singleOrNull()?.playbackBpm==121.25}
            val constant=model.timeline.value.document
            assertTrue(constant.tempoRamps.isEmpty())
            assertEquals(121.25,constant.nativeArrangementPayload().tempo!![1],0.0)
            assertEquals(120.0,constant.playbackTempos.single().source.sourceBpm,0.0)
            assertEquals("analysis_bpm",constant.playbackTempos.single().source.gridProvenance)
            assertFalse(constant.playbackTempos.single().source.beatAnchorKnown)
            compose.runOnIdle {model.controller.seekOccurrence(constant.clips[0].occurrence,4000)}
            val native=app.callbackPlayer as NativeCallbackPlayer
            compose.waitUntil(10000) {
                compose.runOnIdle {
                    val root=JSONObject(native.nativeDiagnostics())
                    val deck=root.optJSONArray("decks")?.optJSONObject(0)
                    root.optLong("scheduleRevision")==0L&&deck!=null&&deck.optBoolean("ready")&&!deck.optBoolean("playing")&&abs(deck.optLong("positionMs")-4000)<=1&&!native.isPlaying
                }
            }
            val constantReceipt=playAndPause(model,native){queuePlay().performClick()}
            compose.waitUntil(10000){model.playback.value.arrangement?.document==constant&&!model.playback.value.isPlaying}
            compose.waitUntil(10000){model.playback.value.title=="Tempo 1"}
            assertEquals("Synthetic ensemble",model.playback.value.artist)
            val constantDeck=constantReceipt.decks.getValue(constant.clips[0].occurrence)
            assertTrue(constantDeck.ready&&constantDeck.keylock&&constantDeck.processingEpoch>0)
            assertEquals(121.25,constantDeck.effectiveBpm!!,0.02)
            assertEquals(121.25/120.0,constantDeck.rate,0.0002)
            evidence.put("constantNative",JSONObject(constantReceipt.diagnostics))

            compose.openWaveformBpm("Tempo 2")
            compose.waitUntil(10000){compose.onAllNodesWithTag("precision-bpm-surface").fetchSemanticsNodes().isNotEmpty()}
            field("Beat anchor milliseconds").assertDoesNotExist()
            compose.onNodeWithText("Confirm source BPM").assertDoesNotExist()
            compose.onNodeWithText("Original: 100 BPM").assertIsDisplayed()
            playbackInput().performTextReplacement("110.5")
            click("Save BPM")
            compose.waitUntil(10000){model.timeline.value.document.playbackTempos.size==2}
            val beforePlacement=model.timeline.value.document
            val incoming=beforePlacement.clips[1]
            compose.onNodeWithContentDescription("Waveform ${incoming.occurrence}").performTouchInput {
                // Actual free placement gesture through production recognizer. Avoid identity/BPM/trace overlays.
                val sourceStart=width*incoming.globalStartMs/beforePlacement.clips.maxOf {it.globalEndMs}.toFloat()
                val begin=Offset((sourceStart+width*0.15f).coerceAtMost(width-8f),height*0.66f)
                swipe(begin,Offset(begin.x-width*0.16f,begin.y),700)
            }
            compose.waitUntil(10000){model.timeline.value.document.clips[1].globalStartMs<model.timeline.value.document.clips[0].globalEndMs}
            val overlap=model.timeline.value.document
            assertTrue(overlap.tempoRamps.isEmpty())
            assertEquals(beforePlacement.clips.map {it.sourceInMs to it.sourceOutMs},overlap.clips.map {it.sourceInMs to it.sourceOutMs})
            val density=compose.activity.resources.displayMetrics.density
            val firstLane=compose.onNodeWithContentDescription("Waveform ${incoming.occurrence}").fetchSemanticsNode().boundsInRoot
            val firstButton=bpm("Tempo 2").fetchSemanticsNode().boundsInRoot
            assertTrue(firstButton.height>=48*density-1)
            assertTrue(firstButton.width>=48*density-1)
            assertEquals(125*density,firstLane.height,1f)
            val footer=auto().fetchSemanticsNode().boundsInRoot
            val zoom=compose.onNodeWithContentDescription("Zoom in").fetchSemanticsNode().boundsInRoot
            assertTrue("Auto switch stays above zoom",footer.bottom<=zoom.top+1)
            raster("auto-off",auto())
            auto().performClick()
            compose.waitUntil(10000){model.timeline.value.document.autoBpmCrossfade&&model.timeline.value.document.tempoRamps.size==1}
            auto().assertIsOn()
            val saved=model.timeline.value.document
            val ramp=saved.tempoRamps.single()
            assertEquals(TempoRampPolicy.AutoSourceBoundsV1,ramp.policy)
            assertFalse(ramp.outgoing.beatAnchorKnown);assertFalse(ramp.incoming.beatAnchorKnown)
            assertEquals(overlap.clips.map {it.globalStartMs},saved.clips.map {it.globalStartMs})
            assertEquals(overlap.clips.map {it.sourceInMs to it.sourceOutMs},saved.clips.map {it.sourceInMs to it.sourceOutMs})
            assertEquals(121.25,ramp.outgoingEffectiveStartBpm,1e-9)
            assertEquals(110.5,ramp.target.customBpm!!,0.0)
            assertEquals(12000.0,saved.clips[0].sourceAtExact(ramp.overlapEndMs),1e-6)
            raster("auto-on",auto())
            assertPersisted(saved)
            val installed=model.playback.value.arrangement!!
            val seek=(ramp.overlapStartMs+250).toLong()
            compose.runOnIdle {model.controller.seekArrangement(installed.identity,seek)}
            compose.waitUntil(10000){abs(model.playback.value.positionMs-seek)<=2&&!model.playback.value.isPlaying}
            val receipt=playAndPause(model,native){queuePlay().performClick()}
            compose.waitUntil(10000){model.playback.value.arrangement?.document==saved&&!model.playback.value.isPlaying}
            compose.waitUntil(10000){model.playback.value.title=="Tempo 1 → Tempo 2"}
            assertEquals("Synthetic ensemble → Synthetic ensemble",model.playback.value.artist)
            assertTrue(receipt.globalMs>=ramp.overlapStartMs&&receipt.globalMs<ramp.overlapEndMs)
            assertEquals(2,receipt.decks.size)
            val elapsed=receipt.globalMs-ramp.overlapStartMs
            val duration=ramp.overlapEndMs-ramp.overlapStartMs
            val pulse=121.25+(110.5-121.25)*elapsed/duration
            val integral=121.25*elapsed+(110.5-121.25)*elapsed*elapsed/(2*duration)
            receipt.decks.forEach {(id,deck)->
                val clip=saved.clips.single {it.occurrence==id}
                val sourceBpm=if(clip.track==1L)120.0 else 100.0
                val prefix=if(clip.track==1L)ramp.overlapStartMs*121.25/120.0 else 0.0
                assertTrue(deck.ready&&deck.keylock&&deck.processingEpoch>0&&deck.playing)
                assertEquals(pulse,deck.effectiveBpm!!,0.02)
                assertEquals(prefix+integral/sourceBpm,deck.sourcePositionMs,2.0)
                assertEquals(deck.sourcePositionMs,deck.nominalSourcePositionMs,0.001)
            }
            evidence.put("autoNative",JSONObject(receipt.diagnostics))
            auto().performClick()
            compose.waitUntil(10000){!model.timeline.value.document.autoBpmCrossfade}
            auto().assertIsOff()
            val off=model.timeline.value.document
            assertTrue(off.tempoRamps.isEmpty());assertEquals(saved.playbackTempos,off.playbackTempos)
            assertEquals(saved.clips.map {it.fadeInMs to it.fadeOutMs},off.clips.map {it.fadeInMs to it.fadeOutMs})
            assertEquals(facts,model.library.value.analysis)
            assertTrue(app.forbiddenWrites.isEmpty())
            evidence.put("serverWriteAttempts",0).put("result","PASS")
        }catch(failure:Throwable){primary=failure;evidence.put("failure",failure.toString());if(app.callbackCreated)evidence.put("native",(app.callbackPlayer as NativeCallbackPlayer).nativeDiagnostics());throw failure}
        finally {
            try {File(instrumentation.targetContext.filesDir,"waveform-bpm-journey.json").writeText(evidence.toString(2));graph.session.retire()}
            catch(cleanup:Throwable){if(primary!=null)primary.addSuppressed(cleanup) else throw cleanup}
        }
    }
    private data class Receipt(val globalMs:Long,val decks:Map<String,PerformanceDeck>,val diagnostics:String)
    private fun playAndPause(model:ProductViewModel,native:NativeCallbackPlayer,play:()->Unit):Receipt {
        val latch=CountDownLatch(1);val result=AtomicReference<Receipt>();val failure=AtomicReference<Throwable>()
        val listener=object:Player.Listener {override fun onIsPlayingChanged(isPlaying:Boolean) {
            if(!isPlaying||result.get()!=null||failure.get()!=null)return
            try {result.set(Receipt(native.currentPosition,native.performanceDecks.toMap(),native.nativeDiagnostics()));model.controller.pause()}
            catch(e:Throwable){failure.set(e)}finally{latch.countDown()}
        }}
        compose.runOnIdle {native.addListener(listener)}
        try {play();assertTrue("Real callback output did not begin",latch.await(20,TimeUnit.SECONDS));failure.get()?.let {throw it};return requireNotNull(result.get())}
        finally {compose.runOnIdle {native.removeListener(listener);model.controller.pause()}}
    }
    private fun raster(name:String,target:SemanticsNodeInteraction) {
        val root=target.fetchSemanticsNode().root as ViewRootForTest
        compose.runOnIdle {
            assertTrue(compose.activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE==0)
            val view=root.view
            var parent:android.view.ViewParent?=view.parent
            while(parent!=null&&parent !is androidx.compose.ui.window.DialogWindowProvider)parent=parent.parent
            val dialog=(parent as? androidx.compose.ui.window.DialogWindowProvider)?.window
            if(dialog!=null)assertTrue("Dialog must allow screenshots and screen recording",dialog.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE==0)
            val dpWidth=view.width/compose.activity.resources.displayMetrics.density
            assertTrue("Fixture must use ordinary 411dp phone geometry, got $dpWidth",dpWidth in 390f..430f)
            val bitmap=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
            try {view.draw(Canvas(bitmap));File(compose.activity.filesDir,"waveform-bpm-$name.png").outputStream().use {assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG,100,it))}}
            finally {bitmap.recycle()}
        }
    }
    private fun assertPersisted(expected:TimelineDocument) {
        val graph=(compose.activity.application as WaveformBpmFixtureApplication).graph
        val raw=File(graph.directory,"timeline").listFiles()!!.single {it.name.startsWith("arrangement-")&&it.name.endsWith(".v1.json")}.readText()
        assertEquals(5,JSONObject(raw).getInt("version"))
        val document=Json.decodeFromString(TimelineDocument.serializer(),JSONObject(raw).getJSONObject("document").toString())
        assertEquals(expected,projectTempoDocument(document))
    }
}

/** Invoke with MissingWaveformBpmFixtureRunner. Library summary cannot replace missing source analysis. */
class MissingWaveformBpmJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun missingSourceBpmConfirmsOnlyDecimalBpmThenSavesPlaybackWithoutBeatAnchor() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val app=instrumentation.targetContext.applicationContext as MissingWaveformBpmFixtureApplication
        var primary:Throwable?=null
        try {
            app.sourceAnalysis.forEach {(id,raw)->
                val wave=AnalysisWaveformJson.parse(Json.parseToJsonElement(raw).jsonObject,TrackId(id),12000)
                assertNull(wave.suggestedBpm);assertNull(wave.tempoTiming);assertNull(wave.phaseTiming)
            }
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("missing-bpm@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onNodeWithContentDescription("Password").performImeAction()
            val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
            compose.waitUntil(10000){model.library.value.rows.size==2}
            compose.onNode(hasText("Tempo 1") and hasClickAction() and hasAnyDescendant(hasContentDescription("More for Tempo 1"))).performClick()
            compose.waitUntil(15000){app.callbackCreated&&model.playback.value.isPlaying&&model.timeline.value.document.clips.size==2}
            compose.onNodeWithContentDescription("Pause").performClick()
            compose.onNodeWithContentDescription("Open listening queue").performClick()
            compose.onNodeWithText("Waveforms").performClick()
            compose.openWaveformBpm("Tempo 1")
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Source BPM value").fetchSemanticsNodes().isNotEmpty()}
            compose.onNode(hasText("Beat anchor milliseconds") and hasSetTextAction()).assertDoesNotExist()
            compose.onNodeWithTag("precision-bpm-surface").assertDoesNotExist()
            compose.onNodeWithText("Confirm source BPM").assertIsNotEnabled()
            val source=compose.onNodeWithContentDescription("Source BPM value")
            source.performTextReplacement("0")
            compose.onNodeWithText("Confirm source BPM").assertIsNotEnabled()
            source.performTextReplacement("138.5")
            compose.onNode(hasText("Confirm source BPM") and hasClickAction()).performScrollTo().performClick()
            compose.onNodeWithText("Original: 138.5 BPM").assertIsDisplayed()
            compose.onNode(hasText("Beat anchor milliseconds") and hasSetTextAction()).assertDoesNotExist()
            compose.onNodeWithTag("precision-bpm-surface").assertTextContains("138.50").performClick()
            val playback=compose.onNodeWithContentDescription("Type BPM")
            playback.assertTextContains("138.50").performTextReplacement("140.25")
            compose.onNode(hasText("Save BPM") and hasClickAction()).performScrollTo().performClick()
            compose.waitUntil(10000){model.timeline.value.document.playbackTempos.singleOrNull()?.playbackBpm==140.25}
            val saved=model.timeline.value.document
            val intent=saved.playbackTempos.single()
            assertEquals("local_bpm",intent.source.gridProvenance);assertFalse(intent.source.beatAnchorKnown)
            assertEquals(138.5,intent.source.sourceBpm,0.0)
            compose.onNodeWithContentDescription("Expand Tempo 1").performClick()
            compose.onNodeWithText("Held 140.25 BPM",useUnmergedTree=true).assertIsDisplayed()
            compose.openWaveformBpm("Tempo 1")
            compose.onNodeWithText("Original: 138.5 BPM").assertIsDisplayed()
            compose.onNode(hasText("Cancel") and hasClickAction()).performScrollTo().performClick()
            assertTrue(app.forbiddenWrites.isEmpty())
            File(instrumentation.targetContext.filesDir,"waveform-missing-bpm-journey.json").writeText(JSONObject().put("result","PASS").put("sourceBpm",138.5).put("playbackBpm",140.25).put("beatAnchorKnown",false).put("serverWriteAttempts",0).toString(2))
        }catch(failure:Throwable){primary=failure;throw failure}
        finally {try {app.graph.session.retire()}catch(cleanup:Throwable){if(primary!=null)primary.addSuppressed(cleanup) else throw cleanup}}
    }
}
