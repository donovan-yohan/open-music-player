package com.soundq.android.performance

import org.junit.Assert.*
import org.junit.Test

class BoundedInteractionTraceTest {
    @Test fun preservesNanosecondsAndLossWithoutUnboundedRetention() {
        val trace=BoundedInteractionTrace(2)
        repeat(5){trace.frame(FrameSample(16_666_667,it.toLong(),4,5,16_666_666,2));trace.input(InputSample(301,4_000_000))}
        assertEquals(2,trace.frames.size);assertEquals(3,trace.discardedFrames)
        assertEquals(2,trace.inputs.size);assertEquals(3,trace.discardedInputs)
        assertEquals(16_666_667,trace.frames[0].totalNs);assertEquals(2,trace.frames[1].droppedCallbacks)
        assertEquals(301,trace.inputs[0].dispatchNs);assertEquals(4_000_000,trace.inputs[0].eventAgeNs)
    }
}
