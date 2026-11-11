package com.soundq.android.product.trackdetails

import com.soundq.android.data.preferences.KeyNotation
import com.soundq.android.data.trackdetails.AnalysisDetail
import kotlinx.serialization.json.*
import java.util.Locale
import org.junit.Assert.*
import org.junit.Test

class KeyNotationFormatterTest {
    @Test fun defaultCamelotAndMusicalChoiceUseIndependentFactsWithFallback() {
        assertEquals("8A",formatAnalysisKey(" Am "," 8a "))
        assertEquals("Am",formatAnalysisKey(" Am "," 8a ",KeyNotation.Musical))
        assertEquals("F# major",formatAnalysisKey(" F# major ",null))
        assertEquals("11B",formatAnalysisKey(" \n "," 11b ",KeyNotation.Musical))
        assertNull(formatAnalysisKey(null,null));assertNull(formatAnalysisKey(" \t ","\n"))
    }
    @Test fun onlyValidCamelotIsAdmittedWithoutConversionOrLocaleDependence() {
        val before=Locale.getDefault()
        try {
            Locale.setDefault(Locale.forLanguageTag("tr-TR"))
            for(number in 1..12)for(letter in listOf("a","b"))assertEquals("$number${letter.uppercase(Locale.ROOT)}",formatAnalysisKey("unrelated"," $number$letter "))
            for(invalid in listOf("0A","13B","01A","8C","8 A","A8","8a junk","8İ","")) {
                assertEquals("raw music",formatAnalysisKey("raw music",invalid))
                assertNull(formatAnalysisKey(null,invalid,KeyNotation.Musical))
            }
            assertEquals("Am",formatAnalysisKey("Am",null));assertNull(formatAnalysisKey(null,null))
        }finally {Locale.setDefault(before)}
    }
    @Test fun existingManualGeneratedPrecedenceAndRawCorrectionValuesRemainUntouched() {
        val analysis=AnalysisDetail(7,"analyzed",
            buildJsonObject {putJsonObject("key"){put("value","Dm")};putJsonObject("camelot"){put("value","7A")}},
            buildJsonObject{},buildJsonObject {putJsonObject("key"){put("value"," Am ")};putJsonObject("camelot"){put("value"," 8a ")}})
        assertEquals("8A",formatAnalysisKey(analysis.text("key"),analysis.text("camelot")))
        assertEquals("Am",formatAnalysisKey(analysis.text("key"),analysis.text("camelot"),KeyNotation.Musical))
        assertEquals(" Am ",analysis.text("key"));assertEquals(" 8a ",analysis.text("camelot"))
        val fallback=analysis.copy(overrides=buildJsonObject {put("key",JsonNull);put("camelot",JsonNull)})
        assertEquals("7A",formatAnalysisKey(fallback.text("key"),fallback.text("camelot")))
        assertEquals("Dm",formatAnalysisKey(fallback.text("key"),fallback.text("camelot"),KeyNotation.Musical))
    }
}
