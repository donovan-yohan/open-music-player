package com.soundq.android.playback.listening

import androidx.media3.common.Player
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest=Config.NONE,sdk=[28],application=android.app.Application::class)
internal class ListeningPausedMutationTest {
    @Test fun replacingDominantIncomingSeeksItsZeroButSelectionStillUsesActualGain() {
        ServiceProbe().use {h->
            val completed=mutableListOf<String>();h.onCompletion{completed+=it}
            h.install();h.ready();h.present(8500);h.player.pause()
            h.player.replaceMediaItem(1,h.items[1].buildUpon().setMediaId("visit-c").build());h.ready()
            assertEquals("visit-c",h.player.getMediaItemAt(1).mediaId)
            assertEquals(7000L,h.global)
            assertEquals("visit-a",h.player.currentMediaItem!!.mediaId);assertEquals(7000L,h.player.currentPosition)
            assertTrue(completed.isEmpty());assertFalse(h.playing)
        }
    }
    @Test fun liveEditAndRetiredGrantAreRefusedBeforeTeardown() {
        ServiceProbe().use {h->
            h.install();h.ready();h.present(1000)
            val original=h.sourceFactory;val plays=h.playCalls
            assertTrue(runCatching{h.player.moveMediaItem(0,1)}.isFailure)
            assertSame(original,h.sourceFactory);assertTrue(h.playing);assertEquals(plays,h.playCalls)
            h.player.pause()
            h.grants.clear()
            assertTrue(runCatching{h.player.moveMediaItem(0,1)}.isFailure)
            assertSame(original,h.sourceFactory);assertEquals("visit-a",h.player.currentMediaItem!!.mediaId)
            assertEquals(1000L,h.player.currentPosition);assertFalse(h.playing)
        }
    }
    @Test fun idleMutationDuringCancelledPreparationWaitsForDrainAndFreshIntentStillWorks() {
        ServiceProbe(held=true).use {h->
            h.install();assertTrue(h.awaitAcquisition());h.player.pause()
            h.player.moveMediaItem(0,1);h.releaseAcquisition();h.ready()
            assertEquals("visit-a",h.player.getMediaItemAt(1).mediaId);assertEquals(7000L,h.global)
            // The requested source-zero is still the other occurrence's full-gain tail.
            assertEquals("visit-b",h.player.currentMediaItem!!.mediaId);assertEquals(7000L,h.player.currentPosition);assertFalse(h.playing)
            h.player.play();assertTrue(h.playing);assertEquals(1,h.outputItems)
        }
    }
    @Test fun firstInsertSelectsWithoutPreparingOrPlayingAndSecondKeepsOccurrence() {
        ServiceProbe().use {h->
            h.player.addMediaItem(h.items[0])
            assertEquals("visit-a",h.player.currentMediaItem!!.mediaId);assertEquals(0L,h.player.currentPosition)
            assertFalse(h.player.playWhenReady);assertEquals(0,h.playCalls);assertEquals(0,h.outputItems);assertEquals(0,h.requestCount)
            h.player.addMediaItem(0,h.items[1])
            assertEquals(listOf("visit-b","visit-a"),(0 until h.player.mediaItemCount).map {h.player.getMediaItemAt(it).mediaId})
            assertEquals("visit-a",h.player.currentMediaItem!!.mediaId);assertEquals(1,h.player.currentMediaItemIndex)
            assertEquals(0,h.requestCount);h.player.prepare();h.ready();assertFalse(h.playing)
        }
    }
    @Test fun pausedReorderPreservesSelectedSourceClockAndRepeatWithoutAutoplay() {
        ServiceProbe(duplicate=true).use {h->
            h.install();h.ready();h.present(8500);h.player.pause();h.player.repeatMode=Player.REPEAT_MODE_ALL
            val plays=h.playCalls;h.player.moveMediaItem(1,0);h.ready()
            assertEquals(listOf("visit-b","visit-a"),(0 until h.player.mediaItemCount).map {h.player.getMediaItemAt(it).mediaId})
            assertEquals("visit-b",h.player.currentMediaItem!!.mediaId);assertEquals(1500L,h.player.currentPosition);assertEquals(1500L,h.global)
            assertFalse(h.playing);assertEquals(plays,h.playCalls);assertEquals(Player.REPEAT_MODE_ALL,h.player.repeatMode)
        }
    }
    @Test fun pausedInsertRetainsCurrentSourcePositionAcrossNewIncomingPlacement() {
        ServiceProbe().use {h->
            h.player.setMediaItems(listOf(h.items[1]),0,2500);h.player.prepare();h.ready()
            h.player.addMediaItem(0,h.items[0]);h.ready()
            assertEquals("visit-b",h.player.currentMediaItem!!.mediaId);assertEquals(2500L,h.player.currentPosition)
            assertEquals(9500L,h.global);assertFalse(h.playing)
        }
    }
    @Test fun selectedReplacementStartsAtZeroAndOldReaderRetainsItsFilesUntilClose() {
        ServiceProbe().use {h->
            h.install();h.ready();h.present(1000);h.player.pause()
            val reader=h.render();reader.open(androidx.media3.datasource.DataSpec(android.net.Uri.parse("soundqlistening://render/old")))
            try {
                val replacement=h.items[0].buildUpon().setMediaId("visit-c").build()
                h.player.replaceMediaItem(0,replacement);h.ready()
                assertEquals("visit-c",h.player.currentMediaItem!!.mediaId);assertEquals(0L,h.player.currentPosition)
                assertEquals(4,h.privateFiles());assertFalse(h.playing)
                assertTrue(runCatching{reader.read(ByteArray(8),0,8)}.isFailure)
            }finally {reader.close()}
            assertEquals(2,h.privateFiles())
        }
    }
    @Test fun replacingSiblingKeepsSelectedOccurrenceCursorAndNoCompletion() {
        ServiceProbe().use {h->
            val completed=mutableListOf<String>();h.onCompletion{completed+=it}
            h.install();h.ready();h.present(8500);h.player.pause()
            h.player.replaceMediaItem(0,h.items[0].buildUpon().setMediaId("visit-new-a").build());h.ready()
            assertEquals("visit-b",h.player.currentMediaItem!!.mediaId);assertEquals(1500L,h.player.currentPosition)
            assertTrue(completed.isEmpty());assertFalse(h.playing)
        }
    }
    @Test fun oversizedAndDuplicateCandidateRefusalLeavesPausedQueueAndRenderUsable() {
        ServiceProbe().use {h->
            h.install();h.ready();h.present(8500);h.player.pause()
            val before=(0 until h.player.mediaItemCount).map(h.player::getMediaItemAt);val factory=h.sourceFactory
            assertTrue(runCatching{h.player.addMediaItem(h.items[0].buildUpon().setMediaId("third").build())}.isFailure)
            assertTrue(runCatching{h.player.replaceMediaItem(0,h.items[1])}.isFailure)
            assertEquals(before,(0 until h.player.mediaItemCount).map(h.player::getMediaItemAt))
            assertEquals("visit-b",h.player.currentMediaItem!!.mediaId);assertEquals(1500L,h.player.currentPosition)
            assertSame(factory,h.sourceFactory);assertEquals(1,h.outputItems);assertEquals(2,h.privateFiles());assertFalse(h.playing)
        }
    }
}
