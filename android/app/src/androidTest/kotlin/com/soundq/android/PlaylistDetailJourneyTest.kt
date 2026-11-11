package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Extends the ordinary signed-in route with the same fixture's actual decoder path. */
class PlaylistDetailJourneyTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    @Test fun opensOwnedPlaylistAndPlaysTappedOrderedTrackThenReturnsToList() {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        app.graph.session.retire()
        val fallback = ProductTransportFixture.server.dispatcher
        ProductTransportFixture.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.url.encodedPath) {
                "/api/v1/playlists" -> MockResponse.Builder().body("""{"data":[{"id":41,"name":"Night route","isPublic":false,"trackCount":2,"durationMs":24000}],"total":1,"limit":20,"offset":0}""").build()
                "/api/v1/playlists/41" -> MockResponse.Builder().body("""{"id":41,"name":"Night route","description":"Night listening","isPublic":false,"trackCount":2,"durationMs":24000,"tracks":[{"id":2,"title":"Fixture 2","artist":"Synthetic ensemble","durationMs":12000},{"id":1,"title":"Fixture 1","artist":"Synthetic ensemble","durationMs":12000}]}""").build()
                else -> fallback.dispatch(request)
            }
        }
        try {
            compose.waitUntil(10000) { compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithContentDescription("Email").performTextInput("playlist@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000) { app.graph.session.capture() != null && compose.onAllNodesWithText("Playlists").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Playlists").performClick()
            compose.waitUntil(10000) { app.graph.playlists.state.value.rows.size == 1 }
            compose.onNode(hasText("Night route") and hasClickAction()).performScrollTo().performClick()
            compose.waitUntil(10000) { app.graph.playlistDetail.state.value.detail != null }
            compose.onNodeWithContentDescription("Play playlist").assertIsDisplayed()
            val before = ProductTransportFixture.requests.size
            val memberRow=hasText("Fixture 1") and hasClickAction() and hasAnyDescendant(hasContentDescription("More for Fixture 1"))
            compose.onNode(memberRow).performScrollTo().performClick()
            val model = androidx.lifecycle.ViewModelProvider(compose.activity)[com.soundq.android.product.ProductViewModel::class.java]
            compose.waitUntil(15000) { model.playback.value.isPlaying && model.playback.value.positionMs > 0 }
            assertEquals(listOf(2L, 1L), model.playback.value.queue.map { it.trackId })
            assertEquals(1L, model.playback.value.queue.single { it.occurrenceId == model.playback.value.selectedOccurrence }.trackId)
            assertTrue(ProductTransportFixture.requests.drop(before).any { it.startsWith("GET /media/") })
            compose.runOnIdle {model.controller.pause()}
            compose.waitUntil(10000){!model.playback.value.isPlaying}
            val paused=model.playback.value
            compose.onNode(memberRow).performScrollTo().performTouchInput {
                down(androidx.compose.ui.geometry.Offset(width*0.9f,center.y));moveBy(androidx.compose.ui.geometry.Offset(-190*compose.activity.resources.displayMetrics.density,0f),delayMillis=300);up()
            }
            compose.waitUntil(10000){compose.runOnIdle {
                val observed=acknowledgedQueueObservation(model).readback
                observed.acknowledged(paused.queue.size+1,observed.serviceSelected)
            }}
            assertEquals(paused.selectedOccurrence,model.playback.value.selectedOccurrence);assertFalse(model.playback.value.isPlaying)
            assertEquals(1,model.playback.value.queue.count {it.manual&&it.trackId==1L})
            compose.onNodeWithContentDescription("Back to playlists").performScrollTo().performClick()
            compose.waitUntil(5000) { app.graph.playlistDetail.state.value.id == null }
            compose.onNodeWithText("Create private playlist").performScrollTo().assertIsDisplayed()
            compose.runOnIdle { model.controller.pause() }
        } finally {
            ProductTransportFixture.server.dispatcher = fallback
            app.graph.playlistDetail.retire()
            app.graph.session.retire()
        }
    }
}
