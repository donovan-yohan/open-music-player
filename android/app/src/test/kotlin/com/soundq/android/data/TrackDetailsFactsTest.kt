package com.soundq.android.data

import com.soundq.android.data.trackdetails.*
import org.junit.Assert.*
import org.junit.Test

class TrackDetailsFactsTest {
    @Test fun durationKeepsUnknownDistinctFromZeroAndDoesNotWrapAtAnHour() {
        assertEquals("Not available",com.soundq.android.product.trackdetails.detailsDuration(null))
        assertEquals("Not available",com.soundq.android.product.trackdetails.detailsDuration(0))
        assertEquals("3:05",com.soundq.android.product.trackdetails.detailsDuration(185000))
        assertEquals("01:01:02",com.soundq.android.product.trackdetails.detailsDuration(3662000))
    }
    @Test fun optionalRecordingFactsStayAbsentAndMalformedFactsAreRejected() {
        val suggestion="""{"mb_recording_id":"12345678-1234-1234-1234-123456789abc","title":"Original","artist":"Ensemble"}"""
        fun parse(extra:String)=TrackDetailsJson.checked {TrackDetailsJson.suggestion(kotlinx.serialization.json.Json.parseToJsonElement(suggestion.dropLast(1)+extra+"}") as kotlinx.serialization.json.JsonObject)}
        assertNull(parse("").album);assertNull(parse("").durationMs)
        assertNull(parse(",\"duration\":0").durationMs)
        listOf(",\"duration\":-1",",\"duration\":\"245000\"",",\"album\":123").forEach {extra->
            val failure=runCatching {parse(extra)}.exceptionOrNull() as? SafeFailure
            assertEquals(SafeFailure.Reason.InvalidResponse,failure?.reason)
        }
    }
    @Test fun canonicalDetailsKeepSourceAndRecordingEditionFactsWithoutChangingNumericIdentity() {
        HttpsFixture().use {f->
            val (_,library,repository)=detailsSetup(f)
            val route=repository.open(library.captureTrack(library.state.value.rows.single())!!)!!
            val row=detailsRow().dropLast(1)+""", "duration_ms":185000,"source_url":"https://www.youtube.com/watch?v=exact-source","mb_suggestions":[{"mb_recording_id":"12345678-1234-1234-1234-123456789abc","title":"Original","artist":"Ensemble","album":"Live edition","duration":245000,"confidence":0.8}]}"""
            f.reply(detailsPage(row));f.reply("{}",404);repository.load(route)
            val detail=repository.state.value.detail!!
            assertEquals("https://www.youtube.com/watch?v=exact-source",detail.sourceUrl)
            assertEquals(TrackId(7),detail.track.id)
            assertEquals(185000L,detail.track.durationMs)
            assertEquals("Live edition",detail.suggestions.single().album)
            assertEquals(245000L,detail.suggestions.single().durationMs)
            val request=f.server.takeRequest(3,java.util.concurrent.TimeUnit.SECONDS)!!
            assertTrue(request.url.queryParameter("fields")!!.split(',').contains("source_url"))
        }
    }
}
