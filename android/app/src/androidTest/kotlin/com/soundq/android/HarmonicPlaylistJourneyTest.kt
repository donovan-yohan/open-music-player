package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Compiled ordinary ProductApp route. Runtime requires a separately admitted lane. */
class HarmonicPlaylistJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun seededOnceManualQueueMembershipReadbackAndAcceptedDjSetting() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication
        app.graph.session.retire()
        val fallback=ProductTransportFixture.server.dispatcher
        val added=AtomicBoolean(false);val reads=AtomicInteger()
        fun summary()="""{"id":41,"name":"Harmonic journey","isPublic":false,"trackCount":${if(added.get())3 else 2},"durationMs":${if(added.get())36000 else 24000}}"""
        fun detail()=summary().dropLast(1)+",\"tracks\":["+
            """{"id":2,"title":"Fixture 2","durationMs":12000,"analysisSummary":{"bpm":{"value":124.4},"camelot":{"value":"8a"}}},{"id":1,"title":"Fixture 1","durationMs":12000}"""+
            (if(added.get())",{\"id\":3,\"title\":\"Unknown length neighbour\",\"durationMs\":12000}"else "")+"]}"
        ProductTransportFixture.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse=when(request.url.encodedPath) {
            "/api/v1/playlists"->MockResponse.Builder().body("""{"data":[${summary()}],"total":1,"limit":20,"offset":0}""").build()
            "/api/v1/playlists/41"->MockResponse.Builder().body(detail()).build()
            "/api/v1/tracks/nearby"->{reads.incrementAndGet();MockResponse.Builder().body("""{"tracks":[{"id":2,"title":"Anchor","bpm":124.4,"camelot":"8A"},{"id":1,"title":"Known length neighbour","bpm":125,"camelot":"9A"},{"id":3,"title":"Unknown length neighbour","bpm":123}],"bpm":124,"camelot":"8A","tolerance":5,"order":"history"}""").build()}
            "/api/v1/playlists/41/tracks"->{assertEquals("POST",request.method);assertEquals("{\"trackIds\":[3]}",request.body!!.utf8());added.set(true);MockResponse.Builder().body("""{"added":[3],"skipped":[],"playlist":${summary()}}""").build()}
            else->fallback.dispatch(request)
        }}
        try {
            app.graph.djModePreferences.load();app.graph.djModePreferences.setEnabled(app.graph.djModePreferences.capture()!!,true){true}
            compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithContentDescription("Email").performTextInput("harmonic@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000){app.graph.session.capture()!=null&&compose.onAllNodesWithText("Playlists").fetchSemanticsNodes().isNotEmpty()}
            val model=compose.runOnIdle {androidx.lifecycle.ViewModelProvider(compose.activity)[com.soundq.android.product.ProductViewModel::class.java]}
            compose.waitUntil(10000){app.graph.library.state.value.rows.size==3&&model.playback.value.connection==com.soundq.android.playback.PlaybackProjection.Connection.Connected}
            // Adding the first item to an empty queue legitimately selects it, in Flutter too.
            // Establish a real paused selection before asserting that harmonic insertion preserves it.
            val libraryRow=hasText("Fixture 1")and hasClickAction()and hasAnyDescendant(hasContentDescription("More for Fixture 1"))
            compose.onNode(hasScrollToNodeAction()).performScrollToNode(libraryRow)
            compose.onNode(libraryRow).assertIsDisplayed().assertIsEnabled().performClick()
            compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.selectedOccurrence!=null}
            val observedPosition=model.playback.value.positionMs
            compose.waitUntil(10000){model.playback.value.isPlaying&&model.playback.value.positionMs>observedPosition}
            compose.onNodeWithContentDescription("Pause").assertIsDisplayed().assertIsEnabled().performClick()
            val settled=compose.settledPausedPlayback(model)
            assertNotNull(settled.projection.selectedOccurrence)
            assertFalse(settled.projection.isPlaying)
            compose.onNodeWithText("Playlists").performClick()
            compose.waitUntil(10000){app.graph.playlists.state.value.rows.isNotEmpty()}
            compose.onNode(hasText("Harmonic journey")and hasClickAction()).performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.playlistDetail.state.value.detail!=null}
            compose.waitUntil(10000){model.playback.value.connection==com.soundq.android.playback.PlaybackProjection.Connection.Connected}
            compose.runOnIdle {assertActualPausedUnchanged(settled)}
            val before=model.playback.value
            compose.onNodeWithContentDescription("Find harmonic matches").performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.harmonic.state.value.result!=null}
            assertEquals(1,reads.get());assertEquals("124",app.graph.harmonic.state.value.draft.bpm)
            compose.onNodeWithText("Ordered by your listening history").performScrollTo().assertIsDisplayed()
            compose.onNode(hasText("Known length neighbour")and hasClickAction()).performScrollTo().performClick()
            compose.onNodeWithText("Back").performScrollTo().performClick();assertEquals(1,reads.get())
            compose.onNode(hasText("Known length neighbour")and hasClickAction()).performScrollTo().performClick()
            compose.onNode(hasText("Add to queue")and hasClickAction()).performScrollTo().performClick()
            compose.waitUntil(10000){compose.runOnIdle {
                val readback=acknowledgedQueueObservation(model).readback
                readback.acknowledged(before.queue.size+1,readback.serviceSelected)
            }}
            assertFalse(model.playback.value.isPlaying);assertEquals(before.selectedOccurrence,model.playback.value.selectedOccurrence)
            compose.runOnIdle {assertEquals(settled.servicePositionMs,model.playback.value.positionMs)}
            assertEquals(1L,model.playback.value.queue.single {it.manual}.trackId)
            compose.onNodeWithContentDescription("Find harmonic matches").performScrollTo().performClick()
            assertEquals(1,reads.get())
            compose.onNode(hasText("Unknown length neighbour")and hasClickAction()).performScrollTo().performClick()
            compose.onNodeWithText("Could not add this track to queue: its length is unknown.").performScrollTo().assertIsDisplayed()
            compose.onNode(hasText("Add to this playlist")and hasClickAction()).performScrollTo().performClick()
            compose.waitUntil(10000){app.graph.playlistManagement.state.value.outcome==com.soundq.android.data.MutationOutcome.Confirmed}
            assertEquals(listOf(2L,1L,3L),app.graph.playlistDetail.state.value.detail!!.tracks.map {it.id.value})
            assertFalse(model.playback.value.isPlaying);assertEquals(before.selectedOccurrence,model.playback.value.selectedOccurrence)
            compose.onNodeWithContentDescription("Back to playlists").performScrollTo().performClick()
            compose.onNodeWithText("Library").performClick()
            compose.onNodeWithContentDescription("Account and settings").performClick()
            compose.onNodeWithText("Settings").performScrollTo().assertIsDisplayed().assertIsEnabled().performClick()
            compose.onNode(hasText("DJ mode")and hasClickAction()).performScrollTo().performClick()
            compose.waitUntil(10000){!app.graph.djModePreferences.state.value.enabled}
            val restored=com.soundq.android.data.preferences.DjModePreferences(java.io.File(app.graph.directory,"dj-mode.v1.json"));restored.load();assertFalse(restored.enabled())
        } finally {ProductTransportFixture.server.dispatcher=fallback;app.graph.harmonic.retire();app.graph.session.retire()}
    }
}
