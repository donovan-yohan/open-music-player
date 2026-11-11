package com.soundq.designsystem

import org.junit.Assert.*
import org.junit.Test

class QuickQueueStateTest {
    @Test fun retreatBelowThresholdClosesAndOpeningFromTrayStillNeedsLeftCrossing() {
        val s=RowRevealState(RowRevealOwner());s.begin(0f)
        s.follow(-170f,184f);s.follow(-150f,184f)
        assertFalse(s.end(112f,.5f,0f,.3f));assertFalse(s.targetOpen)
        s.complete(s.revision,112f);s.request(true);s.complete(s.revision,112f)
        s.begin(-112f);assertTrue(s.follow(-48f,184f));assertTrue(s.end(112f,.5f,0f,.3f))
    }
    @Test fun retreatRearmCancelAndDisabledGeometryDoNotReplay() {
        val s=RowRevealState(RowRevealOwner());s.begin(0f)
        assertTrue(s.follow(-170f,184f));assertFalse(s.follow(-159f,184f));assertFalse(s.armed)
        assertTrue(s.follow(-160f,184f));assertTrue(s.armed)
        assertFalse(s.end(112f,.5f,0f,.3f,cancel=true));assertFalse(s.armed)
        s.complete(s.revision,112f);s.begin(0f,Float.POSITIVE_INFINITY)
        assertFalse(s.follow(-500f,112f));assertFalse(s.end(112f,.5f,-100f,.3f))
        s.dispose();assertFalse(s.end(112f,.5f,0f,.3f))
    }
    @Test fun leftThresholdHapticsThenReleaseQueuesExactlyOnce() {
        val s=RowRevealState(RowRevealOwner())
        s.begin(0f)
        assertEquals(false,s.follow(-112f,184f))
        assertEquals(true,s.follow(-160f,184f))
        assertEquals(false,s.follow(-180f,184f))
        assertEquals(true,s.end(112f,0.5f,0f,0.3f))
        assertEquals(false,s.end(112f,0.5f,0f,0.3f))
        assertFalse(s.targetOpen)
        assertFalse(s.frontTap())
        s.complete(s.revision,112f)
        assertEquals(0f,s.offset)
    }
}
