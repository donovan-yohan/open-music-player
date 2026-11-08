package com.soundq.android

import android.content.ComponentName
import android.os.Looper
import androidx.media3.common.*
import androidx.media3.session.*
import androidx.test.platform.app.InstrumentationRegistry
import com.google.common.util.concurrent.ListenableFuture
import com.soundq.android.data.*
import com.soundq.android.playback.SoundQLibraryService
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class PlaybackFixtureTest {
    @Test fun controllerUsesServiceDecoderAndDuplicateOccurrencesRetireOnLogout() {
        val instrumentation=InstrumentationRegistry.getInstrumentation();val context=instrumentation.targetContext
        val graph=(context.applicationContext as SoundQApplication).graph
        graph.session.retire()
        assertTrue(graph.api.authenticate("synthetic@example.test","test-only-password"))
        graph.rememberTracks(listOf(Track(TrackId(1),"Fixture 1","Synthetic ensemble"),Track(TrackId(2),"Fixture 2","Synthetic ensemble")))
        lateinit var future:ListenableFuture<MediaController>
        instrumentation.runOnMainSync {future=MediaController.Builder(context,SessionToken(context,ComponentName(context,SoundQLibraryService::class.java))).setApplicationLooper(Looper.getMainLooper()).buildAsync()}
        val controller=future.get(10,TimeUnit.SECONDS)
        fun await(predicate:()->Boolean) {
            val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(12)
            var accepted=false
            while(System.nanoTime()<end&&!accepted){instrumentation.runOnMainSync {accepted=predicate()};if(!accepted)Thread.sleep(25)}
            assertTrue("Native predicate did not settle",accepted)
        }
        try {
            await {controller.isCommandAvailable(Player.COMMAND_SET_MEDIA_ITEM)}
            instrumentation.runOnMainSync {controller.setMediaItems(listOf(MediaItem.Builder().setMediaId("1").build(),MediaItem.Builder().setMediaId("1").build(),MediaItem.Builder().setMediaId("2").build()));controller.prepare();controller.play()}
            await {controller.isPlaying&&controller.currentPosition>0&&controller.duration>0}
            instrumentation.runOnMainSync {
                assertEquals(3,controller.mediaItemCount)
                assertNotEquals(controller.getMediaItemAt(0).mediaId,controller.getMediaItemAt(1).mediaId)
                controller.pause();controller.seekTo(2500)
            }
            await {!controller.isPlaying&&controller.currentPosition>=2400}
            instrumentation.runOnMainSync {controller.moveMediaItem(1,2);controller.removeMediaItem(2)}
            await {controller.mediaItemCount==2&&!controller.playWhenReady}
            graph.session.retire()
            await {controller.mediaItemCount==0&&!controller.isPlaying}
        }finally {instrumentation.runOnMainSync {controller.pause();MediaController.releaseFuture(future)}}
    }
}
