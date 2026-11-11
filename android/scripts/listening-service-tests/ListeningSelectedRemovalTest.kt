package com.soundq.android.playback.listening

import androidx.media3.common.Player
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest=Config.NONE,sdk=[28],application=android.app.Application::class)
internal class ListeningSelectedRemovalTest {
    @Test fun selectedRemovalDuringEofRevokesRemainingOldCallbacksAndRepeatRestart() {
        ServiceProbe().use {h->
            h.install();h.ready();h.player.repeatMode=Player.REPEAT_MODE_ONE
            h.onCompletion {h.player.removeMediaItem(h.player.currentMediaItemIndex)}
            var staleCalls=0;h.onCompletion{staleCalls++}
            h.present(10000);h.ready()
            assertEquals("visit-a",h.player.currentMediaItem!!.mediaId);assertEquals(0L,h.player.currentPosition)
            assertEquals(0,staleCalls);assertEquals(Player.REPEAT_MODE_ONE,h.player.repeatMode)
            h.present(10000,Player.STATE_ENDED)
            assertEquals("Restarted surviving source must reach its own EOF",0,h.player.mediaItemCount)
        }
    }
    @Test fun sameOccurrenceIdsInExplicitNewContextCanCompleteAgain() {
        ServiceProbe().use {h->
            val completed=mutableListOf<String>();h.onCompletion{completed+=it}
            h.install();h.ready();h.present(10000)
            assertEquals(listOf("visit-a"),completed)
            h.install();h.ready();h.present(10000)
            assertEquals(listOf("visit-a","visit-a"),completed)
        }
    }
    @Test fun removePlayingOutgoingSelectsIncomingAtZeroWithoutNaturalCompletion() {
        ServiceProbe().use {h->
            val completed=mutableListOf<String>();h.onCompletion{completed+=it}
            h.install();h.ready();h.present(1000)
            h.player.removeMediaItem(0);h.ready()
            assertEquals(1,h.player.mediaItemCount);assertEquals("visit-b",h.player.currentMediaItem!!.mediaId)
            assertEquals(0L,h.player.currentPosition);assertEquals(10000L,h.player.duration)
            assertTrue(h.player.playWhenReady);assertTrue(h.playing);assertTrue(completed.isEmpty())
            h.present(10000,Player.STATE_ENDED);assertEquals(listOf("visit-b"),completed)
        }
    }
    @Test fun removeDominantIncomingDuringOverlapSelectsRemainingOutgoingAtZero() {
        ServiceProbe().use {h->
            h.install();h.ready();h.present(8500);assertEquals("visit-b",h.player.currentMediaItem!!.mediaId)
            h.player.removeMediaItem(1);h.ready()
            assertEquals("visit-a",h.player.currentMediaItem!!.mediaId);assertEquals(0L,h.player.currentPosition)
            assertTrue(h.playing);assertEquals(1,h.outputItems)
        }
    }
    @Test fun pausedNonselectedRemovalPreservesSurvivorSourceCursorAndRepeat() {
        ServiceProbe().use {h->
            h.install();h.ready();h.present(8500);h.player.pause();h.player.repeatMode=Player.REPEAT_MODE_ONE
            h.player.removeMediaItem(0);h.ready()
            assertEquals("visit-b",h.player.currentMediaItem!!.mediaId);assertEquals(1500L,h.player.currentPosition)
            assertFalse(h.player.playWhenReady);assertFalse(h.playing);assertEquals(Player.REPEAT_MODE_ONE,h.player.repeatMode)
        }
    }
    @Test fun heldPreparationRemovalCannotInstallOldQueueAndSurvivorPrepares() {
        ServiceProbe(held=true).use {h->
            h.install();assertTrue(h.awaitAcquisition());h.player.removeMediaItem(0)
            h.releaseAcquisition();h.ready()
            assertEquals(1,h.player.mediaItemCount);assertEquals("visit-b",h.player.currentMediaItem!!.mediaId)
            assertEquals(1,h.outputItems);assertEquals(1,h.privateFiles());assertTrue(h.playing)
        }
    }
    @Test fun singletonSelectionPreparesAndRemovalRetainsOldReaderUntilClose() {
        ServiceProbe().use {h->
            h.player.setMediaItems(listOf(h.items[1]),0,2500);h.player.prepare();h.player.play();h.ready()
            assertEquals("visit-b",h.player.currentMediaItem!!.mediaId);assertEquals(2500L,h.player.currentPosition)
            val reader=h.render()
            try {
                reader.open(androidx.media3.datasource.DataSpec(android.net.Uri.parse("soundqlistening://render/single")))
                h.player.removeMediaItem(0);assertEquals(0,h.player.mediaItemCount);assertEquals(1,h.privateFiles())
                assertTrue(runCatching{reader.read(ByteArray(8),0,8)}.isFailure)
            }finally {reader.close()}
            assertEquals(0,h.privateFiles());assertFalse(h.playing)
        }
    }
}
