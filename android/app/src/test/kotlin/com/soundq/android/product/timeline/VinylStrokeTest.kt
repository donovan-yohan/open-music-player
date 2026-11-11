package com.soundq.android.product.timeline

import org.junit.Assert.*
import org.junit.Test

class VinylStrokeTest {
    @Test fun sourceScaleAndFractionalMotionPreserveSignedVelocity() {
        val stroke=VinylStroke(0.002)
        stroke.begin(100f,1_000_000_000L)
        assertEquals(0.25,stroke.move(100.5f,1_004_000_000L)!!,1e-12)
        assertEquals(-0.125,stroke.move(100.25f,1_008_000_000L)!!,1e-12)
        assertEquals(0.0,stroke.move(100.25f,1_012_000_000L)!!,0.0)
    }
    @Test fun duplicateAndOlderTimesDoNotReplaceTheLastAcceptedSample() {
        val stroke=VinylStroke(0.001)
        stroke.begin(0f,1_000_000_000L)
        assertNull(stroke.move(900f,1_000_000_000L))
        assertNull(stroke.move(900f,999_000_000L))
        assertEquals(0.5,stroke.move(5f,1_010_000_000L)!!,1e-12)
    }
    @Test fun rateLimitsAreSymmetricAndDoNotAccumulateOutwardDebt() {
        val stroke=VinylStroke(1.0)
        stroke.begin(0f,1_000_000_000L)
        assertEquals(8.0,stroke.move(100f,1_001_000_000L)!!,0.0)
        assertEquals(-1.0,stroke.move(99f,2_001_000_000L)!!,0.0)
    }
    @Test fun everyMicroStrokeContributesWithoutIntegerMillisecondRounding() {
        val stroke=VinylStroke(0.001)
        stroke.begin(0f,1_000_000_000L)
        var integratedSeconds=0.0
        repeat(64){i->integratedSeconds+=stroke.move((i+1)/64f,1_000_000_000L+(i+1)*1_000_000L)!!*0.001}
        assertEquals(0.001,integratedSeconds,1e-12)
    }
    @Test fun retiredStrokeCannotGenerateMoreMovementUntilFreshBegin() {
        val stroke=VinylStroke(0.001)
        assertNull(stroke.move(5f,1_010_000_000L))
        stroke.begin(0f,1_000_000_000L);stroke.end()
        assertNull(stroke.move(5f,1_010_000_000L))
        stroke.begin(10f,2_000_000_000L)
        assertEquals(-1.0,stroke.move(0f,2_010_000_000L)!!,1e-12)
    }
    @Test fun invalidCoordinatesCannotPoisonTheNextValidMovement() {
        val stroke=VinylStroke(0.001)
        stroke.begin(0f,1_000_000_000L)
        assertNull(stroke.move(Float.NaN,1_005_000_000L))
        assertEquals(1.0,stroke.move(10f,1_010_000_000L)!!,1e-12)
    }
}
