package com.soundq.android.data.originalimport

import android.app.Application
import android.Manifest
import android.os.Bundle
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.product.LocalEnrichmentVisit
import com.soundq.android.product.captureOriginalImportDisplay
import com.soundq.android.data.trackdetails.DetailsAction
import com.soundq.android.playback.*
import com.soundq.android.playback.nativeengine.NativeCallbackDeck
import com.soundq.android.playback.nativeengine.NativeCallbackSnapshot
import com.soundq.android.playback.nativeengine.NativeListeningJournal
import com.soundq.android.playback.nativeengine.OriginalAwareNativeSource
import com.soundq.android.playback.nativeengine.NativePlaybackSource
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.OkHttpClient
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File
import java.net.InetAddress
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit.SECONDS
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Real graph, authenticated TLS/wire, journal and decoder admission. Only the HTTP producer is substituted. */
@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28], application = Application::class)
class OriginalImportCompositionTest {
    @Test fun coldDetailsReloadRetractsOnlyDurablePreparedFence() = preparedFenceRecovery(reopen = true)

    @Test fun replacementAccountEpochRetractsOnlyItsDurablePreparedFence() = preparedFenceRecovery(reopen = false)

    private fun preparedFenceRecovery(reopen: Boolean) = Fixture().use { f ->
        val peerAccount = "2dc91581-2795-4d0a-b87d-25dbc35c8fc0"
        val peer = f.intent.copy(destination = f.intent.destination.copy(account = peerAccount), operation = UUID.randomUUID())
        f.seed(peer)
        val disk = f.directory.resolve("original-import.v1.json")
        val journal = OriginalImportJournal(disk)
        val peerFence = UUID.randomUUID()
        assertTrue(journal.prepareRemoval(peer.destination, f.track, peerFence) { true })
        // Re-encode exactly the v2 representation: the absence of a prepared marker is never proof.
        val v2 = Json.parseToJsonElement(disk.readText()).jsonObject.let {
            JsonObject(mapOf("version" to JsonPrimitive(2), "rows" to it.getValue("rows")))
        }
        disk.writeText(v2.toString())
        val before = disk.readBytes()
        val neighbor = v2.getValue("rows").jsonArray.last().jsonObject
        val dir = f.directory.toPath()
        val writable = Files.getPosixFilePermissions(dir)
        val readOnly = PosixFilePermissions.fromString("r-x------")
        val deleteCall = java.util.concurrent.atomic.AtomicReference<Call>()
        val headers = AtomicInteger()
        val deletes = AtomicInteger()
        val listener = object : EventListener() {
            override fun callStart(call: Call) { if (call.request().method == "DELETE") deleteCall.set(call) }
            override fun requestHeadersStart(call: Call) { if (call.request().method == "DELETE") headers.incrementAndGet() }
        }
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest) = when (request.method to request.url.encodedPath) {
                "GET" to "/api/v1/library" -> f.libraryPage(true, request)
                "GET" to "/api/v1/tracks/77/analysis" -> f.reply(404, "{}")
                "DELETE" to f.memberPath -> { deletes.incrementAndGet(); MockResponse.Builder().code(204).build() }
                else -> f.reply(500, "{}")
            }
        }
        fun recover(g: AppGraph) {
            f.signIn(g, peerAccount)
            val legacy = f.openDetails(g)
            val details = g.trackDetails
            assertEquals("Unconfirmed", details.state.value.removalIssue?.name)
            assertTrue(details.state.value.removalBlocked)
            assertNull(details.claim(legacy, details.state.value.detail!!, DetailsAction.Remove))
            val scope = f.signIn(g)
            val route = f.openDetails(g) // Read-only directory: this attempt cannot retract even a prepared record.
            assertTrue(details.state.value.removalBlocked)
            assertEquals(OriginalImportPhase.RemovalPending, g.originalImports.entries(scope).single().phase)
            Files.setPosixFilePermissions(dir, writable)
            details.load(route)
            assertEquals("GET", f.next("/api/v1/library").method)
            assertEquals("GET", f.next("/api/v1/tracks/77/analysis").method)
            assertFalse("the exact prepared-only operation must recover on Reload", details.state.value.removalBlocked)
            assertNull(details.state.value.removalIssue)
            assertNotNull(details.claim(route, details.state.value.detail!!, DetailsAction.Remove))
            assertArrayEquals(before, disk.readBytes())
            assertEquals(neighbor, Json.parseToJsonElement(disk.readText()).jsonObject.getValue("rows").jsonArray.last())
            assertEquals(0, headers.get()); assertEquals(0, deletes.get())
            assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
        }
        try {
            f.graph(null, listener = listener).use { g ->
                val scope = f.signIn(g)
                var canceled = false
                val error = assertThrows(SafeFailure::class.java) {
                    g.api.trackDetailsRemove(scope, f.track) {
                        val stored = g.originalImports.state.value.entry(f.intent.operation)
                        if (!canceled && stored?.phase == OriginalImportPhase.RemovalPending) {
                            val reopened = OriginalImportJournal(disk).apply { load() }.state.value
                            assertEquals(stored, reopened.entry(f.intent.operation))
                            assertEquals(peerFence, reopened.entry(peer.operation)?.removal)
                            Files.setPosixFilePermissions(dir, readOnly)
                            checkNotNull(deleteCall.get()).cancel()
                            canceled = true
                        }
                        true
                    }
                }
                assertTrue(canceled)
                assertEquals(SafeFailure.Reason.RemovalNotSentLocalCleanupFailed, error.reason)
                assertEquals(0, headers.get()); assertEquals(0, deletes.get())
                if (!reopen) recover(g)
            }
            if (reopen) f.graph(null, listener = listener).use(::recover)
        } finally { Files.setPosixFilePermissions(dir, writable) }
    }

    @Test fun cancellationAfterVerifiedEntryBoundaryStillLeavesAColdUnknownFence() = Fixture().use { f ->
        val disk = f.directory.resolve("original-import.v1.json")
        val dir = f.directory.toPath()
        val writable = Files.getPosixFilePermissions(dir)
        val deleteCall = java.util.concurrent.atomic.AtomicReference<Call>()
        val headers = AtomicInteger()
        val listener = object : EventListener() {
            override fun callStart(call: Call) { if (call.request().method == "DELETE") deleteCall.set(call) }
            override fun requestHeadersStart(call: Call) { if (call.request().method == "DELETE") headers.incrementAndGet() }
        }
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest) = when (request.method to request.url.encodedPath) {
                "GET" to "/api/v1/library" -> f.libraryPage(true, request)
                "GET" to "/api/v1/tracks/77/analysis" -> f.reply(404, "{}")
                else -> f.reply(500, "{}")
            }
        }
        try {
            f.graph(null, listener = listener).use { g ->
                val scope = f.signIn(g)
                var sawPrepared = false
                var canceledAfterEntry = false
                assertEquals(SafeFailure.Reason.RemovalNotSentLocalCleanupFailed, assertThrows(SafeFailure::class.java) {
                    g.api.trackDetailsRemove(scope, f.track) {
                        if (g.originalImports.entries(scope).singleOrNull()?.phase == OriginalImportPhase.RemovalPending) {
                            val raw = Json.parseToJsonElement(disk.readText()).jsonObject
                            if (raw["prepared"] != null) sawPrepared = true
                            else if (sawPrepared && !canceledAfterEntry) {
                                assertEquals(2, raw.getValue("version").jsonPrimitive.int)
                                Files.setPosixFilePermissions(dir, PosixFilePermissions.fromString("r-x------"))
                                checkNotNull(deleteCall.get()).cancel()
                                canceledAfterEntry = true
                            }
                        }
                        true
                    }
                }.reason)
                assertTrue(canceledAfterEntry)
                assertEquals(0, headers.get()); assertEquals(0, f.server.requestCount)
            }
            Files.setPosixFilePermissions(dir, writable)
            val enteredBytes = disk.readBytes()
            f.graph(null).use { cold ->
                f.signIn(cold)
                val route = f.openDetails(cold)
                assertEquals("Unconfirmed", cold.trackDetails.state.value.removalIssue?.name)
                assertNull(cold.trackDetails.claim(route, cold.trackDetails.state.value.detail!!, DetailsAction.Remove))
                assertArrayEquals(enteredBytes, disk.readBytes())
                assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
            }
        } finally { Files.setPosixFilePermissions(dir, writable) }
    }

    @Test fun transientJournalReadFailureRecoversExactBytesButFutureVersionStaysRejected() = Fixture().use { f ->
        val disk = File(f.directory, "original-import.v1.json")
        val before = disk.readBytes()
        val permissions = Files.getPosixFilePermissions(disk.toPath())
        val journal = OriginalImportJournal(disk)
        try {
            Files.setPosixFilePermissions(disk.toPath(), PosixFilePermissions.fromString("---------"))
            journal.load()
            assertFalse(journal.state.value.ready)
        } finally { Files.setPosixFilePermissions(disk.toPath(), permissions) }
        journal.load()
        assertEquals(f.intent, journal.state.value.rows.single().intent)
        assertArrayEquals(before, disk.readBytes())
        for (rejected in listOf(before.decodeToString().replace("\"version\":1", "\"version\":99").encodeToByteArray(), byteArrayOf(0))) {
            assertFalse(before.contentEquals(rejected))
            disk.writeBytes(rejected)
            val invalid = OriginalImportJournal(disk).apply { load() }
            assertTrue(invalid.state.value.rejected)
            assertArrayEquals(rejected, disk.readBytes())
            disk.writeBytes(before)
            invalid.load()
            assertTrue(invalid.state.value.rejected)
            assertTrue(invalid.state.value.rows.isEmpty())
        }
    }

    @Test fun accepted204RetriesOnlyLocalSettlementOnDetailsReload() = Fixture().use { f ->
        val journal = File(f.directory, "original-import.v1.json")
        val dir = f.directory.toPath()
        val writable = Files.getPosixFilePermissions(dir)
        val member = AtomicBoolean(true)
        val deletes = AtomicInteger()
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.method to request.url.encodedPath) {
                "GET" to "/api/v1/library" -> f.libraryPage(member.get(), request)
                "GET" to "/api/v1/tracks/77/analysis" -> f.reply(404, "{}")
                "DELETE" to f.memberPath -> {
                    check(deletes.incrementAndGet() == 1 && member.compareAndSet(true, false))
                    Files.setPosixFilePermissions(dir, PosixFilePermissions.fromString("r-x------"))
                    MockResponse.Builder().code(204).build()
                }
                else -> f.reply(500, "{}")
            }
        }
        try {
            f.graph(null).use { g ->
                val scope = f.signIn(g)
                val route = f.openDetails(g)
                val details = g.trackDetails
                details.execute(checkNotNull(details.claim(route, details.state.value.detail!!, DetailsAction.Remove)))
                assertEquals("DELETE", f.next(f.memberPath).method)
                assertEquals("GET", f.next("/api/v1/library").method)
                assertEquals("GET", f.next("/api/v1/library").method)
                assertEquals("ConfirmedLocalSettleFailed", details.state.value.removalIssue?.name)
                val pending = OriginalImportJournal(journal).apply { load() }.state.value.rows.single()
                assertEquals(OriginalImportPhase.RemovalPending, pending.phase)
                Files.setPosixFilePermissions(dir, writable)
                details.load(route)
                assertEquals("GET", f.next("/api/v1/library").method)
                val removed = OriginalImportJournal(journal).apply { load() }.state.value.rows.single()
                assertEquals(OriginalImportPhase.Removed, removed.phase)
                assertEquals(pending.removal, removed.removal)
                assertTrue(details.state.value.missing)
                assertFalse(details.state.value.removalBlocked)
                assertNull(details.state.value.removalIssue)
                assertEquals(removed, g.originalImports.entries(scope).single())
                assertEquals(1, deletes.get())
                assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
            }
        } finally { Files.setPosixFilePermissions(dir, writable) }
    }

    @Test fun callDeadlineDuringVerifiedPrepareReportsNotSentWithoutMutationHeaders() = Fixture().use { f ->
        val disk = File(f.directory, "original-import.v1.json")
        val before = disk.readBytes()
        val canceled = CountDownLatch(1)
        val headers = AtomicInteger()
        val listener = object : EventListener() {
            override fun canceled(call: Call) { if (call.request().method == "DELETE") canceled.countDown() }
            override fun requestHeadersStart(call: Call) { if (call.request().method == "DELETE") headers.incrementAndGet() }
        }
        f.graph(null, listener = listener).use { g ->
            val scope = f.signIn(g)
            g.originalImports.load()
            var witnessed = false
            val error = assertThrows(SafeFailure::class.java) {
                g.api.trackDetailsRemove(scope, f.track) {
                    if (!witnessed && g.originalImports.entries(scope).single().phase == OriginalImportPhase.RemovalPending) {
                        assertEquals(OriginalImportPhase.RemovalPending,
                            OriginalImportJournal(disk).apply { load() }.state.value.rows.single().phase)
                        witnessed = true
                        assertTrue(canceled.await(25, SECONDS))
                    }
                    true
                }
            }
            assertTrue(witnessed)
            assertEquals(0, headers.get())
            assertEquals(0, f.server.requestCount)
            assertArrayEquals(before, disk.readBytes())
            assertEquals(SafeFailure.Reason.RemovalNotSent, error.reason)
        }
    }

    @Test fun acknowledgedDeleteWithFailedLocalSettleCannotReviveEitherBorrowingPathAfterRestart() =
        failedDeleteSurvivesRestart(confirmed = true)

    @Test fun enteredDeleteWithLostResponseCannotReviveEitherBorrowingPathAfterRestart() =
        failedDeleteSurvivesRestart(confirmed = false)

    @Test fun clickCapturesPublishedRevisionWhileRealApplyIsHeldBeforeAtomicReplace() = runBlocking {
        Fixture(seedReceipt = false).use { f ->
            shadowOf(RuntimeEnvironment.getApplication()).grantPermissions(Manifest.permission.READ_EXTERNAL_STORAGE)
            val beforeReplace = java.util.concurrent.atomic.AtomicReference<(() -> Unit)?>(null)
            f.graph("fixture", openPhoneAudioStore = { file -> DeviceListeningStore(file) { phase ->
                if (phase == "beforeReplace") beforeReplace.get()?.invoke()
            } }).use { graph ->
                val scope = f.signIn(graph)
                val selected = f.phoneSource(graph)
                graph.originalImports.load()
                val phone = graph.phoneAudio
                val original = checkNotNull(phone.state.value.snapshot?.resolve(selected))
                val ref = phone.reference(original)
                val first = LocalDisplayText("Acknowledged title", "Acknowledged artist", "Acknowledged album")
                val later = LocalDisplayText("Later title", "Later artist", "Later album")
                val firstVisit = LocalEnrichmentVisit(scope, original)
                try {
                    val capture = checkNotNull(phone.captureEnrichment(scope, original, firstVisit.gate))
                    assertSame(MetadataApplyResult.Applied, phone.applyEnrichment(capture, first) { true })
                } finally { firstVisit.close() }
                val acknowledged = checkNotNull(phone.observed(ref))
                val visit = LocalEnrichmentVisit(scope, acknowledged)
                val applySource = checkNotNull(phone.captureEnrichment(scope, acknowledged, visit.gate))
                val stage = CountDownLatch(1)
                val release = CountDownLatch(1)
                val disk = File(graph.directory, "phone-listening.v1.json")
                val prior = disk.readBytes()
                val firstRevision = checkNotNull(acknowledged.displayOverride?.revision)
                assertTrue(firstRevision > 0)
                assertEquals(firstRevision, decodeDomain(prior).files.single { it.owner == selected }.displayOverride?.revision)
                beforeReplace.set { stage.countDown(); check(release.await(10, SECONDS)) }
                val apply = async(Dispatchers.IO) { phone.applyEnrichment(applySource, later) { true } }
                val choice = try {
                    assertTrue(stage.await(10, SECONDS))
                    assertArrayEquals(prior, disk.readBytes())
                    val row = phone.observed(ref)
                    assertEquals(acknowledged, row)
                    assertNull(captureOriginalImportDisplay(selected.copy(incarnation = selected.incarnation + 1), row))
                    val capture = checkNotNull(captureOriginalImportDisplay(selected, row))
                    assertEquals(firstRevision, capture.overrideRevision)
                    assertEquals(ImportDisplay("Acknowledged title", "Acknowledged artist", "Acknowledged album"), capture.text)
                    checkNotNull(graph.originalImports.choose(scope, capture.source, capture.text, capture.overrideRevision) { true })
                } finally { release.countDown() }
                try {
                    assertSame(MetadataApplyResult.Applied, apply.await())
                    val published = checkNotNull(phone.observed(ref)?.displayOverride)
                    assertTrue(published.revision > firstRevision)
                    assertEquals(later, published.text)
                    assertEquals(published, decodeDomain(disk.readBytes()).files.single { it.owner == selected }.displayOverride)
                    assertEquals(firstRevision, choice.intent.overrideRevision)
                    assertEquals(selected, choice.intent.original)
                    assertEquals(ImportDisplay("Acknowledged title", "Acknowledged artist", "Acknowledged album"), choice.intent.display)
                    assertTrue(graph.originalImports.entries(scope).isEmpty())
                    assertEquals(0, f.server.requestCount)
                } finally { beforeReplace.set(null); visit.close() }
            }
        }
    }

    private fun failedDeleteSurvivesRestart(confirmed: Boolean) = Fixture(seedReceipt = false).use { f ->
        val app = shadowOf(RuntimeEnvironment.getApplication())
        val permission = Manifest.permission.READ_EXTERNAL_STORAGE
        app.grantPermissions(permission)
        val member = AtomicBoolean(true)
        val deletes = AtomicInteger()
        val readMode = AtomicInteger()
        val heldBytes = java.util.concurrent.atomic.AtomicReference<ByteArray>()
        val path = f.directory.toPath()
        val writable = Files.getPosixFilePermissions(path)
        val readOnly = PosixFilePermissions.fromString("r-x------")
        val journal = File(f.directory, "original-import.v1.json")
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.method to request.url.encodedPath) {
                "GET" to "/api/v1/library" -> f.libraryPage(member.get() && request.url.queryParameter("liked") != "true", request)
                "GET" to "/api/v1/tracks/77/analysis" -> f.reply(404, "{}")
                "GET" to f.memberPath -> when (readMode.get()) {
                    1 -> f.reply(503, "{}")
                    2 -> f.reply(404, "{}") // no authenticated exact absence code
                    else -> if (member.get()) f.member() else f.reply(404, """{"code":"NOT_FOUND"}""")
                }
                "DELETE" to f.memberPath -> {
                    check(deletes.incrementAndGet() == 1 && member.compareAndSet(true, false))
                    heldBytes.set(journal.readBytes())
                    if (confirmed) {
                        Files.setPosixFilePermissions(path, readOnly)
                        MockResponse.Builder().code(204).build()
                    } else MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build()
                }
                else -> f.reply(500, "{}")
            }
        }
        try {
            val receipt = f.graph("fixture").use { g ->
                val scope = f.signIn(g)
                val intent = f.intent.copy(original = f.phoneSource(g))
                f.seed(intent)
                assertEquals(intent, g.originalImports.admitOnlinePlayback(scope, f.track).single().intent)
                assertEquals("GET", f.next(f.memberPath).method)
                assertEquals(intent, g.originalImports.admitExplicitOriginal(scope, f.track, intent.operation.toString()).single().intent)
                g.originalImports.entries(scope).single()
            }
            val before = journal.readBytes()
            val outcome = f.graph(null).use { g ->
                f.signIn(g)
                assertFalse(g.originalImports.enabled)
                val route = f.openDetails(g)
                val command = checkNotNull(g.trackDetails.claim(route, checkNotNull(g.trackDetails.state.value.detail), DetailsAction.Remove))
                g.trackDetails.execute(command)
                assertEquals("DELETE", f.next(f.memberPath).method)
                if (confirmed) {
                    assertEquals("GET", f.next("/api/v1/library").method) // exact owning Details snapshot
                    assertEquals("GET", f.next("/api/v1/library").method) // existing Library refresh
                    assertTrue(g.trackDetails.state.value.missing)
                    assertEquals(readOnly, Files.getPosixFilePermissions(path))
                }
                assertEquals(if (confirmed) "ConfirmedLocalSettleFailed" else "Unconfirmed", g.trackDetails.state.value.removalIssue?.name)
                assertTrue(g.trackDetails.state.value.removalBlocked)
                g.trackDetails.execute(command) // a consumed action never sends again
                assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
                g.trackDetails.state.value.outcome
            }
            assertArrayEquals(heldBytes.get(), journal.readBytes()) // the TLS handler's pre-response bytes survived settle failure/loss
            Files.setPosixFilePermissions(path, writable)
            assertFalse(member.get())
            member.set(true) // byte-identical producer membership, not a second client POST
            f.graph("fixture").use { g ->
                val scope = f.signIn(g)
                assertEquals(receipt.intent.original, f.phoneSource(g))
                val present = g.api.originalImportTransport(false).membership(scope, f.track) as OriginalMembershipResult.Present
                assertEquals(receipt.membership, present.row)
                assertEquals("GET", f.next(f.memberPath).method)
                g.originalImports.reconcileRestored(scope)
                val online = g.originalImports.admitOnlinePlayback(scope, f.track)
                val explicit = g.originalImports.admitExplicitOriginal(scope, f.track, receipt.intent.operation.toString())
                assertTrue("same-ID exact re-add revived old phone-original aliases: online=${online.size}, explicit=${explicit.size}",
                    online.isEmpty() && explicit.isEmpty())
                assertFalse("the DELETE must already own different journal bytes before the response", before.contentEquals(heldBytes.get()))
                val retained = g.originalImports.entries(scope).single()
                assertEquals(receipt.intent, retained.intent)
                assertEquals(receipt.commit, retained.commit)
                assertEquals(receipt.membership, retained.membership)
                assertEquals("RemovalPending", retained.phase.name)
                val raw = Json.parseToJsonElement(heldBytes.get().decodeToString()).jsonObject
                assertEquals(2, raw.getValue("version").jsonPrimitive.int)
                val operation = raw.getValue("rows").jsonArray.single().jsonObject.getValue("removal").jsonPrimitive.content
                assertEquals(operation, UUID.fromString(operation).toString())
                assertEquals(if (confirmed) MutationOutcome.ReadbackFailed else MutationOutcome.Uncertain, outcome)
                assertEquals(if (confirmed) 8 else 6, f.server.requestCount)
                assertTrue(g.api.library(scope, LibraryQuery(liked = true), 0).tracks.isEmpty())
                assertEquals("true", f.next("/api/v1/library").url.queryParameter("liked"))
                for (mode in listOf(1, 2)) {
                    readMode.set(mode)
                    assertEquals(OriginalMembershipResult.Unconfirmed, g.api.originalImportTransport(false).membership(scope, f.track))
                    assertEquals("GET", f.next(f.memberPath).method)
                    assertTrue(g.originalImports.admitOnlinePlayback(scope, f.track).isEmpty())
                    assertTrue(g.originalImports.admitExplicitOriginal(scope, f.track, receipt.intent.operation.toString()).isEmpty())
                    assertArrayEquals(heldBytes.get(), journal.readBytes())
                }
                assertEquals("RemovalUnconfirmed", g.originalImports.check(scope, receipt.intent.operation) { true }.name)
                assertEquals("RemovalUnconfirmed", g.originalImports.confirm(checkNotNull(g.originalImports.choose(scope,
                    receipt.intent.original, receipt.intent.display) { true })).name)

                // An independent UI reopen and a direct retained API call still cannot send the DELETE.
                val route = f.openDetails(g)
                assertNull(g.trackDetails.claim(route, checkNotNull(g.trackDetails.state.value.detail), DetailsAction.Remove))
                assertEquals("RemovalUnconfirmed", assertThrows(SafeFailure::class.java) {
                    g.api.trackDetailsRemove(scope, f.track) { true }
                }.reason.name)
                assertEquals(1, deletes.get())
                assertEquals(if (confirmed) 14 else 12, f.server.requestCount)
                assertArrayEquals(heldBytes.get(), journal.readBytes())
                assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
                println("response=${if (confirmed) "204+local write refusal" else "lost"}; total=${f.server.requestCount}; DELETE=1 POST=0; online=0 explicit=0; fenced bytes unchanged")
            }
        } finally {
            Files.setPosixFilePermissions(path, writable)
            app.denyPermissions(permission)
        }
    }

    @Test fun storageRefusalAtDispatchSendsNothingForLinkedTrackButOrdinaryRemovalStillWorks() = Fixture().use { f ->
        val journal = File(f.directory, "original-import.v1.json")
        val before = journal.readBytes()
        val path = f.directory.toPath()
        val writable = Files.getPosixFilePermissions(path)
        val deletes = AtomicInteger()
        val ordinaryPath = "/api/v1/library/tracks/78"
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.method to request.url.encodedPath) {
                "GET" to "/api/v1/library" -> f.libraryPage(true, request)
                "GET" to "/api/v1/tracks/77/analysis" -> f.reply(404, "{}")
                "DELETE" to f.memberPath, "DELETE" to ordinaryPath -> {
                    deletes.incrementAndGet(); MockResponse.Builder().code(204).build()
                }
                else -> f.reply(500, "{}")
            }
        }
        f.graph(null).use { g ->
            val scope = f.signIn(g)
            val route = f.openDetails(g)
            val command = checkNotNull(g.trackDetails.claim(route, checkNotNull(g.trackDetails.state.value.detail), DetailsAction.Remove))
            Files.setPosixFilePermissions(path, PosixFilePermissions.fromString("r-x------"))
            try {
                g.trackDetails.execute(command)
                assertEquals("pre-dispatch journal failure must send no DELETE", 0, deletes.get())
                assertEquals(MutationOutcome.Refused, g.trackDetails.state.value.outcome)
                assertArrayEquals(before, journal.readBytes())
                g.api.trackDetailsRemove(scope, TrackId(78)) { true }
                assertEquals("DELETE", f.next(ordinaryPath).method)
                assertEquals(1, deletes.get())
                assertEquals(4, f.server.requestCount)
            } finally { Files.setPosixFilePermissions(path, writable) }
            assertEquals(OriginalImportPhase.Added, g.originalImports.entries(scope).single().phase)
            assertArrayEquals(before, journal.readBytes())
            assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
        }
    }

    @Test fun unreadableAtomicFenceNeverReachesTheOwnedDeleteEndpoint() = unreadableAtomicFence(recover = false)

    @Test fun unreadableAtomicPrepareCanBeRetractedOnlyByItsLiveOwner() = unreadableAtomicFence(recover = true)

    private fun unreadableAtomicFence(recover: Boolean) = Fixture().use { f ->
        val journal = File(f.directory, "original-import.v1.json")
        val before = journal.readBytes()
        val writable = Files.getPosixFilePermissions(journal.toPath())
        val stageWasMadeUnreadable = AtomicBoolean(false)
        f.graph(null).use graph@ { g ->
            val scope = f.signIn(g)
            try {
                assertEquals("RemovalNotSentLocalCleanupFailed", assertThrows(SafeFailure::class.java) {
                    g.api.trackDetailsRemove(scope, f.track) {
                        // The final pre-rename route check runs after the staged bytes were fsynced.
                        // Keep the rename possible but make the renamed file unreadable to the real journal.
                        f.directory.listFiles().orEmpty().singleOrNull { it.name.startsWith(".original-import-") && it.name.endsWith(".pending") }
                            ?.let {
                                Files.setPosixFilePermissions(it.toPath(), emptySet())
                                stageWasMadeUnreadable.set(true)
                            }
                        true
                    }
                }.reason.name)
                assertTrue(stageWasMadeUnreadable.get())
                assertTrue(g.originalImports.state.value.rejected)
                assertEquals(0, f.server.requestCount)
            } finally { Files.setPosixFilePermissions(journal.toPath(), writable) }
            if (recover) {
                assertEquals(LibraryRemovalFenceStatus.NotSentLocalCleanupFailed, g.api.libraryRemovalFenceStatus(scope, f.track))
                assertEquals(OriginalImportPhase.RemovalPending, OriginalImportJournal(journal).apply { load() }.state.value.rows.single().phase)
                assertFalse(g.api.retryUnenteredLibraryRemoval(scope, f.track) { false })
                assertTrue(g.originalImports.state.value.rejected)
                assertTrue(g.api.retryUnenteredLibraryRemoval(scope, f.track) { true })
                assertArrayEquals(before, journal.readBytes())
                assertEquals(OriginalImportPhase.Added, g.originalImports.entries(scope).single().phase)
                assertEquals(0, f.server.requestCount)
                return@graph
            }
            // A same-account re-entry does not inherit the old scope's retry authority.
            val newScope = f.signIn(g)
            assertFalse(g.api.retryUnenteredLibraryRemoval(scope, f.track) { true })
            assertFalse(g.api.retryUnenteredLibraryRemoval(newScope, f.track) { true })
        }
        if (recover) return@use
        assertFalse(before.contentEquals(journal.readBytes()))
        f.graph("fixture").use { g ->
            val scope = f.signIn(g)
            g.originalImports.reconcileRestored(scope)
            assertEquals("RemovalPending", g.originalImports.entries(scope).single().phase.name)
            assertTrue(g.originalImports.associations(scope).isEmpty())
        }
        assertEquals(0, f.server.requestCount)
    }

    @Test fun ambiguousRetractionRequiresExactDiskVerificationBeforePublishing() = Fixture().use { f ->
        val file = File(f.directory, "original-import.v1.json")
        val before = file.readBytes()
        val journal = OriginalImportJournal(file)
        val owner = f.intent.destination
        val operation = UUID.randomUUID()
        assertTrue(journal.prepareRemoval(owner, f.track, operation) { true })
        val permissions = Files.getPosixFilePermissions(file.toPath())
        var injected = false
        try {
            assertThrows(java.io.IOException::class.java) {
                journal.finishRemoval(owner, f.track, operation, acknowledged = false) {
                    f.directory.listFiles().orEmpty().singleOrNull { it.name.endsWith(".pending") }?.let {
                        Files.setPosixFilePermissions(it.toPath(), emptySet())
                        injected = true
                    }
                    true
                }
            }
            assertTrue(injected)
            assertTrue(journal.state.value.rejected)
            assertTrue(journal.state.value.rows.isEmpty())
        } finally { Files.setPosixFilePermissions(file.toPath(), permissions) }
        assertArrayEquals(before, file.readBytes()) // Atomic replacement landed; its readback did not.
        val wrong = before + byteArrayOf(0x20) // Parseable but not the owned replacement.
        file.writeBytes(wrong)
        assertThrows(IllegalStateException::class.java) {
            journal.finishRemoval(owner, f.track, operation, acknowledged = false) { true }
        }
        assertArrayEquals(wrong, file.readBytes())
        assertTrue(journal.state.value.rejected)
        file.writeBytes(before)
        journal.finishRemoval(owner, f.track, operation, acknowledged = false) { true }
        assertArrayEquals(before, file.readBytes())
        assertEquals(OriginalImportPhase.Added, journal.state.value.rows.single().phase)
    }

    @Test fun staleRouteAfterVerifiedFenceButBeforeWireRetractsOnlyItsUnenteredAdmission() = Fixture().use { f ->
        val journal = File(f.directory, "original-import.v1.json")
        val before = journal.readBytes()
        val sawWrittenFence = AtomicBoolean(false)
        f.graph(null).use { g ->
            val scope = f.signIn(g)
            assertEquals(SafeFailure.Reason.Retired, assertThrows(SafeFailure::class.java) {
                g.api.trackDetailsRemove(scope, f.track) {
                    journal.readBytes().contentEquals(before).also { if (!it) sawWrittenFence.set(true) }
                }
            }.reason)
            assertTrue("the route must retire only after the complete fence is visible", sawWrittenFence.get())
            assertEquals(0, f.server.requestCount)
            assertArrayEquals(before, journal.readBytes())
            assertEquals(OriginalImportPhase.Added, g.originalImports.entries(scope).single().phase)
        }
    }

    @Test fun realCallCancellationAfterVerifiedFenceRetractsOnlyItsUnenteredRemoval() = Fixture(seedReceipt = false).use { f ->
        val app = shadowOf(RuntimeEnvironment.getApplication())
        val permission = Manifest.permission.READ_EXTERNAL_STORAGE
        app.grantPermissions(permission)
        val journal = File(f.directory, "original-import.v1.json")
        val member = AtomicBoolean(true)
        val deletes = AtomicInteger()
        val posts = AtomicInteger()
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.method == "POST") posts.incrementAndGet()
                return when (request.method to request.url.encodedPath) {
                    "GET" to f.memberPath -> if (member.get()) f.member() else f.reply(404, """{"code":"NOT_FOUND"}""")
                    "GET" to "/api/v1/library" -> f.libraryPage(member.get(), request)
                    "GET" to "/api/v1/tracks/77/analysis" -> f.reply(404, "{}")
                    "DELETE" to f.memberPath -> {
                        deletes.incrementAndGet()
                        check(member.compareAndSet(true, false))
                        MockResponse.Builder().code(204).build()
                    }
                    else -> f.reply(500, "{}")
                }
            }
        }
        fun persisted() = OriginalImportJournal(journal).apply { load() }.state.value.also { assertTrue(it.ready) }
        try {
            val original = f.graph("fixture").use { g ->
                val scope = f.signIn(g)
                val intent = f.intent.copy(original = f.phoneSource(g))
                f.seed(intent)
                assertEquals(intent, g.originalImports.admitOnlinePlayback(scope, f.track).single().intent)
                assertEquals("GET", f.next(f.memberPath).method)
                assertEquals(intent, g.originalImports.admitExplicitOriginal(scope, f.track, intent.operation.toString()).single().intent)
                g.originalImports.entries(scope).single()
            }
            val peer = original.intent.copy(destination = original.intent.destination.copy(endpoint = f.otherEndpoint.identity),
                operation = UUID.randomUUID())
            f.seed(peer)
            val unrelated = persisted().entry(peer.operation)
            assertNotNull(unrelated)
            val before = journal.readBytes()
            val requestsBeforeCancel = f.server.requestCount
            var deleteCall: Call? = null
            var observedFence: OriginalImportEntry? = null
            var headerStarts = 0
            val listener = object : EventListener() {
                override fun callStart(call: Call) {
                    assertEquals("DELETE", call.request().method)
                    assertEquals(f.memberPath, call.request().url.encodedPath)
                    assertNull(deleteCall)
                    deleteCall = call
                }
                override fun requestHeadersStart(call: Call) { headerStarts++ }
            }
            val failure = f.graph(null, listener = listener).use { g ->
                val scope = f.signIn(g)
                assertFalse(g.originalImports.enabled)
                assertThrows(SafeFailure::class.java) {
                    g.api.trackDetailsRemove(scope, f.track) {
                        val entry = g.originalImports.state.value.entry(original.intent.operation)
                        if (entry?.phase == OriginalImportPhase.RemovalPending) {
                            // This callback stays valid. Cancel synchronously only once the real store
                            // published its verified replacement and an independent reopen agrees.
                            val disk = persisted()
                            assertEquals(entry, disk.entry(original.intent.operation))
                            assertEquals(unrelated, disk.entry(peer.operation))
                            assertEquals(original.copy(phase = OriginalImportPhase.RemovalPending, removal = entry.removal), entry)
                            val call = checkNotNull(deleteCall)
                            assertFalse(call.isCanceled())
                            assertTrue(g.session.remoteCurrent(scope))
                            call.cancel()
                            assertTrue(call.isCanceled())
                            observedFence = entry
                        }
                        true
                    }
                }.reason.also { assertTrue(g.session.remoteCurrent(scope)) }
            }
            assertNotNull("a real DELETE Call must be canceled after verified journal publication", observedFence?.removal)
            assertEquals(requestsBeforeCancel, f.server.requestCount)
            assertEquals(0, deletes.get())
            assertEquals(0, posts.get())
            assertTrue(member.get())

            f.graph("fixture").use { g ->
                val scope = f.signIn(g)
                assertEquals(original.intent.original, f.phoneSource(g))
                g.originalImports.load()
                val restored = g.originalImports.entries(scope).single()
                val online = g.originalImports.admitOnlinePlayback(scope, f.track)
                val explicit = g.originalImports.admitExplicitOriginal(scope, f.track, original.intent.operation.toString())
                println("verified fence; Call canceled with current account and valid route; TLS DELETE=0 POST=0; " +
                    "outcome=$failure, reopened=${restored.phase}, online=${online.size}, explicit=${explicit.size}, headerStarts=$headerStarts")
                assertEquals("the canceled Call stranded its verified fence after reopening (outcome=$failure)", original, restored)
                assertArrayEquals(before, journal.readBytes())
                assertEquals(unrelated, persisted().entry(peer.operation))
                assertEquals(SafeFailure.Reason.RemovalNotSent, failure)
                assertEquals(0, headerStarts)
                assertEquals("GET", f.next(f.memberPath).method)
                assertEquals(original.intent, online.single().intent)
                assertEquals(online, explicit)

                val route = f.openDetails(g)
                val command = checkNotNull(g.trackDetails.claim(route, checkNotNull(g.trackDetails.state.value.detail), DetailsAction.Remove))
                val requestsBeforeRemove = f.server.requestCount
                g.trackDetails.execute(command)
                assertEquals("DELETE", f.next(f.memberPath).method)
                repeat(2) { assertEquals("GET", f.next("/api/v1/library").method) }
                g.trackDetails.execute(command)
                assertEquals(MutationOutcome.Confirmed, g.trackDetails.state.value.outcome)
                assertTrue(g.trackDetails.state.value.missing)
                val settled = persisted()
                assertEquals(OriginalImportPhase.Removed, settled.entry(original.intent.operation)?.phase)
                assertEquals(unrelated, settled.entry(peer.operation))
                assertEquals(requestsBeforeRemove + 3, f.server.requestCount)
                assertEquals(1, deletes.get())
                assertEquals(0, posts.get())
                println("deliberate removal after reopen: TLS DELETE=1 POST=0; exact 204 and both readbacks; unrelated receipt unchanged")
            }
        } finally { app.denyPermissions(permission) }
    }

    @Test fun canceledDeleteWithFailedRetractionRecoversOnlyOnDetailsReloadAndFreshMembership() = Fixture(seedReceipt = false).use { f ->
        val app = shadowOf(RuntimeEnvironment.getApplication())
        val permission = Manifest.permission.READ_EXTERNAL_STORAGE
        app.grantPermissions(permission)
        val journal = File(f.directory, "original-import.v1.json")
        val path = f.directory.toPath()
        val writable = Files.getPosixFilePermissions(path)
        val member = AtomicBoolean(true)
        val exactReadHealthy = AtomicBoolean(true)
        val deletes = AtomicInteger()
        val posts = AtomicInteger()
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.method == "POST") posts.incrementAndGet()
                return when (request.method to request.url.encodedPath) {
                    "GET" to f.memberPath -> if (exactReadHealthy.get()) f.member() else f.reply(503, "{}")
                    "GET" to "/api/v1/library" -> f.libraryPage(member.get(), request)
                    "GET" to "/api/v1/tracks/77/analysis" -> f.reply(404, "{}")
                    "DELETE" to f.memberPath -> {
                        deletes.incrementAndGet()
                        check(member.compareAndSet(true, false))
                        MockResponse.Builder().code(204).build()
                    }
                    else -> f.reply(500, "{}")
                }
            }
        }
        var deleteCall: Call? = null
        var headerStarts = 0
        val listener = object : EventListener() {
            override fun callStart(call: Call) { if (call.request().method == "DELETE") deleteCall = call }
            override fun requestHeadersStart(call: Call) { if (call.request().method == "DELETE") headerStarts++ }
        }
        fun persisted() = OriginalImportJournal(journal).apply { load() }.state.value.also { assertTrue(it.ready) }
        try {
            f.graph("fixture", listener = listener).use { g ->
                val scope = f.signIn(g)
                val intent = f.intent.copy(original = f.phoneSource(g))
                f.seed(intent)
                val peer = intent.copy(destination = intent.destination.copy(endpoint = f.otherEndpoint.identity), operation = UUID.randomUUID())
                f.seed(peer)
                val peerFence = UUID.randomUUID()
                OriginalImportJournal(journal).prepareRemoval(peer.destination, f.track, peerFence) { true }
                val peerEntry = persisted().entry(peer.operation)
                assertEquals(peerFence, peerEntry?.removal)
                val before = journal.readBytes()
                val original = g.originalImports.admitOnlinePlayback(scope, f.track).single()
                assertEquals("GET", f.next(f.memberPath).method)
                val operation = intent.operation.toString()
                assertSame(original, g.originalImports.admitExplicitOriginal(scope, f.track, operation).single())
                fun assertAliasesFenced() {
                    assertFalse(g.originalImports.owns(scope, original))
                    assertTrue(g.originalImports.admitOnlinePlayback(scope, f.track).isEmpty())
                    assertTrue(g.originalImports.admitExplicitOriginal(scope, f.track, operation).isEmpty())
                }
                var fenced: ByteArray? = null
                // Use Track Details' real source-validity callback to cancel only after the pending row
                // is visible both in memory and on disk. The route and account both remain current.
                val route = checkNotNull(g.trackDetails.open(com.soundq.android.data.trackdetails.PlayerDetailsCapture(scope, f.track) {
                    val entry = g.originalImports.state.value.entry(intent.operation)
                    if (fenced == null && entry?.phase == OriginalImportPhase.RemovalPending) {
                        assertEquals(entry, persisted().entry(intent.operation))
                        assertEquals(peerEntry, persisted().entry(peer.operation))
                        assertTrue(g.session.remoteCurrent(scope))
                        fenced = journal.readBytes()
                        Files.setPosixFilePermissions(path, PosixFilePermissions.fromString("r-x------"))
                        checkNotNull(deleteCall).cancel()
                    }
                    true
                }))
                fun reloadDetails() {
                    g.trackDetails.load(route)
                    assertEquals("GET", f.next("/api/v1/library").method)
                    assertEquals("GET", f.next("/api/v1/tracks/77/analysis").method)
                }
                fun claimRemove() = g.trackDetails.claim(route, checkNotNull(g.trackDetails.state.value.detail), DetailsAction.Remove)
                reloadDetails()
                val command = checkNotNull(claimRemove())
                val beforeCancel = f.server.requestCount
                g.trackDetails.execute(command)
                assertNotNull(fenced)
                assertEquals(beforeCancel, f.server.requestCount)
                assertEquals(0, headerStarts)
                assertArrayEquals(fenced, journal.readBytes())
                assertAliasesFenced()
                assertEquals("NotSentLocalCleanupFailed", g.trackDetails.state.value.removalIssue?.name)
                assertEquals(MutationOutcome.Refused, g.trackDetails.state.value.outcome)
                assertTrue(g.trackDetails.state.value.removalBlocked)
                assertNull(claimRemove())
                reloadDetails()
                assertEquals("NotSentLocalCleanupFailed", g.trackDetails.state.value.removalIssue?.name)
                assertArrayEquals(fenced, journal.readBytes())
                assertAliasesFenced()
                assertNull(claimRemove())

                Files.setPosixFilePermissions(path, writable)
                // Cold recovery of certified prepared bytes is exercised separately, without two active file owners.

                reloadDetails()
                assertNull(g.trackDetails.state.value.removalIssue)
                assertFalse(g.trackDetails.state.value.removalBlocked)
                assertArrayEquals(before, journal.readBytes())
                assertEquals(peerEntry, persisted().entry(peer.operation))
                assertFalse(g.originalImports.owns(scope, original))
                assertTrue(g.originalImports.admitExplicitOriginal(scope, f.track, operation).isEmpty())
                exactReadHealthy.set(false)
                assertTrue(g.originalImports.admitOnlinePlayback(scope, f.track).isEmpty())
                assertEquals("GET", f.next(f.memberPath).method)
                assertTrue(g.originalImports.admitExplicitOriginal(scope, f.track, operation).isEmpty())
                exactReadHealthy.set(true)
                val fresh = g.originalImports.admitOnlinePlayback(scope, f.track).single()
                assertEquals("GET", f.next(f.memberPath).method)
                assertEquals(intent, fresh.intent)
                assertNotSame(original, fresh)
                assertSame(fresh, g.originalImports.admitExplicitOriginal(scope, f.track, operation).single())
                assertEquals(0, deletes.get())
                assertEquals(0, posts.get())
                assertEquals(0, headerStarts)
                assertTrue(member.get())

                g.trackDetails.execute(command) // Consumed old intent cannot send after recovery.
                g.trackDetails.execute(checkNotNull(claimRemove()))
                assertEquals("DELETE", f.next(f.memberPath).method)
                repeat(2) { assertEquals("GET", f.next("/api/v1/library").method) }
                assertEquals(1, headerStarts)
                assertEquals(1, deletes.get())
                assertEquals(0, posts.get())
                assertEquals(MutationOutcome.Confirmed, g.trackDetails.state.value.outcome)
                assertEquals(OriginalImportPhase.Removed, persisted().entry(intent.operation)?.phase)
                assertEquals(peerEntry, persisted().entry(peer.operation))
            }
        } finally {
            Files.setPosixFilePermissions(path, writable)
            app.denyPermissions(permission)
        }
    }

    @Test fun replacementDetailsClearsItsUnconfirmedNoticeOnlyAfterExactUnenteredRetraction() =
        replacementDetailsReload()

    @Test fun replacementDetailsReloadKeepsALaterOperationFenced() =
        replacementDetailsReload(laterFence = true)

    @Test fun replacementDetailsReloadPreservesAnUnrelatedRefusal() =
        replacementDetailsReload(refuseMetadata = true)

    private fun replacementDetailsReload(laterFence: Boolean = false, refuseMetadata: Boolean = false) = Fixture().use { f ->
        val disk = File(f.directory, "original-import.v1.json")
        val path = f.directory.toPath()
        val writable = Files.getPosixFilePermissions(path)
        val before = disk.readBytes()
        val heldAtDispatch = CountDownLatch(1)
        val releaseDispatch = CountDownLatch(1)
        val holdAnalysis = AtomicBoolean(false)
        val analysisEntered = CountDownLatch(1)
        val releaseAnalysis = CountDownLatch(1)
        val laterDispatch = CountDownLatch(1)
        val releaseLaterDispatch = CountDownLatch(1)
        val holding = AtomicBoolean(false)
        val deleteCalls = AtomicInteger()
        val mutationHeaders = AtomicInteger()
        val mutationRequests = AtomicInteger()
        val listener = object : EventListener() {
            override fun callStart(call: Call) { if (call.request().method == "DELETE") deleteCalls.incrementAndGet() }
            override fun requestHeadersStart(call: Call) {
                if (call.request().method in setOf("DELETE", "POST")) mutationHeaders.incrementAndGet()
            }
        }
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.method in setOf("DELETE", "POST")) mutationRequests.incrementAndGet()
                return when (request.method to request.url.encodedPath) {
                    "GET" to "/api/v1/library" -> f.libraryPage(true, request)
                    "GET" to "/api/v1/tracks/77/analysis" -> {
                        if (holdAnalysis.get()) {
                            analysisEntered.countDown()
                            check(releaseAnalysis.await(10, SECONDS))
                        }
                        f.reply(404, "{}")
                    }
                    "PUT" to "/api/v1/tracks/77/metadata-override" -> f.reply(403, "{}")
                    else -> f.reply(500, "{}")
                }
            }
        }
        fun persisted() = OriginalImportJournal(disk).apply { load() }.state.value.also { assertTrue(it.ready) }
            .entry(f.intent.operation)!!
        f.graph(null, listener = listener).use { g ->
            val scope = f.signIn(g)
            val details = g.trackDetails
            val playing = PlaybackProjection(connection = PlaybackProjection.Connection.Connected,
                queue = listOf(QueueOccurrence("occ-77", f.track.value, "Known original", "", false)),
                selectedOccurrence = "occ-77", accountEpoch = scope.epoch,
                sessionIdentity = "fixture-player", sourceQueueIncarnation = "fixture-queue")
            val latest = java.util.concurrent.atomic.AtomicReference(playing)
            val capture = checkNotNull(details.capturePlayer(scope, playing) {
                if (g.originalImports.state.value.entry(f.intent.operation)?.phase == OriginalImportPhase.RemovalPending &&
                    holding.compareAndSet(false, true)) {
                    // Hold the final source check in the real network interceptor, after prepareRemoval
                    // and outside the membership lock, so the replacement can observe the fence.
                    heldAtDispatch.countDown()
                    check(releaseDispatch.await(10, SECONDS))
                }
                latest.get()
            })
            val oldRoute = checkNotNull(details.open(capture))
            details.load(oldRoute)
            assertEquals("GET", f.next("/api/v1/library").method)
            assertEquals("GET", f.next("/api/v1/tracks/77/analysis").method)
            val oldCommand = checkNotNull(details.claim(oldRoute, details.state.value.detail!!, DetailsAction.Remove))
            val pool = Executors.newFixedThreadPool(2)
            try {
                val removed = pool.submit { details.execute(oldCommand) }
                assertTrue("old DELETE did not reach held pre-entry admission", heldAtDispatch.await(5, SECONDS))
                val pending = persisted()
                assertEquals(OriginalImportPhase.RemovalPending, pending.phase)
                assertNotNull(pending.removal)
                assertEquals(pending, g.originalImports.state.value.entry(f.intent.operation))
                val fenced = disk.readBytes()
                val prepared = Json.parseToJsonElement(fenced.decodeToString()).jsonObject
                assertEquals(4, prepared.getValue("version").jsonPrimitive.int)
                assertEquals(pending.removal.toString(), prepared.getValue("prepared").jsonArray.single().jsonPrimitive.content)
                assertEquals(1, deleteCalls.get())
                assertEquals(0, mutationHeaders.get())
                assertEquals(0, mutationRequests.get())
                assertTrue(details.current(oldRoute))

                val replacement = f.openDetails(g)
                val beforeReload = details.state.value
                assertFalse(details.current(oldRoute))
                assertTrue(details.current(replacement))
                assertTrue(g.session.remoteCurrent(scope))
                assertEquals("Unconfirmed", beforeReload.removalIssue?.name)
                assertTrue(beforeReload.removalBlocked)
                assertNull(details.claim(replacement, beforeReload.detail!!, DetailsAction.Remove))
                assertFalse(removed.isDone)

                // Force immediate pre-entry retraction to fail, not the preceding prepare/readback.
                Files.setPosixFilePermissions(path, PosixFilePermissions.fromString("r-x------"))
                // The captured Player selection also retires while the source read is held. The
                // old route's pre-call current check has already run inside the interceptor.
                latest.set(playing.copy(selectionIncarnation = playing.selectionIncarnation + 1))
                releaseDispatch.countDown()
                removed.get(10, SECONDS)
                assertSame(beforeReload, details.state.value) // The old command cannot publish into this route.
                assertEquals(pending, persisted())
                assertArrayEquals(fenced, disk.readBytes())
                assertEquals(LibraryRemovalFenceStatus.NotSentLocalCleanupFailed, g.api.libraryRemovalFenceStatus(scope, f.track))
                Files.setPosixFilePermissions(path, writable)

                if (refuseMetadata) {
                    val metadata = DetailsAction.Metadata(com.soundq.android.data.trackdetails.MetadataDraft("Unrelated draft"))
                    details.execute(checkNotNull(details.claim(replacement, details.state.value.detail!!, metadata)))
                    assertEquals("PUT", f.next("/api/v1/tracks/77/metadata-override").method)
                    assertEquals(MutationOutcome.Refused, details.state.value.outcome)
                }
                val beforeRecovery = f.server.requestCount
                if (laterFence) {
                    holdAnalysis.set(true)
                    val reload = pool.submit { details.load(replacement) }
                    assertTrue("Reload did not reach its analysis GET", analysisEntered.await(5, SECONDS))
                    assertTrue(details.state.value.loading)
                    assertArrayEquals(before, disk.readBytes()) // A was verified local-only cleanup.
                    val competingRemoval = pool.submit<SafeFailure.Reason?> {
                        assertThrows(SafeFailure::class.java) {
                            g.api.trackDetailsRemove(scope, f.track) {
                                if (g.originalImports.state.value.entry(f.intent.operation)?.phase != OriginalImportPhase.RemovalPending) true
                                else {
                                    laterDispatch.countDown()
                                    check(releaseLaterDispatch.await(10, SECONDS))
                                    false
                                }
                            }
                        }.reason
                    }
                    assertTrue("later DELETE did not prepare a real pre-entry fence", laterDispatch.await(5, SECONDS))
                    val newer = persisted()
                    assertEquals(OriginalImportPhase.RemovalPending, newer.phase)
                    assertNotNull(newer.removal)
                    assertNotEquals(pending.removal, newer.removal)
                    releaseAnalysis.countDown()
                    reload.get(10, SECONDS)
                    val reloaded = details.state.value
                    assertFalse(reloaded.loading)
                    assertEquals("Unconfirmed", reloaded.removalIssue?.name)
                    assertTrue("cleanup of A must not enable Remove while B owns the fence", reloaded.removalBlocked)
                    assertNull(details.claim(replacement, reloaded.detail!!, DetailsAction.Remove))
                    assertEquals(newer, persisted())
                    releaseLaterDispatch.countDown()
                    assertEquals(SafeFailure.Reason.Retired, competingRemoval.get(10, SECONDS))
                } else details.load(replacement)
                assertEquals("GET", f.next("/api/v1/library").method)
                assertEquals("GET", f.next("/api/v1/tracks/77/analysis").method)
                assertEquals(beforeRecovery + 2, f.server.requestCount)
                assertArrayEquals(before, disk.readBytes())
                assertEquals(OriginalImportPhase.Added, persisted().phase)
                details.execute(oldCommand)
                assertEquals(if (laterFence) 2 else 1, deleteCalls.get())
                assertEquals(0, mutationHeaders.get())
                assertEquals(0, mutationRequests.get())
                val recovered = details.state.value
                assertFalse(recovered.loading)
                if (laterFence) {
                    details.load(replacement)
                    assertEquals("GET", f.next("/api/v1/library").method)
                    assertEquals("GET", f.next("/api/v1/tracks/77/analysis").method)
                    val afterExternalCleanup = details.state.value
                    assertFalse("verified retraction by the other command must retire exactly B", afterExternalCleanup.removalBlocked)
                    assertNull(afterExternalCleanup.removalIssue)
                    assertNotNull(details.claim(replacement, afterExternalCleanup.detail!!, DetailsAction.Remove))
                } else {
                    assertEquals(if (refuseMetadata) MutationOutcome.Refused else null, recovered.outcome)
                    assertFalse(recovered.removalBlocked)
                    assertNotNull("fresh deliberate Remove must be eligible without being executed",
                        details.claim(replacement, recovered.detail!!, DetailsAction.Remove))
                    println("exact verified unentered retraction; replacement Remove claim accepted; " +
                        "mutation headers=${mutationHeaders.get()}, requests=${mutationRequests.get()}, notice=${recovered.removalIssue}, outcome=${recovered.outcome}")
                    assertNull("eligible Remove must not retain the retracted operation's Unconfirmed notice", recovered.removalIssue)
                }
            } finally {
                releaseDispatch.countDown()
                releaseAnalysis.countDown()
                releaseLaterDispatch.countDown()
                pool.shutdownNow()
                pool.awaitTermination(10, SECONDS)
                Files.setPosixFilePermissions(path, writable)
            }
        }
    }

    @Test fun oldAccountEpochCannotSettleEntered204OrChangeOtherReceipts() = Fixture().use { f ->
        val peerAccount = "d92f0c59-efd0-47bc-a0cb-e2117fa383b7"
        val peer = f.intent.copy(destination = f.intent.destination.copy(account = peerAccount), operation = UUID.randomUUID())
        val other = f.intent.copy(destination = f.intent.destination.copy(endpoint = f.otherEndpoint.identity), operation = UUID.randomUUID())
        f.seed(peer); f.seed(other)
        val journal = File(f.directory, "original-import.v1.json")
        val release = CountDownLatch(1)
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                check(request.method == "DELETE" && request.url.encodedPath == f.memberPath)
                check(release.await(8, SECONDS))
                return MockResponse.Builder().code(204).build()
            }
        }
        f.graph(null).use { g ->
            val scope = f.signIn(g)
            val pool = Executors.newSingleThreadExecutor()
            try {
                val removal = pool.submit<SafeFailure.Reason?> {
                    (runCatching { g.api.trackDetailsRemove(scope, f.track) { true } }.exceptionOrNull() as? SafeFailure)?.reason
                }
                assertEquals("DELETE", f.next(f.memberPath).method)
                val fence = journal.readBytes()
                val replacement = f.signIn(g, peerAccount)
                assertEquals(peer, g.originalImports.entries(replacement).single().intent)
                assertEquals(OriginalImportPhase.Added, g.originalImports.entries(replacement).single().phase)
                release.countDown()
                assertEquals(SafeFailure.Reason.Retired, removal.get(8, SECONDS))
                assertArrayEquals(fence, journal.readBytes())
                assertEquals(1, f.server.requestCount)
            } finally { release.countDown(); pool.shutdownNow() }
        }
        f.graph("fixture").use { g ->
            val scope = f.signIn(g)
            g.originalImports.load()
            assertEquals("RemovalPending", g.originalImports.entries(scope).single().phase.name)
            assertEquals("RemovalUnconfirmed", assertThrows(SafeFailure::class.java) {
                g.api.trackDetailsRemove(scope, f.track) { true }
            }.reason.name)
        }
        f.graph(null, endpoint = f.otherEndpoint).use { g ->
            val scope = f.signIn(g)
            g.originalImports.load()
            assertEquals(other, g.originalImports.entries(scope).single().intent)
            assertEquals(OriginalImportPhase.Added, g.originalImports.entries(scope).single().phase)
        }
        assertEquals(1, f.server.requestCount)
        assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
    }

    @Test fun oneExact204RetiresAllKnownOperationsForItsMember() = Fixture().use { f ->
        val other = f.intent.copy(operation = UUID.randomUUID(), original = f.intent.original.copy(
            key = HistoryKey.Device(DeviceFileId(UUID.randomUUID()))))
        f.seed(other)
        val incomplete = other.copy(operation = UUID.randomUUID())
        val journal = File(f.directory, "original-import.v1.json")
        val commit = CommittedOriginal(f.track, f.intent.original.revision)
        OriginalImportJournal(journal).put(OriginalImportEntry(incomplete, OriginalImportPhase.ReadbackRequired, commit), null) { true }
        val captured = java.util.concurrent.atomic.AtomicReference<ByteArray>()
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                check(request.method == "DELETE" && request.url.encodedPath == f.memberPath)
                captured.set(journal.readBytes())
                return MockResponse.Builder().code(204).build()
            }
        }
        f.graph(null).use { g ->
            g.api.trackDetailsRemove(f.signIn(g), f.track) { true }
            assertEquals("DELETE", f.next(f.memberPath).method)
        }
        fun rows(bytes: ByteArray) = kotlinx.serialization.json.Json.parseToJsonElement(bytes.decodeToString()).jsonObject
            .getValue("rows").jsonArray.map { it.jsonObject }
        val beforeAck = rows(captured.get())
        assertEquals(setOf("RemovalPending"), beforeAck.map { it.getValue("phase").jsonPrimitive.content }.toSet())
        val operation = beforeAck.map { it.getValue("removal").jsonPrimitive.content }.distinct().single()
        assertEquals(operation, UUID.fromString(operation).toString())
        assertEquals(2, beforeAck.count { "durationMs" in it })
        val settled = rows(journal.readBytes())
        assertEquals(setOf(operation), settled.map { it.getValue("removal").jsonPrimitive.content }.toSet())
        assertEquals(setOf("Removed"), settled.map { it.getValue("phase").jsonPrimitive.content }.toSet())
        assertEquals(3, settled.size)
        f.graph("fixture").use { g ->
            val scope = f.signIn(g)
            g.originalImports.reconcileRestored(scope)
            assertEquals(setOf(f.intent, other, incomplete), g.originalImports.entries(scope).map { it.intent }.toSet())
            assertTrue(g.originalImports.associations(scope).isEmpty())
        }
        assertEquals(1, f.server.requestCount)
        assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
    }

    @Test fun defaultOwnedDeleteRetiresReceiptBeforeSameIdReaddAndEnabledReconciliation() = Fixture().use { f ->
        val member = AtomicBoolean(true)
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.method to request.url.encodedPath) {
                "GET" to f.memberPath -> if (member.get()) f.member() else f.reply(404, """{"code":"NOT_FOUND"}""")
                "DELETE" to f.memberPath -> {
                    check(member.compareAndSet(true, false))
                    MockResponse.Builder().code(204).build()
                }
                else -> f.reply(500, "{}")
            }
        }
        val receipt = f.graph("fixture").use { enabled ->
            val scope = f.signIn(enabled)
            enabled.originalImports.reconcileRestored(scope)
            assertEquals("GET", f.next(f.memberPath).method)
            assertEquals(f.intent, enabled.originalImports.associations(scope).single().intent)
            enabled.originalImports.entries(scope).single().also { assertEquals(OriginalImportPhase.Added, it.phase) }
        }
        f.graph(null).use { disabled ->
            val scope = f.signIn(disabled)
            assertFalse(disabled.originalImports.enabled)
            disabled.api.trackDetailsRemove(scope, f.track) { true } // Even before startup journal load.
            assertEquals("DELETE", f.next(f.memberPath).method)
            assertFalse(member.get())
        }
        member.set(true) // Producer re-adds numeric ID with byte-identical membership before the next startup.
        f.graph("fixture").use { reopened ->
            val scope = f.signIn(reopened)
            val present = reopened.api.originalImportTransport(false).membership(scope, f.track) as OriginalMembershipResult.Present
            assertEquals(receipt.membership, present.row)
            assertEquals("GET", f.next(f.memberPath).method)
            reopened.originalImports.reconcileRestored(scope)
            assertTrue("same-ID exact readback must not revive the deleted association", reopened.originalImports.associations(scope).isEmpty())
            val retired = reopened.originalImports.entries(scope).single()
            assertEquals(receipt.intent, retired.intent)
            assertEquals(receipt.commit, retired.commit)
            assertEquals(OriginalImportPhase.Removed, retired.phase)
            assertNull(retired.membership)
            assertEquals(OriginalImportRepository.Action.Absent, reopened.originalImports.check(scope, f.intent.operation) { true })
            assertTrue(reopened.originalImports.admitOnlinePlayback(scope, f.track).isEmpty())
            assertTrue(reopened.originalImports.admitExplicitOriginal(scope, f.track, f.intent.operation.toString()).isEmpty())
            assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
        }
    }

    @Test fun defaultObservationIgnoresForeignDisconnectedFailedTruncatedAndFilteredOperations() = Fixture().use { f ->
        val noContent = MockResponse.Builder().code(204).build()
        val journal = File(f.directory, "original-import.v1.json")
        val before = journal.readBytes()
        val foreign = "d92f0c59-efd0-47bc-a0cb-e2117fa383b7"
        f.graph(null, endpoint = f.otherEndpoint).use { g ->
            f.server.enqueue(noContent)
            g.api.trackDetailsRemove(f.signIn(g), f.track) { true }
            assertEquals("localhost", f.next(f.memberPath).url.host)
        }
        f.graph(null, memory = MemoryStore().apply { save(f.endpoint, f.tokens()) }).use { g ->
            assertTrue(g.session.useDeviceDownloads())
            val offline = checkNotNull(g.session.capture())
            assertEquals(AuthState.DeviceOnly(offline.accountId), g.session.state.value)
            assertEquals(SafeFailure.Reason.Retired, assertThrows(SafeFailure::class.java) {
                g.api.trackDetailsRemove(offline, f.track) { true }
            }.reason)
            assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
        }
        f.graph(null).use { g ->
            f.server.enqueue(noContent)
            g.api.trackDetailsRemove(f.signIn(g, foreign), f.track) { true }
            assertEquals("DELETE", f.next(f.memberPath).method)
            val scope = f.signIn(g)
            f.server.enqueue(noContent)
            g.api.trackDetailsRemove(scope, TrackId(78)) { true }
            assertEquals("DELETE", f.next("/api/v1/library/tracks/78").method)
            val ordinary = TrackId(78)
            val ordinaryPath = "/api/v1/library/tracks/${ordinary.value}"
            f.server.enqueue(f.reply(500, "{}"))
            assertThrows(SafeFailure::class.java) { g.api.trackDetailsRemove(scope, ordinary) { true } }
            assertEquals("DELETE", f.next(ordinaryPath).method)
            f.server.enqueue(f.reply(200, "{}")) // Generic success is not a DELETE 204.
            assertThrows(SafeFailure::class.java) { g.api.trackDetailsRemove(scope, ordinary) { true } }
            assertEquals("DELETE", f.next(ordinaryPath).method)
            f.server.enqueue(MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build())
            assertThrows(SafeFailure::class.java) { g.api.trackDetailsRemove(scope, ordinary) { true } }
            assertEquals("DELETE", f.next(ordinaryPath).method)
            f.server.enqueue(f.reply(200, """{"tracks":["""))
            assertThrows(SafeFailure::class.java) { g.api.library(scope, LibraryQuery(), 0) }
            assertEquals("GET", f.next("/api/v1/library").method)
            f.server.enqueue(f.reply(200, """{"tracks":[],"total":0,"limit":20,"offset":0}"""))
            assertTrue(g.api.library(scope, LibraryQuery(text = "not this title", liked = true), 0).tracks.isEmpty())
            assertEquals("true", f.next("/api/v1/library").url.queryParameter("liked"))

            val release = CountDownLatch(1)
            f.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    check(request.method == "DELETE" && request.url.encodedPath == ordinaryPath)
                    check(release.await(8, SECONDS)); return noContent
                }
            }
            val pool = Executors.newSingleThreadExecutor()
            try {
                val deletion = pool.submit<SafeFailure.Reason?> {
                    (runCatching { g.api.trackDetailsRemove(scope, ordinary) { true } }.exceptionOrNull() as? SafeFailure)?.reason
                }
                assertEquals("DELETE", f.next(ordinaryPath).method)
                assertTrue(g.session.lockLocal())
                assertFalse(g.session.remoteCurrent(scope))
                assertTrue(g.session.completeLocalUnlock(checkNotNull(g.session.localUnlockTicket())))
                val again = checkNotNull(g.session.capture())
                assertEquals(scope.accountId, again.accountId)
                assertNotEquals(scope.epoch, again.epoch)
                assertTrue(g.session.remoteCurrent(again))
                release.countDown()
                assertEquals(SafeFailure.Reason.Retired, deletion.get(8, SECONDS))
            } finally { release.countDown(); pool.shutdownNow() }
            assertArrayEquals(before, journal.readBytes())
            assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
        }
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse =
                if (request.method == "GET" && request.url.encodedPath == f.memberPath) f.member() else f.reply(500, "{}")
        }
        f.graph("fixture").use { g ->
            val scope = f.signIn(g)
            g.originalImports.reconcileRestored(scope)
            assertEquals("GET", f.next(f.memberPath).method)
            assertEquals(f.intent, g.originalImports.associations(scope).single().intent)
            assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
        }
    }

    @Test fun listeningJournalObservedDenialRetiresConsentForUnchangedPhoneRow() = Fixture(seedReceipt = false).use { f ->
        f.graph("fixture").use { g ->
            val scope = f.signIn(g)
            val permission = Manifest.permission.READ_EXTERNAL_STORAGE
            val app = shadowOf(RuntimeEnvironment.getApplication())
            app.grantPermissions(permission)
            g.phoneAudio.start()
            f.await { g.phoneAudio.state.value.let { it.ready && it.permission && !it.refreshing && it.scan != null } }

            val bytes = byteArrayOf(0, -1, 10, 13, 22, 19, 8)
            val hash = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
            val revision = ContentRevision(hash, bytes.size.toLong())
            val display = ImportDisplay("Synthetic original", "", "")
            val row = checkNotNull(runBlocking { g.phoneAudio.journal(true) { store, access ->
                val grant = ScanGrant(ScanGrantId(UUID.randomUUID()), GrantKind.INDEXED, "Host fixture", ProviderLocator("fixture", "fixture/index"), true)
                check(store.putGrant(access, grant) != Mutation.REFUSED)
                val scan = checkNotNull(store.beginScan(access, grant.id))
                check(store.publishScan(scan, listOf(DiscoveredAudio(ProviderObjectId("fixture", "source"),
                    ProviderLocator("fixture", "fixture/source"), revision, OriginalMetadata("source.mp3"), 4000)), true) != Mutation.REFUSED)
                checkNotNull(store.snapshot(access)).files.single { it.revision == revision }
            } })
            val productionOriginals = PhoneImportOriginals(g.phoneAudio, g.session::version)
            val journal = File(g.directory, "original-import.v1.json")
            val opens = AtomicInteger()
            // The platform byte reader alone is substituted; source stamps, listening publication, import IO and TLS are real.
            val imports = OriginalImportRepository(g.session, OriginalImportJournal(journal), { original, current ->
                check(original == row.owner && current()); opens.incrementAndGet()
                object : ImportOriginalRead {
                    override val length = revision.byteLength
                    override fun checkCurrent() { check(current()) }
                    override fun readAt(position: Long, buffer: ByteArray, count: Int): Int {
                        bytes.copyInto(buffer, 0, position.toInt(), position.toInt() + count); return count
                    }
                    override fun close() = Unit
                }
            }, productionOriginals::current, productionOriginals::stamp).apply {
                installTransport(g.api.originalImportTransport(true)); load()
            }
            val jobs = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            try {
                val listener = NativeListeningJournal(g, jobs)
                val deck = NativeCallbackDeck(1, 1, 0, 4000, 48000, 192000, true, false, true, 0, 0)
                val ordinary = File.createTempFile("listening-permission", ".encoded", g.directory).apply { writeBytes(bytes) }
                runBlocking {
                    listener.bind(MediaItem.Builder().setMediaId(UUID.randomUUID().toString()).build(), MediaGrant(scope, TrackId(78)),
                        NativePlaybackSource.OwnedTemporary(ordinary), deck, 0) { true }
                }
                val before = g.phoneAudio.state.value
                val ref = g.phoneAudio.reference(row)
                val authority = g.phoneAudio.sourceAuthority(ref)
                assertTrue(before.permission)
                val stale = checkNotNull(imports.choose(scope, row.owner, display) { true })
                app.denyPermissions(permission)
                listener.observe(NativeCallbackSnapshot("{}", 0, deck))
                f.await { !g.phoneAudio.state.value.permission }
                val denied = g.phoneAudio.state.value
                assertEquals(before.scan, denied.scan)
                assertEquals(before.snapshot?.files, denied.snapshot?.files)
                assertEquals(before.snapshot?.grants, denied.snapshot?.grants)
                assertEquals(authority, g.phoneAudio.sourceAuthority(ref))
                assertEquals(row, g.phoneAudio.observed(ref))
                app.grantPermissions(permission)

                // No second choose/refresh may observe the denial on behalf of the actual journal publisher.
                f.server.dispatcher = object : Dispatcher() {
                    override fun dispatch(request: RecordedRequest): MockResponse = when (request.method to request.url.encodedPath) {
                        "POST" to "/api/v1/library/uploads" -> f.reply(201, """{"account_id":"${scope.accountId}","operation_id":"${request.headers["Idempotency-Key"]}","status":"committed","track_id":77,"sha256":"sha256:$hash","byte_length":${bytes.size}}""")
                        "GET" to f.memberPath -> f.reply(200, """{"account_id":"${scope.accountId}","id":77,"sha256":"sha256:$hash","byte_length":${bytes.size},"title":"${display.title}","artist":"","album":"","duration_ms":4000,"added_at":"2026-11-20T19:00:00Z"}""")
                        else -> f.reply(500, "{}")
                    }
                }
                assertEquals(OriginalImportRepository.Action.Unavailable, imports.confirm(stale))
                assertEquals(0, opens.get())
                assertFalse(journal.exists())
                assertTrue(imports.entries(scope).isEmpty())
                assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
                val fresh = checkNotNull(imports.choose(scope, row.owner, display) { true })
                assertEquals(OriginalImportRepository.Action.Added, imports.confirm(fresh))
                val posted = f.next("/api/v1/library/uploads")
                assertEquals("POST", posted.method)
                assertEquals(fresh.intent.operation.toString(), posted.headers["Idempotency-Key"])
                assertEquals("GET", f.next(f.memberPath).method)
                assertEquals(1, opens.get())
                assertEquals(fresh.intent, imports.associations(scope).single().intent)
                assertTrue(journal.isFile)
                assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
            } finally { jobs.cancel(); app.denyPermissions(permission) }
        }
    }

    @Test fun onlineCoordinatorNeedsFreshExactMembershipAndEnteredDeleteFencesHeldPositive() = Fixture().use { f ->
        val allowOld = CountDownLatch(1)
        val allowAck = CountDownLatch(1)
        val reading = CountDownLatch(1)
        val route = AtomicBoolean(true)
        val count = AtomicInteger()
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.method to request.url.encodedPath) {
                "GET" to f.memberPath -> {
                    if (count.incrementAndGet() == 2) { reading.countDown(); check(allowOld.await(8, SECONDS)) }
                    f.member()
                }
                "DELETE" to f.memberPath -> {
                    route.set(false)
                    check(allowAck.await(8, SECONDS))
                    MockResponse.Builder().code(204).build()
                }
                else -> f.reply(500, "{}")
            }
        }
        f.graph("fixture").use { g ->
            val scope = f.signIn(g)
            g.originalImports.load()
            assertTrue(g.originalImports.associations(scope).isEmpty())
            g.observeOriginalImports()
            assertEquals("GET", f.next(f.memberPath).method)
            f.await { g.originalImports.associations(scope).size == 1 }
            val accepted = g.originalImports.associations(scope).single()
            val pool = Executors.newFixedThreadPool(2)
            try {
                val future = pool.submit<OriginalImportRepository.Action> { g.originalImports.check(scope, f.intent.operation) { true } }
                assertTrue(reading.await(4, SECONDS))
                assertEquals("GET", f.next(f.memberPath).method)
                // The route retires after dispatch; the real 204 is still owned by the current account.
                val deletion = pool.submit { g.api.trackDetailsRemove(scope, f.track, route::get) }
                assertEquals("DELETE", f.next(f.memberPath).method)
                f.await { !route.get() }
                assertFalse(g.originalImports.owns(scope, accepted))
                assertEquals("RemovalPending", g.originalImports.entries(scope).single().phase.name)
                allowOld.countDown()
                assertEquals(OriginalImportRepository.Action.Retired, future.get(8, SECONDS))
                assertTrue(g.originalImports.associations(scope).isEmpty())
                allowAck.countDown(); deletion.get(8, SECONDS)
                assertEquals(OriginalImportPhase.Removed, g.originalImports.entries(scope).single().phase)
                assertEquals(3, f.server.requestCount)
                assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
            } finally { allowAck.countDown(); allowOld.countDown(); pool.shutdownNow() }
        }
        f.graph("fixture").use { reopened ->
            val scope = f.signIn(reopened)
            reopened.originalImports.load()
            assertEquals(f.intent, reopened.originalImports.entries(scope).single().intent)
            assertEquals(OriginalImportPhase.Removed, reopened.originalImports.entries(scope).single().phase)
            assertEquals(OriginalImportRepository.Action.Absent, reopened.originalImports.check(scope, f.intent.operation) { true })
            assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
        }
    }

    @Test fun sameAccountReentryDoesNotAdoptOldHeldMembershipResponse() = Fixture().use { f ->
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val reads = AtomicInteger()
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                check(request.method == "GET" && request.url.encodedPath == f.memberPath)
                if (reads.incrementAndGet() == 1) { entered.countDown(); check(release.await(8, SECONDS)) }
                return f.member()
            }
        }
        f.graph("fixture-readback").use { g ->
            val a = f.signIn(g)
            g.originalImports.load()
            val pool = Executors.newSingleThreadExecutor()
            try {
                val prior = pool.submit<OriginalImportRepository.Action> { g.originalImports.check(a, f.intent.operation) { true } }
                assertTrue(entered.await(4, SECONDS)); assertEquals("GET", f.next(f.memberPath).method)
                val b = f.signIn(g, "d92f0c59-efd0-47bc-a0cb-e2117fa383b7")
                assertTrue(g.originalImports.associations(b).isEmpty())
                val newA = f.signIn(g)
                release.countDown()
                assertEquals(OriginalImportRepository.Action.Retired, prior.get(8, SECONDS))
                assertTrue(g.originalImports.associations(newA).isEmpty())
                assertEquals(OriginalImportRepository.Action.Added, g.originalImports.check(newA, f.intent.operation) { true })
                assertEquals("GET", f.next(f.memberPath).method)
                assertEquals(f.intent, g.originalImports.associations(newA).single().intent)
                assertFalse(g.originalImports.writeReady(newA))
            } finally { release.countDown(); pool.shutdownNow() }
        }
    }

    @Test fun exactAbsenceRetiresAnOperationEvenWithANewerPositiveRead() = Fixture().use { f ->
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val reads = AtomicInteger()
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                check(request.method == "GET" && request.url.encodedPath == f.memberPath)
                if (reads.incrementAndGet() != 1) return f.member()
                entered.countDown(); check(release.await(8, SECONDS))
                return f.reply(404, """{"code":"NOT_FOUND"}""")
            }
        }
        f.graph("fixture-readback").use { g ->
            val scope = f.signIn(g)
            val pool = Executors.newSingleThreadExecutor()
            try {
                val sweep = pool.submit { g.originalImports.reconcileRestored(scope) }
                assertTrue(entered.await(4, SECONDS)); assertEquals("GET", f.next(f.memberPath).method)
                assertEquals(OriginalImportRepository.Action.Added, g.originalImports.check(scope, f.intent.operation) { true })
                assertEquals("GET", f.next(f.memberPath).method)
                val accepted = g.originalImports.associations(scope).single()
                release.countDown(); sweep.get(8, SECONDS)
                assertFalse(g.originalImports.owns(scope, accepted))
                assertEquals(OriginalImportPhase.Removed, g.originalImports.entries(scope).single().phase)
                assertEquals(OriginalImportRepository.Action.Absent, g.originalImports.check(scope, f.intent.operation) { true })
                assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
            } finally { release.countDown(); pool.shutdownNow() }
        }
    }

    @Test fun defaultOffStartupObserverLoadsJournalWithoutAnyFeatureDispatch() = runBlocking {
        Fixture().use { f ->
            val journal = File(f.directory, "original-import.v1.json")
            val before = journal.readBytes()
            f.graph(null).use { ordinary ->
                val scope = f.signIn(ordinary)
                // This is the real observer that AppGraph.start launches. A retained Added
                // receipt is a positive trigger in the fixture-enabled counterpart, above.
                withTimeout(5_000) { ordinary.observeOriginalImports().join() }
                assertFalse(ordinary.originalImports.enabled)
                assertFalse(ordinary.originalImports.writeReady(scope))
                assertTrue(ordinary.originalImports.state.value.ready)
                assertEquals(f.intent, ordinary.originalImports.entries(scope).single().intent)
                assertTrue(ordinary.originalImports.associations(scope).isEmpty())
                assertNull(ordinary.originalImports.choose(scope, f.intent.original, f.intent.display) { true })
                assertArrayEquals(before, journal.readBytes())
                assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
                assertEquals(0, f.server.requestCount)
            }
        }
    }

    @Test fun deviceOnlyAndDefaultCannotTurnV4OriginalIntoAnyOtherSource() = Fixture().use { f ->
        f.graph("fixture", memory = MemoryStore().apply { save(f.endpoint, f.tokens()) }).use { phone ->
            assertTrue(phone.session.useDeviceDownloads())
            phone.originalImports.load()
            val scope = requireNotNull(phone.session.capture())
            assertTrue(phone.session.state.value is AuthState.DeviceOnly)
            assertTrue(phone.originalImports.associations(scope).isEmpty())
            f.v4(phone, scope).let { (item, grants) ->
                val error = runCatching { OriginalAwareNativeSource(phone, grants).acquire(item) { true } }.exceptionOrNull()
                assertEquals(SafeFailure.Reason.AudioUnavailable, (error as? SafeFailure)?.reason)
            }
            assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
        }
        f.graph(null).use { off ->
            val scope = f.signIn(off)
            off.originalImports.load()
            assertEquals(f.intent, off.originalImports.entries(scope).single().intent)
            assertTrue(off.originalImports.associations(scope).isEmpty())
            val (item, grants) = f.v4(off, scope)
            val source = OriginalAwareNativeSource(off, grants)
            assertEquals(SafeFailure.Reason.AudioUnavailable, (runCatching { source.acquire(item) { true } }.exceptionOrNull() as? SafeFailure)?.reason)
            assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
            // Positive ordinary source control: reach the real descriptor owner exactly once.
            val plain = item.buildUpon().setMediaMetadata(item.mediaMetadata.buildUpon().setExtras(Bundle.EMPTY).build()).build()
            grants[plain.localConfiguration!!.uri.toString()] = MediaGrant(scope, f.track)
            f.server.enqueue(f.reply(500, "{}"))
            assertNotNull(runCatching { source.acquire(plain) { true } }.exceptionOrNull())
            assertEquals("POST", f.next("/api/v1/playback/urls").method)
            assertNull(f.server.takeRequest(150, java.util.concurrent.TimeUnit.MILLISECONDS))
        }
    }

    internal class Fixture(seedReceipt: Boolean = true) : AutoCloseable {
        val server = MockWebServer()
        private val cert = HeldCertificate.Builder().addSubjectAlternativeName("127.0.0.1").addSubjectAlternativeName("localhost").build()
        private val trust = HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        init { server.useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory()); server.start(InetAddress.getByName("127.0.0.1"), 0) }
        val endpoint = ApiEndpoint.parse(server.url("/api/v1").newBuilder().host("127.0.0.1").build().toString())
        val otherEndpoint = ApiEndpoint.parse(endpoint.base.newBuilder().host("localhost").build().toString())
        private val client = OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(), trust.trustManager).build()
        private val context = RuntimeEnvironment.getApplication()
        val directory = File(context.noBackupFilesDir, "soundq").also { it.mkdirs() }
        private val account = "00000000-1111-4111-a111-222222222222"
        val track = TrackId(77)
        val memberPath = "/api/v1/library/tracks/${track.value}"
        private val revision = ContentRevision("2".repeat(64), 71)
        val intent = OriginalImportIntent(ServerAccount(endpoint.identity, account), UUID.randomUUID(),
            ContentOwner(HistoryKey.Device(DeviceFileId(UUID.randomUUID())), revision, 1), ImportDisplay("Known original", "", ""))
        init { if (seedReceipt) seed(intent) }
        fun seed(intent: OriginalImportIntent) {
            val commit = CommittedOriginal(track, revision)
            val journal = OriginalImportJournal(File(directory, "original-import.v1.json"))
            journal.put(OriginalImportEntry(intent, OriginalImportPhase.Added, commit, OriginalMembership(intent.destination, commit, intent.display, 4000)), null) { true }
        }
        fun phoneSource(graph: AppGraph): ContentOwner {
            graph.phoneAudio.start()
            await { graph.phoneAudio.state.value.let { it.ready && it.permission && !it.refreshing && it.scan != null } }
            val original = checkNotNull(runBlocking { graph.phoneAudio.journal(true) { store, access ->
                store.snapshot(access)?.files?.singleOrNull { it.revision == revision }?.let { return@journal it.owner }
                val grant = ScanGrant(ScanGrantId(UUID.randomUUID()), GrantKind.INDEXED, "Fixture", ProviderLocator("fixture", "fixture/index"), true)
                check(store.putGrant(access, grant) != Mutation.REFUSED)
                val scan = checkNotNull(store.beginScan(access, grant.id))
                check(store.publishScan(scan, listOf(DiscoveredAudio(ProviderObjectId("fixture", "source"),
                    ProviderLocator("fixture", "fixture/source"), revision, OriginalMetadata("source.mp3"), 4000)), true) != Mutation.REFUSED)
                checkNotNull(store.snapshot(access)).files.single { it.revision == revision }.owner
            } })
            check(PhoneImportOriginals(graph.phoneAudio, graph.session::version).current(original))
            return original
        }
        fun libraryPage(present: Boolean, request: RecordedRequest): MockResponse {
            val row = if (present) """{"id":${track.value},"title":"Known original","artist":"","album":"","duration_ms":4000,"has_metadata_override":false,"mb_verified":false}""" else ""
            return reply(200, """{"tracks":[$row],"total":${if (present) 1 else 0},"limit":${request.url.queryParameter("limit")},"offset":0}""")
        }
        fun openDetails(graph: AppGraph): com.soundq.android.data.trackdetails.DetailsRoute {
            graph.library.refine(LibraryQuery())
            assertEquals("GET", next("/api/v1/library").method)
            val capture = checkNotNull(graph.library.captureTrack(graph.library.state.value.rows.single()))
            val route = checkNotNull(graph.trackDetails.open(capture))
            graph.trackDetails.load(route)
            assertEquals("GET", next("/api/v1/library").method)
            assertEquals("GET", next("/api/v1/tracks/77/analysis").method)
            return route
        }
        fun tokens(id: String = account) = SecretTokens("opaque-test-access", "opaque-test-refresh", id)
        fun graph(mode: String?, memory: MemoryStore = MemoryStore(), endpoint: ApiEndpoint = this.endpoint, listener: EventListener? = null,
            openPhoneAudioStore: (File) -> DeviceListeningStore = { DeviceListeningStore(it) }) =
            AppGraph(context, endpoint, if (listener == null) client else client.newBuilder().eventListener(listener).build(),
                store = memory, originalImportFixtureMode = mode, openPhoneAudioStore = openPhoneAudioStore)
        fun signIn(graph: AppGraph, id: String = account): AccountScope = graph.session.run {
            check(accept(beginIntent(), tokens(id))); requireNotNull(capture())
        }
        fun reply(code: Int, json: String) = MockResponse.Builder().code(code).body(json)
            .setHeader("Cache-Control", "private, no-store").setHeader("Content-Type", "application/json").build()
        fun member() = reply(200, """{"account_id":"$account","id":77,"sha256":"sha256:${revision.sha256}","byte_length":71,"title":"Known original","artist":"","album":"","duration_ms":4000,"added_at":"2026-11-20T19:00:00Z"}""")
        fun next(path: String) = checkNotNull(server.takeRequest(4, SECONDS)).also {
            assertEquals(path, it.url.encodedPath); assertEquals("Bearer opaque-test-access", it.headers["Authorization"])
        }
        fun await(done: () -> Boolean) {
            val end = System.nanoTime() + SECONDS.toNanos(5)
            while (!done() && System.nanoTime() < end) Thread.sleep(5)
            assertTrue(done())
        }
        fun v4(g: AppGraph, scope: AccountScope): Pair<MediaItem, ConcurrentHashMap<String, MediaGrant>> {
            val saved = QueueSnapshot(g.endpoint.identity, scope.accountId,
                listOf(SavedOccurrence("fixture-occurrence", track.value, "Known original", "", false, true, originalOperation = intent.operation.toString())), 0, 0)
            val decoded = requireNotNull(QueueSnapshot.decode(saved.encode(), g.endpoint.identity, scope.accountId)).items.single()
            assertEquals(intent.operation.toString(), decoded.originalOperation)
            val uri = "soundq://track/${track.value}/${decoded.occurrence}"
            val item = MediaItem.Builder().setMediaId(decoded.occurrence).setUri(uri).setMediaMetadata(MediaMetadata.Builder().setExtras(Bundle().apply {
                putString("originalImportOperation", decoded.originalOperation)
            }).build()).build()
            return item to ConcurrentHashMap<String, MediaGrant>().apply { put(uri, MediaGrant(scope, track, true, originalOnly = true)) }
        }
        override fun close() { server.close(); client.connectionPool.evictAll(); client.dispatcher.executorService.shutdown() }
    }
}
