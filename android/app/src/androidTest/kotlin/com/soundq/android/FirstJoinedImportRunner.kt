package com.soundq.android

import android.app.Application
import android.content.Context
import android.os.Bundle
import androidx.test.runner.AndroidJUnitRunner
import com.soundq.android.data.ApiEndpoint
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.decodeCertificatePem
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.Proxy
import java.net.URI
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList

/** Test-APK runner for one owned, externally supervised Go TLS journey. No fallback endpoints. */
class FirstJoinedImportRunner : AndroidJUnitRunner() {
    override fun newApplication(cl: ClassLoader, className: String, context: Context): Application =
        super.newApplication(cl, FirstJoinedImportApplication::class.java.name, context)

    override fun onCreate(arguments: Bundle) {
        check(arguments.getString("joinGrant") == "owned-go-private-import-v1")
        val phase = requireNotNull(arguments.getString("joinPhase"))
        val method = when (phase) {
            "submit" -> "mountedClickSnapshotSurvivesLaterApplyAndLostAck"
            "recover" -> "mountedRecoveryAfterProcessRestartReadsOnlyOriginalOperation"
            else -> error("Unknown joined-import phase")
        }
        check(arguments.getString("class") == "com.soundq.android.FirstJoinedImportJourneyTest#$method")
        FirstJoinedImportApplication.phase = phase
        super.onCreate(arguments)
    }
}

class FirstJoinedImportApplication : SoundQApplication() {
    internal class Settings(val origin: String, val account: String, val email: String, val password: String,
        val publicCertificateBase64: String)
    internal data class Exchange(val method: String, val path: String, val uuid: String?, val status: Int?)
    internal val observed = CopyOnWriteArrayList<Exchange>()
    internal lateinit var settings: Settings
        private set

    override fun createGraph(): AppGraph {
        check(packageName == "com.soundq.android.dev.importjoin" && phase in setOf("submit", "recover"))
        val input = File(filesDir, "first-joined-import-fixture.json")
        check(input.isFile && input.length() in 1..12_288)
        val fields = JSONObject(input.readText())
        check(fields.keys().asSequence().toSet() == setOf("origin", "account", "email", "password", "publicCertificateBase64"))
        val origin = fields.getString("origin")
        val uri = URI(origin)
        check(uri.scheme == "https" && uri.host == "127.0.0.1" && uri.port in 1..65535 && uri.rawPath == "/api/v1" &&
            uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null && origin == "https://127.0.0.1:${uri.port}/api/v1")
        val owner = fields.getString("account")
        check(UUID.fromString(owner).toString() == owner && owner != "00000000-0000-0000-0000-000000000000")
        val email = fields.getString("email")
        val password = fields.getString("password")
        check(email.matches(Regex("[a-z0-9.+-]{1,64}@example\\.test")) && password.length in 12..128)
        val cert = fields.getString("publicCertificateBase64")
        val pem = String(Base64.getDecoder().decode(cert), Charsets.US_ASCII)
        check(Regex("\\A-----BEGIN CERTIFICATE-----[\\r\\n]+[A-Za-z0-9+/=\\r\\n]+-----END CERTIFICATE-----[\\r\\n]*\\z").matches(pem))
        settings = Settings(origin, owner, email, password, cert)
        val trust = HandshakeCertificates.Builder().addTrustedCertificate(pem.decodeCertificatePem()).build()
        val client = OkHttpClient.Builder().proxy(Proxy.NO_PROXY).protocols(listOf(Protocol.HTTP_1_1))
            .sslSocketFactory(trust.sslSocketFactory(), trust.trustManager)
            .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
            .addInterceptor { chain ->
                val url = chain.request().url
                if (url.scheme != "https" || url.host != "127.0.0.1" || url.port != uri.port) {
                    observed.add(Exchange("BLOCKED", "outside-fixture-origin", null, null))
                    throw IOException("Request outside owned fixture origin")
                }
                chain.proceed(chain.request())
            }
            .addNetworkInterceptor { chain ->
                val request = chain.request()
                val path = request.url.encodedPath
                // Never read/write the one-shot body or retain any auth header.
                val uuid = request.header("Idempotency-Key")?.takeIf { path == "/api/v1/library/uploads" }
                var status: Int? = null
                try { chain.proceed(request).also { status = it.code } }
                finally { observed.add(Exchange(request.method, path, uuid, status)) }
            }
            .build()
        // Keep the product's encrypted session and durable app state across a real process restart.
        // The client still exposes its normal write affordance in phase two; Go must be readback-only.
        return AppGraph(this, ApiEndpoint.parse(origin), apiClient = client, mediaClient = client,
            originalImportFixtureMode = "fixture")
    }

    internal companion object { @Volatile var phase: String? = null }
}
