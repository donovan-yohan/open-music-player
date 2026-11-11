package com.soundq.designsystem

import org.junit.Assert.*
import org.junit.Test

class PrecisionBpmTest {
    @Test fun upwardMotionIncreasesAndRightEdgeIsOneHundredTimesFiner() {
        val coarse=PrecisionBpmGesture(120.0,80.0,180.0,0.0,100.0)
        val fine=PrecisionBpmGesture(120.0,80.0,180.0,1.0,100.0)
        assertEquals(122.0,coarse.move(0.0,90.0),1e-9)
        assertEquals(120.02,fine.move(1.0,90.0),1e-9)
        assertEquals(120.0,coarse.move(0.0,100.0),1e-9)
    }
    @Test fun movingHorizontallyChangesOnlyFutureSensitivityWithoutJumping() {
        val gesture=PrecisionBpmGesture(120.0,80.0,180.0,0.0,100.0)
        assertEquals(122.0,gesture.move(0.0,90.0),1e-9)
        assertEquals(122.0,gesture.move(1.0,90.0),1e-9)
        assertEquals(122.02,gesture.move(1.0,80.0),1e-9)
    }
    @Test fun diagonalMotionDoesNotDependOnPointerSamplingFrequency() {
        val coarse=PrecisionBpmGesture(120.0,80.0,180.0,0.0,100.0)
        val sampled=PrecisionBpmGesture(120.0,80.0,180.0,0.0,100.0)
        val expected=coarse.move(1.0,0.0)
        repeat(100){i->sampled.move((i+1)/100.0,100.0-(i+1))}
        assertEquals(expected,sampled.bpm,1e-9)
    }
    @Test fun clampingHasNoHiddenOvershootWhenDirectionReverses() {
        val gesture=PrecisionBpmGesture(179.0,80.0,180.0,0.0,100.0)
        assertEquals(180.0,gesture.move(0.0,0.0),0.0)
        assertEquals(179.8,gesture.move(0.0,1.0),1e-9)
    }
    @Test fun releaseAndCancelPermanentlyRetireTheContact() {
        val cancelled=PrecisionBpmGesture(120.0,80.0,180.0,0.0,100.0)
        cancelled.move(0.0,90.0)
        assertEquals(120.0,cancelled.cancel(),0.0)
        assertEquals(120.0,cancelled.move(0.0,0.0),0.0)
        val released=PrecisionBpmGesture(120.0,80.0,180.0,0.0,100.0)
        released.move(0.0,90.0)
        assertEquals(122.0,released.finish(),1e-9)
        assertEquals(122.0,released.move(0.0,0.0),1e-9)
    }
    @Test fun resetStartsAtCurrentValueEndsExactlyAtOriginalAndHasSmoothEndpoints() {
        assertEquals(151.25,precisionBpmReset(151.25,150.04,0.0),0.0)
        assertEquals(150.04,precisionBpmReset(151.25,150.04,1.0),0.0)
        val midpoint=precisionBpmReset(151.25,150.04,0.5)
        assertTrue(midpoint>150.04&&midpoint<151.25)
        assertEquals(150.04,precisionBpmReset(151.25,150.04,3.0),0.0)
        assertEquals(151.25,precisionBpmReset(151.25,150.04,-1.0),0.0)
    }
    @Test fun comparisonKeepsAboveBelowAndOriginalDistinct() {
        assertEquals(BpmRelation.Above,bpmRelation(151.25,150.04))
        assertEquals(BpmRelation.Below,bpmRelation(149.25,150.04))
        assertEquals(BpmRelation.Original,bpmRelation(150.04,150.04))
    }
}
