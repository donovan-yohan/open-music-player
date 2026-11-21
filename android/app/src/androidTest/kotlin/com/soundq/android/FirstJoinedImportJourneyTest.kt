package com.soundq.android

import android.content.ContentValues
import android.net.Uri
import android.os.Environment
import android.os.Process
import android.provider.MediaStore
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.AccountScope
import com.soundq.android.data.AuthState
import com.soundq.android.data.deviceaudio.ContentRevision
import com.soundq.android.data.deviceaudio.DeviceAudio
import com.soundq.android.data.deviceaudio.LocalDisplayText
import com.soundq.android.data.deviceaudio.MetadataApplyResult
import com.soundq.android.product.LocalEnrichmentVisit
import com.soundq.android.data.originalimport.ImportDisplay
import com.soundq.android.data.originalimport.OriginalImportPhase
import com.soundq.android.playback.PlaybackProjection
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit.SECONDS
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Two mounted methods, one fixture run: submit, externally restart both processes, recover. */
@SdkSuppress(minSdkVersion = 30)
class FirstJoinedImportJourneyTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val app get() = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FirstJoinedImportApplication
    private val graph get() = app.graph
    private val resolver get() = app.contentResolver
    private val checkpoint get() = File(graph.directory, "first-joined-observed.checkpoint")
    private val first = ImportDisplay("Joined Studio Cut", "Joined Credit", "Joined Edition")
    private val later = ImportDisplay("Later Local Cut", "Later Local Credit", "Later Local Edition")
    private val revision = ContentRevision("bf83725946603791eace9c56d16c97dfedd79f28f64145171d7595180fc5e20b", 97157)
    private val uploadPath = "/api/v1/library/uploads"
    private val unknown = "Add to Library isn’t confirmed. Check import status in Library."

    @Test fun mountedClickSnapshotSurvivesLaterApplyAndLostAck() {
        assertEquals("submit", FirstJoinedImportApplication.phase)
        assertTrue(Environment.isExternalStorageManager())
        assertFalse(checkpoint.exists())
        compose.waitUntil(20_000) { graph.session.state.value is AuthState.SignedOut }
        compose.signInThroughSettings(app.settings.email, app.settings.password) { graph.session.state.value is AuthState.SignedIn }
        val scope = awaitReady()
        assertTrue(graph.originalImports.entries(scope).isEmpty())
        val bytes = File(app.filesDir, "first-joined-original.mp3").let { file ->
            assertEquals(revision.byteLength, file.length()); file.readBytes()
        }
        assertEquals(revision.sha256, digest(bytes))
        val uri = insertOriginal(bytes)
        val original = graph.phoneAudio.awaitIndexed(uri) { it.revision == revision }
        assertNull(original.displayOverride)
        val accepted = runBlocking { apply(scope, original, first) }
        val firstRevision = requireNotNull(accepted.displayOverride?.revision)
        assertTrue(firstRevision > 0)
        assertEquals(original.owner, accepted.owner)
        val startingPlayback = idleTransport()

        val more = "More for ${first.title}"
        compose.waitUntil(15_000) { compose.onAllNodes(hasScrollToIndexAction()).fetchSemanticsNodes().size == 1 }
        compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasContentDescription(more))
        compose.onNodeWithContentDescription(more).assertIsDisplayed().performClick()
        // A second editor cannot ordinarily be opened over this sheet. Hold the real Apply
        // at review admission, click while the previous revision is still acknowledged, then
        // release Apply and verify its publication before accepting the immutable disclosure.
        val held = CountDownLatch(1)
        val release = CountDownLatch(1)
        val firstReview = AtomicBoolean(true)
        val updated = runBlocking {
            val competing = async(Dispatchers.IO) {
                apply(scope, accepted, later) {
                    if (firstReview.compareAndSet(true, false)) {
                        held.countDown()
                        check(release.await(30, SECONDS))
                    }
                    true
                }
            }
            try {
                assertTrue(held.await(10, SECONDS))
                assertEquals(accepted, graph.phoneAudio.observed(graph.phoneAudio.reference(accepted)))
                dialogAction("Add to Library").performScrollTo().assertIsDisplayed().performClick()
                disclosure(first)
                assertTrue(graph.originalImports.entries(scope).isEmpty())
                assertTrue(importExchanges().isEmpty())
            } finally { release.countDown() }
            competing.await()
        }
        assertEquals(accepted.owner, updated.owner)
        val laterRevision = requireNotNull(updated.displayOverride?.revision)
        assertTrue(laterRevision > firstRevision)
        disclosure(first)
        dialogText("Title: ${later.title}").assertDoesNotExist()
        assertTrue(importExchanges().isEmpty())
        dialogAction("Upload & add").assertIsDisplayed().performClick()
        waitText(unknown, 110_000)

        val row = graph.originalImports.entries(scope).single()
        assertEquals(OriginalImportPhase.Unconfirmed, row.phase)
        assertEquals(first, row.intent.display)
        assertEquals(firstRevision, row.intent.overrideRevision)
        assertEquals(revision, row.intent.original.revision)
        assertTrue(graph.originalImports.associations(scope).isEmpty())
        assertEquals(listOf(FirstJoinedImportApplication.Exchange("POST", uploadPath, row.intent.operation.toString(), null)), importExchanges())
        dialogAction("Add to Library").assertDoesNotExist()
        dialogAction("Upload & add").assertDoesNotExist()
        sameIdleTransport(startingPlayback)
        noLookupOrFetch()
        assertEquals(revision.sha256, digest(resolver.openInputStream(uri)!!.use { it.readBytes() }))
        checkpoint.writeText("${Process.myPid()}\n${row.intent.operation}\n$uri\n$firstRevision\n$laterRevision\n")
    }

    @Test fun mountedRecoveryAfterProcessRestartReadsOnlyOriginalOperation() {
        assertEquals("recover", FirstJoinedImportApplication.phase)
        val (pid, op, media, firstRevision, laterRevision) = checkpoint.readLines().also { assertEquals(5, it.size) }
        assertNotEquals(pid.toInt(), Process.myPid())
        assertTrue(firstRevision.toLong() > 0 && laterRevision.toLong() > firstRevision.toLong())
        val operation = UUID.fromString(op)
        val scope = awaitReady() // Ordinary encrypted session restore; do not sign in as another account.
        assertTrue(graph.originalImports.writeReady(scope)) // The client has not hidden writes by configuration.
        val startingPlayback = idleTransport()
        val pending = graph.originalImports.entries(scope).single()
        assertEquals(operation, pending.intent.operation)
        assertEquals(first, pending.intent.display)
        assertEquals(firstRevision.toLong(), pending.intent.overrideRevision)
        assertEquals(OriginalImportPhase.Unconfirmed, pending.phase)
        val phone = graph.phoneAudio.awaitIndexed(Uri.parse(media)) { it.revision == revision }
        assertEquals(pending.intent.original, phone.owner)
        assertEquals(later.title, phone.displayTitle)
        assertEquals(laterRevision.toLong(), phone.displayOverride?.revision)
        assertTrue(importExchanges().isEmpty())

        // The owned edge supplies one empty status result, then allows the live Go readback.
        waitText("Check status")
        compose.onNode(hasText("Check status") and hasClickAction()).assertIsDisplayed().performClick()
        waitText(unknown)
        assertEquals(listOf(FirstJoinedImportApplication.Exchange("GET", "$uploadPath/$operation", null, 404)), importExchanges())
        assertEquals(pending, graph.originalImports.entries(scope).single())
        assertTrue(graph.originalImports.associations(scope).isEmpty())
        compose.onNodeWithText("Upload & add").assertDoesNotExist()
        compose.onNode(hasText("Check status") and hasClickAction()).assertIsDisplayed().performClick()

        compose.waitUntil(35_000) { graph.originalImports.associations(scope).size == 1 }
        val binding = graph.originalImports.associations(scope).single()
        assertEquals(pending.intent, binding.intent)
        assertEquals(first, binding.membership.display)
        assertEquals(revision, binding.membership.original.revision)
        assertEquals(listOf(404, 200), importExchanges().map { event ->
            assertEquals("GET", event.method); assertEquals("$uploadPath/$operation", event.path); event.status
        })
        val member = app.observed.filter { it.path == "/api/v1/library/tracks/${binding.track.value}" }
        assertEquals(listOf(FirstJoinedImportApplication.Exchange("GET", "/api/v1/library/tracks/${binding.track.value}", null, 200)), member)
        compose.waitUntil(30_000) { graph.library.state.value.rows.count { it.id == binding.track } == 1 }
        val more = "More for ${first.title}"
        compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasContentDescription(more))
        compose.onNodeWithContentDescription(more).assertIsDisplayed()
        compose.onNodeWithText("In Library · Original on phone").assertIsDisplayed()
        compose.onNodeWithContentDescription("More for ${later.title}").assertDoesNotExist()
        sameIdleTransport(startingPlayback)
        noLookupOrFetch()
        assertTrue(importExchanges().all { it.method == "GET" })
        assertEquals(revision.sha256, digest(resolver.openInputStream(Uri.parse(media))!!.use { it.readBytes() }))
        // External owner retains fixtures and runs teardown exactly once after terminal evidence.
    }

    private fun disclosure(expected: ImportDisplay) {
        dialogText("Add to Library?").assertIsDisplayed()
        for (line in listOf("Server: ${app.settings.origin}", "Account: ${app.settings.account}",
            "Title: ${expected.title}", "Artist: ${expected.artist}", "Album: ${expected.album}",
            "Artwork you applied in SoundQ is not included in this upload. Artwork embedded in the original file stays in the file.")) {
            dialogText(line).performScrollTo().assertIsDisplayed()
        }
    }

    private fun dialogAction(label: String) = compose.onNode(hasText(label) and hasClickAction() and hasAnyAncestor(isDialog()))
    private fun dialogText(label: String) = compose.onNode(hasText(label) and hasAnyAncestor(isDialog()))
    private fun waitText(label: String, limitMs: Long = 20_000) = compose.waitUntil(limitMs) {
        compose.onAllNodesWithText(label).fetchSemanticsNodes().isNotEmpty()
    }

    private fun awaitReady(): AccountScope {
        compose.waitUntil(30_000) { graph.session.state.value is AuthState.SignedIn && graph.originalImports.state.value.ready &&
            graph.phoneAudio.state.value.ready && graph.controller.state.value.connection == PlaybackProjection.Connection.Connected }
        return requireNotNull(graph.session.capture()).also { scope ->
            assertEquals(app.settings.account, scope.accountId)
            assertTrue(graph.session.remoteCurrent(scope))
        }
    }

    private fun insertOriginal(bytes: ByteArray): Uri {
        val uri = requireNotNull(resolver.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, "joined-fixture-original.mp3")
            put(MediaStore.MediaColumns.MIME_TYPE, "audio/mpeg")
            put(MediaStore.MediaColumns.RELATIVE_PATH, "Music/SoundQ Import Join")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }))
        requireNotNull(resolver.openOutputStream(uri, "w")).use { it.write(bytes) }
        assertEquals(1, resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null))
        return uri
    }

    private suspend fun apply(scope: AccountScope, row: DeviceAudio, text: ImportDisplay,
        reviewCurrent: () -> Boolean = { true }): DeviceAudio {
        val visit = LocalEnrichmentVisit(scope, row)
        try {
            val source = requireNotNull(graph.phoneAudio.captureEnrichment(scope, row, visit.gate))
            assertSame(MetadataApplyResult.Applied, graph.phoneAudio.applyEnrichment(source,
                LocalDisplayText(text.title, text.artist, text.album), reviewCurrent = reviewCurrent))
        } finally { visit.close() }
        return requireNotNull(graph.phoneAudio.observed(graph.phoneAudio.reference(row))).also {
            assertNotNull(it.displayOverride)
            assertEquals(text, ImportDisplay(it.displayTitle, it.displayArtist.orEmpty(), it.displayAlbum.orEmpty()))
        }
    }

    private fun idleTransport(): PlaybackProjection = graph.controller.state.value.also {
        assertTrue(it.queue.isEmpty()); assertNull(it.selectedOccurrence); assertFalse(it.isPlaying); assertFalse(it.preparing)
    }

    private fun sameIdleTransport(before: PlaybackProjection) {
        val after = idleTransport()
        assertEquals(before.queueRevision, after.queueRevision)
        assertEquals(before.selectionIncarnation, after.selectionIncarnation)
        assertEquals(before.source, after.source)
    }

    private fun importExchanges() = app.observed.filter { it.path == uploadPath || it.path.startsWith("$uploadPath/") }
    private fun noLookupOrFetch() {
        assertTrue(app.observed.none { e -> e.method == "BLOCKED" || e.path.startsWith("/api/v1/musicbrainz/") || e.path == "/api/v1/playback/urls" ||
            e.path.contains("/stream") || e.path.contains("/download") && !e.path.contains("/download-jobs") || e.path.contains("/stems") })
    }

    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}
