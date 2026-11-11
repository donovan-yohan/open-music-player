package com.soundq.android.data

import com.soundq.android.data.trackdetails.*
import com.soundq.android.product.trackdetails.TempoDraft
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class TempoCorrectionRequestTest {
    @Test fun localTappedAndScaledDraftOnlyWritesOnExplicitCorrectionWithExactRevisionAndPreservedOverrides() {
        HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            val prior="""{"manual_timing_v2":{"schema_version":2,"bpm":123.5,"beat_anchor_ms":87,"beats_per_bar":4,"downbeat_phase_index":3,"phrase_length_bars":8},"key":{"value":"A minor","provenance":"manual_override"},"custom":{"keep":true}}"""
            f.reply(detailsPage());f.reply(analysisBody(3,prior));repository.load(route)
            val base=repository.state.value.analysis!!
            val draft=TempoDraft().tap(1000).tap(1480).scale(0.5,base.number("bpm")).scale(2.0,base.number("bpm"))
            assertEquals(125.0,draft.text.toDouble(),0.0)
            assertEquals(2,f.server.requestCount)
            assertEquals(3,repository.state.value.analysis!!.revision)
            val correction=AnalysisCorrection(bpm=draft.text.toDouble())
            assertNull(correction.anchorMs);assertNull(correction.meter);assertNull(correction.phase);assertNull(correction.key)
            val command=repository.claim(route,repository.state.value.detail!!,DetailsAction.Analysis(base,correction))!!
            val accepted=prior.replace("123.5","125.0")
            f.reply(analysisBody(4,accepted));f.reply(analysisBody(4,accepted));repository.execute(command)
            assertEquals(MutationOutcome.Confirmed,repository.state.value.outcome)
            assertEquals(4,repository.state.value.analysis!!.revision)
            val requests=(1..4).map {f.server.takeRequest(3,TimeUnit.SECONDS)!!}
            assertEquals(listOf("GET","GET","PATCH","GET"),requests.map {it.method})
            val wire=Json.parseToJsonElement(requests[2].body!!.utf8()).jsonObject
            assertEquals(JsonPrimitive(3),wire["expected_revision"])
            assertEquals(JsonPrimitive("replace"),wire["timing_mutation"])
            assertEquals(Json.parseToJsonElement(accepted),wire["overrides"])
            assertEquals("/api/v1/tracks/7/analysis/overrides",requests[2].url.encodedPath)
        }
    }
}
