package com.soundq.android.data.originalimport

import com.soundq.android.data.*
import com.soundq.android.data.deviceaudio.*
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.serialization.json.*
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import mockwebserver3.SocketEffect
import okhttp3.OkHttpClient
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Real SoundQApi/OkHttp/TLS. Only the producer/fault and platform file descriptor are host fixtures. */
class OriginalImportWireTest {
    @get:Rule val temp = TemporaryFolder()

    @Test fun uploadRetiredAfterDurableWriteDoesNotBlockFreshExplicitChoice() = notSentUpload(atWire = false)

    @Test fun uploadRefusedByActualWireGuardDoesNotBlockFreshExplicitChoice() = notSentUpload(atWire = true)

    private fun notSentUpload(atWire: Boolean) = fixture().use { f ->
        var pendingChecks = 0
        val old = requireNotNull(f.repository.choose(f.scope, f.owner, f.display) {
            if (f.repository.entries(f.scope).none { it.phase == OriginalImportPhase.Unconfirmed }) true
            else ++pendingChecks == 1 && atWire
        })
        val disposition = f.repository.confirm(old)
        assertEquals(if (atWire) 2 else 1, pendingChecks)
        assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
        f.reconstruct(writes = true)
        val fresh = f.added()
        assertNotEquals(old.intent.operation, fresh.intent.operation)
        assertEquals(OriginalImportRepository.Action.Retired, disposition)
        assertTrue(f.repository.entries(f.scope).none { it.intent.operation == old.intent.operation && it.phase in activeImportPhases })
    }

    @Test fun tcpConnectionRefusalBeforeWireDoesNotStrandThePendingUpload() = preGuardUploadFailure(tls = false)

    @Test fun untrustedTlsHandshakeBeforeWireDoesNotStrandThePendingUpload() = preGuardUploadFailure(tls = true)

    private fun preGuardUploadFailure(tls: Boolean) {
        val initialCall = AtomicReference<okhttp3.Call>()
        val terminal = AtomicReference<java.io.IOException>()
        val headers = java.util.concurrent.atomic.AtomicInteger()
        val listener = object : okhttp3.EventListener() {
            override fun callStart(call: okhttp3.Call) {
                if (call.request().method == "POST") initialCall.compareAndSet(null, call)
            }
            override fun callFailed(call: okhttp3.Call, ioe: java.io.IOException) {
                if (call.request().method == "POST") check(terminal.compareAndSet(null, ioe))
            }
            override fun requestHeadersStart(call: okhttp3.Call) {
                if (call.request().method == "POST") headers.incrementAndGet()
            }
        }
        fixture(listener, untrustedServer = tls).use { f ->
            val port = f.server.port
            if (!tls) f.server.close()
            val old = f.choice()
            val action = f.repository.confirm(old)
            val failed = requireNotNull(terminal.get())
            assertEquals(old.intent.operation.toString(), requireNotNull(initialCall.get()).request().header("Idempotency-Key"))
            assertTrue(if (tls) failed is javax.net.ssl.SSLHandshakeException else failed is java.net.ConnectException)
            assertEquals(0, headers.get())
            assertEquals(0, f.server.requestCount)
            f.restartTlsServer(port)
            f.reconstruct(writes = true)
            val fresh = f.added()
            assertNotEquals(old.intent.operation, fresh.intent.operation)
            assertEquals(OriginalImportRepository.Action.Retired, action)
            assertEquals(1, headers.get())
            assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
        }
    }

    @Test fun canonicalDelete401RetractsOnlyExactFenceWithoutRefreshOrReplay() = deleteRefusal(401, canonical = true)

    @Test fun noncanonicalDelete401KeepsFence() = deleteRefusal(401, canonical = false)

    @Test fun delete503KeepsFenceAndDoesNotReplayDespiteRetryAfter() = deleteRefusal(503, canonical = false)

    private fun deleteRefusal(code: Int, canonical: Boolean) = fixture().use { f ->
        val choice = f.added()
        val track = TrackId(77)
        val before = f.repository.entries(f.scope).single()
        f.server.enqueue(MockResponse.Builder().code(code)
            .setHeader("Content-Type", "text/plain; charset=utf-8").setHeader("X-Content-Type-Options", "nosniff")
            .setHeader("Retry-After", "0")
            .body(if (canonical) """{"code":"TOKEN_EXPIRED","message":"access token has expired"}""" + "\n" else "other").build())
        val error = assertThrows(SafeFailure::class.java) { f.api.trackDetailsRemove(f.scope, track) { true } }
        assertEquals("DELETE", f.next("/api/v1/library/tracks/77").method)
        assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
        assertTrue(f.repository.admitExplicitOriginal(f.scope, track, choice.intent.operation.toString()).isEmpty())
        if (canonical) {
            assertEquals(SafeFailure.Reason.Refused, error.reason)
            assertEquals(before, f.repository.entries(f.scope).single())
            f.server.enqueue(f.reply(200, f.membership()))
            assertEquals(choice.intent, f.repository.admitOnlinePlayback(f.scope, track).single().intent)
            assertEquals("GET", f.next("/api/v1/library/tracks/77").method)
            f.server.enqueue(MockResponse.Builder().code(204).build())
            assertEquals(LibraryRemovalReceipt.Confirmed, f.api.trackDetailsRemove(f.scope, track) { true })
            assertEquals("DELETE", f.next("/api/v1/library/tracks/77").method)
        } else {
            assertEquals(SafeFailure.Reason.RemovalUnconfirmed, error.reason)
            assertEquals(OriginalImportPhase.RemovalPending, f.repository.entries(f.scope).single().phase)
        }
        assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
    }

