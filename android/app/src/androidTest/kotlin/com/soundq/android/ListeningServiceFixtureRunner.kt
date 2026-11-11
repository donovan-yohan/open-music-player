package com.soundq.android

import android.os.Looper
import androidx.media3.common.*
import androidx.media3.exoplayer.ExoPlayer
import com.soundq.android.data.*
import com.soundq.android.playback.MediaGrant
import com.soundq.android.playback.listening.ListeningServicePlayer
import kotlinx.coroutines.*
import mockwebserver3.*
import java.util.concurrent.*

/** Explicit test component only. Selection is fixed before Application.onCreate / graph.start. */
class ListeningServiceFixtureRunner:ProductFixtureRunner() {
 override val fixtureApplicationClass get()=ListeningServiceFixtureApplication::class.java.name
}
class ListeningServiceFixtureApplication:FixtureApplication() {
 internal data class Construction(val output:ExoPlayer,val player:ListeningServicePlayer,val grants:ConcurrentHashMap<String,MediaGrant>,val jobs:CoroutineScope) {
  val completions=mutableListOf<String>()
  var appendedLocal:Long?=null
  val renders=mutableSetOf<com.soundq.android.playback.listening.PreparedListening>()
  fun observeRender() {
   val field=ListeningServicePlayer::class.java.getDeclaredField("prepared").apply{isAccessible=true}
   (field.get(player) as? com.soundq.android.playback.listening.PreparedListening)?.let(renders::add)
  }
 }
 internal val constructions=mutableListOf<Construction>()
 override fun createLibraryPlayer(output:ExoPlayer,grants:ConcurrentHashMap<String,MediaGrant>,jobs:CoroutineScope):Player {
  check(Looper.myLooper()==Looper.getMainLooper())
  val selected=ListeningServicePlayer.createRollingMp3(output,graph,grants,jobs,1000)
  val captured=Construction(output,selected,grants,jobs)
  constructions+=captured
  selected.addCompletionListener{captured.completions+=it.mediaId}
  selected.addListener(object:Player.Listener {
   override fun onTimelineChanged(timeline:Timeline,reason:Int){if(selected.mediaItemCount==5 && captured.appendedLocal==null)captured.appendedLocal=selected.currentPosition}
   override fun onEvents(player:Player,events:Player.Events){captured.observeRender()}
  })
  return selected
 }
 override fun prepareGraph(graph:AppGraph) {
  // Off-main, before graph.start can bind any service/controller. Other cohorts retain WAV.
  check(Looper.myLooper()!=Looper.getMainLooper())
  ListeningServiceTransport.install(ProductTransportFixture.server)
 }
}
/** Authenticated library only. Real MP3 acquisition is warmed through TemporaryAudioCache, not HTTP. */
internal object ListeningServiceTransport {
 val selectors=CopyOnWriteArrayList<RecordedRequest>()
 val searches=CopyOnWriteArrayList<RecordedRequest>()
 @Volatile var entered=CountDownLatch(1)
 @Volatile var release=CountDownLatch(0)
 @Volatile var hold=false
 fun reset(held:Boolean=false){selectors.clear();hold=held;entered=CountDownLatch(1);release=CountDownLatch(if(held)1 else 0)}
 fun install(server:MockWebServer) {
  val ordinary=server.dispatcher
  server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
   if(request.url.encodedPath!="/api/v1/library")return ordinary.dispatch(request)
   check(request.headers["Authorization"]=="Bearer synthetic-fixture-access")
   val limit=request.url.queryParameter("limit")?.toInt() ?: 20
   val offset=request.url.queryParameter("offset")?.toInt() ?: 0
   val continuation=limit==100 && request.url.queryParameter("q").isNullOrBlank()
   if(!request.url.queryParameter("q").isNullOrBlank())searches+=request
   if(continuation){selectors+=request;entered.countDown();check(release.await(15,TimeUnit.SECONDS))}
   val ids=if(continuation)listOf(90,91) else listOf(1,2,3)
   val query=request.url.queryParameter("q").orEmpty()
   val rows=ids.filter{offset==0 && (query.isBlank() || "Fixture $it".contains(query,true))}.joinToString(","){"""{"id":$it,"title":"Fixture $it","artist":"Synthetic MP3 ensemble","duration_ms":3000,"is_liked":${ProductTransportFixture.liked}}"""}
   return MockResponse.Builder().addHeader("Content-Type","application/json").body("""{"tracks":[$rows],"total":${ids.size},"limit":$limit,"offset":$offset}""").build()
  }}
 }
}
