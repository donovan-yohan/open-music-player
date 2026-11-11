package com.soundq.android.data

import mockwebserver3.MockWebServer
import mockwebserver3.MockResponse
import okhttp3.OkHttpClient
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class ApiTest {
    @Test fun acknowledgedLikeUsesRealHttpThenInvalidatesAndReadsBack() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","fixture"))
            val api=SoundQApi(session,f.client)
            val repository=LibraryRepository(session,api::library,api::like)
            fun page(liked:Boolean)="""{"tracks":[{"id":7,"title":"Fixture","is_liked":$liked}],"total":1,"limit":20,"offset":0}"""
            f.reply(page(false));repository.refine(LibraryQuery())
            val row=repository.state.value.rows.single()
            f.reply("{}",204);f.reply(page(true))
            repository.like(row)
            assertEquals(true,repository.state.value.rows.single().liked)
            assertEquals(MutationOutcome.Confirmed,repository.state.value.mutations[TrackId(7)])
            val paths=(1..3).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!.let {it.method+" "+it.url.encodedPath}}
            assertEquals(listOf("GET /api/v1/library","POST /api/v1/library/tracks/7/like","GET /api/v1/library"),paths)
        }
    }
    @Test fun descriptorUnavailableAndInvalidExpiryAreSafeFailures() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","fixture"))
            val api=SoundQApi(session,f.client);val scope=session.capture()!!
            f.reply("""{"urls":[],"unavailable":[{"trackId":7,"code":"audio_unavailable"}]}""")
            assertEquals(SafeFailure.Reason.AudioUnavailable,(runCatching {api.descriptor(scope,TrackId(7))}.exceptionOrNull() as SafeFailure).reason)
            f.reply("""{"urls":[{"trackId":7,"url":"https://media.invalid/audio?signature=test-only","expiresAt":"2020-01-01T00:00:00Z"}]}""")
            val error=runCatching {api.descriptor(scope,TrackId(7))}.exceptionOrNull()!!
            assertFalse(error.toString().contains("signature"));assertFalse(error.toString().contains("media.invalid"))
        }
    }
    @Test fun realHttpsLoginThenScopedPagedLibrary() {
        val cert = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val server = MockWebServer()
        server.useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory())
        server.start()
        try {
            val trust = HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
            val session = AccountSession(ApiEndpoint.parse(server.url("/api/v1").toString()), MemoryStore())
            val api = SoundQApi(session, OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(), trust.trustManager).build())
            server.enqueue(MockResponse.Builder().code(200).body("""{"accessToken":"synthetic-a","refreshToken":"synthetic-r","user":{"id":"fixture-account"}}""").build())
            assertTrue(api.authenticate("fixture@example.test", "test-only-password"))
            val login = server.takeRequest(2, TimeUnit.SECONDS)!!
            assertEquals("/api/v1/auth/login", login.url.encodedPath)
            assertNull(login.headers["Authorization"])
            assertTrue(login.body!!.utf8().contains("test-only-password"))
            server.enqueue(MockResponse.Builder().code(200).body("""{"tracks":[{"id":7,"title":"海辺 — Étude","artist":"Fixture","is_liked":true}],"total":51,"limit":20,"offset":20}""").build())
            val page = api.library(session.capture()!!, LibraryQuery(text="海", liked=true, sort=LibrarySort.Title, ascending=true),20)
            assertEquals(51,page.total); assertEquals(true,page.tracks.single().liked)
            val request = server.takeRequest(2,TimeUnit.SECONDS)!!
            assertEquals("Bearer synthetic-a",request.headers["Authorization"])
            assertEquals("20",request.url.queryParameter("offset")); assertEquals("海",request.url.queryParameter("q"))
            assertEquals("true",request.url.queryParameter("liked"))
        } finally { server.close() }
    }
}
