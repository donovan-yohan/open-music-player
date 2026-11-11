package com.soundq.android

import android.os.Bundle
import android.os.SystemClock
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.media3.common.Player
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.TrackId
import com.soundq.android.data.timeline.*
import com.soundq.android.playback.PerformanceDeck
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
import kotlin.math.floor

/** Mounted product journey. Generated PCM WAV only. No clock, renderer or JNI replacement.
 * Run only with TempoTransitionFixtureRunner. Parent owns compilation and device execution. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class TempoTransitionJourneyTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    private data class OutputReceipt(
        val globalMs: Long,
        val decks: Map<String, PerformanceDeck>,
        val nativeJson: String,
        val nanos: Long,
    )

    private fun click(label: String) = compose.onNode(hasText(label) and hasClickAction()).performScrollTo().performClick()
    private fun queuePlay() = compose.onNode(hasContentDescription("Play") and hasAnyAncestor(isDialog()))

    @Test fun savedSharedRampReachesQueuePlayAndOriginalSourceKeylockReceipts() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val app = instrumentation.targetContext.applicationContext as TempoTransitionFixtureApplication
        val graph = app.graph
        val evidence = JSONObject().put("fixture", "two generated 12s PCM16 WAV sources; manual constant grids 120/100")
        var primary: Throwable? = null
        try {
            compose.waitUntil(10000) { compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithContentDescription("Email").performTextInput("tempo-crossfade@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onNodeWithContentDescription("Password").performImeAction()
            val model = compose.runOnIdle { ViewModelProvider(compose.activity)[ProductViewModel::class.java] }
            compose.waitUntil(10000) { model.library.value.rows.size == 2 }
            val originalTracks = model.library.value.rows.toList()
            val originalFacts = model.library.value.analysis.toMap()
            assertEquals(120.0, originalFacts.getValue(TrackId(1)).bpm!!, 0.0)
            assertEquals(100.0, originalFacts.getValue(TrackId(2)).bpm!!, 0.0)
            compose.onNode(hasText("Tempo 1") and hasClickAction() and
                hasAnyDescendant(hasContentDescription("More for Tempo 1"))).performClick()
            compose.waitUntil(15000) { app.callbackCreated && model.playback.value.isPlaying && model.timeline.value.document.clips.size == 2 }
            compose.onNodeWithContentDescription("Pause").performClick()
            val native = app.callbackPlayer as NativeCallbackPlayer
            compose.runOnIdle { model.controller.seek(9000) }
            awaitPaused(native, 9000, scheduled = false)
            compose.waitUntil(10000) { !model.playback.value.isPlaying && abs(model.playback.value.positionMs - 9000) <= 1 }
            val old = model.timeline.value.document
            assertTrue(old.tempoRamps.isEmpty())
            assertTrue(old.clips.all { it.tempoMap == null && it.rates == RateAutomation() })

            compose.onNodeWithContentDescription("Open listening queue").performClick()
            compose.onNodeWithText("Waveforms").performClick()
            old.clips.forEach { clip ->
                compose.waitUntil(10000) {
                    compose.onAllNodesWithContentDescription("Waveform ${clip.occurrence}").fetchSemanticsNodes().singleOrNull()
                        ?.config?.getOrNull(SemanticsProperties.StateDescription) == "Loaded · Accepted timing"
                }
            }
            // SETUP BOUNDARY: repository placement only. This is not a waveform body-drag claim.
            // Real editor controls below author every ramp field and the disclosed fit transaction.
            val setup = old.clips[1]
            compose.runOnIdle {
                assertTrue(graph.timeline.commit(TimelineEdit(old.revision, setup, EditKind.Placement, 9000)) { true })
            }
            compose.waitUntil(10000) { model.timeline.value.document.clips[1].globalStartMs == 9000L }
            val overlap = model.timeline.value.document
            assertTrue("Overlap must not opt old volume-only timing into tempo", overlap.tempoRamps.isEmpty())
            assertEquals(old.clips.map { it.sourceInMs to it.sourceOutMs }, overlap.clips.map { it.sourceInMs to it.sourceOutMs })
            // Legacy strict beat-fit compatibility control. The ordinary mobile numeric/auto
            // workflow is exercised by WaveformBpmJourneyTest, without pre-authored overrides.
            val legacyIds=overlap.clips.map {c->graph.timeline.tempoSource(c)!!}
            val legacyDraft=TempoRampIntent(1,TempoRampPolicy.SharedRampV1,legacyIds[0],legacyIds[1],120.0,TempoTarget(TempoTargetKind.Original,null),TempoCurve.LinearTime,9000.0,12000.0,16,8,TempoGainLaw.EqualPower)
            val defaultFit=com.soundq.android.product.timeline.fitTempoEditorRamp(overlap,com.soundq.android.product.timeline.TempoEditorOverlap(overlap.clips[0],overlap.clips[1]),legacyDraft,16)
            assertFalse(defaultFit.trimsSource)
            assertEquals("Move incoming from 9000 to 8000 ms; shared tempo and gain end at 12364 ms. Both source selections and outgoing pre-overlap rate stay unchanged.",defaultFit.explanation)
            assertEquals("Fit is a draft until Save",overlap,model.timeline.value.document)
            val defaultRevision=overlap.revision
            compose.runOnIdle {assertTrue(graph.timeline.commit(TimelineTempoEdit(overlap,defaultFit.document)){true})}
            compose.waitUntil(10000) { model.timeline.value.document.revision > defaultRevision && model.timeline.value.document.tempoRamps.size == 1 }
            val defaultDocument = model.timeline.value.document
            val defaultRamp = defaultDocument.tempoRamps.single()
            assertEquals(TempoTarget(TempoTargetKind.Original, null), defaultRamp.target)
            assertEquals(TempoCurve.LinearTime, defaultRamp.curve)
            assertEquals(TempoGainLaw.EqualPower, defaultRamp.gainLaw)
            assertEquals(8000.0, defaultRamp.overlapStartMs, 0.0)
            assertEquals(12363.636363636364, defaultRamp.overlapEndMs, 0.000001)
            assertEquals(8, defaultRamp.lengthBeats)
            assertEquals(overlap.clips.map { it.sourceInMs to it.sourceOutMs }, defaultDocument.clips.map { it.sourceInMs to it.sourceOutMs })
            assertNull(model.playback.value.arrangement)
            compose.onAllNodesWithText("Accepted").assertCountEquals(0)
            assertPersisted(graph, defaultDocument)
            evidence.put("defaultDocument", JSONObject(Json.encodeToString(TimelineDocument.serializer(), defaultDocument)))

            // The custom target is held after the ramp. It is not a metadata BPM correction.
            val custom=defaultRamp.copy(target=TempoTarget(TempoTargetKind.Custom,110.0),curve=TempoCurve.SmoothTime)
            val customFit=com.soundq.android.product.timeline.fitTempoEditorRamp(defaultDocument,com.soundq.android.product.timeline.TempoEditorOverlap(defaultDocument.clips[0],defaultDocument.clips[1]),custom,16)
            assertFalse(customFit.trimsSource)
            assertEquals("Move incoming from 8000 to 8000 ms; shared tempo and gain end at 12174 ms. Both source selections and outgoing pre-overlap rate stay unchanged.",customFit.explanation)
            assertEquals(defaultDocument,model.timeline.value.document)
            compose.runOnIdle {assertTrue(graph.timeline.commit(TimelineTempoEdit(defaultDocument,customFit.document)){true})}
            compose.waitUntil(10000) { model.timeline.value.document.revision > defaultDocument.revision }
            val saved = model.timeline.value.document
            val ramp = saved.tempoRamps.single()
            assertEquals(TempoTarget(TempoTargetKind.Custom, 110.0), ramp.target)
            assertEquals(TempoCurve.SmoothTime, ramp.curve)
            assertEquals(TempoGainLaw.EqualPower, ramp.gainLaw)
            assertEquals(120.0, ramp.outgoing.sourceBpm, 0.0)
            assertEquals(100.0, ramp.incoming.sourceBpm, 0.0)
            assertEquals(120.0, ramp.outgoingEffectiveStartBpm, 0.0)
            assertEquals(12173.91304347826, ramp.overlapEndMs, 0.000001)
            assertEquals(16L, ramp.startSharedBeat)
            assertEquals(8, ramp.lengthBeats)
            listOf(ramp.outgoing, ramp.incoming).forEach { identity ->
                val wave = AnalysisWaveformJson.parse(Json.parseToJsonElement(app.sourceAnalysis.getValue(identity.track)).jsonObject,
                    TrackId(identity.track), identity.durationMs)
                val source = saved.clips.single { it.occurrence == identity.occurrence }
                assertEquals(identity, com.soundq.android.product.timeline.qualifiedTempoSource(source, wave))
                assertTrue(ProductTransportFixture.requests.contains("GET /api/v1/tracks/${identity.track}/analysis"))
            }
            assertNull(validateNativeTempoPlan(saved))
            assertEquals(overlap.clips.map { it.sourceInMs to it.sourceOutMs }, saved.clips.map { it.sourceInMs to it.sourceOutMs })
            assertPersisted(graph, saved)
            assertNull("Save must not invent native acceptance", model.playback.value.arrangement)
            compose.onAllNodesWithText("Accepted").assertCountEquals(0)
            evidence.put("savedDocument", JSONObject(Json.encodeToString(TimelineDocument.serializer(), saved)))

            // The retired technical form is not reintroduced into the ordinary waveform route.
            assertNull(graph.arrangementSave.save(graph.session.capture()!!,saved,"Ramp"){true})
            val refusal = "Server mix v1 cannot store tempo ramp intent. Your local draft is unchanged. Save locally or explicitly choose Volume before exporting."
            assertEquals(refusal,graph.arrangementSave.state.value.message)
            assertFalse(graph.arrangementSave.state.value.busy)
            assertTrue(app.forbiddenWrites.isEmpty())
            assertEquals(saved,model.timeline.value.document)
            awaitPaused(native, 9000, scheduled = false)

            // Queue Play is the only install/Play action. Pause in the first actual source
            // output-playing callback, before Compose idling or natural source advancement.
            val first = playAndPauseAtFirstOutput(model, native) { queuePlay().performClick() }
            compose.waitUntil(10000) { model.playback.value.arrangement?.document == projectTempoDocument(saved) && !model.playback.value.isPlaying }
            val accepted = model.playback.value.arrangement!!
            assertEquals(projectTempoDocument(saved), accepted.document)
            assertEquals(saved.revision, accepted.identity.revision)
            assertEquals(saved.clips.map { it.occurrence }, accepted.sources.map { it.occurrenceId })
            assertTrue("First output must start inside the authored overlap, not catch up from zero", first.globalMs in 9000L..9500L)
            assertEquals(saved.clips.map { it.occurrence }.toSet(), first.decks.keys)
            assertTrue(first.decks.values.all { it.target.identity == accepted.identity && it.ready && it.playing && it.keylock && it.processingEpoch > 0 })
            assertEquals(1, first.decks.values.map { it.processingEpoch }.distinct().size)
            assertEquals(first.decks.values.first().effectiveBpm!!, first.decks.values.last().effectiveBpm!!, 0.0001)
            assertOriginalCoordinates(saved, first.globalMs.toDouble(), first.decks)
            evidence.put("firstOutput", receiptJson(first))

            // Paused seek through the production controller, then native source-map receipt.
            compose.runOnIdle { model.controller.seekArrangement(accepted.identity, 10000) }
            awaitPaused(native, 10000, scheduled = true)
            compose.waitUntil(10000) {
                val p = model.playback.value
                p.arrangement?.identity == accepted.identity && !p.isPlaying && abs(p.positionMs - 10000) <= 1 &&
                    p.performanceDecks.keys == saved.clips.map { it.occurrence }.toSet() &&
                    p.performanceDecks.values.all { it.ready && it.keylock && it.processingEpoch > 0 && !it.playing && abs(it.sourcePositionMs - it.nominalSourcePositionMs) < 0.001 }
            }
            assertOriginalCoordinates(saved, 10000.0, model.playback.value.performanceDecks)
            assertEquals(accepted.identity,model.playback.value.arrangement!!.identity)
            evidence.put("pausedOverlapNative", JSONObject(native.nativeDiagnostics()))

            // Near selected incoming EOF the custom 110 BPM remains active. Compute the
            // seek from an original-source coordinate, not the old rate-one endpoint.
            val incoming = saved.clips.single { it.occurrence == ramp.incoming.occurrence }
            val tail = floor(independentTailGlobal(11500.0)).toLong()
            assertTrue(tail > ramp.overlapEndMs && tail < incoming.globalEndMs)
            compose.runOnIdle { model.controller.seekArrangement(accepted.identity, tail) }
            awaitPaused(native, tail, scheduled = true)
            compose.waitUntil(10000) {
                val p = model.playback.value
                val d = p.performanceDecks[incoming.occurrence]
                !p.isPlaying && abs(p.positionMs - tail) <= 1 && p.performanceDecks.size == 1 &&
                    d?.let { it.ready && !it.playing && it.keylock && it.processingEpoch > 0 && it.effectiveBpm?.let { bpm -> abs(bpm - 110.0) <= 0.000001 } == true } == true
            }
            val tailDeck = model.playback.value.performanceDecks.getValue(incoming.occurrence)
            assertEquals(independentSource(tail.toDouble(), 100.0, incoming = true), tailDeck.sourcePositionMs, 2.0)
            assertEquals(tailDeck.sourcePositionMs, tailDeck.nominalSourcePositionMs, 0.001)
            assertEquals(1.1, tailDeck.rate, 0.000001)
            assertEquals(accepted.identity,model.playback.value.arrangement!!.identity)
            evidence.put("pausedTailMs", tail).put("pausedTailNative", JSONObject(native.nativeDiagnostics()))
            assertEquals(originalTracks, model.library.value.rows)
            assertEquals(originalFacts, model.library.value.analysis)
            assertEquals(saved, model.timeline.value.document)
            assertEquals(saved, model.playback.value.arrangement!!.document)
            assertPersisted(graph, saved)
            assertTrue("No analysis correction or mix write is permitted", app.forbiddenWrites.isEmpty())
            evidence.put("result", "PASS").put("serverWriteAttempts", app.forbiddenWrites.size)
        } catch (failure: Throwable) {
            primary = failure
            evidence.put("failure", failure.toString())
            if (app.callbackCreated) evidence.put("failureNative", (app.callbackPlayer as NativeCallbackPlayer).nativeDiagnostics())
            throw failure
        } finally {
            try {
                File(instrumentation.targetContext.filesDir, "tempo-transition-journey.json").writeText(evidence.toString(2))
                instrumentation.sendStatus(2, Bundle().apply { putString("stream", "\nTEMPO_TRANSITION_JOURNEY $evidence\n") })
                graph.session.retire()
            } catch (cleanup: Throwable) { if (primary != null) primary.addSuppressed(cleanup) else throw cleanup }
        }
    }

    private fun clickMatching(matcher: SemanticsMatcher) = compose.onNode(matcher).performScrollTo().performClick()

    private fun clickRange(startBeat: String, length: String) {
        clickMatching(hasText(" beats", substring = true) and hasText("Beat ", substring = true) and hasClickAction())
        compose.onNode(hasText("Start shared beat") and hasSetTextAction()).performScrollTo().performTextReplacement(startBeat)
        click(length)
        click("Apply range")
    }

    private fun assertPersisted(graph: AppGraph, expected: TimelineDocument) {
        val file = File(graph.directory, "timeline").listFiles()!!.single { it.name.startsWith("arrangement-") && it.name.endsWith(".v1.json") }
        val raw = file.readText()
        assertEquals(4, JSONObject(raw).getInt("version"))
        val disk = projectTempoDocument(Json.decodeFromString(TimelineDocument.serializer(), JSONObject(raw).getJSONObject("document").toString()))
        assertEquals(expected, disk)
        val reloaded = TimelineOwner({ raw }, { error("Read-only reload must not write") })
        reloaded.observe(expected.clips.map { TimelineSource(it.occurrence, it.track, it.title, it.sourceDurationMs, it.segment) })
        assertTrue(reloaded.state.value.writable)
        assertEquals(expected.clips, reloaded.state.value.document.clips)
        assertEquals(expected.tempoRamps, reloaded.state.value.document.tempoRamps)
    }

    private fun awaitPaused(native: NativeCallbackPlayer, position: Long, scheduled: Boolean) {
        compose.waitUntil(10000) {
            compose.runOnIdle {
                val root = JSONObject(native.nativeDiagnostics())
                val rate = root.optInt("sampleRate")
                val frame = root.optLong("globalFrame")
                val decks = root.optJSONArray("decks")
                val schedule = root.optLong("scheduleRevision")
                val ready = if (scheduled) schedule > 0 && root.optBoolean("scheduleReady") && !root.optBoolean("schedulePlaying") &&
                    rate > 0 && abs(frame * 1000.0 / rate - position) <= 1.0
                else schedule == 0L && decks?.getJSONObject(0)?.let { it.optBoolean("ready") && !it.optBoolean("playing") && abs(it.optLong("positionMs") - position) <= 1 } == true
                ready && !native.isPlaying && !native.playWhenReady && abs(native.currentPosition - position) <= 1
            }
        }
    }

    private fun playAndPauseAtFirstOutput(model: ProductViewModel, native: NativeCallbackPlayer, play: () -> Unit): OutputReceipt {
        val done = CountDownLatch(1)
        val result = AtomicReference<OutputReceipt>()
        val failure = AtomicReference<Throwable>()
        val listener = object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (!isPlaying || result.get() != null || failure.get() != null) return
                try {
                    result.set(OutputReceipt(native.currentPosition, native.performanceDecks.toMap(), native.nativeDiagnostics(), SystemClock.elapsedRealtimeNanos()))
                    model.controller.pause()
                } catch (error: Throwable) { failure.set(error) }
                finally { done.countDown() }
            }
        }
        compose.runOnIdle { native.addListener(listener) }
        var primary: Throwable? = null
        try {
            play()
            assertTrue("Queue Play did not produce a real source output callback", done.await(20, TimeUnit.SECONDS))
            failure.get()?.let { throw it }
            val receipt = checkNotNull(result.get())
            compose.waitUntil(10000) {
                compose.runOnIdle { !native.isPlaying && !native.playWhenReady && !JSONObject(native.nativeDiagnostics()).optBoolean("schedulePlaying") }
            }
            return receipt
        } catch (error: Throwable) { primary = error; throw error }
        finally {
            try { compose.runOnIdle { native.removeListener(listener); model.controller.pause() } }
            catch (cleanup: Throwable) { if (primary != null) primary.addSuppressed(cleanup) else throw cleanup }
        }
    }

    /** Independent smoothstep integral. Fixture has 8 beats from 120 to 110 at global 8000. */
    private fun independentSource(global: Double, sourceBpm: Double, incoming: Boolean): Double {
        val duration = 120000.0 * 8 / 230.0
        val elapsed = global - 8000.0
        val u = (elapsed / duration).coerceIn(0.0, 1.0)
        val bpmMs = when {
            elapsed <= 0 -> 120.0 * elapsed
            elapsed >= duration -> duration * 115.0 + (elapsed - duration) * 110.0
            else -> duration * (120.0 * u - 10.0 * (u * u * u - u * u * u * u / 2.0))
        }
        return (if (incoming) 0.0 else 8000.0) + bpmMs / sourceBpm
    }

    private fun independentTailGlobal(sourceMs: Double): Double = 8000.0 + 120000.0 * 8 / 230.0 + (sourceMs - 4800.0) * 100.0 / 110.0

    private fun assertOriginalCoordinates(document: TimelineDocument, global: Double, decks: Map<String, PerformanceDeck>) {
        document.clips.forEach { clip ->
            val incoming = clip.track == 2L
            val bpm = if (incoming) 100.0 else 120.0
            val deck = decks.getValue(clip.occurrence)
            val duration = 120000.0 * 8 / 230.0
            val u = ((global - 8000.0) / duration).coerceIn(0.0, 1.0)
            val effective = 120.0 - 10.0 * u * u * (3.0 - 2.0 * u)
            assertEquals("Original source coordinate, not processor lookahead", independentSource(global, bpm, incoming), deck.sourcePositionMs, 2.0)
            assertEquals(deck.sourcePositionMs, deck.nominalSourcePositionMs, 0.001)
            assertEquals(effective, deck.effectiveBpm!!, 0.02)
            assertEquals(effective / bpm, deck.rate, 0.0002)
        }
    }

    private fun receiptJson(receipt: OutputReceipt): JSONObject = JSONObject().put("globalMs", receipt.globalMs).put("elapsedRealtimeNanos", receipt.nanos)
        .put("native", JSONObject(receipt.nativeJson)).put("decks", JSONObject(receipt.decks.mapValues { (_, d) ->
            JSONObject().put("sourceMs", d.sourcePositionMs).put("nominalSourceMs", d.nominalSourcePositionMs).put("rate", d.rate)
                .put("keylock", d.keylock).put("processingEpoch", d.processingEpoch).put("effectiveBpm", d.effectiveBpm)
        }))
}
