package com.soundq.android.playback

import org.junit.Assert.*
import org.junit.Test

class ContextAdmissionTest {
    @Test fun incomingContextLimitMatchesServiceWhileLeavingManualCarryPolicyIntact() {
        assertEquals(500, QueuePolicy.MAX_CONTEXT_TRACKS)
        assertFalse(QueuePolicy.acceptsContext(0))
        assertTrue(QueuePolicy.acceptsContext(2))
        assertTrue(QueuePolicy.acceptsContext(500))
        assertFalse(QueuePolicy.acceptsContext(501))
        assertFalse(QueuePolicy.acceptsContext(Int.MAX_VALUE))
        assertEquals(listOf(2, 4), QueuePolicy.carriedManual(listOf(true, false, true, false, true), 1))
    }
}