    @Test fun deleteWhileUploadTargetUnknownFencesLateDedupeAckAndStalePositive() = fixture().use { f ->
        val choice = f.choice()
        val uploadHeld = java.util.concurrent.CountDownLatch(1)
        val uploadRelease = java.util.concurrent.CountDownLatch(1)
        val deleteHeld = java.util.concurrent.CountDownLatch(1)
        val deleteRelease = java.util.concurrent.CountDownLatch(1)
        val uploadSettledOrReadHeld = java.util.concurrent.CountDownLatch(1)
        val readRelease = java.util.concurrent.CountDownLatch(1)
        val track = TrackId(77)
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.method to request.url.encodedPath) {
                "POST" to "/api/v1/library/uploads" -> {
                    uploadHeld.countDown(); check(uploadRelease.await(10, TimeUnit.SECONDS))
                    f.reply(200, f.receipt(choice.intent.operation))
                }
                "DELETE" to "/api/v1/library/tracks/77" -> {
                    deleteHeld.countDown(); check(deleteRelease.await(10, TimeUnit.SECONDS))
                    MockResponse.Builder().code(204).build()
                }
                "GET" to "/api/v1/library/tracks/77" -> {
                    val stale = f.membership()
                    uploadSettledOrReadHeld.countDown(); check(readRelease.await(10, TimeUnit.SECONDS))
                    f.reply(200, stale)
                }
                else -> f.reply(500, "{}")
            }
        }
        val pool = java.util.concurrent.Executors.newFixedThreadPool(2)
        try {
            val upload = pool.submit<OriginalImportRepository.Action> {
                try { f.repository.confirm(choice) } finally { uploadSettledOrReadHeld.countDown() }
            }
            assertTrue(uploadHeld.await(5, TimeUnit.SECONDS))
            assertEquals(OriginalImportPhase.Unconfirmed, f.repository.entries(f.scope).single().phase)
            val remove = pool.submit<LibraryRemovalReceipt> { f.api.trackDetailsRemove(f.scope, track) { true } }
            assertTrue(deleteHeld.await(5, TimeUnit.SECONDS))
            uploadRelease.countDown()
            assertTrue(uploadSettledOrReadHeld.await(5, TimeUnit.SECONDS))
            deleteRelease.countDown()
            assertEquals(LibraryRemovalReceipt.Confirmed, remove.get(5, TimeUnit.SECONDS))
            readRelease.countDown()
            assertNotEquals(OriginalImportRepository.Action.Added, upload.get(5, TimeUnit.SECONDS))
            assertEquals(OriginalImportPhase.Removed, f.repository.entries(f.scope).single().phase)
            assertTrue(f.repository.admitExplicitOriginal(f.scope, track, choice.intent.operation.toString()).isEmpty())
            f.reconstruct(writes = true)
            assertTrue(f.repository.admitOnlinePlayback(f.scope, track).isEmpty())
            val posted = f.next("/api/v1/library/uploads")
            assertEquals(choice.intent.operation.toString(), posted.headers["Idempotency-Key"])
            assertEquals("DELETE", f.next("/api/v1/library/tracks/77").method)
            assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
        } finally {
            uploadRelease.countDown(); deleteRelease.countDown(); readRelease.countDown()
            pool.shutdownNow(); pool.awaitTermination(10, TimeUnit.SECONDS)
        }
    }

    @Test fun coldStatusAfterDelete204CannotAdoptItsSameIdReadd() = fixture().use { f ->
        val choice = f.choice()
        val track = TrackId(77)
        val op = choice.intent.operation
        f.server.enqueue(MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build())
        assertEquals(OriginalImportRepository.Action.Unconfirmed, f.repository.confirm(choice))
        assertEquals("POST", f.next("/api/v1/library/uploads").method)
        f.server.enqueue(MockResponse.Builder().code(204).build())
        assertEquals(LibraryRemovalReceipt.Confirmed, f.api.trackDetailsRemove(f.scope, track) { true })
        assertEquals("DELETE", f.next("/api/v1/library/tracks/77").method)
        f.reconstruct(writes = true)
        assertEquals(OriginalImportPhase.Unconfirmed, f.repository.entries(f.scope).single().phase)
        f.server.enqueue(f.reply(200, f.receipt(op)))
        f.server.enqueue(f.reply(200, f.membership())) // identical authoritative member would be returned after external re-add
        assertEquals(OriginalImportRepository.Action.Absent, f.repository.check(f.scope, op) { true })
        assertEquals("GET", f.next("/api/v1/library/uploads/$op").method)
        assertEquals(OriginalImportPhase.Removed, f.repository.entries(f.scope).single().phase)
        assertTrue(f.repository.admitOnlinePlayback(f.scope, track).isEmpty())
        assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
    }

    @Test fun freshImportReclaimsOnlyNoCommitRowsAtJournalRowLimit() = capacity(dense = false)

    @Test fun freshImportReclaimsOnlyNoCommitRowsAtJournalByteLimit() = capacity(dense = true)

    private fun capacity(dense: Boolean) = fixture().use { f ->
        val keep = f.seedCapacity(dense)
        f.reconstruct(writes = true)
        val new = f.added()
        assertNotEquals(keep.intent.operation, new.intent.operation)
        assertEquals(keep, OriginalImportJournal(f.file).apply { load() }.state.value.entry(keep.intent.operation))
        assertEquals(2, f.repository.entries(f.scope).size)
        assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
    }

    @Test fun unresolvedDurableRemovalBlocksDifferentUploadInLiveReopenedAndReenteredOwner() = fixture().use { f ->
        f.added()
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val uploadAttempts = java.util.concurrent.atomic.AtomicInteger()
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.method to request.url.encodedPath) {
                "DELETE" to "/api/v1/library/tracks/77" -> {
                    entered.countDown(); check(release.await(6, TimeUnit.SECONDS))
                    MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build()
                }
                "POST" to "/api/v1/library/uploads" -> {
                    uploadAttempts.incrementAndGet()
                    f.reply(400, """{"code":"INVALID_UPLOAD"}""")
                }
                else -> f.reply(500, "{}")
            }
        }
        val pool = java.util.concurrent.Executors.newSingleThreadExecutor()
        try {
            val removed = pool.submit<SafeFailure> { assertThrows(SafeFailure::class.java) { f.api.trackDetailsRemove(f.scope, TrackId(77)) { true } } }
            assertTrue(entered.await(4, TimeUnit.SECONDS))
            assertEquals(OriginalImportRepository.Action.AlreadyInProgress, f.repository.confirm(f.differentChoice()))
            release.countDown()
            assertEquals(SafeFailure.Reason.RemovalUnconfirmed, removed.get(5, TimeUnit.SECONDS).reason)
            assertEquals("DELETE", f.next("/api/v1/library/tracks/77").method)
            val pending = f.file.readBytes()
            val afterLoss = f.repository.confirm(f.differentChoice())
            f.reconstruct(writes = true)
            val afterReopen = f.repository.confirm(f.differentChoice())
            f.signIn("852115de-5f05-4072-b69f-391b1fce7914")
            // Different authenticated owner proceeds through the actual upload wire on the same endpoint.
            assertEquals(OriginalImportRepository.Action.Refused, f.repository.confirm(f.differentChoice()))
            f.signIn(f.account)
            val afterReentry = f.repository.confirm(f.differentChoice())
            assertEquals(listOf(OriginalImportRepository.Action.AlreadyInProgress, OriginalImportRepository.Action.AlreadyInProgress,
                OriginalImportRepository.Action.AlreadyInProgress), listOf(afterLoss, afterReopen, afterReentry))
            assertEquals(1, uploadAttempts.get())
            assertEquals("POST", f.next("/api/v1/library/uploads").method)
            val beforeEntry = OriginalImportJournal(f.file).apply { load() }.state.value.rows.first { it.intent.destination.account == f.account }
            val pendingRow = Json.parseToJsonElement(pending.decodeToString()).jsonObject.getValue("rows").jsonArray.single().jsonObject
            assertEquals(pendingRow.getValue("removal").jsonPrimitive.content, beforeEntry.removal.toString())
            assertEquals(OriginalImportPhase.RemovalPending, beforeEntry.phase)
            assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
        } finally { release.countDown(); pool.shutdownNow(); pool.awaitTermination(6, TimeUnit.SECONDS) }
    }

    @Test fun deliberateUploadCanEnterAfterOnlyTheExactPreparedFenceIsCleanedUp() = fixture().use { f ->
        f.added()
        val dir = requireNotNull(f.file.parentFile).toPath()
        val writable = java.nio.file.Files.getPosixFilePermissions(dir)
        try {
            val error = assertThrows(SafeFailure::class.java) {
                f.api.trackDetailsRemove(f.scope, TrackId(77)) {
                    if (f.repository.entries(f.scope).single().phase == OriginalImportPhase.RemovalPending) {
                        java.nio.file.Files.setPosixFilePermissions(dir, java.nio.file.attribute.PosixFilePermissions.fromString("r-x------"))
                        false
                    } else true
                }
            }
            assertEquals(SafeFailure.Reason.RemovalNotSentLocalCleanupFailed, error.reason)
            assertEquals(OriginalImportRepository.Action.AlreadyInProgress, f.repository.confirm(f.differentChoice()))
            assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
        } finally { java.nio.file.Files.setPosixFilePermissions(dir, writable) }
        f.reconstruct(writes = true)
        assertNotNull(f.api.retryLibraryRemovalSettlement(f.scope, TrackId(77)) { true })
        assertEquals(OriginalImportPhase.Added, f.repository.entries(f.scope).single().phase)
        val after = f.differentChoice()
        f.server.enqueue(f.reply(400, """{"code":"INVALID_UPLOAD"}"""))
        assertEquals(OriginalImportRepository.Action.Refused, f.repository.confirm(after))
        val post = f.next("/api/v1/library/uploads")
        assertEquals("POST", post.method)
        assertEquals(after.intent.operation.toString(), post.headers["Idempotency-Key"])
        assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
    }

    @Test fun alreadyEnteredRecoveryOfDifferentTrackDoesNotReleaseDetachedUncertainDeleteFence() = fixture().use { f ->
        val uploadB = f.choice()
        val statusPath = "/api/v1/library/uploads/${uploadB.intent.operation}"
        val statusEntered = java.util.concurrent.CountDownLatch(1)
        val releaseStatus = java.util.concurrent.CountDownLatch(1)
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.method to request.url.encodedPath) {
                "POST" to "/api/v1/library/uploads", "DELETE" to "/api/v1/library/tracks/77" ->
                    MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build()
                "GET" to statusPath -> {
                    statusEntered.countDown(); check(releaseStatus.await(8, TimeUnit.SECONDS))
                    f.reply(200, JsonObject(Json.parseToJsonElement(f.receipt(uploadB.intent.operation)).jsonObject +
                        ("track_id" to JsonPrimitive(88))).toString())
                }
                "GET" to "/api/v1/library/tracks/88" -> f.reply(200, f.membership(track = 88))
                else -> f.reply(500, "{}")
            }
        }
        assertEquals(OriginalImportRepository.Action.Unconfirmed, f.repository.confirm(uploadB))
        assertEquals("POST", f.next("/api/v1/library/uploads").method)
        f.reconstruct(writes = true)
        val pool = java.util.concurrent.Executors.newSingleThreadExecutor()
        try {
            val recovery = pool.submit<OriginalImportRepository.Action> { f.repository.check(f.scope, uploadB.intent.operation) { true } }
            assertTrue(statusEntered.await(4, TimeUnit.SECONDS))
            assertEquals("GET", f.next(statusPath).method)
            assertEquals(SafeFailure.Reason.RemovalUnconfirmed, assertThrows(SafeFailure::class.java) {
                f.api.trackDetailsRemove(f.scope, TrackId(77)) { true }
            }.reason)
            assertEquals("DELETE", f.next("/api/v1/library/tracks/77").method)
            releaseStatus.countDown()
            assertEquals(OriginalImportRepository.Action.Added, recovery.get(5, TimeUnit.SECONDS))
            assertEquals("GET", f.next("/api/v1/library/tracks/88").method)
            f.reconstruct(writes = true)
            assertEquals(TrackId(88), f.repository.entries(f.scope).single().commit?.track)
            assertEquals(LibraryRemovalFenceStatus.Unconfirmed, f.api.libraryRemovalFenceStatus(f.scope, TrackId(77)))
            val fenced = f.file.readBytes()
            assertEquals(OriginalImportRepository.Action.AlreadyInProgress, f.repository.confirm(f.differentChoice()))
            assertArrayEquals(fenced, f.file.readBytes())
            assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
        } finally { releaseStatus.countDown(); pool.shutdownNow(); pool.awaitTermination(8, TimeUnit.SECONDS) }
    }

    @Test fun mutatingStatusIsWithheldAfterAnOverlappingUncertainDelete() = statusRemoveOverlap(atGuard = false)

    @Test fun mutatingStatusRechecksAtActualGuardAfterAnOverlappingUncertainDelete() = statusRemoveOverlap(atGuard = true)

    private fun statusRemoveOverlap(atGuard: Boolean) {
        val holdCall = java.util.concurrent.atomic.AtomicBoolean(false)
        val started = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        fun isStatus(call: okhttp3.Call) = call.request().method == "GET" && call.request().url.encodedPath.startsWith("/api/v1/library/uploads/")
        val headers = java.util.concurrent.atomic.AtomicInteger()
        val listener = object : okhttp3.EventListener() {
            override fun callStart(call: okhttp3.Call) {
                if (isStatus(call) && holdCall.get()) { started.countDown(); check(release.await(8, TimeUnit.SECONDS)) }
            }
            override fun requestHeadersStart(call: okhttp3.Call) { if (isStatus(call)) headers.incrementAndGet() }
        }
        fixture(listener).use { f ->
            val choice = f.choice()
            val statusPath = "/api/v1/library/uploads/${choice.intent.operation}"
            f.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = when (request.method to request.url.encodedPath) {
                    "POST" to "/api/v1/library/uploads", "DELETE" to "/api/v1/library/tracks/77" ->
                        MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build()
                    "GET" to statusPath -> f.reply(200, f.receipt(choice.intent.operation, status = "pending"))
                    else -> f.reply(500, "{}")
                }
            }
            assertEquals(OriginalImportRepository.Action.Unconfirmed, f.repository.confirm(choice))
            assertEquals("POST", f.next("/api/v1/library/uploads").method)
            fun checkStatus() = f.repository.check(f.scope, choice.intent.operation) { true }
            assertEquals(OriginalImportRepository.Action.Unconfirmed, checkStatus())
            assertEquals("GET", f.next(statusPath).method)
            assertEquals(1, headers.get())
            fun loseDelete() {
                assertEquals(SafeFailure.Reason.RemovalUnconfirmed, assertThrows(SafeFailure::class.java) {
                    f.api.trackDetailsRemove(f.scope, TrackId(77)) { true }
                }.reason)
                assertEquals("DELETE", f.next("/api/v1/library/tracks/77").method)
            }
            val pool = java.util.concurrent.Executors.newSingleThreadExecutor()
            try {
                if (atGuard) {
                    holdCall.set(true)
                    val check = pool.submit<OriginalImportRepository.Action> { checkStatus() }
                    assertTrue(started.await(4, TimeUnit.SECONDS))
                    loseDelete()
                    release.countDown()
                    assertEquals(OriginalImportRepository.Action.Unconfirmed, check.get(5, TimeUnit.SECONDS))
                } else {
                    loseDelete()
                    f.reconstruct(writes = true)
                    assertEquals(OriginalImportRepository.Action.RemovalUnconfirmed, checkStatus())
                }
                assertEquals(1, headers.get())
                assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
                assertEquals(OriginalImportPhase.Unconfirmed, f.repository.entries(f.scope).single().phase)
            } finally { release.countDown(); pool.shutdownNow(); pool.awaitTermination(8, TimeUnit.SECONDS) }
        }
    }

    @Test fun effectiveTextChangesWithoutRetiringExactOriginalProof() = fixture().use { f ->
        val choice = f.choice()
        val track = TrackId(77)
        val op = choice.intent.operation
        val edited = f.membership().replace("Accepted title", "Edited title")
        f.server.enqueue(f.reply(201, f.receipt(op)))
        f.server.enqueue(f.reply(200, edited))
        assertEquals(OriginalImportRepository.Action.Added, f.repository.confirm(choice))
        assertEquals("POST", f.next("/api/v1/library/uploads").method)
        assertEquals("GET", f.next("/api/v1/library/tracks/77").method)
        val binding = f.repository.admitExplicitOriginal(f.scope, track, op.toString()).single()
        assertEquals("Edited title", binding.membership.display.title)
        f.server.enqueue(f.reply(200, edited.replace("Edited title", "Edited again")))
        assertEquals("Edited again", f.repository.admitOnlinePlayback(f.scope, track).single().membership.display.title)
        assertEquals("GET", f.next("/api/v1/library/tracks/77").method)
        assertTrue("the continuously verified decoder lease must still own the same audio", f.repository.owns(f.scope, binding))
        f.reconstruct(writes = true)
        assertEquals(f.display, f.repository.entries(f.scope).single().intent.display)
        assertTrue(f.repository.admitExplicitOriginal(f.scope, track, op.toString()).isEmpty())
        f.server.enqueue(f.reply(200, edited))
        assertEquals("Edited title", f.repository.admitOnlinePlayback(f.scope, track).single().membership.display.title)
        assertEquals("GET", f.next("/api/v1/library/tracks/77").method)
        assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
    }

    @Test fun responseLostAfterBodyRecoversSameUuidAndCurrentLibraryWithoutReplay() = fixture().use { f ->
        val committed = AtomicReference<UUID>()
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.method to request.url.encodedPath) {
                "POST" to "/api/v1/library/uploads" -> {
                    val id = UUID.fromString(request.headers["Idempotency-Key"]!!)
                    check(committed.compareAndSet(null, id))
                    MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build()
                }
                "GET" to "/api/v1/library/uploads/${committed.get()}" -> f.reply(200, f.receipt(requireNotNull(committed.get())))
                "GET" to "/api/v1/library/tracks/77" -> f.reply(200, f.membership())
                "GET" to "/api/v1/library" -> f.reply(200, f.page(committed.get() != null))
                else -> f.reply(500, "{}")
            }
        }
        f.library.refine(LibraryQuery(text = "Accepted", liked = true))
        assertEquals("GET", f.next("/api/v1/library").method)
        assertTrue(f.library.state.value.rows.isEmpty())
        val choice = f.choice()
        assertEquals(0, f.repository.entries(f.scope).size)
        assertEquals(OriginalImportRepository.Action.Unconfirmed, f.repository.confirm(choice))
        assertEquals(choice.intent.operation, committed.get())
        assertTrue(f.repository.associations(f.scope).isEmpty())
        f.reconstruct(writes = false)
        assertNull(f.repository.choose(f.scope, f.owner, f.display) { true })
        assertEquals(OriginalImportRepository.Action.Added, f.repository.check(f.scope, choice.intent.operation) { true })
        val upload = f.next("/api/v1/library/uploads")
        assertEquals("POST", upload.method)
        assertEquals(listOf(choice.intent.operation.toString()), upload.headers.values("Idempotency-Key"))
        f.assertAllowedMultipart(upload)
        assertEquals("GET", f.next("/api/v1/library/uploads/${choice.intent.operation}").method)
        assertEquals("GET", f.next("/api/v1/library/tracks/77").method)
        val ordinary = f.next("/api/v1/library")
        assertEquals("GET", ordinary.method)
        assertEquals("Accepted", ordinary.url.queryParameter("q"))
        assertEquals("true", ordinary.url.queryParameter("liked"))
        assertEquals("Accepted", f.library.state.value.query.text)
        assertEquals(TrackId(77), f.library.state.value.rows.single().id)
        assertEquals(f.display, f.repository.associations(f.scope).single().membership.display)
        assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
    }

    @Test fun definitiveAckCannotMakeAnAliasWithoutExactAccountTrackHashAndLength() = fixture().use { f ->
        val choice = f.choice()
        f.server.enqueue(f.reply(201, f.receipt(choice.intent.operation)))
        f.server.enqueue(f.reply(200, f.membership(account = "852115de-5f05-4072-b69f-391b1fce7914")))
        assertEquals(OriginalImportRepository.Action.ReadbackRequired, f.repository.confirm(choice))
        assertEquals("POST", f.next("/api/v1/library/uploads").method)
        assertEquals("GET", f.next("/api/v1/library/tracks/77").method)
        for (mismatch in listOf(f.membership(track = 78), f.membership(hash = "5".repeat(64)), f.membership(length = f.bytes.size + 1))) {
            f.server.enqueue(f.reply(200, mismatch))
            assertEquals(OriginalImportRepository.Action.ReadbackRequired, f.repository.check(f.scope, choice.intent.operation) { true })
            assertTrue(f.repository.associations(f.scope).isEmpty())
            assertEquals("GET", f.next("/api/v1/library/tracks/77").method)
        }
        f.server.enqueue(f.reply(200, f.membership()))
        assertEquals(OriginalImportRepository.Action.Added, f.repository.check(f.scope, choice.intent.operation) { true })
        assertEquals("GET", f.next("/api/v1/library/tracks/77").method)
        assertEquals(1, f.repository.associations(f.scope).size)
        assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
    }

    @Test fun uploadNeverFollowsRedirectOrRefreshesAfter401AndGenericFailureStaysUnknown() {
        for (status in listOf(401, 503, 307, 408)) fixture().use { f ->
            val choice = f.choice()
            f.server.enqueue(f.reply(status, "{\"code\":\"UPLOAD_UNAVAILABLE\"}", location = f.endpoint.identity + "/redirect-trap"))
            assertEquals(OriginalImportRepository.Action.Unconfirmed, f.repository.confirm(choice))
            val request = f.next("/api/v1/library/uploads")
            assertEquals("POST", request.method)
            assertEquals(choice.intent.operation.toString(), request.headers["Idempotency-Key"])
            assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
            assertEquals(OriginalImportRepository.Action.AlreadyInProgress, f.repository.confirm(f.choice()))
        }
    }

    @Test fun statusNotFoundAndClosedNeverMintAnotherPost() = fixture().use { f ->
        val choice = f.choice()
        f.server.enqueue(f.reply(202, f.receipt(choice.intent.operation, status = "pending")))
        assertEquals(OriginalImportRepository.Action.Unconfirmed, f.repository.confirm(choice))
        assertEquals("POST", f.next("/api/v1/library/uploads").method)
        f.server.enqueue(f.reply(404, "{\"code\":\"NOT_FOUND\",\"message\":\"Not found\"}"))
        assertEquals(OriginalImportRepository.Action.Unconfirmed, f.repository.check(f.scope, choice.intent.operation) { true })
        assertEquals("GET", f.next("/api/v1/library/uploads/${choice.intent.operation}").method)
        assertEquals(OriginalImportRepository.Action.AlreadyInProgress, f.repository.confirm(f.choice()))
        f.server.enqueue(f.reply(200, f.receipt(choice.intent.operation, status = "closed")))
        assertEquals(OriginalImportRepository.Action.Closed, f.repository.check(f.scope, choice.intent.operation) { true })
        assertEquals("GET", f.next("/api/v1/library/uploads/${choice.intent.operation}").method)
        f.reconstruct(writes = true)
        assertEquals(OriginalImportRepository.Action.Closed, f.repository.confirm(f.choice()))
        assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
    }

    @Test fun historicalCommitAndConfirmedAbsentMembershipCannotResurrectAnUpload() = fixture().use { f ->
        val choice = f.choice()
        f.server.enqueue(f.reply(200, f.receipt(choice.intent.operation)))
        f.server.enqueue(f.reply(404, "{\"code\":\"NOT_FOUND\",\"message\":\"Not found\"}"))
        assertEquals(OriginalImportRepository.Action.Absent, f.repository.confirm(choice))
        assertEquals("POST", f.next("/api/v1/library/uploads").method)
        assertEquals("GET", f.next("/api/v1/library/tracks/77").method)
        f.reconstruct(writes = true)
        assertTrue(f.repository.associations(f.scope).isEmpty())
        assertEquals(OriginalImportRepository.Action.Absent, f.repository.confirm(f.choice()))
        assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
    }

    @Test fun overBudgetEncodedManifestNeverCreatesAnOperationOrARequest() = fixture().use { f ->
        val escaped = "a" + "\u0001".repeat(498) + "z"
        assertNull(f.repository.choose(f.scope, f.owner, ImportDisplay(escaped, escaped, escaped)) { true })
        assertTrue(f.repository.entries(f.scope).isEmpty())
        assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
        assertNotNull(f.choice())
    }

    @Test fun historicalReceiptCannotAuthorizeUntilFreshExactMembershipAndAbsenceStaysRetired() = fixture().use { f ->
        val choice = f.added()
        val op = choice.intent.operation
        f.reconstruct(writes = true)
        assertTrue("journal restore must not grant membership", f.repository.associations(f.scope).isEmpty())
        f.server.enqueue(f.reply(503, "{\"code\":\"UPLOAD_UNAVAILABLE\"}"))
        assertEquals(OriginalImportRepository.Action.ReadbackRequired, f.repository.check(f.scope, op) { true })
        assertEquals("GET", f.next("/api/v1/library/tracks/77").method)
        assertEquals(OriginalImportPhase.Added, f.repository.entries(f.scope).single().phase)
        f.server.enqueue(f.reply(200, f.membership()))
        assertEquals(OriginalImportRepository.Action.Added, f.repository.check(f.scope, op) { true })
        assertEquals("GET", f.next("/api/v1/library/tracks/77").method)
        assertNotNull(f.repository.playbackTrack(f.scope, TrackId(77), op.toString()))
        f.server.enqueue(f.reply(404, "{\"code\":\"NOT_FOUND\"}"))
        assertEquals(OriginalImportRepository.Action.Absent, f.repository.check(f.scope, op) { true })
        assertEquals("GET", f.next("/api/v1/library/tracks/77").method)
        f.reconstruct(writes = true)
        assertEquals(OriginalImportPhase.Removed, f.repository.entries(f.scope).single().phase)
        assertEquals(choice.intent, f.repository.entries(f.scope).single().intent)
        assertNull(f.repository.playbackTrack(f.scope, TrackId(77), op.toString()))
        assertEquals(OriginalImportRepository.Action.Absent, f.repository.confirm(f.choice()))
        assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
    }

    @Test fun fixtureToDefaultKeepsReceiptButDisablesProjectionAndExplicitBorrowing() = fixture().use { f ->
        val choice = f.added()
        val op = choice.intent.operation.toString()
        f.reconstruct(writes = null)
        assertEquals(choice.intent, f.repository.entries(f.scope).single().intent)
        assertFalse(f.repository.ready(f.scope))
        assertTrue(f.repository.associations(f.scope).isEmpty())
        assertNull(f.repository.playbackTrack(f.scope, TrackId(77), op))
        var alternate = 0
        fun acquire(explicit: String?) = originalPlayback(choice.intent.destination, TrackId(77), explicit, false,
            { f.repository.associations(f.scope) }, { true }, { "borrowed" }, { alternate++; "ordinary" })
        assertTrue(runCatching { acquire(op) }.exceptionOrNull() is SafeFailure)
        assertEquals(0, alternate)
        assertEquals("ordinary", acquire(null))
        assertEquals(1, alternate)
        assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
    }

    @Test fun acknowledgedClickSnapshotSurvivesNewApplyAndLostAckWithoutReplaying() = fixture().use { f ->
        val original = DeviceAudio((f.owner.key as HistoryKey.Device).id, ProviderObjectId("media", "synthetic"),
            f.owner.revision, f.owner.incarnation, OriginalMetadata("Owned.mp3", "Original", "Tag artist", "Tag album"),
            13000L, emptyList())
        val accepted = original.copy(displayOverride = LocalDisplayOverride(4, LocalDisplayText(f.display.title, f.display.artist, f.display.album)))
        val capture = requireNotNull(com.soundq.android.product.captureOriginalImportDisplay(f.owner, accepted))
        val choice = requireNotNull(f.repository.choose(f.scope, capture.source, capture.text, capture.overrideRevision) { true })
        val later = requireNotNull(com.soundq.android.product.captureOriginalImportDisplay(f.owner, accepted.copy(
            displayOverride = LocalDisplayOverride(5, LocalDisplayText("Later title", "Later artist", "Later album")))))
        assertEquals(capture.source, later.source)
        assertEquals(5L, later.overrideRevision)
        assertNotEquals(capture.text, later.text)
        assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))

        val op = choice.intent.operation
        f.server.enqueue(MockResponse.Builder().onResponseStart(mockwebserver3.SocketEffect.CloseSocket()).build())
        assertEquals(OriginalImportRepository.Action.Unconfirmed, f.repository.confirm(choice))
        val post = f.next("/api/v1/library/uploads")
        assertEquals("POST", post.method)
        assertEquals(op.toString(), post.headers["Idempotency-Key"])
        f.assertAllowedMultipart(post)

        f.reconstruct(writes = true)
        assertEquals(choice.intent, f.repository.entries(f.scope).single().intent)
        assertEquals(4L, f.repository.entries(f.scope).single().intent.overrideRevision)
        val path = "/api/v1/library/uploads/$op"
        f.server.enqueue(f.reply(404, "{\"code\":\"NOT_FOUND\"}"))
        assertEquals(OriginalImportRepository.Action.Unconfirmed, f.repository.check(f.scope, op) { true })
        assertEquals("GET", f.next(path).method)
        fun laterChoice() = requireNotNull(f.repository.choose(f.scope, later.source, later.text, later.overrideRevision) { true })
        assertEquals(OriginalImportRepository.Action.AlreadyInProgress, f.repository.confirm(laterChoice()))
        f.server.enqueue(f.reply(200, f.receipt(op, "closed")))
        assertEquals(OriginalImportRepository.Action.Closed, f.repository.check(f.scope, op) { true })
        assertEquals("GET", f.next(path).method)
        f.reconstruct(writes = true)
        assertEquals(OriginalImportRepository.Action.Closed, f.repository.confirm(laterChoice()))
        assertEquals(choice.intent, f.repository.entries(f.scope).single().intent)
        assertNull(f.server.takeRequest(150, TimeUnit.MILLISECONDS))
    }

    private fun fixture(listener: okhttp3.EventListener = okhttp3.EventListener.NONE, untrustedServer: Boolean = false) =
        Fixture(temp.newFolder(), listener, untrustedServer)
    private class Fixture(dir: File, listener: okhttp3.EventListener, untrustedServer: Boolean) : AutoCloseable {
        val account = "a85209c6-2c36-42ac-88b5-a3440838f66c"
        var server = MockWebServer()
            private set
        val bytes = System.getenv("SOUNDQ_ORIGINAL_IMPORT_QA")?.let { File(it, "original.mp3").readBytes() }
            ?: byteArrayOf(0, 0xff.toByte(), 10, 13, 22, 19, 8)
        val sha = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        val owner = ContentOwner(HistoryKey.Device(DeviceFileId(UUID.randomUUID())), ContentRevision(sha, bytes.size.toLong()), 1)
        private val otherBytes = bytes + 13.toByte()
        private val otherOwner = owner.copy(key = HistoryKey.Device(DeviceFileId(UUID.randomUUID())), revision = ContentRevision(
            MessageDigest.getInstance("SHA-256").digest(otherBytes).joinToString("") { "%02x".format(it) }, otherBytes.size.toLong()))
        val display = ImportDisplay("Accepted title", "Accepted artist", "Accepted album")
        val file = File(dir, "journal.json")
        private val cert = HeldCertificate.Builder().addSubjectAlternativeName("127.0.0.1").build()
        private val trust = HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        private fun startTls(port: Int, serverCert: HeldCertificate) {
            server.useHttps(HandshakeCertificates.Builder().heldCertificate(serverCert).build().sslSocketFactory())
            server.start(java.net.InetAddress.getByName("127.0.0.1"), port)
        }
        init {
            val serverCert = if (untrustedServer) HeldCertificate.Builder().addSubjectAlternativeName("127.0.0.1").build() else cert
            startTls(0, serverCert)
        }
        fun restartTlsServer(port: Int) {
            server.close()
            server = MockWebServer()
            startTls(port, cert)
        }
        val endpoint = ApiEndpoint.parse(server.url("/api/v1").newBuilder().host("127.0.0.1").build().toString())
        private val auth = AccountSession(endpoint, MemoryStore()).also { check(it.accept(it.beginIntent(), SecretTokens("fixture-access", "fixture-refresh", account))) }
        var scope = auth.capture()!!
            private set
        fun signIn(account: String) {
            check(auth.accept(auth.beginIntent(), SecretTokens("fixture-access", "fixture-refresh", account)))
            scope = requireNotNull(auth.capture())
        }
        val api = SoundQApi(auth, OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(), trust.trustManager).eventListener(listener).build(),
            com.soundq.android.data.acquisition.IntakeReceipts(), {}, { repository })
        val library = LibraryRepository(auth, api::library, api::like)
        var repository: OriginalImportRepository = build(true)
        fun reconstruct(writes: Boolean?) { repository = build(writes) }
        fun choice() = requireNotNull(repository.choose(scope, owner, display) { true })
        fun differentChoice() = requireNotNull(repository.choose(scope, otherOwner, display) { true })
        fun seedCapacity(dense: Boolean): OriginalImportEntry {
            val source = choice().intent
            val keep = OriginalImportEntry(source.copy(original = source.original.copy(
                revision = source.original.revision.copy(sha256 = "1".repeat(64)))), OriginalImportPhase.Closed)
            val text = if (dense) "a".repeat(350) else "a"
            val template = OriginalImportEntry(source.copy(operation = UUID(0, 1), display = ImportDisplay(text, text, text)),
                OriginalImportPhase.Refused)
            OriginalImportJournal(file).apply { put(keep, null) { true }; put(template, null) { true } }
            val sample = Json.parseToJsonElement(file.readText()).jsonObject.getValue("rows").jsonArray
            val row = sample.last().jsonObject
            fun bytes(n: Int) = buildJsonObject {
                put("version", 1)
                put("rows", buildJsonArray {
                    add(sample.first())
                    repeat(n) { i -> add(JsonObject(row + ("operation" to JsonPrimitive(UUID(0, i.toLong() + 1).toString())))) }
                })
            }.toString().encodeToByteArray()
            val encodedRowBytes = row.toString().encodeToByteArray().size + 1
            val count = if (dense) (2_000_000 - bytes(0).size) / encodedRowBytes else 4095
            var full = bytes(count)
            if (dense && 2_000_000 - full.size > 40) {
                var pad = 2_000_000 - full.size - 40
                val accepted = Json.parseToJsonElement(full.decodeToString()).jsonObject
                val rows = accepted.getValue("rows").jsonArray
                val first = rows.first().jsonObject.toMutableMap()
                for (field in listOf("title", "artist", "album")) {
                    val textBefore = first.getValue(field).jsonPrimitive.content
                    val extra = minOf(pad, 500 - textBefore.length)
                    first[field] = JsonPrimitive(textBefore + "a".repeat(extra))
                    pad -= extra
                }
                full = JsonObject(accepted + ("rows" to JsonArray(listOf(JsonObject(first)) + rows.drop(1)))).toString().encodeToByteArray()
            }
            assertTrue(full.size <= 2_000_000)
            if (dense) assertTrue(full.size >= 1_999_960 && count < 4095)
            file.writeBytes(full)
            return requireNotNull(OriginalImportJournal(file).apply { load() }.state.value.entry(keep.intent.operation))
        }
        fun added(): OriginalImportRepository.Choice = choice().also {
            server.enqueue(reply(201, receipt(it.intent.operation)))
            server.enqueue(reply(200, membership()))
            assertEquals(OriginalImportRepository.Action.Added, repository.confirm(it))
            assertEquals("POST", next("/api/v1/library/uploads").method)
            assertEquals("GET", next("/api/v1/library/tracks/77").method)
        }
        private fun build(writes: Boolean?) = OriginalImportRepository(auth, OriginalImportJournal(file), { original, current ->
            val audio = when (original) { owner -> bytes; otherOwner -> otherBytes; else -> error("unknown source") }
            object : ImportOriginalRead {
                override val length = audio.size.toLong()
                override fun checkCurrent() { check(current()) }
                override fun readAt(position: Long, bytes: ByteArray, count: Int): Int {
                    audio.copyInto(bytes, 0, position.toInt(), position.toInt() + count); return count
                }
                override fun close() {}
            }
        }, { it == owner || it == otherOwner }, onAdded = { captured, _ ->
            val observed = library.state.value
            if (library.projectionScope(observed)?.epoch == captured.epoch) library.refreshObserved(captured, observed)
        }).also {
            if (writes != null) it.installTransport(api.originalImportTransport(writes), writes)
            it.load()
        }
        fun reply(code: Int, json: String, location: String? = null): MockResponse = MockResponse.Builder().code(code).body(json)
            .setHeader("Cache-Control", "private, no-store").setHeader("Content-Type", "application/json")
            .apply { if (location != null) setHeader("Location", location) }.build()
        fun receipt(op: UUID, status: String = "committed"): String = buildJsonObject {
            put("account_id",account);put("operation_id",op.toString());put("status",status)
            if(status=="committed"){put("track_id",77);put("sha256","sha256:$sha");put("byte_length",bytes.size)}
        }.toString()
        fun membership(account: String = this.account, track: Int = 77, hash: String = sha, length: Int = bytes.size) = buildJsonObject {
            put("account_id",account);put("id",track);put("sha256","sha256:$hash");put("byte_length",length)
            put("title",display.title);put("artist",display.artist);put("album",display.album);put("duration_ms",13000);put("added_at","2026-11-20T19:00:00Z")
        }.toString()
        fun page(added: Boolean) = if (!added) """{"tracks":[],"total":0,"limit":20,"offset":0}""" else
            """{"tracks":[{"id":77,"title":"Accepted title","artist":"Accepted artist","album":"Accepted album","is_liked":true,"duration_ms":13000}],"total":1,"limit":20,"offset":0}"""
        fun next(path: String): RecordedRequest = requireNotNull(server.takeRequest(2, TimeUnit.SECONDS)).also {
            assertEquals(path, it.url.encodedPath)
            assertEquals("Bearer fixture-access", it.headers["Authorization"])
        }
        fun assertAllowedMultipart(request: RecordedRequest) {
            val contentType = requireNotNull(request.headers["Content-Type"])
            assertTrue(contentType.startsWith("multipart/form-data; boundary="))
            val boundary = contentType.substringAfter("boundary=")
            assertTrue(boundary.length in 1..70)
            assertNull(request.headers["Content-Encoding"])
            val raw = request.body!!.toByteArray().toString(Charsets.ISO_8859_1)
            val parts = raw.split("--$boundary")
            assertEquals(4, parts.size);assertEquals("",parts.first());assertEquals("--\r\n",parts.last())
            val manifest = parts[1].substringAfter("\r\n\r\n").removeSuffix("\r\n").toByteArray(Charsets.ISO_8859_1).decodeToString()
            assertTrue(parts[1].startsWith("\r\nContent-Disposition: form-data; name=\"manifest\"\r\nContent-Type: application/json\r\n"))
            assertTrue(parts[2].startsWith("\r\nContent-Disposition: form-data; name=\"audio\"\r\nContent-Type: audio/mpeg\r\n"))
            assertFalse(parts[1].contains("filename="));assertFalse(parts[2].substringBefore("\r\n\r\n").contains("filename="))
            val objectValue = Json.parseToJsonElement(manifest).jsonObject
            assertEquals(setOf("sha256","byte_length","title","artist","album"), objectValue.keys)
            assertEquals("sha256:$sha", objectValue.getValue("sha256").jsonPrimitive.content)
            assertEquals(bytes.size, objectValue.getValue("byte_length").jsonPrimitive.int)
            assertEquals(display.title, objectValue.getValue("title").jsonPrimitive.content)
            assertEquals(display.artist, objectValue.getValue("artist").jsonPrimitive.content)
            assertEquals(display.album, objectValue.getValue("album").jsonPrimitive.content)
            assertArrayEquals(bytes, parts[2].substringAfter("\r\n\r\n").removeSuffix("\r\n").toByteArray(Charsets.ISO_8859_1))
        }
        override fun close() = server.close()
    }
}
