package com.soundq.android.data.connect

import org.junit.Assert.*
import org.junit.Test

class ConnectLeaseTest {
    @Test fun temporaryDisabledCannotBusyRetryOrPermanentlyLatch() {
        assertEquals(30_000L,LeaseRecovery.delayMillis(503))
        assertEquals(30_000L,LeaseRecovery.delayMillis(429))
    }
    @Test fun malformedSourceUuidIsNotNormalized() {
        assertTrue(runCatching {uuid("1-1-1-1-1")}.isFailure)
        assertTrue(runCatching {uuid("00000000-0000-0000-0000-000000000000")}.isFailure)
    }
}
