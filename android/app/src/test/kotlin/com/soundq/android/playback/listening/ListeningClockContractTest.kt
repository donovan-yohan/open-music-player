package com.soundq.android.playback.listening

import com.soundq.android.data.timeline.*
import org.junit.Assert.*
import org.junit.Test

internal data class ClockPoint(val occurrence: String, val sourceMs: Long, val durationMs: Long, val gain: Double, val segment: QueueSegment)
internal data class ClockReading(val active: List<ClockPoint>, val selected: ClockPoint?)
internal interface ClockProbe {
    val starts: List<Long>
    fun observe(globalMs: Long): ClockReading
    fun globalAt(occurrence: String, sourceMs: Long): Long
}
class ListeningClockContractTest {
    @Test fun literalExecutedFlutterClocksRetainMultiplicityDominanceAndHeadConsumption() {
        val sources = listOf("a", "b", "c").mapIndexed { i, id -> TimelineSource(id, 7, "Same recording", 10000, QueueSegment.entries[i]) }
        val schedule = createClockProbe(sources, 3000)
        assertEquals(listOf(0L, 7000L, 14000L), schedule.starts)
        val expected = listOf(
            Triple(0L, "a", 0L), Triple(6999L, "a", 6999L), Triple(7000L, "a", 7000L),
            Triple(8000L, "a", 8000L), Triple(8500L, "b", 1500L), Triple(9000L, "b", 2000L),
            Triple(10000L, "b", 3000L), Triple(14000L, "b", 7000L), Triple(15500L, "c", 1500L), Triple(20000L, "c", 6000L)
        )
        expected.forEach { (global, id, local) ->
            val reading = schedule.observe(global)
            assertEquals("selected at $global", id, reading.selected?.occurrence)
            assertEquals(local, reading.selected!!.sourceMs)
            assertEquals(10000L, reading.selected.durationMs)
        }
        val active = schedule.observe(8000).active
        assertEquals(listOf("a", "b"), active.map { it.occurrence })
        assertEquals(listOf(8000L, 1000L), active.map { it.sourceMs })
        assertEquals(listOf(QueueSegment.Manual, QueueSegment.Context), active.map { it.segment })
        assertEquals(kotlin.math.sqrt(3.0) / 2, active[0].gain, 1e-12)
        assertEquals(.5, active[1].gain, 1e-12)
        assertEquals(listOf("b"), schedule.observe(10000).active.map { it.occurrence })
        assertTrue(schedule.observe(24000).active.isEmpty())
        assertNull(schedule.observe(24000).selected)
        assertEquals(7000L, schedule.globalAt("b", 0))
        assertEquals(17000L, schedule.globalAt("b", 10000))
        assertEquals(8500L, schedule.globalAt("b", 1500))
        assertEquals(9500L, schedule.globalAt("a", 9500))
    }
}
