package com.soundq.android.playback.listening

import android.net.Uri
import android.os.Bundle
import android.os.Looper
import androidx.media3.common.*
import androidx.media3.datasource.*
import androidx.media3.exoplayer.ExoPlayer
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import com.soundq.android.playback.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap

@RunWith(RobolectricTestRunner::class)
@Config(manifest=Config.NONE, sdk=[28], application=android.app.Application::class)
internal class ListeningServiceTracerTest {
    private fun settle(until:()->Boolean) {
        val end=System.nanoTime()+10_000_000_000L
        while(!until() && System.nanoTime()<end) {shadowOf(Looper.getMainLooper()).idle();Thread.sleep(2)}
        shadowOf(Looper.getMainLooper()).idle();assertTrue("bounded asynchronous boundary did not settle",until())
    }
    @Test fun ordinaryFacadeSelectsIncomingAtMidpointAndKeepsFullSourceSeek() {
        ServiceProbe().use {h->
            h.install();h.ready()
            assertEquals("one private output item, not a second ordinary queue",1,h.outputItems)
            for((global,index,source) in listOf(Triple(8000L,0,8000L),Triple(8500L,1,1500L),Triple(9000L,1,2000L),Triple(10000L,1,3000L))) {
                h.present(global);assertEquals(index,h.player.currentMediaItemIndex);assertEquals(source,h.player.currentPosition)
                assertEquals(10000L,h.player.duration);assertEquals("soundq",h.player.currentMediaItem!!.localConfiguration!!.uri.scheme)
                val w=h.player.currentTimeline.getWindow(index,Timeline.Window());assertEquals(10000L,w.durationMs)
            }
            val discontinuities=h.discontinuities.filter {it.first.mediaItem?.mediaId=="visit-a" && it.second.mediaItem?.mediaId=="visit-b"}
            assertEquals(1,discontinuities.size)
            assertEquals(8500L,discontinuities.single().first.positionMs);assertEquals(1500L,discontinuities.single().second.positionMs)
            assertTrue(h.transitions.contains("visit-b"));assertFalse(h.transitions.any {it.startsWith("render:")})
            h.player.seekTo(0,9900);assertEquals(9900L,h.global);assertEquals(0,h.player.currentMediaItemIndex);assertEquals(9900L,h.player.currentPosition)
            h.present(9900);assertEquals(1,h.player.currentMediaItemIndex);assertEquals(2900L,h.player.currentPosition)
            h.player.seekTo(1,0);assertEquals(7000L,h.global);assertEquals(1,h.player.currentMediaItemIndex);assertEquals(0L,h.player.currentPosition)
        }
    }
    @Test fun ordinaryAcquisitionAndActualJniMatchEveryIndependentDecodedSample() {
        ServiceProbe().use {h->
            h.install();h.ready()
            val a=h.decoded("a");val b=h.decoded("b")
            val out=File(System.getProperty("soundq.listening.output"),"service.f32")
            var frame=0L;var maxError=0.0
            h.render().use {source->
                assertTrue(source.open(DataSpec(Uri.parse("soundqlistening://render/test")))>0)
                val header=ByteArray(44);assertEquals(44,source.read(header,0,44));assertEquals("RIFF",String(header,0,4))
                val bytes=ByteArray(2048*8)
                out.outputStream().use {saved->while(true) {
                    val n=source.read(bytes,0,bytes.size);if(n<0)break;saved.write(bytes,0,n)
                    val f=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
                    repeat(n/8) {j->val t=frame+j;val u=((t-336000).toDouble()/144000).coerceIn(0.0,1.0)
                        repeat(2) {ch->
                            val av=if(t<480000)a[(t*2+ch).toInt()].toDouble() else 0.0
                            val bv=if(t>=336000)b[((t-336000)*2+ch).toInt()].toDouble() else 0.0
                            val expected=av*kotlin.math.cos(u*Math.PI/2)+bv*kotlin.math.sin(u*Math.PI/2)
                            maxError=maxOf(maxError,kotlin.math.abs(expected-f.float))
                        }
                    };frame+=n/8
                }}
            }
            assertEquals(816000L,frame);assertTrue("every-sample error $maxError",maxError<=.00008)
            h.assertOrdinaryNetwork()
            File(out.parentFile,"service-oracle.json").writeText("{\"frames\":$frame,\"samples\":${frame*2},\"maxError\":$maxError}")
        }
    }
    @Test fun pauseStopReplaceAndAccountRetirementDefeatHeldAcquisition() {
        for(action in 0..3)ServiceProbe(held=true).use {h->
            h.install();assertTrue(h.awaitAcquisition())
            when(action){0->h.player.pause();1->h.player.stop();2->h.player.setMediaItems(h.items.reversed(),0,0);3->h.graph.session.retire()}
            h.releaseAcquisition();settle{h.preparationSettled}
            assertEquals("late preparation must not install after action $action",0,h.outputItems);assertEquals(0,h.playCalls)
            assertEquals(0,h.privateFiles())
        }
    }
    @Test fun localOnlyMissHasNoDescriptorOrArtifactRequest() {
        ServiceProbe(localOnly=true).use {h->h.install();settle{h.preparationSettled};assertEquals(0,h.requestCount);assertEquals(0,h.outputItems);assertNotNull(h.player.playerError)}
    }
    @Test fun completionIsActualOutgoingEofNotDominanceAndSeekDoesNotComplete() {
        ServiceProbe().use {h->
            val completed=mutableListOf<String>();h.onCompletion{completed+=it}
            h.install();h.ready();h.present(8500);assertTrue(completed.isEmpty())
            h.player.seekTo(0,9900);assertTrue(completed.isEmpty());h.present(9999);assertTrue(completed.isEmpty())
            h.present(10000);assertEquals(listOf("visit-a"),completed)
            h.present(10001);assertEquals(1,completed.size)
            h.present(17000,Player.STATE_ENDED);assertEquals(listOf("visit-a","visit-b"),completed)
        }
    }
    @Test fun actualServiceRecorderCompletesOutgoingAtEofNotMidpoint() {
        ServiceProbe().use {h->
            h.install();h.ready()
            val recorder=com.soundq.android.playback.system.ServicePlayRecorder(h.player,h.graph.session,h.graph.api)
            try {
                h.present(8500);assertEquals(4,h.requestCount)
                h.present(10000);settle{h.requestCount==5}
                h.present(17000,Player.STATE_ENDED);settle{h.requestCount==6}
                val requests=(0 until 6).map{h.tls.server.takeRequest()};val plays=requests.filter{it.target.contains("/plays")}
                assertEquals(listOf(7L,8L),plays.map{kotlinx.serialization.json.Json.parseToJsonElement(it.body!!.utf8()).toString().let {raw->Regex("[0-9]+").find(raw)!!.value.toLong()}})
            }finally{recorder.close()}
        }
    }
    @Test fun actualServiceLikeEligibilityTracksLogicalDominanceAndLocalOnlyRefuses() {
        ServiceProbe().use {h->
            h.install();h.ready();h.present(8500)
            assertEquals(8L,h.likeTrack())
        }
        ServiceProbe(localOnly=true).use {h->assertNull(h.likeTrack())}
    }
    @Test fun actualServicePersistenceSavesLogicalSourcePositionAndRestoresPaused() {
        ServiceProbe().use {h->
            h.install();h.ready();h.present(8500)
            val saved=h.saveAndRead()
            assertEquals(1,saved.selected);assertEquals(1500L,saved.position)
            assertEquals(listOf("visit-a","visit-b"),saved.items.map{it.occurrence})
            assertEquals(listOf(QueueOrigin.Context,QueueOrigin.Manual),saved.items.map{it.origin})
            val raw=saved.encode();assertFalse(raw.contains("render:"));assertFalse(raw.contains("/media/"));assertFalse(raw.contains("listening-"))
            h.restore(saved);assertEquals(1,h.player.currentMediaItemIndex);assertEquals(1500L,h.player.currentPosition)
            assertEquals(0,h.outputItems);assertFalse(h.player.playWhenReady)
        }
    }
    @Test fun accountRetirementAfterReadyStopsSoleOutputAndRevokesReads() {
        ServiceProbe().use {h->
            h.install();h.ready();assertTrue(h.playing)
            h.graph.session.retire();settle{!h.playing}
            assertEquals(Player.STATE_IDLE,h.player.playbackState)
            assertTrue(runCatching{h.render()}.isFailure)
        }
    }
    @Test fun duplicateRecordingRetainsDistinctOccurrencesAndRecorderTrackDedup() {
        ServiceProbe(duplicate=true).use {h->
            h.install();h.ready();h.present(8500);assertEquals("visit-b",h.player.currentMediaItem!!.mediaId)
            assertEquals(7L,h.player.currentMediaItem!!.mediaMetadata.extras!!.getLong("trackId"))
            val recorder=com.soundq.android.playback.system.ServicePlayRecorder(h.player,h.graph.session,h.graph.api)
            try{h.present(10000);settle{h.requestCount==5};h.present(17000,Player.STATE_ENDED);shadowOf(Looper.getMainLooper()).idle();assertEquals(5,h.requestCount)}finally{recorder.close()}
        }
    }
    @Test fun explicitDownloadsAndTemporaryCacheUseOrdinaryPrecedenceWithoutNetwork() {
        ServiceProbe().use {h->
            h.seedDownloads();val requests=h.requestCount
            h.install();h.ready();assertEquals(requests,h.requestCount)
            h.render().use {source->source.open(DataSpec(Uri.parse("soundqlistening://render/test")));val bytes=ByteArray(44);assertEquals(44,source.read(bytes,0,44))}
        }
        ServiceProbe().use {h->
            h.seedTemporary();h.install();h.ready();assertEquals(0,h.requestCount)
        }
    }
    @Test fun recorderSurvivesNewOccurrenceQueueAndOldCompletionCannotRecordNewAccount() {
        ServiceProbe().use {h->
            h.install();h.ready();val recorder=com.soundq.android.playback.system.ServicePlayRecorder(h.player,h.graph.session,h.graph.api)
            try {
                val next=h.items.map {it.buildUpon().setMediaId(it.mediaId+"-replacement").build()}
                h.player.setMediaItems(next,0,0);h.player.prepare();h.player.play();h.ready();h.present(10000)
                settle{h.requestCount==9}
                h.graph.session.retire();h.present(17000,Player.STATE_ENDED);assertEquals(9,h.requestCount)
            }finally{recorder.close()}
        }
    }
    @Test fun nativeReadOwnerSurvivesStopUntilLoaderCloseAndThenPrivateFilesRetire() {
        ServiceProbe().use {h->
            h.install();h.ready();val source=h.render();source.open(DataSpec(Uri.parse("soundqlistening://render/test")))
            val before=h.privateFiles();assertEquals(2,before)
            h.player.stop();assertEquals("loader owns native copies after logical stop",before,h.privateFiles())
            source.close();assertEquals(0,h.privateFiles())
        }
    }
}
