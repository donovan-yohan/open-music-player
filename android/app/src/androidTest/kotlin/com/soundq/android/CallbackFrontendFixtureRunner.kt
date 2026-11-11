package com.soundq.android

import android.os.Bundle
import com.soundq.android.AppGraph
import mockwebserver3.*
import okio.Buffer

/** Test APK only. Real MP3 music over fixture TLS, same product graph and player. */
class CallbackFrontendFixtureRunner : ProductFixtureRunner() {
    override val fixtureApplicationClass get()=CallbackFrontendFixtureApplication::class.java.name
}

open class CallbackFrontendFixtureApplication : FixtureApplication() {
    lateinit var callbackPlayer: androidx.media3.common.Player
        private set
    internal override fun createCallbackLibraryPlayer(
        grants: java.util.concurrent.ConcurrentHashMap<String, com.soundq.android.playback.MediaGrant>,
        jobs: kotlinx.coroutines.CoroutineScope,
    ): androidx.media3.common.Player = super.createCallbackLibraryPlayer(grants, jobs).also { callbackPlayer = it }

    override fun prepareGraph(graph:AppGraph) {
        val context=androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().context
        val music=context.assets.open("callback/frontend.mp3").use {it.readBytes()}
        val analysis=context.assets.open("callback/frontend-analysis.json").bufferedReader().use {org.json.JSONObject(it.readText())}
        check(music.size in 1..2*1024*1024)
        val original=ProductTransportFixture.server.dispatcher
        ProductTransportFixture.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                val path=request.url.encodedPath
                val analysisTrack=Regex("/api/v1/tracks/([0-9]+)/analysis").matchEntire(path)?.groupValues?.get(1)?.toLong()
                if(analysisTrack!=null) {
                    ProductTransportFixture.requests.add(request.method+" "+path)
                    if(request.headers["Authorization"]!="Bearer synthetic-fixture-access")return MockResponse.Builder().code(401).build()
                    return MockResponse.Builder().code(200).addHeader("Content-Type","application/json")
                        .body(org.json.JSONObject(analysis.toString()).put("track_id",analysisTrack).toString()).build()
                }
                if(path.startsWith("/media/")) {
                    ProductTransportFixture.requests.add(request.method+" "+path)
                    if(request.headers["Authorization"]!=null)return MockResponse.Builder().code(400).build()
                    val start=request.headers["Range"]?.substringAfter("bytes=")?.substringBefore('-')?.toIntOrNull() ?: 0
                    if(start !in 0..music.size)return MockResponse.Builder().code(416).build()
                    val response=MockResponse.Builder().code(if(start>0)206 else 200)
                        .addHeader("Content-Type","audio/mpeg").addHeader("Accept-Ranges","bytes")
                    if(start>0)response.addHeader("Content-Range","bytes $start-${music.size-1}/${music.size}")
                    return response.body(Buffer().write(music.copyOfRange(start,music.size))).build()
                }
                if(path=="/api/v1/playback/urls") {
                    ProductTransportFixture.requests.add(request.method+" "+path)
                    if(request.headers["Authorization"]!="Bearer synthetic-fixture-access")return MockResponse.Builder().code(401).build()
                    val body=request.body!!.utf8()
                    val id=Regex("\\[([0-9]+)\\]").find(body)?.groupValues?.get(1) ?: error("Missing fixture track")
                    val json="""{"urls":[{"trackId":$id,"url":"${ProductTransportFixture.origin.resolve("/media/$id.mp3")}","expiresAt":"2030-01-01T00:00:00Z","contentType":"audio/mpeg","sizeBytes":${music.size}}]}"""
                    return MockResponse.Builder().code(200).addHeader("Content-Type","application/json").body(json).build()
                }
                return original.dispatch(request)
            }
        }
    }
}

/** Separate synthetic queue/draft files from the installed user's current work. */
class IsolatedCallbackFixtureApplication : CallbackFrontendFixtureApplication() {
    override fun getNoBackupFilesDir():java.io.File = java.io.File(super.getNoBackupFilesDir(),"overlap-fixture").apply {mkdirs()}
}
class IsolatedCallbackFixtureRunner : ProductFixtureRunner() {
    override val fixtureApplicationClass get()=IsolatedCallbackFixtureApplication::class.java.name
}
