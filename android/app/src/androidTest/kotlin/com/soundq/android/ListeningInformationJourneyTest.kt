package com.soundq.android

import androidx.compose.ui.semantics.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.RecordedRequest
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Run with CallbackFrontendFixtureRunner: ordinary Activity, real service/JNI and MP3.
 * No component-only mount, synthetic cursor, external account or alternate player. */
class ListeningInformationJourneyTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app get() = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CallbackFrontendFixtureApplication
    private val artist = "Synthetic ensemble"
    private val length = 12000L // callback/frontend-analysis.json artifacts.source.duration_ms

    private fun inSurface(dialog: Boolean): SemanticsMatcher =
        if (dialog) hasAnyAncestor(isDialog()) else !hasAnyAncestor(isDialog())

    private fun identity(title: String, dialog: Boolean = false) =
        hasContentDescription("$title, $artist") and hasClickAction() and inSurface(dialog)

    private fun action(label: String, dialog: Boolean = false) =
        compose.onNode(hasContentDescription(label) and inSurface(dialog))

    private fun row(title: String, dialog: Boolean = false) = hasClickAction() and
        hasAnyDescendant(hasText(title)) and
        hasAnyDescendant(hasContentDescription("More for $title")) and inSurface(dialog)

    private fun signIn(): ProductViewModel {
        compose.runOnIdle { app.graph.session.retire() }
        compose.waitUntil(10000) { compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithContentDescription("Email").performTextInput("listening-information@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        compose.waitUntil(15000) { app.graph.library.state.value.rows.size == 3 && !app.graph.library.state.value.loading }
        return compose.runOnIdle { ViewModelProvider(compose.activity)[ProductViewModel::class.java] }
    }

    private fun startPaused(model: ProductViewModel) {
        assertEquals("com.soundq.android.playback.nativeengine.NativeCallbackPlayer", app.callbackPlayer.javaClass.name)
        compose.onNode(row("Fixture 1"), useUnmergedTree = true).performScrollTo().performClick()
        compose.waitUntil(20000) { model.playback.value.let { it.title == "Fixture 1" && it.isPlaying && it.positionMs >= 300 } }
        action("Pause").assertIsDisplayed().performClick()
        compose.waitUntil(10000) { !model.playback.value.isPlaying && !model.playback.value.preparing }
        assertNull(model.playback.value.error)
        assertEquals(length, model.playback.value.queue.first().durationMs)
    }

    private fun seekInPlayer(model: ProductViewModel, fraction: Float) {
        val title = model.playback.value.title!!
        compose.onNode(identity(title)).performClick()
        val occurrence = model.playback.value.selectedOccurrence
        action("Playback position", dialog = true).performSemanticsAction(SemanticsActions.SetProgress) { it(fraction) }
        val target = (length * fraction).toLong()
        compose.waitUntil(10000) { model.playback.value.let {
            it.selectedOccurrence == occurrence && !it.preparing && !it.isPlaying && kotlin.math.abs(it.positionMs - target) <= 100
        } }
        action("Close Now playing", dialog = true).performClick()
    }

    // Compact's preexisting artwork and identity locate the consuming chrome. The
    // shared Column has no semantics on baseline. Use its measured vertical band,
    // not a root-wide text/progress search that Library or full player could satisfy.
    private fun compactBand(title: String, dialog: Boolean = false): SemanticsMatcher {
        compose.onNode(identity(title, dialog)).assertIsDisplayed()
        val art = compose.onNode(hasTestTag("compact-artwork") and inSurface(dialog), useUnmergedTree = true)
            .assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        val pad = 12f * compose.density.density
        return SemanticsMatcher("inside compact artwork vertical band") { node ->
            val b = node.boundsInRoot
            b.width > 0 && b.height > 0 && b.top >= art.top - pad && b.bottom <= art.bottom + pad
        } and inSurface(dialog)
    }

    private fun assertCompactProgress(model: ProductViewModel, dialog: Boolean = false) {
        val state = compose.runOnIdle { model.playback.value }
        assertFalse(state.isPlaying)
        assertTrue(state.durationMs > 0)
        val expected = state.positionMs.toFloat() / state.durationMs
        val matcher = compactBand(state.title!!, dialog) and
            SemanticsMatcher.keyIsDefined(SemanticsProperties.ProgressBarRangeInfo)
        compose.waitUntil(5000) { compose.onAllNodes(matcher, useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty() }
        val nodes = compose.onAllNodes(matcher, useUnmergedTree = true).fetchSemanticsNodes()
        assertEquals("One rendered compact song progress indicator", 1, nodes.size)
        val range = nodes.single().config[SemanticsProperties.ProgressBarRangeInfo]
        assertNotEquals(ProgressBarRangeInfo.Indeterminate, range)
        val normalized = (range.current - range.range.start) / (range.range.endInclusive - range.range.start)
        assertEquals("Compact progress follows observed source-song cursor", expected, normalized, .015f)
        compose.onNode(matcher, useUnmergedTree = true).assertIsDisplayed()
    }

    private fun time(ms: Long): String {
        val seconds = ms / 1000
        return "${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')}"
    }

    private fun visibleTime(value: String, scope: SemanticsMatcher) {
        // Accept separate Text nodes or a single elapsed / total Text, not a
        // contentDescription-only implementation or an unrelated Library row.
        val token = Regex("(?<![0-9:])${Regex.escape(value)}(?![0-9:])")
        val text = SemanticsMatcher("visible numeric time $value") { node ->
            node.config.getOrElse(SemanticsProperties.Text) { emptyList() }.any { token.containsMatchIn(it.text) }
        }
        compose.onAllNodes(scope and text, useUnmergedTree = true).onFirst().assertIsDisplayed()
    }

    @Test fun compactProgressTracksPausedSeekInLibraryAndQueue() {
        val model = signIn()
        try {
            startPaused(model)
            seekInPlayer(model, .5f)
            assertCompactProgress(model)
            action("Open listening queue").performClick()
            compose.onNode(hasText("Queue") and hasAnyAncestor(isDialog())).assertIsDisplayed()
            assertCompactProgress(model, dialog = true)
        } finally { compose.runOnIdle { app.graph.session.retire() } }
    }

    @Test fun compactElapsedAndKnownLengthAreVisibleSongFacts() {
        val model = signIn()
        try {
            startPaused(model)
            seekInPlayer(model, .5f)
            val state = compose.runOnIdle { model.playback.value }
            assertEquals(length, state.durationMs)
            visibleTime(time(state.positionMs), compactBand(state.title!!))
            visibleTime(time(length), compactBand(state.title!!))
            action("Open listening queue").performClick()
            visibleTime(time(state.positionMs), compactBand(state.title!!, dialog = true))
            visibleTime(time(length), compactBand(state.title!!, dialog = true))
        } finally { compose.runOnIdle { app.graph.session.retire() } }
    }

    @Test fun queueKnownMemberLengthIsNotBorrowedFromCompactOrLibrary() {
        val model = signIn()
        try {
            startPaused(model)
            action("Open listening queue").performClick()
            assertEquals(listOf(length, length, length), model.playback.value.queue.map { it.durationMs })
            for (item in model.playback.value.queue) {
                val member = row(item.title, dialog = true)
                compose.onNode(member, useUnmergedTree = true).performScrollTo().assertIsDisplayed()
                visibleTime(time(item.durationMs), hasAnyAncestor(member) and hasAnyAncestor(isDialog()))
            }
        } finally { compose.runOnIdle { app.graph.session.retire() } }
    }

    @Test fun privatePlaylistMemberKnownLengthSurvivesOrderListProjection() = playlistDuration(false)
    @Test fun publicPlaylistMemberKnownLengthSurvivesMediaRowProjection() = playlistDuration(true)

    private fun playlistDuration(public: Boolean) {
        val original = ProductTransportFixture.server.dispatcher
        val summary = """{"id":41,"name":"Timing route","description":"","isPublic":$public,"trackCount":3,"durationMs":24000}"""
        val detail = summary.dropLast(1) + """, "tracks":[{"id":1,"title":"Fixture 1","artist":"$artist","durationMs":12000},{"id":2,"title":"Fixture 2","artist":"$artist","durationMs":12000},{"id":3,"title":"Unknown length","artist":"$artist","durationMs":0}]}"""
        ProductTransportFixture.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val body = when (request.url.encodedPath) {
                    "/api/v1/playlists" -> """{"data":[$summary],"total":1,"limit":20,"offset":0}"""
                    "/api/v1/playlists/41" -> detail
                    else -> return original.dispatch(request) // preserve MP3, analysis and grants
                }
                assertEquals("Bearer synthetic-fixture-access", request.headers["Authorization"])
                assertEquals("GET", request.method)
                return MockResponse.Builder().addHeader("Content-Type", "application/json").body(body).build()
            }
        }
        try {
            signIn()
            compose.onNodeWithText("Playlists").performClick()
            compose.waitUntil(10000) { app.graph.playlists.state.value.rows.size == 1 }
            compose.onNode(hasText("Timing route") and hasClickAction()).performScrollTo().performClick()
            compose.waitUntil(10000) { app.graph.playlistDetail.state.value.detail?.tracks?.size == 3 }
            assertEquals(listOf(length, length, 0L), app.graph.playlistDetail.state.value.detail!!.tracks.map { it.durationMs })
            for (title in listOf("Fixture 1", "Fixture 2")) {
                val member = row(title)
                compose.onNode(member, useUnmergedTree = true).performScrollTo().assertIsDisplayed()
                visibleTime(time(length), hasAnyAncestor(member) and inSurface(false))
            }
            val unknown = row("Unknown length")
            compose.onNode(unknown, useUnmergedTree = true).performScrollTo().assertIsDisplayed()
            compose.onAllNodes(hasText("0:00", substring = true) and hasAnyAncestor(unknown), useUnmergedTree = true).assertCountEquals(0)
        } finally {
            ProductTransportFixture.server.dispatcher = original
            compose.runOnIdle { app.graph.session.retire() }
        }
    }

    @Test fun existingPauseSeekNextAndReturnControlsKeepRealPlaybackOwnership() {
        val model = signIn()
        try {
            startPaused(model)
            seekInPlayer(model, .25f)
            val first = model.playback.value.selectedOccurrence
            val paused = model.playback.value.positionMs
            compose.onNode(identity("Fixture 1")).performClick()
            for (label in listOf("Play", "Next track", "Previous track")) {
                val bounds = action(label, dialog = true).assertIsDisplayed().fetchSemanticsNode().boundsInRoot
                assertTrue("$label retains 48dp action cell", bounds.width + 1 >= 48 * compose.density.density && bounds.height + 1 >= 48 * compose.density.density)
            }
            // No elapsed wall-clock guess: commands await observed selection/cursor.
            action("Next track", dialog = true).performClick()
            compose.waitUntil(15000) { model.playback.value.let { it.title == "Fixture 2" && it.selectedOccurrence != first && !it.preparing } }
            action("Previous track", dialog = true).performClick()
            compose.waitUntil(15000) { model.playback.value.let { it.title == "Fixture 1" && it.selectedOccurrence == first && !it.preparing } }
            assertFalse(model.playback.value.isPlaying)
            action("Close Now playing", dialog = true).performClick()
            seekInPlayer(model, .25f)
            assertTrue(kotlin.math.abs(paused - model.playback.value.positionMs) <= 100)
            assertNull(model.playback.value.error)
            assertTrue(ProductTransportFixture.requests.any { it.startsWith("GET /media/") })
        } finally { compose.runOnIdle { app.graph.session.retire() } }
    }
}
