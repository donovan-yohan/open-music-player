package com.soundq.android

import android.content.ComponentName
import android.os.Bundle
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

/** Compiled here only. Parent may execute on the exclusively owned synthetic fixture. */
class ShuffleTraversalJourneyTest {
    @Test fun ordinaryControllerKeepsCanonicalDuplicateRowsAndManualBatchNext() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val context=instrumentation.targetContext
        val graph=(context.applicationContext as SoundQApplication).graph
        graph.session.retire()
        assertTrue(graph.api.authenticate("synthetic@example.test","test-only-password"))
        graph.rememberTracks(listOf(Track(TrackId(1),"Fixture 1",durationMs=12000),Track(TrackId(2),"Fixture 2",durationMs=12000)))
        lateinit var future:ListenableFuture<MediaController>
        instrumentation.runOnMainSync {future=MediaController.Builder(context,SessionToken(context,ComponentName(context,SoundQLibraryService::class.java))).setApplicationLooper(Looper.getMainLooper()).buildAsync()}
        val controller=future.get(10,TimeUnit.SECONDS)
        fun await(predicate:()->Boolean) {
            val end=System.nanoTime()+TimeUnit.SECONDS.toNanos(12)
            var accepted=false
            while(System.nanoTime()<end&&!accepted){instrumentation.runOnMainSync {accepted=predicate()};if(!accepted)Thread.sleep(25)}
            assertTrue("Native shuffle predicate did not settle",accepted)
        }
        fun request(id:String,manual:Boolean=false)=MediaItem.Builder().setMediaId(id).setRequestMetadata(MediaItem.RequestMetadata.Builder().setExtras(Bundle().apply {putBoolean("manual",manual)}).build()).build()
        try {
            await {controller.isCommandAvailable(Player.COMMAND_SET_MEDIA_ITEM)}
            instrumentation.runOnMainSync {controller.setMediaItems(listOf(request("1"),request("1"),request("2"),request("1"),request("2")),2,1700);controller.prepare();controller.play()}
            await {controller.isPlaying&&controller.currentPosition>=1700}
            var canonical=emptyList<String>();var selected=""
            instrumentation.runOnMainSync {canonical=(0 until controller.mediaItemCount).map{controller.getMediaItemAt(it).mediaId};selected=controller.currentMediaItem!!.mediaId;controller.shuffleModeEnabled=true}
            await {controller.shuffleModeEnabled}
            instrumentation.runOnMainSync {
                assertEquals(canonical,(0 until controller.mediaItemCount).map{controller.getMediaItemAt(it).mediaId})
                assertEquals(selected,controller.currentMediaItem!!.mediaId)
                assertEquals(2,controller.currentTimeline.getFirstWindowIndex(true))
                assertTrue(controller.playWhenReady)
                controller.addMediaItems(3,listOf(request("1",true),request("1",true)))
            }
            await {controller.mediaItemCount==7}
            var first="";var second=""
            instrumentation.runOnMainSync {
                first=controller.getMediaItemAt(3).mediaId;second=controller.getMediaItemAt(4).mediaId
                assertNotEquals(first,second)
                assertEquals(3,controller.nextMediaItemIndex)
                assertEquals(canonical,(0 until controller.mediaItemCount).map{controller.getMediaItemAt(it).mediaId}.filter{it!=first&&it!=second})
                controller.seekToNextMediaItem()
            }
            await {controller.currentMediaItem?.mediaId==first}
            instrumentation.runOnMainSync {assertEquals(4,controller.nextMediaItemIndex);controller.seekToNextMediaItem()}
            await {controller.currentMediaItem?.mediaId==second}
            instrumentation.runOnMainSync {controller.shuffleModeEnabled=false}
            await {!controller.shuffleModeEnabled}
            graph.session.retire()
            await {controller.mediaItemCount==0&&!controller.playWhenReady}
        }finally {instrumentation.runOnMainSync {controller.pause();MediaController.releaseFuture(future)}}
    }
}
