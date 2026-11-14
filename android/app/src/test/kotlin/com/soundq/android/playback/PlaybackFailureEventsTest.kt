package com.soundq.android.playback

import org.junit.Assert.assertEquals
import org.junit.Test

class PlaybackFailureEventsTest {
    @Test fun equivalentOutputErrorsAndHealthyPollsAreNotNewFailures() {
        val events=PlaybackFailureEvents()
        repeat(50) {events.audio(null,null)}
        assertEquals(0L,events.revision)
        repeat(500) {events.audio(1,"Audio output unavailable")}
        assertEquals(1L,events.revision)
    }
    @Test fun canonicalClearRearmsSameFailureEvenWithoutAnIntermediateUiPublication() {
        val events=PlaybackFailureEvents()
        events.audio(1,"route")
        events.audio(null,null)
        events.audio(1,"route")
        assertEquals(2L,events.revision)
    }
    @Test fun changedFailureAndExplicitContextRefusalGetNewReceipts() {
        val events=PlaybackFailureEvents()
        events.audio(1,"route");events.audio(2,"decode")
        assertEquals(2L,events.revision)
        events.contextRefused()
        assertEquals(3L,events.revision)
    }
}
