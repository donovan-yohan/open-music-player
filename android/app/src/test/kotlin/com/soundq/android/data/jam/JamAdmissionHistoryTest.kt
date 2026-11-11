package com.soundq.android.data.jam

import org.junit.Assert.*
import org.junit.Test

class JamAdmissionHistoryTest {
    @Test fun attemptIsLatchedBeforeUnknownAdmissionAndNeverEvicted() {
        val h=AdmissionHistory()
        assertTrue(h.begin("request"))
        assertTrue(h.attempted("request"))
        assertFalse(h.begin("request"))
        repeat(49){assertTrue(h.begin("r$it"))}
        assertFalse(h.begin("overflow"))
        assertFalse(h.begin("request"))
    }
}
