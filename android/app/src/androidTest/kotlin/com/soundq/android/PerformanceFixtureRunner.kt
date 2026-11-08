package com.soundq.android

import com.soundq.android.data.*
import mockwebserver3.*
import okio.Buffer

/** Test-only four-source synthetic click/carrier fixture with measured spectral peaks. */
class PerformanceFixtureRunner:ProductFixtureRunner() {
    override val fixtureApplicationClass get()=PerformanceFixtureApplication::class.java.name
}
class PerformanceFixtureApplication:CallbackFrontendFixtureApplication() {
    internal val performanceCalls=HeldPerformancePublication()
    internal lateinit var performancePlayer:com.soundq.android.playback.nativeengine.NativeCallbackPlayer
    internal override fun createCallbackLibraryPlayer(
        grants:java.util.concurrent.ConcurrentHashMap<String,com.soundq.android.playback.MediaGrant>,
        jobs:kotlinx.coroutines.CoroutineScope,
    ):androidx.media3.common.Player = com.soundq.android.playback.nativeengine.NativeCallbackPlayer(graph,grants,jobs,calls=performanceCalls).also {performancePlayer=it}
    override fun getNoBackupFilesDir():java.io.File=java.io.File(super.getNoBackupFilesDir(),"performance-fixture").apply {mkdirs()}
    override fun prepareGraph(graph:AppGraph) {
        super.prepareGraph(graph)
        val assets=androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().context.assets
        val music=(1L..4L).associateWith {id->assets.open("performance/track-$id.mp3").use {it.readBytes()}}
        val analysis=(1L..4L).associateWith {id->assets.open("performance/track-$id-analysis.json").bufferedReader().use {it.readText()}}
        val previous=ProductTransportFixture.server.dispatcher
        ProductTransportFixture.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                val path=request.url.encodedPath
                if(path=="/api/v1/library") {
                    if(request.headers["Authorization"]!="Bearer synthetic-fixture-access")return MockResponse.Builder().code(401).build()
                    val rows=(1..4).joinToString(","){id->"""{"id":$id,"title":"Performance $id","artist":"Synthetic source","duration_ms":128000,"is_liked":false}"""}
                    return json("""{"tracks":[$rows],"total":4,"limit":20,"offset":0}""")
                }
                Regex("/api/v1/tracks/([1-4])/analysis").matchEntire(path)?.let {match->
                    if(request.headers["Authorization"]!="Bearer synthetic-fixture-access")return MockResponse.Builder().code(401).build()
                    return json(analysis.getValue(match.groupValues[1].toLong()))
                }
                if(path=="/api/v1/playback/urls") {
                    if(request.headers["Authorization"]!="Bearer synthetic-fixture-access")return MockResponse.Builder().code(401).build()
                    val raw=org.json.JSONObject(request.body!!.utf8()).getJSONArray("trackIds")
                    val urls=org.json.JSONArray()
                    repeat(raw.length()){index->val id=raw.getLong(index);val bytes=music.getValue(id)
                        urls.put(org.json.JSONObject().put("trackId",id).put("url",ProductTransportFixture.origin.resolve("/media/performance-$id.mp3").toString()).put("expiresAt","2030-01-01T00:00:00Z").put("contentType","audio/mpeg").put("sizeBytes",bytes.size))}
                    return json(org.json.JSONObject().put("urls",urls).toString())
                }
                Regex("/media/performance-([1-4]).mp3").matchEntire(path)?.let {match->
                    if(request.headers["Authorization"]!=null)return MockResponse.Builder().code(400).build()
                    val bytes=music.getValue(match.groupValues[1].toLong());val start=request.headers["Range"]?.substringAfter("bytes=")?.substringBefore('-')?.toIntOrNull() ?: 0
                    if(start !in 0..bytes.size)return MockResponse.Builder().code(416).build()
                    val response=MockResponse.Builder().code(if(start>0)206 else 200).addHeader("Content-Type","audio/mpeg").addHeader("Accept-Ranges","bytes")
                    if(start>0)response.addHeader("Content-Range","bytes $start-${bytes.size-1}/${bytes.size}")
                    return response.body(Buffer().write(bytes.copyOfRange(start,bytes.size))).build()
                }
                return previous.dispatch(request)
            }
        }
    }
    private fun json(body:String)=MockResponse.Builder().code(200).addHeader("Content-Type","application/json").body(body).build()
}

/** Hold only callback-state publication. Real JNI, native sync and audio keep
 * running; command admission must not be mistaken for this missing ACK. */
internal class HeldPerformancePublication:com.soundq.android.playback.nativeengine.NativeCallbackCalls by com.soundq.android.playback.nativeengine.JniNativeCallbackCalls {
    @Volatile private var latest:String?=null
    @Volatile private var held:String?=null
    val admissions=java.util.concurrent.atomic.AtomicInteger()
    val unlinks=java.util.concurrent.atomic.AtomicInteger()
    val scratchCalls=java.util.concurrent.CopyOnWriteArrayList<String>()
    override fun scratch(handle:Long,operation:Int,instance:Long,gesture:Long,eventNanos:Long,rate:Double):Boolean =
        com.soundq.android.playback.nativeengine.JniNativeCallbackCalls.scratch(handle,operation,instance,gesture,eventNanos,rate).also {
            if(scratchCalls.size<200)scratchCalls.add("$operation $eventNanos $it")
        }
    fun hold(){held=checkNotNull(latest)}
    fun release(){held=null}
    override fun state(handle:Long):String = held ?: com.soundq.android.playback.nativeengine.JniNativeCallbackCalls.state(handle).also {latest=it}
    override fun sync(handle:Long,incoming:Long,reference:Long,beats:Int,referenceBpm:Double,referenceAnchorMs:Double,referenceOriginMs:Double,incomingBpm:Double,incomingAnchorMs:Double,incomingOriginMs:Double):Boolean =
        com.soundq.android.playback.nativeengine.JniNativeCallbackCalls.sync(handle,incoming,reference,beats,referenceBpm,referenceAnchorMs,referenceOriginMs,incomingBpm,incomingAnchorMs,incomingOriginMs).also {if(it){if(beats>0)admissions.incrementAndGet() else unlinks.incrementAndGet()}}
}
