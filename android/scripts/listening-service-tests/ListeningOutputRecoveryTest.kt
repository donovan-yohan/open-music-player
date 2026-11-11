package com.soundq.android.playback.listening

import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest=Config.NONE,sdk=[28],application=android.app.Application::class)
internal class ListeningOutputRecoveryTest {
    @Test fun explicitPrepareAfterPhysicalFailureClearsErrorAndKeepsLogicalCursor() {
        ServiceProbe().use {h->
            h.install();h.ready();h.present(8500)
            h.player.repeatMode=Player.REPEAT_MODE_ALL
            val requests=h.requestCount;val factory=h.sourceFactory;val plays=h.playCalls
            h.physicalState=Player.STATE_IDLE;h.playing=false
            val failure=PlaybackException("Synthetic decoder failure",null,PlaybackException.ERROR_CODE_DECODING_FAILED)
            h.listeners.toList().forEach {it.onPlayerError(failure)}
            assertSame(failure,h.player.playerError);assertFalse(h.player.playWhenReady)
            h.player.prepare()
            assertNull(h.player.playerError)
            h.ready();assertEquals("visit-b",h.player.currentMediaItem!!.mediaId)
            assertEquals(1500L,h.player.currentPosition);assertFalse(h.playing)
            assertEquals(Player.REPEAT_MODE_ALL,h.player.repeatMode);assertEquals(requests,h.requestCount)
            assertSame(factory,h.sourceFactory);assertEquals(2,h.privateFiles());assertEquals(plays,h.playCalls)
            h.player.play();assertTrue(h.playing)
        }
    }
}
