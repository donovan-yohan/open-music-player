package com.soundq.android.playback.listening

import androidx.media3.common.Player
import com.soundq.android.data.SecretTokens
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest=Config.NONE,sdk=[28],application=android.app.Application::class)
internal class ListeningDelayedAccountTest {
    private fun offMain(block:()->Unit) {
        var failure:Throwable?=null
        val thread=Thread {try {block()}catch(t:Throwable){failure=t}}
        thread.start();thread.join(5000);assertFalse(thread.isAlive)
        failure?.let {throw it}
    }
    @Test fun missedLocalLockStillRetiresPlayingRenderAndPreservesSourceCursor() {
        ServiceProbe().use {h->
            h.install();h.ready();h.present(8500)
            offMain {
                assertTrue(h.graph.session.lockLocal())
                assertTrue(h.graph.session.completeLocalUnlock(h.graph.session.localUnlockTicket()!!))
            }
            h.settle{!h.playing}
            assertEquals(2,h.player.mediaItemCount);assertEquals("visit-b",h.player.currentMediaItem!!.mediaId)
            assertEquals(1500L,h.player.currentPosition);assertFalse(h.player.playWhenReady)
            assertEquals(0,h.outputItems);assertEquals(0,h.privateFiles())
        }
    }
    @Test fun twoUnobservedLocalCyclesRetainSameLogicalContextPaused() {
        ServiceProbe().use {h->
            h.install();h.ready();h.present(8500)
            offMain {repeat(2){
                assertTrue(h.graph.session.lockLocal())
                assertTrue(h.graph.session.completeLocalUnlock(h.graph.session.localUnlockTicket()!!))
            }}
            h.settle{!h.playing}
            assertEquals(2,h.player.mediaItemCount);assertEquals("visit-b",h.player.currentMediaItem!!.mediaId)
            assertEquals(1500L,h.player.currentPosition);assertFalse(h.player.playWhenReady)
            assertEquals(0,h.outputItems);assertEquals(0,h.privateFiles())
            h.graph.session.retire();h.settle{h.player.mediaItemCount==0}
            assertNull(h.player.currentMediaItem)
        }
    }
    @Test fun equalSignedInReplacementBeforeCollectorTurnClearsOldContext() {
        ServiceProbe().use {h->
            h.install();h.ready();h.present(8500);h.player.pause()
            offMain {assertTrue(h.graph.session.accept(h.graph.session.beginIntent(),SecretTokens("fresh-a","fresh-r","tracer")))}
            h.settle{h.player.mediaItemCount==0}
            assertNull(h.player.currentMediaItem);assertEquals(0,h.outputItems)
            assertEquals(0,h.privateFiles());assertFalse(h.player.playWhenReady)
            assertEquals(Player.STATE_IDLE,h.player.playbackState)
        }
    }
}
