package com.soundq.android

import android.content.ComponentName
import android.os.Bundle
import android.os.Looper
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.media3.common.*
import androidx.media3.session.*
import androidx.test.platform.app.InstrumentationRegistry
import com.google.common.util.concurrent.ListenableFuture
import com.soundq.android.data.*
import com.soundq.android.data.playlists.*
import com.soundq.android.playback.*
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.TimeUnit
import java.util.concurrent.CopyOnWriteArrayList

/** Actual mounted callbacks + HTTPS repository + real MediaController/service/decoder. */
class PlaylistCapacityJourneyTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    @Test fun oversizedContextRefusesWithoutResumingOldQueueAnd500StillPlays() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val app = instrumentation.targetContext.applicationContext as SoundQApplication
        app.graph.session.retire()
        val fallback = ProductTransportFixture.server.dispatcher
        val detailRequests = CopyOnWriteArrayList<String>()
        var count = 501
        fun body(): String {
            val rows = (1..count).joinToString(",") { """{"id":$it,"title":"Capacity $it","artist":"Synthetic ensemble","durationMs":12000}""" }
            return """{"id":41,"name":"Capacity route","isPublic":false,"trackCount":$count,"durationMs":${count * 12000},"tracks":[$rows]}"""
        }
        ProductTransportFixture.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.url.encodedPath) {
                "/api/v1/playlists" -> MockResponse.Builder().body("""{"data":[{"id":41,"name":"Capacity route","isPublic":false,"trackCount":$count,"durationMs":${count * 12000}}],"total":1,"limit":20,"offset":0}""").build()
                "/api/v1/playlists/41" -> {
                    assertEquals("Bearer synthetic-fixture-access", request.headers["Authorization"])
                    assertEquals("https", request.url.scheme)
                    detailRequests.add(request.method + " " + request.url.encodedPath)
                    MockResponse.Builder().body(body()).build()
                }
                else -> fallback.dispatch(request)
            }
        }
        lateinit var future: ListenableFuture<MediaController>
        var observer: MediaController? = null
        val evidence = StringBuilder()
        fun stage(name: String) {
            instrumentation.sendStatus(2, Bundle().apply { putString("capacity_stage", name) })
            evidence.appendLine(name)
            // Finite capture dwell, not a correctness/readiness delay.
            Thread.sleep(1100)
        }
        try {
            compose.waitUntil(10000) { compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithContentDescription("Email").performTextInput("capacity@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000) { app.graph.session.capture() != null && app.graph.library.state.value.rows.size == 3 }
            val model = androidx.lifecycle.ViewModelProvider(compose.activity)[ProductViewModel::class.java]
            instrumentation.runOnMainSync {
                future = MediaController.Builder(app, SessionToken(app, ComponentName(app, SoundQLibraryService::class.java))).setApplicationLooper(Looper.getMainLooper()).buildAsync()
            }
            observer = future.get(10, TimeUnit.SECONDS)
            val c = observer!!
            compose.waitUntil(10000) { model.playback.value.connection == PlaybackProjection.Connection.Connected }
            compose.onNode(hasText("Fixture 1") and hasClickAction()).performScrollTo().performClick()
            compose.waitUntil(15000) { model.playback.value.isPlaying && model.playback.value.positionMs > 0 && model.playback.value.durationMs > 0 }
            compose.runOnIdle { model.controller.pause(); model.controller.seek(2750) }
            compose.waitUntil(10000) { model.playback.value.positionMs == 2750L && !model.playback.value.isPlaying }
            data class Snapshot(val ids: List<String>, val tracks: List<Long>, val selected: Int, val position: Long, val intent: Boolean, val state: Int)
            fun snapshot(): Snapshot {
                lateinit var result: Snapshot
                instrumentation.runOnMainSync {
                    result = Snapshot((0 until c.mediaItemCount).map { c.getMediaItemAt(it).mediaId }, (0 until c.mediaItemCount).map { c.getMediaItemAt(it).mediaMetadata.extras!!.getLong("trackId") }, c.currentMediaItemIndex, c.currentPosition, c.playWhenReady, c.playbackState)
                }
                return result
            }
            val old = snapshot()
            assertEquals(listOf(1L, 2L, 3L), old.tracks)
            assertEquals(2750L, old.position); assertFalse(old.intent); assertEquals(Player.STATE_READY, old.state)
            evidence.appendLine("oldPaused=$old")
            stage("old-paused-positive")
            compose.onNodeWithText("Playlists").performClick()
            compose.waitUntil(10000) { app.graph.playlists.state.value.rows.size == 1 }
            compose.onNode(hasText("Capacity route") and hasClickAction()).performScrollTo().performClick()
            compose.waitUntil(10000) { app.graph.playlistDetail.state.value.detail?.tracks?.size == 501 }
            val detail = app.graph.playlistDetail.state.value.detail!!
            assertEquals((1L..501L).toList(), detail.tracks.map { it.id.value })
            assertTrue(body().toByteArray().size < 2_000_000)
            val capture = app.graph.playlistDetail.capturePlayback()!!
            compose.onNodeWithText(QueuePolicy.CONTEXT_LIMIT_MESSAGE).performScrollTo().assertIsDisplayed()
            compose.onNodeWithContentDescription("Play playlist").performScrollTo().performClick()
            compose.waitForIdle()
            assertEquals(old, snapshot())
            stage("501-play-all-visible-refusal")
            compose.onNode(hasText("Capacity 1") and hasClickAction()).performScrollTo().performClick()
            compose.waitForIdle(); assertEquals(old, snapshot())
            // Bypass any presentation decision: the actual shared adapter must guard all callers.
            compose.runOnIdle { model.controller.playContext(detail.tracks, 500) }
            compose.waitForIdle(); assertEquals(old, snapshot())
            evidence.appendLine("after501=${snapshot()}; fullMembership=${detail.tracks.size}; bytes=${body().toByteArray().size}")
            stage("501-row-and-controller-guard-unchanged")
            // Route retirement must also refuse a retained real ViewModel playback callback.
            instrumentation.runOnMainSync { compose.activity.onBackPressedDispatcher.onBackPressed() }
            compose.waitUntil(5000) { app.graph.playlistDetail.state.value.id == null }
            compose.runOnIdle { model.playPlaylist(capture, TrackId(1)) }
            assertEquals(old, snapshot())
            count = 500
            compose.onNode(hasText("Capacity route") and hasClickAction()).performScrollTo().performClick()
            compose.waitUntil(10000) { app.graph.playlistDetail.state.value.detail?.tracks?.size == 500 }
            compose.onNodeWithText(QueuePolicy.CONTEXT_LIMIT_MESSAGE).assertDoesNotExist()
            compose.onNodeWithContentDescription("Play playlist").performScrollTo().performClick()
            compose.waitUntil(15000) { model.playback.value.queue.size == 500 && model.playback.value.isPlaying && model.playback.value.positionMs > 0 }
            val positive = snapshot()
            assertEquals((1L..500L).toList(), positive.tracks); assertEquals(0, positive.selected); assertTrue(positive.intent)
            evidence.appendLine("positive500Count=${positive.ids.size}; selected=${positive.selected}; intent=${positive.intent}; state=${positive.state}")
            stage("500-play-all-success")
            compose.onNode(hasText("Capacity 2") and hasClickAction()).performScrollTo().performClick()
            compose.waitUntil(15000) { model.playback.value.queue.size == 500 && model.playback.value.queue.singleOrNull { it.occurrenceId == model.playback.value.selectedOccurrence }?.trackId == 2L && model.playback.value.isPlaying }
            assertEquals(1, snapshot().selected)
            stage("500-tapped-row-success")
            val current = app.graph.playlistDetail.capturePlayback()!!
            app.graph.session.retire()
            compose.runOnIdle { model.playPlaylist(current, TrackId(1)) }
            compose.waitUntil(10000) { model.playback.value.queue.isEmpty() && !model.playback.value.isPlaying }
            evidence.appendLine("retired-account-callback-refused; detailHTTPS=$detailRequests")
            assertEquals(2, detailRequests.size)
        } finally {
            java.io.File(app.filesDir, "capacity-evidence.txt").writeText(evidence.toString())
            observer?.let { instrumentation.runOnMainSync { it.pause(); MediaController.releaseFuture(future) } }
            ProductTransportFixture.server.dispatcher = fallback
            app.graph.playlistDetail.retire(); app.graph.session.retire()
        }
    }
}
