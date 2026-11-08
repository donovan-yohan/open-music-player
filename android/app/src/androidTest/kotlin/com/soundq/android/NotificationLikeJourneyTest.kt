package com.soundq.android

import android.content.ComponentName
import android.os.Bundle
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.session.*
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import com.soundq.android.playback.SoundQLibraryService
import com.google.common.util.concurrent.ListenableFuture
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

/** Compiled actual session/controller journey. Execution and OS notification pixels are separate gates. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class NotificationLikeJourneyTest {
    @Test fun currentSongHeartAndLibraryRowsShareAcknowledgedLikeAndUnlike() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val context=instrumentation.targetContext
        val app=context.applicationContext as FixtureApplication
        val graph=app.graph
        graph.api.logout()
        assertTrue(graph.api.authenticate("notification@example.test","synthetic-password"))
        ProductTransportFixture.liked=false
        graph.library.refine(LibraryQuery())
        graph.rememberTracks(graph.library.state.value.rows)
        lateinit var connection:ListenableFuture<MediaController>
        instrumentation.runOnMainSync {
            connection=MediaController.Builder(context,SessionToken(context,ComponentName(context,SoundQLibraryService::class.java)))
                .setApplicationLooper(Looper.getMainLooper()).buildAsync()
        }
        val controller=connection.get(10,TimeUnit.SECONDS)
        try {
            instrumentation.runOnMainSync {controller.setMediaItem(MediaItem.Builder().setMediaId("1").build())}
            fun action(label:String):SessionCommand {
                var found:SessionCommand?=null
                val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(8)
                while(found==null&&System.nanoTime()<deadline) {
                    instrumentation.runOnMainSync {found=controller.mediaButtonPreferences.firstOrNull {it.displayName.toString()==label&&it.isEnabled}?.sessionCommand}
                    if(found==null)Thread.yield()
                }
                return checkNotNull(found){"Current acknowledged $label action unavailable"}
            }
            val first=action("Like")
            lateinit var result:ListenableFuture<SessionResult>
            val before=ProductTransportFixture.requests.size
            instrumentation.runOnMainSync {result=controller.sendCustomCommand(first,Bundle.EMPTY)}
            assertEquals(SessionResult.RESULT_SUCCESS,result.get(8,TimeUnit.SECONDS).resultCode)
            assertEquals(true,graph.library.state.value.rows.first {it.id.value==1L}.liked)
            val unlike=action("Unlike")
            instrumentation.runOnMainSync {result=controller.sendCustomCommand(first,Bundle.EMPTY)}
            assertTrue(result.get(5,TimeUnit.SECONDS).resultCode!=SessionResult.RESULT_SUCCESS)
            instrumentation.runOnMainSync {result=controller.sendCustomCommand(unlike,Bundle.EMPTY)}
            assertEquals(SessionResult.RESULT_SUCCESS,result.get(8,TimeUnit.SECONDS).resultCode)
            assertEquals(false,graph.library.state.value.rows.first {it.id.value==1L}.liked)
            action("Like")
            assertEquals(listOf("POST /api/v1/library/tracks/1/like","DELETE /api/v1/library/tracks/1/like"),ProductTransportFixture.requests.drop(before).filter {it.endsWith("/like")})
            instrumentation.runOnMainSync {assertFalse(controller.playWhenReady);assertEquals(0,controller.currentMediaItemIndex);assertEquals(1,controller.mediaItemCount)}
        } finally {instrumentation.runOnMainSync {controller.release()}}
    }
}
