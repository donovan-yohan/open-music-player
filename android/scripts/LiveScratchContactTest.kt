package com.soundq.android.product.timeline

import org.junit.Assert.*
import org.junit.Test

/** The runnable contact probe supplies only the Media3/clock boundary, not hardware. */
class LiveScratchContactTest {
    @Test fun cancellationAndUpAreCausallyAfterTheLastMove() {
        for(cancel in listOf(false,true)) {
            val controller=com.soundq.android.playback.ControllerProjection()
            val contact=LiveScratchContact(controller,com.soundq.android.playback.ArrangementIdentity(),"incoming"){true}
            contact.begin(1_000_000_000L)
            contact.move(-0.01,1_010_000_000L)
            contact.finish(1_010_000_000L,cancel)
            assertTrue("Terminal must pass the real player's strict event ordering",controller.terminals.single().second>controller.moves.single().second)
            contact.retire();assertEquals(1,controller.terminals.size)
        }
    }
    @Test fun lateBeginAfterReleaseOnlyCancelsAndCannotForwardBufferedMotion() {
        val controller=com.soundq.android.playback.ControllerProjection().apply {held=true}
        val contact=LiveScratchContact(controller,com.soundq.android.playback.ArrangementIdentity(),"incoming"){true}
        contact.begin(1_000_000_000L);contact.move(0.01,1_010_000_000L);contact.finish(1_010_000_000L,false)
        controller.acknowledge()
        assertTrue(controller.moves.isEmpty());assertEquals("cancel",controller.terminals.single().first)
        assertTrue(controller.terminals.single().second>1_010_000_000L)
    }
}
