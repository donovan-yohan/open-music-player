package com.soundq.android.playback.listening

import com.soundq.android.data.timeline.*
import com.soundq.android.playback.mix.*
import org.junit.Assert.*
import org.junit.Test

class ListeningScheduleTest {
    private fun source(id: String, duration: Long = 10000) = TimelineSource(id, 7, id, duration, QueueSegment.Context)
    @Test fun halfDurationBoundAndZeroPreserveOriginalSourceExtents() {
        val inputs = listOf(source("a", 10001), source("b", 3001), source("c", 9000))
        val bounded = ListeningSchedule.compile(inputs, 12000)
        assertEquals(listOf(0L, 8501L, 10002L), bounded.occurrences.map { it.startMs })
        assertEquals(listOf(1500L, 1500L, 0L), bounded.occurrences.map { it.fadeOutMs })
        assertEquals(inputs, bounded.occurrences.map { it.source })
        val zero = ListeningSchedule.compile(inputs, 0)
        assertEquals(sequentialTimeline(inputs).map { it.globalStartMs }, zero.occurrences.map { it.startMs })
        assertEquals(listOf("b"), zero.observe(10001).active.map { it.occurrence.source.occurrence })
        assertEquals(0L, zero.observe(10001).selected!!.sourceMs)
        assertEquals(13002L, zero.globalAt("c", 0))
    }
    @Test fun emptyPreservesConfiguredDefaultWithoutOpeningAnEmptyNativeStream() {
        val empty = ListeningSchedule.compile(emptyList(), 4321)
        assertEquals(4321L, empty.defaultOverlapMs); assertEquals(0L, empty.durationMs)
        assertNull(empty.observe(0).selected)
        assertTrue(runCatching { empty.renderPlan(emptyMap()) }.isFailure)
    }
    @Test fun rejectsMalformedSourcesDefaultsAndSeekBounds() {
        val a = source("a")
        for (inputs in listOf(listOf(a, a), listOf(a.copy(occurrence = " ")), listOf(a.copy(track = 0)), listOf(a.copy(durationMs = 0)), listOf(a.copy(durationMs = Long.MAX_VALUE)), List(501) { source("$it") })) {
            assertTrue(runCatching { ListeningSchedule.compile(inputs, 3000) }.isFailure)
        }
        for (overlap in listOf(-1L, 12001L, Long.MAX_VALUE)) assertTrue(runCatching { ListeningSchedule.compile(listOf(a), overlap) }.isFailure)
        val s = ListeningSchedule.compile(listOf(a), 3000)
        assertTrue(runCatching { s.observe(-1) }.isFailure)
        assertTrue(runCatching { s.globalAt("a", -1) }.isFailure)
        assertTrue(runCatching { s.globalAt("a", 10001) }.isFailure)
        assertTrue(runCatching { s.globalAt("absent", 0) }.isFailure)
        assertTrue(runCatching { s.renderPlan(emptyMap()) }.isFailure)
        assertTrue(runCatching { s.renderPlan(mapOf("a" to "file", "extra" to "file")) }.isFailure)
        assertTrue(runCatching { s.renderPlan(mapOf("a" to " ")) }.isFailure)
    }
    @Test fun singleAndOneMillisecondSourcesDoNotInventFades() {
        val single = ListeningSchedule.compile(listOf(source("a")), 12000)
        assertEquals(10000L, single.durationMs); assertEquals(1.0, single.observe(9999).selected!!.gain, 0.0)
        val tiny = ListeningSchedule.compile(listOf(source("a", 1), source("b", 1)), 12000)
        assertEquals(listOf(0L, 1L), tiny.occurrences.map { it.startMs })
        assertEquals(2L, tiny.durationMs)
    }
    @Test fun snapshotsDoNotAliasCallerCollections() {
        val sources = mutableListOf(source("a"), source("b"))
        val s = ListeningSchedule.compile(sources, 3000); sources.clear()
        assertEquals(2, s.occurrences.size)
        val paths = mutableListOf("a.opus")
        val events = mutableListOf(MixRenderEvent(1, 0, 1, .5f))
        val clips = mutableListOf(MixRenderClip(0, 10, 0, paths = paths, events = events))
        val plan = MixRenderPlan(10, clips); paths.clear(); events.clear(); clips.clear()
        assertEquals(listOf("a.opus"), plan.clips.single().paths)
        assertEquals(1, plan.clips.single().events.size)
    }
    @Test fun acceptedRendererMetadataCannotBeMutatedThroughListCasts() {
        val plan = MixRenderPlan(10, listOf(MixRenderClip(0, 10, 0, paths = listOf("a.opus"), events = listOf(MixRenderEvent(0, 0, 1, 1f)))))
        assertTrue(runCatching { (plan.sources as MutableList<String>).clear() }.isFailure)
        assertTrue(runCatching { (plan.clips as MutableList<MixRenderClip>).clear() }.isFailure)
        assertTrue(runCatching { (plan.clips.single().paths as MutableList<String>).clear() }.isFailure)
        assertTrue(runCatching { (plan.clips.single().events as MutableList<MixRenderEvent>).clear() }.isFailure)
    }
    @Test fun rendererRefusesInvalidExtentGainFadeBusAndArithmetic() {
        val c = MixRenderClip(0, 10, 0, paths = listOf("a.opus"))
        for (bad in listOf(c.copy(startMs = -1), c.copy(endMs = 0), c.copy(sourceStartMs = -1), c.copy(sourceStartMs = Long.MAX_VALUE), c.copy(fadeInMs = 6, fadeOutMs = 5), c.copy(fadeOutMs = -1), c.copy(gainDb = Double.NaN), c.copy(gainDb = 1.0), c.copy(paths = emptyList()), c.copy(events = listOf(MixRenderEvent(0, 1, 1, 1f))), c.copy(events = listOf(MixRenderEvent(0, 0, 251, 1f))))) {
            assertTrue(runCatching { MixRenderPlan(10, listOf(bad)) }.isFailure)
        }
        assertTrue(runCatching { MixRenderPlan(11, listOf(c)) }.isFailure)
        assertTrue(runCatching { MixRenderPlan(10, listOf(c), listOf("other.opus")) }.isFailure)
        assertTrue(runCatching { NativeMixStream(MixRenderPlan(Long.MAX_VALUE, listOf(c.copy(endMs = Long.MAX_VALUE)))) }.isFailure)
        assertTrue(runCatching { NativeMixStream(MixRenderPlan(12000000, listOf(c.copy(endMs = 12000000)))) }.isFailure)
    }
}
