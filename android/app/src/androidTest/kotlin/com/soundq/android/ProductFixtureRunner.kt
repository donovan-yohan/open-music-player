package com.soundq.android

import android.content.Intent
import android.os.Looper
import okhttp3.HttpUrl
import java.net.InetAddress
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.AndroidJUnitRunner
import com.soundq.android.data.*
import mockwebserver3.*
import okhttp3.OkHttpClient
import okhttp3.tls.*
import okio.Buffer
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CopyOnWriteArrayList

/** Test APK only. HTTPS server, generated WAV and synthetic identity; no production endpoint switching. */
open class ProductFixtureRunner:AndroidJUnitRunner() {
    protected open val fixtureApplicationClass get()=FixtureApplication::class.java.name
    override fun newApplication(cl:ClassLoader,className:String,context:android.content.Context):android.app.Application =
        super.newApplication(cl,fixtureApplicationClass,context)
    override fun onStart() {
        // Queued behind Application.onCreate on the actual main looper; tests cannot start early.
        runOnMainSync {
            val app=targetContext.applicationContext as FixtureApplication
            check(app.graph.endpoint.identity==ProductTransportFixture.endpoint.identity)
            check(ProductTransportFixture.networkingStayedOffMain && !app.bootstrapThread.isAlive)
        }
        val context=targetContext
        val app=context.applicationContext as FixtureApplication
        try {super.onStart()}finally {
            runOnMainSync {context.stopService(Intent(context,com.soundq.android.playback.SoundQLibraryService::class.java));app.graph.close()}
            ProductTransportFixture.server.close();app.fixtureClient.connectionPool.evictAll();app.fixtureClient.dispatcher.executorService.shutdown()
        }
    }
}
/** Installed only by this test runner: production graph/endpoint/Keystore never start. */
open class FixtureApplication:SoundQApplication() {
    protected open fun prepareGraph(graph:AppGraph) {}
    lateinit var fixtureClient:OkHttpClient
        private set
    lateinit var bootstrapThread:Thread
        private set
    var graphCreatedOnMain=false
        private set
    override fun createGraph():AppGraph {
        graphCreatedOnMain=Looper.myLooper()==Looper.getMainLooper()
        check(graphCreatedOnMain)
        // newApplication and Application.onCreate are both main-thread framework callbacks.
        // Finish the entire networking/URL phase before returning the graph to onCreate.
        val executor=Executors.newSingleThreadExecutor {task -> Thread(task,"soundq-fixture-bootstrap").also {bootstrapThread=it}}
        val prepared=java.util.concurrent.atomic.AtomicReference<AppGraph?>()
        val abandoned=java.util.concurrent.atomic.AtomicBoolean(false)
        val future=executor.submit {
            try {
                ProductTransportFixture.start()
                val trust=HandshakeCertificates.Builder().addTrustedCertificate(ProductTransportFixture.certificate.certificate).build()
                fixtureClient=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager).followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).build()
                prepared.set(AppGraph(this,ProductTransportFixture.endpoint,fixtureClient,object:SessionStore {
                    private var tokens:SecretTokens?=null
                    override fun load(endpoint:ApiEndpoint)=tokens
                    override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){this.tokens=tokens}
                    override fun clear(){tokens=null}
                },fixtureClient).also {graph ->
                    graph.directory.listFiles()?.filter {it.name.startsWith("queue-")}?.forEach {it.delete()}
                    prepareGraph(graph)
                })
                check(!abandoned.get()){"Fixture bootstrap retired before publication"}
            } catch(failure:Throwable) {
                try {closeFixture(prepared.get())}catch(cleanup:Throwable){failure.addSuppressed(cleanup)}
                throw failure
            }
        }
        try {
            try {future.get(10,TimeUnit.SECONDS)}catch(failure:ExecutionException){throw failure.cause ?: failure}
            executor.shutdown()
            check(executor.awaitTermination(5,TimeUnit.SECONDS)){"Fixture bootstrap executor did not retire"}
            bootstrapThread.join(TimeUnit.SECONDS.toMillis(5))
            check(!bootstrapThread.isAlive){"Fixture bootstrap thread did not retire"}
            return checkNotNull(prepared.get())
        } catch(failure:Throwable) {
            abandoned.set(true)
            future.cancel(true);executor.shutdownNow()
            try {
                val executorRetired=executor.awaitTermination(5,TimeUnit.SECONDS)
                bootstrapThread.join(TimeUnit.SECONDS.toMillis(5))
                val retired=executorRetired && !bootstrapThread.isAlive
                try {closeFixture(prepared.get())}finally {
                    check(retired){"Fixture bootstrap cleanup did not retire"}
                }
            } catch(cleanup:Throwable){failure.addSuppressed(cleanup)}
            throw failure
        }
    }
    private fun closeFixture(graph:AppGraph?) {
        graph?.close()
        try {ProductTransportFixture.close()}finally {
            if(::fixtureClient.isInitialized) {
                fixtureClient.connectionPool.evictAll()
                fixtureClient.dispatcher.executorService.shutdownNow()
            }
        }
    }
}
object ProductTransportFixture {
    lateinit var server:MockWebServer
    lateinit var origin:HttpUrl
        private set
    lateinit var endpoint:ApiEndpoint
        private set
    @Volatile var networkingStayedOffMain=false
        private set
    private fun requireIo() {
        check(Looper.myLooper()!=Looper.getMainLooper()){"Fixture networking must not run on main"}
    }
    fun close() {if(::server.isInitialized)server.close()}
    val certificate=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
    val requests=CopyOnWriteArrayList<String>()
    val recordedPlays=CopyOnWriteArrayList<Long>()
    @Volatile var liked=false
    var audioDurationMs=12000L
    private val wav:ByteArray by lazy {
        val rate=16000;val samples=(rate*audioDurationMs/1000).toInt();val bytes=samples*2
        val b=ByteBuffer.allocate(44+bytes).order(ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray()).putInt(36+bytes).put("WAVEfmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(rate).putInt(rate*2).putShort(2).putShort(16).put("data".toByteArray()).putInt(bytes)
        repeat(samples){i -> b.putShort((kotlin.math.sin(i*2*Math.PI*220/rate)*800).toInt().toShort())};b.array()
    }
    fun start() {
        requireIo()
        server=MockWebServer();server.useHttps(HandshakeCertificates.Builder().heldCertificate(certificate).build().sslSocketFactory())
        server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
            requests.add(request.method+" "+request.url.encodedPath)
            val path=request.url.encodedPath
            if(path.startsWith("/media/")) {
                if(request.headers["Authorization"]!=null)return MockResponse.Builder().code(400).build()
                val start=request.headers["Range"]?.substringAfter("bytes=")?.substringBefore('-')?.toIntOrNull() ?: 0
                val body=wav.copyOfRange(start.coerceIn(0,wav.size),wav.size)
                val response=MockResponse.Builder().code(if(start>0)206 else 200).addHeader("Content-Type","audio/wav").addHeader("Accept-Ranges","bytes")
                if(start>0)response.addHeader("Content-Range","bytes $start-${wav.size-1}/${wav.size}")
                return response.body(Buffer().write(body)).build()
            }
            if(path in listOf("/api/v1/auth/login","/api/v1/auth/register","/api/v1/auth/refresh"))return reply("""{"accessToken":"synthetic-fixture-access","refreshToken":"synthetic-fixture-refresh","user":{"id":"fixture-account"}}""",if(path.endsWith("register"))201 else 200)
            if(request.headers["Authorization"]!="Bearer synthetic-fixture-access")return reply("{}",401)
            if(path=="/api/v1/auth/logout")return reply("{}",204)
            if(path=="/api/v1/me/plays") {
                if(request.method!="POST")return reply("{}",405)
                val id=org.json.JSONObject(request.body!!.utf8()).getLong("trackId")
                recordedPlays.add(id)
                return reply("""{"trackId":$id,"played":true}""",201)
            }
            if(path.endsWith("/like")){liked=request.method=="POST";return reply("{}",204)}
            if(path=="/api/v1/library") {
                val offset=request.url.queryParameter("offset")?.toIntOrNull() ?: 0
                val query=request.url.queryParameter("q").orEmpty()
                val count=if(request.url.queryParameter("liked")=="true"&&!liked)0 else 3
                // Like the server, total counts the query's matches, so a refined list pages to its end.
                val matches=(1..count).filter {"Fixture $it".contains(query,true)||query.isBlank()}
                val rows=matches.filter {offset==0}.joinToString(",") {"""{"id":$it,"title":"Fixture $it","artist":"Synthetic ensemble","duration_ms":12000,"is_liked":$liked}"""}
                return reply("""{"tracks":[$rows],"total":${matches.size},"limit":20,"offset":$offset}""")
            }
            if(path=="/api/v1/playback/urls") {
                val body=request.body!!.utf8();val id=Regex("\\[([0-9]+)\\]").find(body)?.groupValues?.get(1) ?: "1"
                return reply("""{"urls":[{"trackId":$id,"url":"${origin.resolve("/media/$id.wav")}","expiresAt":"2030-01-01T00:00:00Z","contentType":"audio/wav","sizeBytes":${wav.size}}]}""")
            }
            return reply("{}",404)
        }}
        requireIo()
        server.start(InetAddress.getByAddress("localhost",byteArrayOf(127,0,0,1)),0)
        requireIo()
        origin=HttpUrl.Builder().scheme("https").host("localhost").port(server.port).build()
        endpoint=ApiEndpoint.parse(origin.resolve("/api/v1")!!.toString())
        networkingStayedOffMain=true
    }
    private fun reply(body:String,code:Int=200):MockResponse {val response=MockResponse.Builder().code(code).addHeader("Content-Type","application/json");if(code!=204)response.body(body);return response.build()}
}
