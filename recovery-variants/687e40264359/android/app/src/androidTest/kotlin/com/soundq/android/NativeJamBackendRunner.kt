package com.soundq.android

import android.content.Intent
import android.os.Bundle
import androidx.test.runner.AndroidJUnitRunner
import com.soundq.android.data.*
import okhttp3.OkHttpClient
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.decodeCertificatePem
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Test APK only: explicit owned Go TLS origin and its public certificate.
 * No mock HTTP dispatcher, synthetic owner token, permissive verifier, or live
 * endpoint fallback. Memory credential storage is a declared test boundary. */
class NativeJamBackendRunner:AndroidJUnitRunner() {
    override fun newApplication(cl:ClassLoader,className:String,context:android.content.Context):android.app.Application =
        super.newApplication(cl,NativeJamBackendApplication::class.java.name,context)
    override fun onCreate(arguments:Bundle) {
        NativeJamBackendParameters.options=Bundle(arguments)
        super.onCreate(arguments)
    }
    override fun onStart() {
        val app=targetContext.applicationContext as NativeJamBackendApplication
        try {super.onStart()}finally {
            runOnMainSync {targetContext.stopService(Intent(targetContext,com.soundq.android.playback.SoundQLibraryService::class.java));app.graph.close()}
            app.fixtureClient.connectionPool.evictAll();app.fixtureClient.dispatcher.executorService.shutdown()
        }
    }
}
private object NativeJamBackendParameters {@Volatile var options:Bundle?=null}
class NativeJamBackendApplication:SoundQApplication() {
    lateinit var fixtureClient:OkHttpClient
        private set
    lateinit var callbackPlayer:androidx.media3.common.Player
        private set
    internal override fun createCallbackLibraryPlayer(
        grants:java.util.concurrent.ConcurrentHashMap<String,com.soundq.android.playback.MediaGrant>,
        jobs:kotlinx.coroutines.CoroutineScope,
    ):androidx.media3.common.Player=super.createCallbackLibraryPlayer(grants,jobs).also {callbackPlayer=it}
    override fun createGraph():AppGraph {
        val options=checkNotNull(NativeJamBackendParameters.options)
        val raw=checkNotNull(options.getString("nativeJamApi"));val uri=java.net.URI(raw)
        require(uri.scheme=="https"&&uri.host=="127.0.0.1"&&uri.port>0&&uri.path=="/api/v1"&&uri.rawUserInfo==null&&uri.rawQuery==null&&uri.rawFragment==null)
        val pem=String(java.util.Base64.getDecoder().decode(checkNotNull(options.getString("nativeJamCertificate"))),Charsets.UTF_8)
        val executor=Executors.newSingleThreadExecutor()
        val prepared=java.util.concurrent.atomic.AtomicReference<AppGraph?>()
        val abandoned=java.util.concurrent.atomic.AtomicBoolean(false)
        val future=executor.submit {
            val trust=HandshakeCertificates.Builder().addTrustedCertificate(pem.decodeCertificatePem()).build()
            fixtureClient=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager)
                .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).build()
            val graph=AppGraph(this,ApiEndpoint.parse(raw),fixtureClient,object:SessionStore {
                private var tokens:SecretTokens?=null
                @Synchronized override fun load(endpoint:ApiEndpoint)=tokens
                @Synchronized override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){this.tokens=tokens}
                @Synchronized override fun clear(){tokens=null}
            },fixtureClient)
            prepared.set(graph)
            if(abandoned.get()){graph.close();error("Native Jam bootstrap retired")}
        }
        try {future.get(10,TimeUnit.SECONDS);return checkNotNull(prepared.get())}
        catch(error:Exception){abandoned.set(true);future.cancel(true);prepared.get()?.close();throw error}
        finally {executor.shutdownNow();check(executor.awaitTermination(5,TimeUnit.SECONDS)){"Native Jam bootstrap did not retire"}}
    }
}
