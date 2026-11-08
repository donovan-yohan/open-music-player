package com.soundq.android.playback

import com.soundq.android.data.timeline.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ArrangementFadePathTest {
    @Test fun authoredFadeFieldsReachStrictArrangementPlanWithoutDroppingDuplicateOccurrences() {
        val raw="""{"revision":4,"clips":[{"occurrence":"out","track":7,"title":"Duplicate","sourceDurationMs":2000,"sourceInMs":250,"sourceOutMs":1500,"globalStartMs":0,"segment":"Context","fadeOutMs":750},{"occurrence":"in","track":7,"title":"Duplicate","sourceDurationMs":2000,"sourceInMs":0,"sourceOutMs":1250,"globalStartMs":500,"segment":"Context","fadeInMs":750}]}"""
        // Test-only predecessor adapter permits reaching the old plan mapper rather than stopping at its absent DTO fields.
        val document=Json {ignoreUnknownKeys=true}.decodeFromString<TimelineDocument>(raw)
        val plan=document.arrangementPlan()
        assertEquals(listOf("out","in"),plan.clips.map {it.occurrence})
        assertEquals(750L,plan.clips[0].fadeOut)
        assertEquals(750L,plan.clips[1].fadeIn)
        assertTrue(document.matchesArrangement(plan))
    }
}
