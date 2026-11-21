package com.soundq.android.product.trackdetails

import android.app.Application
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import com.soundq.android.data.MutationOutcome
import com.soundq.android.data.originalimport.OriginalImportCompositionTest.Fixture
import com.soundq.android.data.trackdetails.DetailsAction
import com.soundq.android.data.trackdetails.DetailsTicket
import com.soundq.designsystem.SoundQTheme
import java.util.concurrent.atomic.AtomicBoolean
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.RecordedRequest
import mockwebserver3.SocketEffect
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The production sheet consumes real route publications; only the loopback HTTP peer is scripted. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class, qualifiers = "w412dp-h915dp")
class TrackDetailsRemovalFeedbackTest {
    @get:Rule val compose = createComposeRule()

    @Test fun lostRemovalShowsOnlyItsSpecializedResult() = exercise()

    @Test fun refusedMetadataIsVisibleWithTheRetainedRemovalFence() = exercise(MutationOutcome.Refused)

    @Test fun acknowledgedMetadataIsVisibleWithTheRetainedRemovalFence() = exercise(MutationOutcome.Confirmed)

    @Test fun acceptedMetadataWithFailedReadbackKeepsBothNoticesAndOneReloadAction() = exercise(MutationOutcome.ReadbackFailed)

    private fun button(label: String) = compose.onNode(hasText(label) and hasClickAction())
    private fun click(label: String) = button(label).performScrollTo().assertIsEnabled().performClick()
    private fun notice(label: String) {
        compose.onAllNodesWithText(label).assertCountEquals(1)
        compose.onNodeWithText(label).performScrollTo().assertIsDisplayed()
    }

    private fun exercise(metadataOutcome: MutationOutcome? = null) = Fixture().use { f ->
        val accepted = AtomicBoolean()
        val failReadback = AtomicBoolean(metadataOutcome == MutationOutcome.ReadbackFailed)
        val metadataPath = "/api/v1/tracks/77/metadata-override"
        val analysisPath = "/api/v1/tracks/77/analysis"
        val libraryPath = "/api/v1/library"
        val journal = f.directory.resolve("original-import.v1.json")
        val beforeRemoval = journal.readBytes()
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.method to request.url.encodedPath) {
                "GET" to libraryPath -> when {
                    !accepted.get() -> f.libraryPage(true, request)
                    failReadback.get() -> f.reply(503, "{}")
                    else -> f.reply(200, """{"tracks":[{"id":77,"title":"Personal title","duration_ms":4000,"has_metadata_override":true,"mb_verified":false}],"total":1,"limit":${request.url.queryParameter("limit")},"offset":0}""")
                }
                "GET" to analysisPath -> f.reply(404, "{}")
                // DELETE enters the wire, but there is no accepted response; membership still reads present.
                "DELETE" to f.memberPath -> MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build()
                "PUT" to metadataPath -> if (metadataOutcome == MutationOutcome.Refused) f.reply(403, "{}") else {
                    accepted.set(true)
                    f.reply(200, """{"track_id":77,"title":"Personal title","artist":null,"album":null,"has_metadata_override":true}""")
                }
                else -> f.reply(500, "{}")
            }
        }
        f.graph(null).use { g ->
            f.signIn(g)
            val route = f.openDetails(g)
            val details = g.trackDetails
            val commands = mutableListOf<DetailsTicket>()
            var reloads = 0
            compose.setContent {
                SoundQTheme {
                    TrackDetailsSheet(details.state.collectAsState().value,
                        { observed, action -> commands += checkNotNull(details.claim(route, observed, action)) },
                        { reloads++ }, {})
                }
            }
            click("Remove from Library")
            button("Confirm Library removal").assertIsDisplayed().performClick()
            notice("Saving change")
            button("Remove from Library").assertIsNotEnabled()
            val removal = compose.runOnIdle { commands.single() }
            assertEquals(DetailsAction.Remove, removal.action)
            details.execute(removal)
            assertEquals("DELETE", f.next(f.memberPath).method)
            val fenced = journal.readBytes()
            assertFalse(beforeRemoval.contentEquals(fenced))
            notice("Removal not confirmed")
            compose.onNodeWithText("Change not confirmed").assertDoesNotExist()
            compose.onNodeWithText("Saving change").assertDoesNotExist()
            button("Remove from Library").assertIsNotEnabled()
            button("Edit metadata").assertIsNotEnabled()

            fun reload() {
                click("Reload song details")
                details.load(route)
                assertEquals("GET", f.next(libraryPath).method)
                assertEquals("GET", f.next(analysisPath).method)
            }
            reload()
            notice("Removal not confirmed")
            compose.onNodeWithText("Change not confirmed").assertDoesNotExist()
            button("Remove from Library").assertIsNotEnabled()
            if (metadataOutcome != null) {
                click("Edit metadata")
                compose.onNodeWithContentDescription("Title").performScrollTo().performTextReplacement("Personal title")
                click("Save metadata")
                notice("Saving change")
                button("Save metadata").assertIsNotEnabled()
                val metadata = compose.runOnIdle { commands.toList() }.also { assertEquals(2, it.size) }.last()
                assertTrue(metadata.action is DetailsAction.Metadata)
                details.execute(metadata)
                val request = f.next(metadataPath)
                assertEquals("PUT", request.method)
                assertEquals("""{"title":"Personal title","artist":null,"album":null}""", request.body!!.utf8())
                if (metadataOutcome != MutationOutcome.Refused) assertEquals("GET", f.next(libraryPath).method)
                if (metadataOutcome == MutationOutcome.Confirmed) assertEquals("GET", f.next(libraryPath).method)
                assertEquals(metadataOutcome, details.state.value.outcome)
                notice("Removal not confirmed")
                notice(when (metadataOutcome) {
                    MutationOutcome.Refused -> "Change refused"
                    MutationOutcome.Confirmed -> "Change saved"
                    else -> "Change accepted, refresh failed"
                })
                compose.onNodeWithText("Saving change").assertDoesNotExist()
                if (metadataOutcome == MutationOutcome.ReadbackFailed) {
                    button("Save metadata").assertIsNotEnabled()
                    compose.onAllNodes(hasText("Reload song details") and hasClickAction()).assertCountEquals(1)
                    failReadback.set(false)
                    reload()
                    button("Save metadata").assertIsEnabled()
                } else button("Save metadata").assertIsEnabled()
                compose.onNodeWithContentDescription("Back to Song details").performScrollTo().performClick()
                if (metadataOutcome != MutationOutcome.Confirmed) button("Discard").assertIsDisplayed().performClick()
                button("Remove from Library").performScrollTo().assertIsDisplayed().assertIsNotEnabled()
                button("Edit metadata").assertIsEnabled()
            }
            assertArrayEquals(fenced, journal.readBytes())
            compose.runOnIdle {
                assertEquals(if (metadataOutcome == MutationOutcome.ReadbackFailed) 2 else 1, reloads)
                assertEquals(if (metadataOutcome == null) 1 else 2, commands.size)
            }
            assertNull(details.claim(route, details.state.value.detail!!, DetailsAction.Remove))
            assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
        }
    }
}
