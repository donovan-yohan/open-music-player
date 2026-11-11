package com.soundq.android

import androidx.media3.common.Player
import com.soundq.android.data.TrackId
import com.soundq.android.data.timeline.AnalysisWaveformJson
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.RecordedRequest
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList

/** Test APK only. Inherits the real 12s PCM WAV, TLS grants and production JNI factory. */
class TempoTransitionFixtureRunner : ProductFixtureRunner() {
    override val fixtureApplicationClass get() = TempoTransitionFixtureApplication::class.java.name
}

open class TempoTransitionFixtureApplication : FixtureApplication() {
    open val durationMs=12000L
    lateinit var callbackPlayer: Player
        private set
    val callbackCreated get() = ::callbackPlayer.isInitialized
    val forbiddenWrites = CopyOnWriteArrayList<String>()
    open val sourceAnalysis: Map<Long, String> = (1L..2L).associateWith {analysis(it)}

    override fun getNoBackupFilesDir(): File =
        File(super.getNoBackupFilesDir(), "tempo-transition-fixture").apply { mkdirs() }

    internal override fun createCallbackLibraryPlayer(
        grants: java.util.concurrent.ConcurrentHashMap<String, com.soundq.android.playback.MediaGrant>,
        jobs: kotlinx.coroutines.CoroutineScope,
    ): Player = super.createCallbackLibraryPlayer(grants, jobs).also { callbackPlayer = it }

    override fun prepareGraph(graph: AppGraph) {
        // This directory belongs only to this fixture application, never the user's draft.
        File(graph.directory, "timeline").deleteRecursively()
        sourceAnalysis.forEach { (id, raw) ->
            val accepted = AnalysisWaveformJson.parse(Json.parseToJsonElement(raw).jsonObject, TrackId(id), durationMs)
            check(accepted.tiers.single().minima.size == 120)
            if(accepted.tempoTiming!=null) {
                check(accepted.phaseTiming?.periodMs == if (id == 1L) 500L else 600L)
                check(accepted.phaseTiming?.provenance == "manual_timing_v2")
            } else {check(accepted.phaseTiming==null);check(accepted.suggestedBpm!=null)}
        }
        val original = ProductTransportFixture.server.dispatcher
        ProductTransportFixture.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.url.encodedPath
                val analysisId = Regex("/api/v1/tracks/([12])/analysis").matchEntire(path)?.groupValues?.get(1)?.toLong()
                val analysisPath = Regex("/api/v1/tracks/[12]/analysis(?:/.*)?").matches(path)
                if ((path.startsWith("/api/v1/mixes") || path.startsWith("/api/v1/mix-plans") || analysisPath) && request.method !in listOf("GET", "HEAD")) {
                    forbiddenWrites.add("${request.method} $path")
                    return json("{}", 405)
                }
                if (path == "/api/v1/library" || analysisId != null) {
                    ProductTransportFixture.requests.add("${request.method} $path")
                    if (request.headers["Authorization"] != "Bearer synthetic-fixture-access") return json("{}", 401)
                    if (analysisId != null) return json(sourceAnalysis.getValue(analysisId))
                    val offset = request.url.queryParameter("offset")?.toIntOrNull() ?: 0
                    val query = request.url.queryParameter("q").orEmpty()
                    val rows = JSONArray()
                    if (offset == 0) for (id in 1..2) {
                        if (query.isNotBlank() && !"Tempo $id".contains(query, true)) continue
                        rows.put(JSONObject().put("id", id).put("title", "Tempo $id").put("artist", "Synthetic ensemble")
                            .put("duration_ms", durationMs).put("is_liked", false).put("analysis_status", "analyzed")
                            .put("analysis_summary", JSONObject().put("bpm", JSONObject().put("value", if (id == 1) 120 else 100))))
                    }
                    return json(JSONObject().put("tracks", rows).put("total", 2).put("limit", 20).put("offset", offset).toString())
                }
                // The inherited generated WAV and signed URLs are decoder inputs, not fake PCM/rendering.
                return original.dispatch(request)
            }
        }
    }

    private fun json(body: String, code: Int = 200): MockResponse =
        MockResponse.Builder().code(code).addHeader("Content-Type", "application/json").body(body).build()

    companion object {
        /** Exact signed extrema of ProductTransportFixture's 16kHz, 220Hz, 800-amplitude PCM16 WAV.
         * Constant timing is explicitly authored synthetic metadata, not an analyzer quality claim. */
        internal fun analysis(id: Long,authored:Boolean=true,durationMs:Long=12000): String {
            val bpm = if (id == 1L) 120 else 100
            val period = if (id == 1L) 500 else 600
            val minima = JSONArray()
            val maxima = JSONArray()
            val framesPerBin=(durationMs*16/120).toInt()
            repeat(120) { bin ->
                val pcm = (bin * framesPerBin until (bin + 1) * framesPerBin).map { frame ->
                    (kotlin.math.sin(frame * 2 * Math.PI * 220 / 16000) * 800).toInt().toShort().toDouble() / 32768.0
                }
                minima.put(pcm.minOrNull()!!)
                maxima.put(pcm.maxOrNull()!!)
            }
            val beats = JSONArray((0..durationMs.toInt() step period).toList())
            val grid = JSONObject().put("beats_ms", beats)
            val tempo = JSONObject().put("value", bpm)
            val manual = JSONObject().put("schema_version", 2).put("provenance", "manual_override")
                .put("revision", 1).put("bpm", bpm).put("beat_anchor_ms", 0)
            val result=JSONObject().put("track_id", id).put("schema_version", 2).put("status", "analyzed")
                .put("updated_at", "2026-11-01T00:00:00Z").put("override_revision", 1)
                .put("summary", JSONObject().put("bpm", tempo).put("beat_grid", grid)
                    .put("waveform", JSONObject().put("min_peaks", minima).put("max_peaks", maxima)))
                .put("effective_timing", JSONObject().put("bpm", tempo).put("beat_grid", grid))
                .put("overrides", JSONObject().put("manual_timing_v2", manual))
            if(!authored){result.remove("overrides");result.remove("override_revision");result.remove("effective_timing")}
            return result.toString()
        }
    }
}
