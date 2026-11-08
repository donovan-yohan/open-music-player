package com.soundq.android.playback.listening

import androidx.media3.common.Player
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest=Config.NONE, sdk=[28], application=android.app.Application::class)
internal class ListeningQueueResetTest {
    @Test fun emptyReplacementClearsPlayingLogicalQueueWithoutCompletingIt() {
        ServiceProbe().use {h->
            val completed=mutableListOf<String>();h.onCompletion{completed+=it}
            h.install();h.ready();h.present(8500)
            h.player.setMediaItems(emptyList(),true)
            assertEquals(0,h.player.mediaItemCount);assertNull(h.player.currentMediaItem)
            assertTrue(h.player.currentTimeline.isEmpty)
            assertEquals(0L,h.player.currentPosition);assertEquals(Player.STATE_IDLE,h.player.playbackState)
            assertFalse(h.player.playWhenReady);assertFalse(h.playing);assertEquals(0,h.outputItems)
            assertTrue(completed.isEmpty());assertEquals(0,h.privateFiles())
            h.install();h.ready();assertTrue(h.playing);assertEquals("visit-a",h.player.currentMediaItem!!.mediaId)
        }
    }
    @Test fun clearAllRetiresHeldPreparationAndFreshQueueStillPrepares() {
        ServiceProbe(held=true).use {h->
            h.install();assertTrue(h.awaitAcquisition())
            h.player.clearMediaItems()
            assertEquals(0,h.player.mediaItemCount);assertFalse(h.player.playWhenReady)
            h.releaseAcquisition();h.settle{h.preparationSettled}
            assertEquals(0,h.outputItems);assertEquals(0,h.playCalls);assertEquals(0,h.privateFiles())
            h.install();h.ready();assertTrue(h.playing);assertEquals(2,h.player.mediaItemCount)
        }
    }
    @Test fun clearDuringRepeatCompletionDoesNotRestartOrCallRetiredRecorder() {
        ServiceProbe().use {h->
            h.install();h.ready();h.player.repeatMode=Player.REPEAT_MODE_ONE
            h.onCompletion{h.player.clearMediaItems()}
            var staleCalls=0;h.onCompletion{staleCalls++}
            val seeks=h.seekCalls.size
            h.present(10000)
            assertEquals(0,h.player.mediaItemCount);assertEquals(0,h.outputItems)
            assertEquals(seeks,h.seekCalls.size);assertEquals(0,staleCalls);assertFalse(h.playing)
        }
    }
    @Test fun clearRetainsNativeCopiesUntilOutstandingLoaderCloses() {
        ServiceProbe().use {h->
            h.install();h.ready();val reader=h.render()
            try {
                reader.open(androidx.media3.datasource.DataSpec(android.net.Uri.parse("soundqlistening://render/reset")))
                assertEquals(2,h.privateFiles())
                h.player.clearMediaItems()
                assertEquals(0,h.player.mediaItemCount);assertEquals(2,h.privateFiles())
                assertTrue(runCatching{reader.read(ByteArray(8),0,8)}.isFailure)
            }finally {reader.close()}
            assertEquals(0,h.privateFiles())
        }
    }
}
