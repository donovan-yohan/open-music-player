package com.soundq.android.playback.mix

import com.soundq.android.data.mix.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class MixRenderAdapterTest {
    private fun clip(extra: String = "") = MixJson.clip(Json.parseToJsonElement("""{"clipId":"clip-a","queueItemId":"a","trackId":7,"sourceStartMs":0,"sourceEndMs":10000,"timelineStartMs":0$extra}""").jsonObject)
    private fun plan(c: MixClip) = SavedMix("00000000-0000-4000-8000-000000000001", 1, "Saved", listOf(c))
    @Test fun savedAdapterStillRevalidatesRawDocumentAndUnsupportedPolicies() {
        assertTrue(runCatching { plan(clip(",\"tempoPolicy\":\"constantTempoLock\"")).renderPlan(mapOf(7L to "a.opus"), emptyMap()) }.isFailure)
        assertTrue(runCatching { plan(clip(",\"gainDb\":1")).renderPlan(mapOf(7L to "a.opus"), emptyMap()) }.isFailure)
        val valid = clip()
        val edited = valid.copy(json = JsonObject(valid.json + ("unsupported" to JsonPrimitive(1))))
        assertTrue(runCatching { plan(edited).renderPlan(mapOf(7L to "a.opus"), emptyMap()) }.isFailure)
        assertTrue(runCatching { plan(valid).renderPlan(emptyMap(), emptyMap()) }.isFailure)
        assertTrue(runCatching { plan(valid).renderPlan(mapOf(7L to "a.opus"), mapOf("clip-a" to PreparedMixStems(listOf("vocals"), listOf("v.opus")))) }.isFailure)
        val rendered = plan(valid).renderPlan(mapOf(7L to "a.opus"), emptyMap())
        assertEquals(10000L, rendered.durationMs)
        assertEquals(listOf("a.opus"), rendered.sources)
    }
}
