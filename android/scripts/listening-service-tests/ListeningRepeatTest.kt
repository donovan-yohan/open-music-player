package com.soundq.android.playback.listening

import androidx.media3.common.Player
import com.soundq.android.playback.SavedRepeatMode
import com.soundq.android.playback.system.ServicePlayRecorder
import android.os.Looper
import org.robolectric.Shadows.shadowOf
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest=Config.NONE, sdk=[28], application=android.app.Application::class)
internal class ListeningRepeatTest {
    @Test fun repeatOneRestartsActualOutgoingAtEofAfterIncomingDominance() {
        ServiceProbe().use {h->
            val completed=mutableListOf<String>();h.onCompletion{completed+=it}
            h.install();h.ready()
            h.player.repeatMode=Player.REPEAT_MODE_ONE
            h.present(8500)
            assertEquals("visit-b",h.player.currentMediaItem!!.mediaId)
            assertEquals(1500L,h.player.currentPosition);assertTrue(completed.isEmpty())
            h.present(10000)
            assertEquals(listOf("visit-a"),completed)
            assertEquals("repeat one must restart completed outgoing, not dominant incoming",0L,h.global)
            assertEquals("visit-a",h.player.currentMediaItem!!.mediaId)
            assertEquals(0L,h.player.currentPosition)
            assertEquals(Player.REPEAT_MODE_ONE,h.player.repeatMode)
            assertEquals(Player.STATE_READY,h.player.playbackState)
            assertEquals(1,h.outputItems)
        }
    }
    @Test fun repeatAllWrapsOnlyAtFullScheduleEndAndRearamsNaturalCompletions() {
        ServiceProbe().use {h->
            val completed=mutableListOf<String>();h.onCompletion{completed+=it}
            h.install();h.ready();h.player.repeatMode=Player.REPEAT_MODE_ALL
            h.present(8500);assertEquals(1500L,h.player.currentPosition);assertTrue(completed.isEmpty())
            h.present(10000);assertEquals(listOf("visit-a"),completed)
            assertEquals(10000L,h.global);assertEquals(3000L,h.player.currentPosition)
            h.present(16999);assertEquals(listOf("visit-a"),completed)
            h.present(17000,Player.STATE_ENDED)
            assertEquals(listOf("visit-a","visit-b"),completed)
            assertEquals("repeat all wraps only at whole schedule EOF",0L,h.global)
            assertEquals("visit-a",h.player.currentMediaItem!!.mediaId);assertEquals(0L,h.player.currentPosition)
            h.present(10000);assertEquals(listOf("visit-a","visit-b","visit-a"),completed)
            h.present(17000,Player.STATE_ENDED)
            assertEquals(listOf("visit-a","visit-b","visit-a","visit-b"),completed)
            assertEquals(0L,h.global);assertEquals(1,h.outputItems)
        }
    }
    @Test fun repeatOffExhaustsOnceAndBackwardSeekDoesNotSynthesizeAnotherCompletion() {
        ServiceProbe().use {h->
            val completed=mutableListOf<String>();h.onCompletion{completed+=it}
            h.install();h.ready();h.player.repeatMode=Player.REPEAT_MODE_OFF
            h.present(8500);assertTrue(completed.isEmpty())
            h.present(10000);assertEquals(listOf("visit-a"),completed);assertEquals(3000L,h.player.currentPosition)
            h.present(17000,Player.STATE_ENDED);h.present(17000,Player.STATE_ENDED)
            assertEquals(listOf("visit-a","visit-b"),completed)
            assertEquals(Player.STATE_ENDED,h.player.playbackState);assertEquals(17000L,h.global)
            h.player.seekTo(0,0);h.present(10000);h.present(17000,Player.STATE_ENDED)
            assertEquals("explicit backward seeks do not rearm completion",listOf("visit-a","visit-b"),completed)
            assertEquals(listOf(Player.REPEAT_MODE_OFF),h.physicalRepeatModes)
        }
    }
    @Test fun repeatOneKeepsCompletedIdentityStableAcrossCyclesAndExplicitSeekIsNotEof() {
        ServiceProbe().use {h->
            val completed=mutableListOf<String>();h.onCompletion{completed+=it}
            h.install();h.ready();h.player.repeatMode=Player.REPEAT_MODE_ONE
            h.player.seekTo(1,3000);h.present(10000);assertTrue(completed.isEmpty())
            assertEquals(10000L,h.global)
            h.player.seekTo(0,0)
            repeat(3) {
                h.present(8500);assertEquals("visit-b",h.player.currentMediaItem!!.mediaId)
                h.present(10000);assertEquals(0L,h.global);assertEquals("visit-a",h.player.currentMediaItem!!.mediaId)
            }
            assertEquals(listOf("visit-a","visit-a","visit-a"),completed)
            assertEquals(listOf(Player.REPEAT_MODE_OFF),h.physicalRepeatModes)
        }
    }
    @Test fun repeatChangesDuringOverlapUseModeAtActualEof() {
        for(mode in listOf(Player.REPEAT_MODE_OFF,Player.REPEAT_MODE_ONE,Player.REPEAT_MODE_ALL))ServiceProbe().use {h->
            val completed=mutableListOf<String>();h.onCompletion{completed+=it}
            h.install();h.ready();h.player.repeatMode=Player.REPEAT_MODE_ONE
            h.present(8500);val seeks=h.seekCalls.size;val plays=h.playCalls
            h.player.repeatMode=mode
            assertEquals(seeks,h.seekCalls.size);assertEquals(plays,h.playCalls)
            h.present(10000);assertEquals(listOf("visit-a"),completed)
            assertEquals(if(mode==Player.REPEAT_MODE_ONE)0L else 10000L,h.global)
            assertEquals(mode,h.player.repeatMode)
        }
    }
    @Test fun pausedModeEventsPersistAndActualRestoreModesKeepSourceAndOccurrenceIdentity() {
        ServiceProbe(duplicate=true).use {h->
            h.install();h.ready();h.present(8500);h.player.pause();h.bindModePersistence()
            val seeks=h.seekCalls.size;val plays=h.playCalls
            for((mode,savedMode) in listOf(Player.REPEAT_MODE_ALL to SavedRepeatMode.All,Player.REPEAT_MODE_ONE to SavedRepeatMode.One,Player.REPEAT_MODE_OFF to SavedRepeatMode.Off)) {
                h.player.repeatMode=mode
                h.settle{h.repeatEvents.lastOrNull()==mode && h.eventFlags.contains(Player.EVENT_REPEAT_MODE_CHANGED)}
                val saved=h.persistedMode()
                assertEquals(savedMode,saved.loopMode);assertEquals(1,saved.selected);assertEquals(1500L,saved.position)
                assertEquals(listOf("visit-a","visit-b"),saved.items.map{it.occurrence})
                assertEquals(listOf(7L,7L),saved.items.map{it.track})
                assertEquals(seeks,h.seekCalls.size);assertEquals(plays,h.playCalls);assertFalse(h.playing)
                ServiceProbe(duplicate=true).use {fresh->
                    val rebound=saved.copy(endpoint=fresh.graph.endpoint.identity,account=fresh.scope.accountId)
                    fresh.startup(rebound);assertEquals(mode,fresh.player.repeatMode)
                    assertEquals(1,fresh.player.currentMediaItemIndex);assertEquals(1500L,fresh.player.currentPosition)
                    assertEquals(0,fresh.playCalls);assertTrue(fresh.seekCalls.isEmpty());assertFalse(fresh.player.playWhenReady)
                    assertEquals(rebound.encode(),fresh.saveAndRead().encode())
                }
            }
            assertEquals(listOf(Player.REPEAT_MODE_OFF),h.physicalRepeatModes)
        }
    }
    @Test fun completionPauseStopReplaceOrAccountRetirementCannotApplyStaleRepeatRestart() {
        for(mode in listOf(Player.REPEAT_MODE_ONE,Player.REPEAT_MODE_ALL))for(action in 0..3)ServiceProbe().use {h->
            h.install();h.ready();h.player.repeatMode=mode
            if(mode==Player.REPEAT_MODE_ALL)h.present(10000)
            var calls=0
            h.onCompletion {
                calls++
                if(calls==1)when(action) {
                    0->h.player.pause()
                    1->h.player.stop()
                    2->h.player.setMediaItems(h.items.reversed(),0,0)
                    3->h.graph.session.retire()
                }
            }
            val seeks=h.seekCalls.size
            h.present(if(mode==Player.REPEAT_MODE_ONE)10000 else 17000,if(mode==Player.REPEAT_MODE_ONE)Player.STATE_READY else Player.STATE_ENDED)
            assertEquals(1,calls);assertEquals("no callback-superseded seek for mode $mode action $action",seeks,h.seekCalls.size)
            if(action!=3) {
                if(action==0)h.player.seekTo(0,0)
                h.player.prepare();h.player.play();h.ready();assertTrue(h.playing)
            }else {h.settle{!h.playing};assertTrue(runCatching{h.render()}.isFailure)}
        }
    }
    @Test fun duplicateRecorderRetainsTrackDedupAcrossRepeatAllCycles() {
        ServiceProbe(duplicate=true).use {h->
            h.install();h.ready();h.player.repeatMode=Player.REPEAT_MODE_ALL
            val completed=mutableListOf<String>();h.onCompletion{completed+=it}
            ServicePlayRecorder(h.player,h.graph.session,h.graph.api).use {
                h.present(8500);h.present(10000);h.settle{h.requestCount==5}
                h.present(17000,Player.STATE_ENDED);h.present(8500);h.present(10000);h.present(17000,Player.STATE_ENDED)
                shadowOf(Looper.getMainLooper()).idle();assertEquals(5,h.requestCount)
                assertEquals(listOf("visit-a","visit-b","visit-a","visit-b"),completed)
                val plays=(0 until 5).map{h.tls.server.takeRequest()}.filter{it.target.contains("/plays")}
                assertEquals(1,plays.size);assertTrue(plays.single().body!!.utf8().contains("7"))
            }
        }
    }
    @Test fun replacedQueueRetiresRemainingOldCompletionCallbacksBeforeActualRecorder() {
        ServiceProbe().use {h->
            h.install();h.ready();h.player.repeatMode=Player.REPEAT_MODE_ONE
            val next=h.items.map {it.buildUpon().setMediaId(it.mediaId+"-next").build()}
            h.onCompletion{h.player.setMediaItems(next,0,0)}
            ServicePlayRecorder(h.player,h.graph.session,h.graph.api).use {
                h.present(10000)
                assertEquals("visit-a-next",h.player.currentMediaItem!!.mediaId)
                assertEquals(0,h.outputItems);assertEquals(4,h.requestCount)
            }
        }
    }
    @Test fun repeatOneIncomingRestartDoesNotAdoptEarlierOutgoingOnNextCycle() {
        ServiceProbe().use {h->
            val completed=mutableListOf<String>();h.onCompletion{completed+=it}
            h.install();h.ready();h.player.seekTo(1,3000);h.player.repeatMode=Player.REPEAT_MODE_ONE
            h.present(17000,Player.STATE_ENDED)
            assertEquals(listOf("visit-b"),completed);assertEquals(7000L,h.global)
            h.present(10000)
            assertEquals("a prior occurrence in the finite render is not this repeat cycle",listOf("visit-b"),completed)
            assertEquals(10000L,h.global)
            h.present(17000,Player.STATE_ENDED)
            assertEquals(listOf("visit-b","visit-b"),completed);assertEquals(7000L,h.global)
        }
    }
}
