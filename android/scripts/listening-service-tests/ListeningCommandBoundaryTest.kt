package com.soundq.android.playback.listening

import android.net.Uri
import android.os.Looper
import androidx.media3.common.Player
import androidx.media3.datasource.DataSpec
import kotlinx.coroutines.Job
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest=Config.NONE,sdk=[28],application=android.app.Application::class)
internal class ListeningCommandBoundaryTest {
    @Test fun pausedOutgoingTailSeekSurvivesInlineBufferingThenDeferredEventsAndReady() {
        ServiceProbe(seekCallbacks=true).use {h->
            val completed=mutableListOf<String>();h.onCompletion{completed+=it}
            h.install();h.ready();h.present(1000);h.player.pause()
            h.player.seekTo(0,9900)
            assertEquals("explicit outgoing occurrence must survive inline seek callback",0,h.player.currentMediaItemIndex)
            assertEquals(9900L,h.player.currentPosition);assertEquals(9900L,h.global)
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals(0,h.player.currentMediaItemIndex);assertEquals(9900L,h.player.currentPosition)
            h.present(9900,Player.STATE_READY)
            assertEquals(0,h.player.currentMediaItemIndex);assertEquals(9900L,h.player.currentPosition)
            assertEquals(10000L,h.player.duration);assertTrue(completed.isEmpty());assertFalse(h.playing)
            h.player.play();h.present(9901)
            assertEquals(1,h.player.currentMediaItemIndex);assertEquals(2901L,h.player.currentPosition)
            h.present(10000);assertEquals(listOf("visit-a"),completed)
        }
    }
    @Test fun pausedOutgoingSelectionAlsoSurvivesDeferredOnlySeekNotifications() {
        ServiceProbe(seekCallbacks=true).use {h->
            val completed=mutableListOf<String>();h.onCompletion{completed+=it}
            h.install();h.ready();h.player.pause();h.physicalState=Player.STATE_BUFFERING
            h.player.seekTo(0,9900)
            assertEquals(0,h.player.currentMediaItemIndex)
            shadowOf(Looper.getMainLooper()).idle()
            assertEquals("deferred onEvents at unchanged paused position is not natural playback",0,h.player.currentMediaItemIndex)
            assertEquals(9900L,h.player.currentPosition)
            h.present(9900);assertEquals(0,h.player.currentMediaItemIndex);assertTrue(completed.isEmpty())
            h.player.seekTo(1,0);shadowOf(Looper.getMainLooper()).idle();h.present(7000)
            assertEquals(1,h.player.currentMediaItemIndex);assertEquals(0L,h.player.currentPosition)
            h.player.play();h.present(8500)
            assertEquals(1,h.player.currentMediaItemIndex);assertEquals(1500L,h.player.currentPosition)
            h.present(10000);assertEquals(listOf("visit-a"),completed)
        }
    }
    @Test fun playingOutgoingSeekReturnsExplicitSelectionThenIndependentObservationRestoresDominance() {
        ServiceProbe(seekCallbacks=true).use {h->
            val completed=mutableListOf<String>();h.onCompletion{completed+=it}
            h.install();h.ready();h.present(8500)
            h.player.seekTo(0,9900)
            assertEquals(0,h.player.currentMediaItemIndex);assertEquals(9900L,h.player.currentPosition)
            assertTrue(h.playing);assertTrue(completed.isEmpty())
            h.present(9900)
            assertEquals(1,h.player.currentMediaItemIndex);assertEquals(2900L,h.player.currentPosition)
            h.present(10000);assertEquals(listOf("visit-a"),completed)
        }
    }
    @Test fun publicReleaseRetiresSoleOutputRenderAndAccountObserverExactlyOnce() {
        ServiceProbe().use {h->
            h.install();h.ready()
            val completed=mutableListOf<String>();h.onCompletion{completed+=it}
            val source=h.render();source.open(DataSpec(Uri.parse("soundqlistening://render/release")))
            try {
                assertTrue(h.playing);assertTrue(h.listeners.isNotEmpty());assertEquals(2,h.privateFiles())
                h.player.release()
                assertEquals("public pinned SimpleBasePlayer.release must reach the sole output",1,h.releaseCalls)
                assertTrue(h.player.isCommandAvailable(Player.COMMAND_RELEASE))
                assertFalse(h.playing);assertTrue(h.listeners.isEmpty())
                assertFalse(h.jobs.coroutineContext[Job]!!.children.any{it.isActive})
                assertTrue(runCatching{h.render()}.isFailure)
                shadowOf(Looper.getMainLooper()).idle()
                val events=h.eventFlags.toList();val transitions=h.transitions.toList()
                h.graph.session.retire();h.present(17000,Player.STATE_ENDED)
                shadowOf(Looper.getMainLooper()).idle()
                assertEquals(events,h.eventFlags);assertEquals(transitions,h.transitions);assertTrue(completed.isEmpty())
                h.player.release();assertEquals(1,h.releaseCalls)
            }finally{source.close()}
            assertEquals(0,h.privateFiles())
        }
    }
    @Test fun publicReleaseCancelsHeldPreparationWithoutLateInstallOrPublication() {
        ServiceProbe(held=true).use {h->
            h.install();assertTrue(h.awaitAcquisition())
            h.player.release()
            assertEquals("release must retire while acquisition is held",1,h.releaseCalls)
            shadowOf(Looper.getMainLooper()).idle()
            val events=h.eventFlags.toList();val transitions=h.transitions.toList()
            h.releaseAcquisition();h.settle{h.preparationSettled}
            assertEquals(0,h.outputItems);assertEquals(0,h.playCalls);assertEquals(0,h.privateFiles())
            assertTrue(h.listeners.isEmpty());assertFalse(h.jobs.coroutineContext[Job]!!.children.any{it.isActive})
            assertEquals(events,h.eventFlags);assertEquals(transitions,h.transitions)
        }
    }
}
