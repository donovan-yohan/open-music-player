package com.soundq.android.playback.listening

import androidx.media3.common.Player
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest=Config.NONE,sdk=[28],application=android.app.Application::class)
internal class ListeningNavigationTest {
    @Test fun nextUsesExistingMixedClockAndDoesNotCompleteOutgoingOrReplayHead() {
        ServiceProbe().use {h->
            val completed=mutableListOf<String>();h.onCompletion{completed+=it}
            h.install();h.ready();h.present(1000)
            h.player.seekToNextMediaItem()
            assertEquals("visit-b",h.player.currentMediaItem!!.mediaId);assertEquals(0L,h.player.currentPosition)
            assertEquals(7000L,h.global);assertTrue(h.playing);assertTrue(completed.isEmpty());assertEquals(1,h.outputItems)
        }
    }
    @Test fun previousAlwaysUsesPredecessorEvenPastToolkitRestartThreshold() {
        ServiceProbe().use {h->
            h.install();h.ready();h.present(12000);h.player.pause()
            assertEquals("visit-b",h.player.currentMediaItem!!.mediaId);assertEquals(5000L,h.player.currentPosition)
            h.player.seekToPrevious()
            assertEquals("visit-a",h.player.currentMediaItem!!.mediaId);assertEquals(0L,h.player.currentPosition)
            assertEquals(0L,h.global);assertFalse(h.playing)
        }
    }
    @Test fun firstPreviousRestartsFirstEvenWithRepeatAll() {
        ServiceProbe().use {h->
            h.install();h.ready();h.present(1000);h.player.repeatMode=Player.REPEAT_MODE_ALL
            h.player.seekToPrevious()
            assertEquals("visit-a",h.player.currentMediaItem!!.mediaId);assertEquals(0L,h.global)
            assertEquals(0L,h.player.currentPosition);assertTrue(h.playing)
        }
    }
    @Test fun nextAtTailOffDoesNothingOneRestartsAndAllWraps() {
        for(mode in listOf(Player.REPEAT_MODE_OFF,Player.REPEAT_MODE_ONE,Player.REPEAT_MODE_ALL))ServiceProbe().use {h->
            h.install();h.ready();h.present(12000);h.player.repeatMode=mode
            val seeks=h.seekCalls.size;h.player.seekToNextMediaItem()
            assertEquals(if(mode==Player.REPEAT_MODE_ALL)"visit-a"else"visit-b",h.player.currentMediaItem!!.mediaId)
            assertEquals(when(mode){Player.REPEAT_MODE_OFF->5000L;else->0L},h.player.currentPosition)
            assertEquals(when(mode){Player.REPEAT_MODE_OFF->12000L;Player.REPEAT_MODE_ONE->7000L;else->0L},h.global)
            if(mode==Player.REPEAT_MODE_OFF)assertEquals(seeks,h.seekCalls.size)
            assertTrue(h.playing)
        }
    }
    @Test fun emptyNavigationIsSafeAndAdvertisedCommandsHaveRealHandlers() {
        ServiceProbe().use {h->
            for(command in listOf(Player.COMMAND_SEEK_TO_NEXT,Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,Player.COMMAND_SEEK_TO_PREVIOUS,Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM))assertTrue("Missing logical navigation command $command",h.player.isCommandAvailable(command))
            h.player.seekToNextMediaItem();h.player.seekToPrevious();h.player.seekToPreviousMediaItem()
            assertEquals(0,h.player.mediaItemCount);assertTrue(h.seekCalls.isEmpty());assertEquals(0,h.playCalls)
        }
    }
    @Test fun navigationDuringPendingAcquisitionRetiresOldWorkWithoutAutoplay() {
        ServiceProbe(held=true).use {h->
            h.install();assertTrue(h.awaitAcquisition());h.player.seekToNextMediaItem()
            h.releaseAcquisition();h.settle{h.preparationSettled}
            assertEquals("visit-b",h.player.currentMediaItem!!.mediaId);assertEquals(0L,h.player.currentPosition)
            assertEquals(0,h.outputItems);assertEquals(0,h.playCalls);assertFalse(h.player.playWhenReady)
        }
    }
}
