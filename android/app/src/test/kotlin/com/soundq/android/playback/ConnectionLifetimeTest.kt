package com.soundq.android.playback
import org.junit.Assert.*
import org.junit.Test
class ConnectionLifetimeTest {
    @Test fun closeReleasesExactlyOnceAndRefusesLatePublication() {
        var releases = 0
        val lifetime = ConnectionLifetime { releases++ }
        assertTrue(lifetime.active)
        lifetime.close()
        lifetime.close()
        assertFalse(lifetime.active)
        assertEquals(1, releases)
    }
}
