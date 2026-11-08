package com.soundq.android.playback.system

import android.os.Looper

import androidx.media3.common.*
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.*
import androidx.test.platform.app.InstrumentationRegistry
import com.google.common.util.concurrent.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Real pinned MediaSession/controller continuations and production transport boundary.
 * No audio/network/account fixture: the ExoPlayer is observed before loader readiness.
 * Compiled here; execution belongs exclusively to the parent runtime owner.
 */
@androidx.annotation.OptIn(UnstableApi::class)
class ServiceTransportSessionTest {
    private val instrumentation=InstrumentationRegistry.getInstrumentation()
    private fun main(block:()->Unit)=instrumentation.runOnMainSync(block)
    private class Fixture(val player:ExoPlayer,val transport:ServiceTransportPlayer,val session:MediaSession) {
        var owner:ServiceTransportPlayer.Read?=null
        val entered=CountDownLatch(1)
        var current=true
    }
    private fun fixture(search:Boolean):Fixture {
        lateinit var f:Fixture
        main {
            val context=instrumentation.targetContext
            val player=ExoPlayer.Builder(context).build()
            val transport=ServiceTransportPlayer(player){f.current}
            val callback=object:MediaSession.Callback {

                override fun onSetMediaItems(session:MediaSession,controller:MediaSession.ControllerInfo,items:List<MediaItem>,index:Int,position:Long):ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
                    f.owner=transport.begin {f.current};f.entered.countDown()
                    return Futures.immediateFuture(MediaSession.MediaItemsWithStartPosition(transport.handoff(),C.INDEX_UNSET,C.TIME_UNSET))
                }
                override fun onPlaybackResumption(session:MediaSession,controller:MediaSession.ControllerInfo,play:Boolean):ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
                    if(f.owner==null){f.owner=transport.begin {f.current};f.entered.countDown()}
                    return Futures.immediateFuture(MediaSession.MediaItemsWithStartPosition(transport.handoff(),C.INDEX_UNSET,C.TIME_UNSET))
                }
            }
            val session=MediaSession.Builder(context,transport).setId("transport-regression-${System.nanoTime()}").setCallback(callback).build()
            f=Fixture(player,transport,session)
            if(search)player.setMediaItems(listOf(item("old")))
        }
        return f
    }
    private fun item(id:String)=MediaItem.Builder().setMediaId(id).setUri("soundq-test://$id").build()
    private fun controller(f:Fixture):ListenableFuture<MediaController> {
        lateinit var future:ListenableFuture<MediaController>
        main {future=MediaController.Builder(instrumentation.targetContext,f.session.token).setApplicationLooper(Looper.getMainLooper()).buildAsync()}
        future.get(5,TimeUnit.SECONDS)
        return future
    }
    /** Observe the actual transport predicate, not controller masking or a guessed sleep. */
    private fun await(predicate:()->Boolean) {
        val until=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
        var accepted=false
        while(!accepted && System.nanoTime()<until){main {accepted=predicate()};if(!accepted)Thread.yield()}
        assertTrue("actual transport boundary",accepted)
    }
    @Test fun resumptionPauseStopNoisyAndPausedStartupCannotReplayButFreshPlayWorks() {
        for(cancellation in listOf("pause","stop","noisy")) {
            val f=fixture(false);val future=controller(f);val c=future.get()
            try {
                main {c.play()};assertTrue(f.entered.await(5,TimeUnit.SECONDS));await {f.owner?.play==true}
                main {when(cancellation){"pause"->c.pause();"stop"->c.stop();else->f.transport.retire()}}
                await {!f.transport.resolving}
                main {
                    f.player.setMediaItems(listOf(item("startup")));f.player.pause()
                    f.transport.complete(f.owner!!,listOf(item("saved")),0,0)
                    assertFalse(f.player.playWhenReady);assertEquals(Player.STATE_IDLE,f.player.playbackState)
                    assertEquals("startup",f.player.currentMediaItem!!.mediaId)
                    c.play()
                }
                await {f.player.playWhenReady}
            } finally {main {MediaController.releaseFuture(future);f.session.release();f.player.release()}}
        }
    }
    @Test fun heldSearchFollowOnsResolveRequestedQueueAndOtherControllerPauseWins() {
        for(cancel in listOf(false,true)) {
            val f=fixture(true);val first=controller(f);val second=controller(f);val a=first.get();val b=second.get()
            try {
                main {a.setMediaItem(MediaItem.Builder().setRequestMetadata(MediaItem.RequestMetadata.Builder().setSearchQuery("requested").build()).build())}
                assertTrue(f.entered.await(5,TimeUnit.SECONDS))
                main {a.prepare();a.play()};await {f.owner?.prepare==true && f.owner?.play==true}
                if(cancel){main {b.pause()};await {!f.transport.resolving}}
                main {
                    assertFalse("old queue cannot play while held",f.player.playWhenReady)
                    f.transport.complete(f.owner!!,listOf(item("requested")),0,0)
                    assertEquals(!cancel,f.player.playWhenReady)
                    assertEquals(if(cancel)"old" else "requested",f.player.currentMediaItem!!.mediaId)
                }
            } finally {main {MediaController.releaseFuture(first);MediaController.releaseFuture(second);f.session.release();f.player.release()}}
        }
    }
    @Test fun accountAndNewSelectionRetireHeldRead() {
        for(account in listOf(false,true)) {
            val f=fixture(true);val future=controller(f);val c=future.get()
            try {
                main {c.setMediaItem(MediaItem.Builder().setRequestMetadata(MediaItem.RequestMetadata.Builder().setSearchQuery("requested").build()).build())}
                assertTrue(f.entered.await(5,TimeUnit.SECONDS))
                main {c.prepare();c.play()};await {f.owner?.prepare==true && f.owner?.play==true}
                main {
                    if(account){f.current=false;f.transport.retire()} else {f.transport.setMediaItems(listOf(item("new")),0,0);f.transport.pause()}
                    f.transport.complete(f.owner!!,listOf(item("requested")),0,0)
                    assertFalse(f.player.playWhenReady)
                    assertEquals(if(account)"old" else "new",f.player.currentMediaItem!!.mediaId)
                }
            } finally {main {MediaController.releaseFuture(future);f.session.release();f.player.release()}}
        }
    }
}
