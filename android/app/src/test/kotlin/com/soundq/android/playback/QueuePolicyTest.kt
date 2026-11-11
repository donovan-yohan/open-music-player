package com.soundq.android.playback

import org.junit.Assert.*
import org.junit.Test

class QueuePolicyTest {
    @Test fun manualTracksPrecedeContextAndSurviveContextReplacement() {
        val origins=listOf(false,true,true,false,true)
        assertEquals(3,QueuePolicy.manualInsert(origins,0))
        assertEquals(listOf(1,2,4),QueuePolicy.carriedManual(origins,0))
        assertEquals(0,QueuePolicy.manualInsert(emptyList(),-1))
        assertEquals(listOf(4),QueuePolicy.carriedManual(origins,2))
    }
}
