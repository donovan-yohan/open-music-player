package com.soundq.designsystem

import org.junit.Assert.assertEquals
import org.junit.Test

class SongTimeTest {
    @Test fun hourBoundaryUsesTwoDigitHoursWithoutChangingSubhourClocks() {
        for ((ms, expected) in listOf(0L to "0:00", 59_999L to "0:59", 3_599_999L to "59:59",
            3_600_000L to "01:00:00", 12_372_000L to "03:26:12", 360_000_000L to "100:00:00")) {
            assertEquals("milliseconds=$ms", expected, formatSongTime(ms))
        }
    }
    @Test fun unknownNegativeAndLargestInputsKeepTheirExistingMeaning() {
        assertEquals("—:—", formatSongTime(null))
        assertEquals("0:00", formatSongTime(-1))
        assertEquals("0:00", formatSongTime(Long.MIN_VALUE))
        assertEquals("2562047788015:12:55", formatSongTime(Long.MAX_VALUE))
    }
    @Test fun compactClockUsesTheSamePresentationWithoutChangingNumericTiming() {
        val timing=CompactSongTiming(elapsedMs=3_600_000, totalMs=12_372_000, selected=true)
        assertEquals("01:00:00 / 03:26:12", timing.clockText)
        assertEquals("Elapsed 01:00:00, Duration 03:26:12", timing.clockDescription)
        assertEquals(3_600_000L,timing.elapsed)
        assertEquals(12_372_000L,timing.total)
    }
}
