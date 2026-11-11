package com.soundq.android

import android.content.ComponentName
import android.os.Looper
import androidx.media3.common.*
import androidx.media3.session.*
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import com.soundq.android.playback.SoundQLibraryService
import com.google.common.util.concurrent.ListenableFuture
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

/** Actual MediaBrowser/service adapter. Compile here, parent-owned runtime qualification. */
class SystemMediaJourneyTest {
    @Test fun naturalCompletionPostsOldTrackExactlyOnceThroughService() {
        val instrumentation=InstrumentationRegistry.getInstrumentation();val context=instrumentation.targetContext
        val graph=(context.applicationContext as SoundQApplication).graph
        assertTrue(graph.api.authenticate("synthetic@example.test","test-only-password"))
        lateinit var future:ListenableFuture<MediaBrowser>
        instrumentation.runOnMainSync {future=MediaBrowser.Builder(context,SessionToken(context,ComponentName(context,SoundQLibraryService::class.java))).setApplicationLooper(Looper.getMainLooper()).buildAsync()}
        val browser=future.get(10,TimeUnit.SECONDS)
        lateinit var read:ListenableFuture<LibraryResult<com.google.common.collect.ImmutableList<MediaItem>>>
        try {
            instrumentation.runOnMainSync {read=browser.getChildren(SoundQLibraryService.LIBRARY,0,20,null)}
            val tracks=read.get(10,TimeUnit.SECONDS).value!!
            val before=ProductTransportFixture.requests.size
            val playsBefore=ProductTransportFixture.recordedPlays.size
            instrumentation.runOnMainSync {browser.setMediaItems(listOf(tracks[0],tracks[1]));browser.prepare();browser.play()}
            val until=System.nanoTime()+TimeUnit.SECONDS.toNanos(20)
            while(System.nanoTime()<until && ProductTransportFixture.requests.drop(before).count {it=="POST /api/v1/me/plays"}<1)Thread.sleep(20)
            assertEquals(1,ProductTransportFixture.requests.drop(before).count {it=="POST /api/v1/me/plays"})
            assertEquals(listOf(1L),ProductTransportFixture.recordedPlays.drop(playsBefore))
            instrumentation.runOnMainSync {browser.pause()}
        } finally {instrumentation.runOnMainSync {MediaController.releaseFuture(future)};graph.session.retire()}
    }
    @Test fun authenticatedBrowseSearchAndDuplicateOccurrencesUseTheExistingPlayer() {
        val instrumentation=InstrumentationRegistry.getInstrumentation();val context=instrumentation.targetContext
        val graph=(context.applicationContext as SoundQApplication).graph
        assertTrue(graph.api.authenticate("synthetic@example.test","test-only-password"))
        lateinit var future:ListenableFuture<MediaBrowser>
        instrumentation.runOnMainSync {future=MediaBrowser.Builder(context,SessionToken(context,ComponentName(context,SoundQLibraryService::class.java))).setApplicationLooper(Looper.getMainLooper()).buildAsync()}
        val browser=future.get(10,TimeUnit.SECONDS)
        fun <T> call(block:()->ListenableFuture<T>):T {lateinit var result:ListenableFuture<T>;instrumentation.runOnMainSync {result=block()};return result.get(10,TimeUnit.SECONDS)}
        try {
            val root=call {browser.getLibraryRoot(null)}.value!!
            assertFalse(root.mediaMetadata.isPlayable!!)
            val folders=call {browser.getChildren(root.mediaId,0,20,null)}.value!!
            assertTrue(folders.any {it.mediaId==SoundQLibraryService.LIBRARY})
            val tracks=call {browser.getChildren(SoundQLibraryService.LIBRARY,0,20,null)}.value!!
            assertEquals(listOf("library:1","library:2","library:3"),tracks.map {it.mediaId})
            assertTrue(tracks.all {it.localConfiguration==null && it.mediaMetadata.isPlayable==true})
            assertEquals(LibraryResult.RESULT_SUCCESS,call {browser.search("Fixture 2",null)}.resultCode)
            assertEquals(listOf("library:2"),call {browser.getSearchResult("Fixture 2",0,20,null)}.value!!.map {it.mediaId})
            instrumentation.runOnMainSync {browser.setMediaItems(listOf(tracks[0],tracks[0]));browser.prepare()}
            val until=System.nanoTime()+TimeUnit.SECONDS.toNanos(10)
            var accepted=false
            while(System.nanoTime()<until && !accepted) {
                instrumentation.runOnMainSync {accepted=browser.mediaItemCount==2 && browser.getMediaItemAt(0).mediaMetadata.extras?.getLong("trackId")==1L}
                if(!accepted)Thread.sleep(20)
            }
            assertTrue("Resolved through service",accepted)
            instrumentation.runOnMainSync {
                assertNotEquals(browser.getMediaItemAt(0).mediaId,browser.getMediaItemAt(1).mediaId)
                assertFalse(browser.playWhenReady) // prepare/browse never invent play
                browser.pause()
            }
            graph.session.revoke()
            assertNotEquals(LibraryResult.RESULT_SUCCESS,call {browser.getChildren(SoundQLibraryService.LIBRARY,0,20,null)}.resultCode)
        } finally {instrumentation.runOnMainSync {MediaController.releaseFuture(future)};graph.session.retire()}
    }
}
