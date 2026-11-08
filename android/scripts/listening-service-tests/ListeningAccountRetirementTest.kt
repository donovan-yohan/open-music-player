package com.soundq.android.playback.listening

import android.net.Uri
import androidx.media3.common.Player
import androidx.media3.datasource.DataSpec
import com.soundq.android.playback.MediaGrant
import com.soundq.android.data.SecretTokens
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest=Config.NONE,sdk=[28],application=android.app.Application::class)
internal class ListeningAccountRetirementTest {
    @Test fun lockUnlockWithoutCollectorTurnStillStopsAndKeepsCursor() {
        ServiceProbe().use {h->
            h.install();h.ready();h.present(8500)
            assertTrue(h.graph.session.lockLocal())
            assertTrue(h.graph.session.completeLocalUnlock(h.graph.session.localUnlockTicket()!!))
            h.settle{!h.playing}
            assertEquals(2,h.player.mediaItemCount);assertEquals("visit-b",h.player.currentMediaItem!!.mediaId)
            assertEquals(1500L,h.player.currentPosition);assertFalse(h.player.playWhenReady)
            assertEquals(0,h.outputItems);assertEquals(0,h.privateFiles())
        }
    }
    @Test fun accountRetirementClearsLogicalQueueWhileReaderRetainsRetiredFiles() {
        ServiceProbe().use {h->
            h.install();h.ready();h.present(8500)
            val reader=h.render();reader.open(DataSpec(Uri.parse("soundqlistening://render/old")))
            try {
                h.graph.session.retire();h.settle{!h.playing}
                assertEquals(0,h.player.mediaItemCount);assertNull(h.player.currentMediaItem)
                assertEquals(Player.STATE_IDLE,h.player.playbackState);assertFalse(h.player.playWhenReady)
                assertEquals(0,h.outputItems);assertEquals(2,h.privateFiles())
                assertTrue(runCatching{reader.read(ByteArray(8),0,8)}.isFailure)
                val plays=h.playCalls;h.player.play();assertEquals(plays,h.playCalls)
            }finally {reader.close()}
            assertEquals(0,h.privateFiles())
        }
    }
    @Test fun heldAcquisitionRetirementCannotRestoreOldQueueOrInstallAfterAccountReplacement() {
        ServiceProbe(held=true).use {h->
            h.install();assertTrue(h.awaitAcquisition())
            h.graph.session.retire();h.settle{!h.player.playWhenReady}
            h.graph.session.accept(h.graph.session.beginIntent(),SecretTokens("new-a","new-r","tracer"))
            h.releaseAcquisition();h.settle{h.preparationSettled}
            assertEquals(0,h.player.mediaItemCount);assertNull(h.player.currentMediaItem)
            assertEquals(0,h.outputItems);assertEquals(0,h.privateFiles());assertEquals(0,h.playCalls)
            assertTrue(runCatching{h.player.setMediaItems(h.items,0,0)}.isFailure)
            assertEquals(0,h.player.mediaItemCount)
            val fresh=h.graph.session.capture()!!
            h.items.forEach {item->
                val uri=item.localConfiguration!!.uri.toString();val previous=h.grants.getValue(uri)
                h.grants[uri]=MediaGrant(fresh,previous.track,previous.localOnly)
            }
            h.player.setMediaItems(h.items,0,0);h.player.prepare();h.ready()
            assertFalse(h.playing);h.player.play();assertTrue(h.playing)
        }
    }
    @Test fun sameAccountCredentialReplacementRetiresPausedOldContext() {
        ServiceProbe().use {h->
            h.install();h.ready();h.present(8500);h.player.pause()
            h.graph.session.accept(h.graph.session.beginIntent(),SecretTokens("new-a","new-r","tracer"))
            h.settle{h.outputItems==0}
            assertEquals(0,h.player.mediaItemCount);assertNull(h.player.currentMediaItem)
            assertEquals(0,h.privateFiles());assertFalse(h.player.playWhenReady)
        }
    }
    @Test fun localLockPreservesSameSessionOccurrenceCursorButCannotAutoplayOnUnlock() {
        ServiceProbe().use {h->
            h.install();h.ready();h.present(8500)
            assertTrue(h.graph.session.lockLocal());h.settle{!h.playing}
            assertEquals(listOf("visit-a","visit-b"),(0 until h.player.mediaItemCount).map {h.player.getMediaItemAt(it).mediaId})
            assertEquals("visit-b",h.player.currentMediaItem!!.mediaId);assertEquals(1500L,h.player.currentPosition)
            assertFalse(h.player.playWhenReady);assertEquals(0,h.outputItems);assertEquals(0,h.privateFiles())
            val plays=h.playCalls;val ticket=h.graph.session.localUnlockTicket()!!
            assertTrue(h.graph.session.completeLocalUnlock(ticket))
            h.items.forEach {item->
                val uri=item.localConfiguration!!.uri.toString();val previous=h.grants.getValue(uri)
                h.grants[uri]=MediaGrant(h.graph.session.capture()!!,previous.track,previous.localOnly)
            }
            h.settle{h.player.mediaItemCount==2};assertFalse(h.playing);assertEquals(plays,h.playCalls)
        }
    }
}
