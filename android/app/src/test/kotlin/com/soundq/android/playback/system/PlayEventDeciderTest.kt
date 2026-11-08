package com.soundq.android.playback.system

import org.junit.Assert.*
import org.junit.Test

/** Mirrors executed Flutter vectors. Position threshold is not a continuous-listening metric. */
class PlayEventDeciderTest {
    @Test fun rawPositionThresholdCompletionAndSameTrackDedupMatchFlutter() {
        val d=PlayEventDecider()
        assertNull(d.observePosition("a",7,29_999))
        assertEquals(7L,d.observePosition("a",7,30_000))
        assertNull(d.completed("a",7))
        assertNull(d.observePosition("same-track-next-occurrence",7,45_000))
        assertNull(d.completed("same-track-next-occurrence",7))
        assertNull(d.observePosition("b",8,0));assertEquals(8L,d.completed("b",8))
        assertNull(d.observePosition("c",9,0));assertEquals(9L,d.completed("c",9))
        d.reset();assertNull(d.completed("c",9))
        assertEquals(7L,d.observePosition("seek-or-restore",7,45_000))
    }
    @Test fun completionCannotBeMisattributedToDifferentOccurrence() {
        val d=PlayEventDecider()
        d.observePosition("a",7,0);d.observePosition("b",8,0)
        assertNull(d.completed("a",7));assertNull(d.completed("b",7));assertEquals(8L,d.completed("b",8))
        d.reset();assertNull(d.observePosition("restored",7,29_000));assertEquals(7L,d.observePosition("restored",7,30_000))
    }
}
