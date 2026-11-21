package com.soundq.android.data

import com.soundq.android.data.device.*
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.data.discovery.DiscoveryCalls
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit.SECONDS
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.RecordedRequest
import org.junit.Assert.*
import org.junit.Test

class LocalEnrichmentWireTest {
    private val terms = LocalEnrichmentTerms.reviewed("Reviewed 星", "Approved Artist", "Album only on server", 123_456)!!
    private val recording = "11111111-2222-4333-8444-555555555555"
    private val release = "22222222-2222-4333-8444-555555555555"
    private val group = "33333333-2222-4333-8444-555555555555"
    private val row = """{"recordingMbid":"$recording","title":"Corrected title","artist":"Corrected artist","album":"Corrected album","releaseMbid":"$release","releaseGroupMbid":"$group"}"""
    private val suggestion = """{"status":"suggestions","candidates":[$row]}"""

    private fun account(f: HttpsFixture): AccountSession = AccountSession(f.endpoint, MemoryStore()).apply { acceptOwner("owner") }
    private fun AccountSession.acceptOwner(id: String) { check(accept(beginIntent(), SecretTokens("fixture", "fixture-refresh", id))) }

    @Test fun exactReviewedBodyAndTypedOutputThroughCanonicalAuthenticatedTls() = HttpsFixture().use { f ->
        val session = account(f)
        val api = SoundQApi(session, f.client)
        f.server.enqueue(MockResponse.Builder().body(suggestion).build())
        assertEquals(0, f.server.requestCount)
        val reply = api.localEnrichment(session.capture()!!, terms, DiscoveryCalls()) { true } as LocalEnrichmentReply.Suggestions
        val request = checkNotNull(f.server.takeRequest(2, SECONDS))
        assertEquals("POST", request.method)
        assertEquals("/api/v1/musicbrainz/local-enrichment/suggestions", request.target)
        assertEquals("Bearer fixture", request.headers["Authorization"])
        assertEquals("no-store", request.headers["Cache-Control"])
        assertEquals("""{"title":"Reviewed 星","artist":"Approved Artist","album":"Album only on server","durationMs":123456}""", request.body!!.utf8())
        assertEquals(1, f.server.requestCount)
        val parsed = reply.candidates.single()
        assertEquals(recording, parsed.recording.value)
        assertEquals(release, parsed.release?.value)
        assertEquals(group, parsed.releaseGroup?.value)
        assertEquals(LocalDisplayText("Corrected title", "Corrected artist", "Corrected album"), parsed.text)
    }

    @Test fun offAmbiguousNoMatchAndFailuresCannotOfferASelectionAndDoNotReplay() = HttpsFixture().use { f ->
        val session = account(f)
        val api = SoundQApi(session, f.client)
        val ambiguous = """{"status":"ambiguous","reason":"similar_candidates","candidates":[$row,${row.replace(recording, release)}]}"""
        val cases = listOf(
            Triple(404, "private error content", LocalEnrichmentReply.Disabled),
            Triple(401, "private error content", LocalEnrichmentReply.SignIn),
            Triple(429, "private error content", LocalEnrichmentReply.Busy),
            Triple(503, "private error content", LocalEnrichmentReply.Unavailable),
            Triple(200, """{"status":"no_match","candidates":[]}""", LocalEnrichmentReply.NoMatch),
            Triple(200, ambiguous, LocalEnrichmentReply.Ambiguous),
            Triple(200, suggestion.replace(recording, "00000000-0000-0000-0000-000000000000"), LocalEnrichmentReply.Unavailable),
            Triple(200, suggestion.replace("\"title\":", "\"artworkUrl\":\"https://fixture.invalid/image\",\"title\":"), LocalEnrichmentReply.Unavailable),
            Triple(200, suggestion + " ".repeat(33_000), LocalEnrichmentReply.Unavailable),
            Triple(307, "", LocalEnrichmentReply.Unavailable),
        )
        cases.forEachIndexed { ordinal, (status, payload, expected) ->
            val response = MockResponse.Builder().code(status).body(payload)
            if (status == 503) response.addHeader("Retry-After", "0")
            if (status == 307) response.addHeader("Location", "https://fixture.invalid/never")
            f.server.enqueue(response.build())
            assertSame(expected, api.localEnrichment(session.capture()!!, terms, DiscoveryCalls()) { true })
            assertEquals(ordinal + 1, f.server.requestCount)
            assertEquals("/api/v1/musicbrainz/local-enrichment/suggestions", f.server.takeRequest(2, SECONDS)?.target)
        }
    }

