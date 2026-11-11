package com.soundq.android.product.timeline

import org.junit.Assert.*
import org.junit.Test

class TempoTransitionControlsTest {
    @Test fun numericInputKeepsInvalidDraftAndUsesActualHostLimits() {
        for(value in listOf("", "no", "NaN", "Infinity", "0", "-1", "59.9", "200.1"))
            assertNotNull(value,tempoBpmInputError(value,60.0,200.0))
        assertNull(tempoBpmInputError("124.25",60.0,200.0))
        assertNull(tempoBpmInputError("60",60.0,200.0))
        assertNull(tempoBpmInputError("200",60.0,200.0))
        assertNotNull(tempoBpmInputError("120",null,null))
        assertNotNull(tempoBpmInputError("120",Double.NaN,200.0))
        assertNotNull(tempoBpmInputError("120",200.0,60.0))
    }
}
