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

    private fun fixture() = Fixture(temp.newFolder())
    private class Fixture(dir: File) : AutoCloseable {
        val account = "a85209c6-2c36-42ac-88b5-a3440838f66c"
        val server = MockWebServer()
        val bytes = System.getenv("SOUNDQ_ORIGINAL_IMPORT_QA")?.let { File(it, "original.mp3").readBytes() }
            ?: byteArrayOf(0, 0xff.toByte(), 10, 13, 22, 19, 8)
        val sha = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        val owner = ContentOwner(HistoryKey.Device(DeviceFileId(UUID.randomUUID())), ContentRevision(sha, bytes.size.toLong()), 1)
        val display = ImportDisplay("Accepted title", "Accepted artist", "Accepted album")
        private val file = File(dir, "journal.json")
        private val cert = HeldCertificate.Builder().addSubjectAlternativeName("127.0.0.1").build()
        private val trust = HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        init { server.useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory()); server.start(java.net.InetAddress.getByName("127.0.0.1"), 0) }
        val endpoint = ApiEndpoint.parse(server.url("/api/v1").newBuilder().host("127.0.0.1").build().toString())
        private val auth = AccountSession(endpoint, MemoryStore()).also { check(it.accept(it.beginIntent(), SecretTokens("fixture-access", "fixture-refresh", account))) }
        val scope = auth.capture()!!
        private val api = SoundQApi(auth, OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(), trust.trustManager).build())
        val library = LibraryRepository(auth, api::library, api::like)
        var repository = build(true)
        fun reconstruct(writes: Boolean?) { repository = build(writes) }
        fun choice() = requireNotNull(repository.choose(scope, owner, display) { true })
        fun added(): OriginalImportRepository.Choice = choice().also {
            server.enqueue(reply(201, receipt(it.intent.operation)))
            server.enqueue(reply(200, membership()))
            assertEquals(OriginalImportRepository.Action.Added, repository.confirm(it))
            assertEquals("POST", next("/api/v1/library/uploads").method)
            assertEquals("GET", next("/api/v1/library/tracks/77").method)
        }
        private fun build(writes: Boolean?) = OriginalImportRepository(auth, OriginalImportJournal(file), { original, current ->
            check(original == owner)
            object : ImportOriginalRead {
                override val length = bytes.size.toLong()
                override fun checkCurrent() { check(current()) }
                override fun readAt(position: Long, bytes: ByteArray, count: Int): Int {
                    this@Fixture.bytes.copyInto(bytes, 0, position.toInt(), position.toInt() + count); return count
                }
                override fun close() {}
            }
        }, { it == owner }, onAdded = { captured, _ ->
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