    @Test fun accountAbaDropsHeldReplyAndFreshSameAccountCanLookUp() = HttpsFixture().use { f ->
        val entered = CountDownLatch(1)
        val releaseHeld = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        val session = account(f)
        val capture = session.capture()!!
        val api = SoundQApi(session, f.client)
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                entered.countDown()
                check(releaseHeld.await(5, SECONDS))
                return MockResponse.Builder().body(suggestion).build()
            }
        }
        try {
            val result = executor.submit<SafeFailure.Reason> {
                assertThrows(SafeFailure::class.java) { api.localEnrichment(capture, terms, DiscoveryCalls()) { true } }.reason
            }
            assertTrue(entered.await(3, SECONDS))
            session.acceptOwner("other-owner")
            session.acceptOwner("owner")
            releaseHeld.countDown()
            assertEquals(SafeFailure.Reason.Retired, result.get(3, SECONDS))
            assertThrows(SafeFailure::class.java) { api.localEnrichment(capture, terms, DiscoveryCalls()) { true } }
            assertEquals(1, f.server.requestCount)
            assertTrue(api.localEnrichment(session.capture()!!, terms, DiscoveryCalls()) { true } is LocalEnrichmentReply.Suggestions)
            assertEquals(2, f.server.requestCount)
        } finally {
            releaseHeld.countDown()
            executor.shutdownNow()
        }
    }

    @Test fun draftDoesNotLeakLocationOrIdentifiersAndNeverAltersApprovedTerms() {
        val original = OriginalMetadata("Safe basename.flac", null, "content://media/12", "sha256:" + "b".repeat(64), "private art sentinel")
        val device = DeviceAudio(DeviceFileId(UUID.randomUUID()), ProviderObjectId("test", "private object"), ContentRevision("a".repeat(64), 123), 1,
            original, 300, listOf(LocatorAccess(ScanGrantId(UUID.randomUUID()), ProviderLocator("test", "/private/parent/file.flac"), AccessState.AVAILABLE)))
        val draft = LocalEnrichmentDraft.from(device)
        assertEquals("Safe basename", draft.title)
        assertEquals("", draft.artist)
        assertEquals("", draft.album)
        assertEquals("""{"title":"Safe basename"}""", LocalEnrichmentTerms.reviewed(draft.title, draft.artist, draft.album, null)!!.json().toString())
        assertEquals("", LocalEnrichmentDraft.from(device.copy(metadata = original.copy(filename = "/secret/Safe basename.flac"))).title)
        val indexed = device.copy(metadata = original.copy(album = "Private directory fallback", title = original.filename))
        assertEquals("Safe basename", LocalEnrichmentDraft.from(indexed).title)
        assertEquals("", LocalEnrichmentDraft.from(indexed).album)
        assertEquals("Accepted album", LocalEnrichmentDraft.from(indexed.copy(displayOverride =
            LocalDisplayOverride(1, LocalDisplayText(null, null, "Accepted album")))).album)
        val invalid = listOf("path/song", "path／song", "content:secret", "a".repeat(64), recording, "song.flac", "song%2Ftitle", "name@example.org", "line\nbreak", "前\u202E後", "  not as reviewed  ")
        invalid.forEach { assertNull(LocalEnrichmentTerms.reviewed(it, "", "", null)) }
        assertNull(LocalEnrichmentTerms.reviewed("a".repeat(201), "", "", null))
        assertNull(LocalEnrichmentTerms.reviewed("a".repeat(200), "b".repeat(200), "c".repeat(51), null))
        assertEquals("Café 星", LocalEnrichmentTerms.reviewed("Café 星", "", "", null)!!.title)
    }
}
