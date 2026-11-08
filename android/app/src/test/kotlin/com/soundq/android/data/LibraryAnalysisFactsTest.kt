package com.soundq.android.data

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class LibraryAnalysisFactsTest {
    private fun read(raw:String)=libraryAnalysisFacts(Json.parseToJsonElement(raw).jsonObject)
    @Test fun missingUnknownOrMalformedOptionalFactsDoNotInventZeroValues() {
        for(raw in listOf("{}","""{"analysis_status":"future","analysis_summary":null}""","""{"analysis_summary":{"bpm":{"value":"128"},"key":{"value":42},"camelot":{"value":"13A"}}}""","""{"analysis_summary":{"bpm":{"value":0},"key":{"value":" "},"camelot":{"value":"bad"}}}"""))assertNull(read(raw))
    }
    @Test fun independentFactsRemainAvailableWhenASiblingIsInvalid() {
        assertEquals(LibraryAnalysisFacts("stale",null,"A minor","8A"),read("""{"analysis_status":"stale","analysis_summary":{"bpm":{"value":-1},"key":{"value":" A minor "},"camelot":{"value":"8a"}}}"""))
        assertEquals(LibraryAnalysisFacts(null,128.5,null,null),read("""{"analysis_summary":{"bpm":{"value":128.5},"camelot":{"value":"0B"}}}"""))
    }
    @Test fun compactFactsDoNotAdoptWaveformsTimingOrUnknownFields() {
        val body=buildJsonObject {put("analysis_status","analyzed");put("analysis_summary",buildJsonObject {put("bpm",buildJsonObject {put("value",128)});put("key",buildJsonObject {put("value","x".repeat(101))});put("waveform",buildJsonArray {repeat(100){add(0.5)}});put("manual_timing_v2",buildJsonObject {put("bpm",90)})})}
        assertEquals(LibraryAnalysisFacts("analyzed",128.0,null,null),libraryAnalysisFacts(body))
    }
}
