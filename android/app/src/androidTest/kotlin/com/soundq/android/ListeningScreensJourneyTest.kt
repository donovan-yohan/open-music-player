package com.soundq.android

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.preferences.Appearance
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Complete ordinary native callers. Screenshot evidence is independently inspected after execution. */
class ListeningScreensJourneyTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private fun action(label: String, dialog: Boolean = false) = compose.onNode(
        hasContentDescription(label) and if (dialog) hasAnyAncestor(isDialog()) else !hasAnyAncestor(isDialog())
    )

    @Test fun captureOrdinaryLibraryQueueAndPrivatePlaylistRows() {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CallbackFrontendFixtureApplication
        val original = ProductTransportFixture.server.dispatcher
        fun summary() = """{"id":41,"name":"Evening listening","description":"","isPublic":false,"trackCount":3,"durationMs":24000}"""
        ProductTransportFixture.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val body = when (request.url.encodedPath) {
                    "/api/v1/playlists" -> """{"data":[${summary()}],"total":1,"limit":20,"offset":0}"""
                    "/api/v1/playlists/41" -> summary().dropLast(1) + """, "tracks":[{"id":1,"title":"Kaleidoscope — 夜のあいだに (Extended live recording)","artist":"旅人たち / Synthetic ensemble","durationMs":12000},{"id":2,"title":"The quiet part, before the last train home","artist":"Synthetic ensemble and the evening orchestra","durationMs":12000},{"id":3,"title":"Unknown length","artist":"Synthetic ensemble","durationMs":0}]}"""
                    else -> return original.dispatch(request)
                }
                return MockResponse.Builder().addHeader("Content-Type", "application/json").body(body).build()
            }
        }
        try {
            // The reported adjacent Search/More layout is the accepted DJ-mode header.
            app.graph.djModePreferences.load()
            assertTrue(app.graph.djModePreferences.setEnabled(app.graph.djModePreferences.capture()!!,true) {true})
            assertTrue(app.graph.djModePreferences.enabled())
            compose.runOnIdle { app.graph.session.retire() }
            compose.waitUntil(10000) { compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithContentDescription("Email").performTextInput("listening-captures@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(15000) { app.graph.library.state.value.let { !it.loading && it.rows.size == 3 } }
            val appearance = Appearance.fromWire(InstrumentationRegistry.getArguments().getString("captureAppearance") ?: "light")!!
            compose.waitUntil(10000) { app.graph.appearancePreferences.state.value.ready }
            val capture = app.graph.appearancePreferences.capture()!!
            assertTrue(app.graph.appearancePreferences.setChoice(capture, appearance) { true })
            assertEquals(appearance, app.graph.appearancePreferences.state.value.choice)
            val model = compose.runOnIdle { ViewModelProvider(compose.activity)[ProductViewModel::class.java] }
            compose.onNode(hasClickAction() and hasAnyDescendant(hasText("Fixture 1")) and
                hasAnyDescendant(hasContentDescription("More for Fixture 1")), useUnmergedTree = true).performClick()
            compose.waitUntil(20000) { model.playback.value.let { it.isPlaying && it.positionMs >= 300 } }
            action("Pause").performClick()
            compose.waitUntil(10000) { !model.playback.value.isPlaying && !model.playback.value.preparing }
            val title = model.playback.value.title!!
            compose.onNode(hasContentDescription("$title, Synthetic ensemble") and hasClickAction()).performClick()
            action("Playback position", true).performSemanticsAction(SemanticsActions.SetProgress) { it(.5f) }
            compose.waitUntil(10000) { model.playback.value.let { !it.isPlaying && !it.preparing && kotlin.math.abs(it.positionMs - 6000) <= 100 } }
            action("Close Now playing", true).performClick()
            compose.waitForIdle()
            captureListeningStage("library-paused-half-song")
            action("Open listening queue").performClick()
            compose.onNode(hasText("Queue") and hasAnyAncestor(isDialog())).assertIsDisplayed()
            compose.waitForIdle()
            captureListeningStage("queue-paused-half-song")
            action("Close Queue", true).performClick()
            compose.onNodeWithText("Playlists").performClick()
            compose.waitUntil(10000) { app.graph.playlists.state.value.rows.size == 1 }
            compose.onNode(hasText("Evening listening") and hasClickAction()).performScrollTo().performClick()
            compose.waitUntil(10000) { app.graph.playlistDetail.state.value.detail?.tracks?.size == 3 }
            compose.waitForIdle()
            val unknownRow = hasClickAction() and hasAnyDescendant(hasText("Unknown length")) and
                hasAnyDescendant(hasContentDescription("More for Unknown length"))
            val unknownTime = compose.onNode(hasText("—:—") and hasAnyAncestor(unknownRow), useUnmergedTree = true)
                .assertIsDisplayed()
            val layouts = mutableListOf<TextLayoutResult>()
            unknownTime.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
            assertEquals("Actual unknown-duration Text layout is available", 1, layouts.size)
            val layout = layouts.single()
            val metadataBand = compose.onNode(hasTestTag("library-row-metadata") and hasAnyAncestor(unknownRow), useUnmergedTree = true)
                .fetchSemanticsNode().boundsInRoot
            assertTrue("The shared metadata slot must reserve the full natural single-line duration width: natural=${layout.multiParagraph.intrinsics.maxIntrinsicWidth}, allocated=${metadataBand.width}",
                layout.multiParagraph.intrinsics.maxIntrinsicWidth <= metadataBand.width + .5f)
            assertFalse("The unavailable duration must not be visually clipped", layout.didOverflowWidth)
            assertTrue("All unavailable-duration glyphs fit its painted cell",
                layout.getBoundingBox(2).right <= unknownTime.fetchSemanticsNode().boundsInRoot.width + .5f)
            val ordinal = compose.onNode(hasText("3") and hasAnyAncestor(unknownRow), useUnmergedTree = true)
                .assertIsDisplayed().fetchSemanticsNode().boundsInRoot
            assertTrue("Unavailable duration and member position must occupy separate, non-overlapping cells",
                unknownTime.fetchSemanticsNode().boundsInRoot.right <= ordinal.left + .5f)
            captureListeningStage("playlist-private-known-and-unknown")
            compose.assertFlatPlaylistHeader()
            // The public path is independently checked by ListeningInformationJourneyTest.
            assertNull(model.playback.value.error)
        } finally {
            ProductTransportFixture.server.dispatcher = original
            compose.runOnIdle { app.graph.session.retire() }
        }
    }
}
