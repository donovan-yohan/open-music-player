package com.soundq.android.playback.system

import org.junit.Assert.*
import org.junit.Test

class SystemPolicyTest {
    @Test fun duckAndTransientResumeButManualPauseNoisyPermanentAndPendingPlayDoNot() {
        var active=true;var pauses=0;var resumes=0
        val p=InterruptionPolicy({active},{active=false;pauses++},{active=true;resumes++})
        p.loss(true);assertFalse(active);assertEquals(1,pauses)
        p.loss(true);p.gain();assertTrue(active);assertEquals(1,resumes)
        p.loss(true);p.command();p.gain();assertFalse(active);assertEquals(1,resumes)
        active=true;p.loss(true);p.loss(false);p.gain();assertFalse(active)
        active=true;p.loss(false);p.gain();assertFalse(active)
        p.loss(true);p.gain();assertEquals(1,resumes) // pending/preparing is not active playback
    }
    @Test fun onlyVerifiedOsTrustOrOwnUidCanConnect() {
        for(same in listOf(false,true))for(trust in listOf(false,true))for(verified in listOf(false,true))
            assertEquals(same || (trust && verified),systemControllerAllowed(same,trust,verified))
    }
}
