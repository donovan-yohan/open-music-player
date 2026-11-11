package com.soundq.designsystem
import org.junit.Assert.assertEquals
import org.junit.Test
class MotionTest {
    @Test fun queueSettleUsesCanonicalListTimingAndZeroDurationReduction() {
        assertEquals(soundq.design.generated.SoundQComposeTokens.MOTION_DURATION_LIST,SoundQMotion().queue.durationMillis)
        assertEquals(0,SoundQMotion(reduced=true).queue.durationMillis)
    }
    @Test fun reducedMotionRemovesAnimatedDuration() {
        assertEquals(0, SoundQMotion(reduced = true).selection.durationMillis)
    }
}
