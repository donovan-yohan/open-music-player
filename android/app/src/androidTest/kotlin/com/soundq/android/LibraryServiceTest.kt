package com.soundq.android

import android.content.ComponentName
import android.os.Looper
import androidx.test.platform.app.InstrumentationRegistry
import androidx.media3.common.Player
import androidx.media3.session.*
import com.soundq.android.playback.SoundQLibraryService
import com.google.common.util.concurrent.ListenableFuture
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class LibraryServiceTest {
    @Test fun realBrowserSeesEmptyRootAndNoPlaybackMutationCommands() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        (context.applicationContext as SoundQApplication).graph.session.retire()
        lateinit var future: ListenableFuture<MediaBrowser>
        instrumentation.runOnMainSync {
            future = MediaBrowser.Builder(context, SessionToken(context, ComponentName(context, SoundQLibraryService::class.java)))
                .setApplicationLooper(Looper.getMainLooper()).buildAsync()
        }
        try {
            val browser = future.get(10, TimeUnit.SECONDS)
            lateinit var root: ListenableFuture<LibraryResult<androidx.media3.common.MediaItem>>
            instrumentation.runOnMainSync {
                assertFalse(browser.isCommandAvailable(Player.COMMAND_PLAY_PAUSE))
                assertFalse(browser.isCommandAvailable(Player.COMMAND_CHANGE_MEDIA_ITEMS))
                root = browser.getLibraryRoot(null)
            }
            val rootResult = root.get(10, TimeUnit.SECONDS)
            assertEquals(LibraryResult.RESULT_SUCCESS, rootResult.resultCode)
            assertEquals(false, rootResult.value!!.mediaMetadata.isPlayable)
            lateinit var children: ListenableFuture<LibraryResult<com.google.common.collect.ImmutableList<androidx.media3.common.MediaItem>>>
            instrumentation.runOnMainSync { children = browser.getChildren(rootResult.value!!.mediaId, 0, 20, null) }
            val result = children.get(10, TimeUnit.SECONDS)
            assertEquals(LibraryResult.RESULT_SUCCESS, result.resultCode)
            assertTrue(result.value!!.isEmpty())
        } finally {
            instrumentation.runOnMainSync { MediaController.releaseFuture(future) }
        }
    }
}
