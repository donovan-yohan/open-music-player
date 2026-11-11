package com.soundq.android.playback.listening

import android.net.Uri
import android.os.*
import androidx.media3.common.*
import androidx.media3.datasource.*
import androidx.media3.exoplayer.ExoPlayer
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import com.soundq.android.playback.*
import kotlinx.coroutines.*
import mockwebserver3.*
import okhttp3.*
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.junit.Assert.*
import java.io.File
import java.lang.reflect.Proxy
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.*
import java.util.concurrent.ConcurrentHashMap

internal class ServiceProbe(val held:Boolean=false,val localOnly:Boolean=false,val duplicate:Boolean=false,val seekCallbacks:Boolean=false,val rolling:Boolean=false):AutoCloseable {
    val tls=HttpsFixture()
    val graph=AppGraph(RuntimeEnvironment.getApplication(),tls.endpoint,tls.client,MemoryStore(),tls.client)
    val grants=ConcurrentHashMap<String,MediaGrant>()
    val scope:AccountScope
    val fixture=File(System.getProperty("soundq.listening.fixture"))
    val entered=CountDownLatch(1);val release=CountDownLatch(if(held)1 else 0)
    val jobs=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
    var global=0L
    var physicalState=Player.STATE_IDLE
    var playing=false
    var playCalls=0
    var releaseCalls=0
    val seekCalls=mutableListOf<Long>()
    val physicalRepeatModes=mutableListOf<Int>()
    val repeatEvents=mutableListOf<Int>()
    val eventFlags=mutableListOf<Int>()
    var physicalItems=listOf<MediaItem>()
    val outputItems get()=physicalItems.size
    val listeners=mutableListOf<Player.Listener>()
    val transitions=mutableListOf<String>()
    val discontinuities=mutableListOf<Pair<Player.PositionInfo,Player.PositionInfo>>()
    var sourceFactory:DataSource.Factory?=null
    val output:ExoPlayer
    val player:Player
    val items:List<MediaItem>
    init {
        graph.session.accept(graph.session.beginIntent(),SecretTokens("a","r","tracer"));scope=graph.session.capture()!!
        graph.storagePreferences.load();graph.storagePreferences.setTemporaryAudio(graph.storagePreferences.capture()!!,false){true}
        tls.server.dispatcher=object:mockwebserver3.Dispatcher() {override fun dispatch(r:RecordedRequest):MockResponse {
            entered.countDown();check(release.await(10,TimeUnit.SECONDS))
            if(r.target.contains("/plays"))return MockResponse.Builder().code(201).body("{}").build()
            if(r.target.contains("/library"))return MockResponse.Builder().body("""{"tracks":[{"id":8,"title":"B","artist":"Fixture","duration_ms":10000,"is_liked":false}],"total":1,"limit":20,"offset":0}""").build()
            val id=if(r.target.contains("/media/")){if(r.target.contains("8.opus"))8 else 7} else kotlinx.serialization.json.Json.parseToJsonElement(r.body!!.utf8()).let {kotlinx.serialization.json.Json.parseToJsonElement(it.toString()).toString().let {body->if(body.contains("[8]"))8 else 7}}
            if(r.target.contains("/media/"))return MockResponse.Builder().body(okio.Buffer().write(File(fixture,if(id==7)"a.opus" else "b.opus").readBytes())).build()
            val bytes=File(fixture,if(id==7)"a.opus" else "b.opus").length()
            return MockResponse.Builder().body("""{"urls":[{"trackId":$id,"url":"${tls.server.url("/media/$id.opus")}","expiresAt":"2030-01-01T00:00:00Z","contentType":"audio/ogg","codec":"opus","sizeBytes":$bytes}]}""").build()
        }}
        output=Proxy.newProxyInstance(javaClass.classLoader,arrayOf(ExoPlayer::class.java)) {proxy,m,args->when(m.name) {
            "getApplicationLooper"->Looper.getMainLooper()
            "getCurrentPosition","getContentPosition","getBufferedPosition","getContentBufferedPosition"->global
            "getTotalBufferedDuration"->0L
            "getDuration"->17000L
            "getPlaybackState"->physicalState
            "getPlayWhenReady"->playing
            "isPlaying"->playing && physicalState==Player.STATE_READY
            "getPlaybackSuppressionReason","getRepeatMode","getCurrentMediaItemIndex","getCurrentPeriodIndex"->0
            "getShuffleModeEnabled","isLoading","isPlayingAd"->false
            "getCurrentMediaItem"->physicalItems.firstOrNull()
            "getMediaItemCount"->physicalItems.size
            "getMediaItemAt"->physicalItems[args!![0] as Int]
            "getCurrentTimeline"->timeline(physicalItems)
            "getAvailableCommands"->Player.Commands.Builder().addAllCommands().build()
            "getMediaMetadata","getPlaylistMetadata"->MediaMetadata.EMPTY
            "getAudioAttributes"->AudioAttributes.DEFAULT
            "getVolume"->1f
            "getPlaybackParameters"->PlaybackParameters.DEFAULT
            "addListener"->{listeners+=args!![0] as Player.Listener;null}
            "removeListener"->{listeners-=args!![0] as Player.Listener;null}
            "setMediaItems"->{physicalItems=(args!![0] as List<MediaItem>).toList();global=if(args.size==3)args[2] as Long else 0L;null}
            "setMediaItem"->{physicalItems=listOf(args!![0] as MediaItem);null}
            "clearMediaItems"->{physicalItems=emptyList();null}
            "prepare"->{physicalState=Player.STATE_BUFFERING;null}
            "setPlayWhenReady"->{playing=args!![0] as Boolean;if(playing)playCalls++;null}
            "play"->{playing=true;playCalls++;null}
            "pause"->{playing=false;null}
            "stop"->{physicalState=Player.STATE_IDLE;playing=false;null}
            "seekTo"->{
                val previousState=physicalState
                global=args!!.last() as Long;seekCalls+=global
                // Pinned ExoPlayerImpl masks READY/ENDED before inline state callbacks;
                // ListenerSet's aggregate onEvents is delivered on a later looper turn.
                if(previousState==Player.STATE_ENDED || (seekCallbacks && previousState==Player.STATE_READY))physicalState=Player.STATE_BUFFERING
                if(seekCallbacks) {
                    val captured=listeners.toList()
                    if(previousState!=physicalState)captured.forEach{it.onPlaybackStateChanged(physicalState)}
                    Handler(Looper.getMainLooper()).post{captured.forEach{it.onEvents(proxy as Player,Player.Events(androidx.media3.common.FlagSet.Builder().add(Player.EVENT_POSITION_DISCONTINUITY).add(Player.EVENT_PLAYBACK_STATE_CHANGED).build()))}}
                }
                null
            }
            "setRepeatMode"->{physicalRepeatModes+=args!![0] as Int;null}
            "release"->{releaseCalls++;null}
            "hashCode"->System.identityHashCode(this)
            "equals"->false
            "toString"->"hardware-only Exo transport"
            else->when(m.returnType){java.lang.Boolean.TYPE->false;java.lang.Integer.TYPE->0;java.lang.Long.TYPE->0L;java.lang.Float.TYPE->0f;else->null}
        }} as ExoPlayer
        items=listOf(7L,if(duplicate)7L else 8L).mapIndexed {i,id->
            val occ=if(i==0)"visit-a" else "visit-b";val uri=Uri.parse("soundq://track/$id/$occ")
            grants[uri.toString()]=MediaGrant(scope,TrackId(id),localOnly)
            MediaItem.Builder().setMediaId(occ).setUri(uri).setMediaMetadata(MediaMetadata.Builder().setTitle(occ).setExtras(Bundle().apply {putLong("trackId",id);putLong("durationMs",10000);putBoolean("localOnly",localOnly);putString("origin",if(i==0)"Context" else "Manual");putBoolean("manual",i==1)}).build()).build()
        }
        player=createPlayer()
        player.addListener(object:Player.Listener {
            override fun onMediaItemTransition(m:MediaItem?,reason:Int){m?.let{transitions+=it.mediaId}}
            override fun onPositionDiscontinuity(old:Player.PositionInfo,next:Player.PositionInfo,reason:Int){discontinuities+=old to next}
            override fun onRepeatModeChanged(repeatMode:Int){repeatEvents+=repeatMode}
            override fun onEvents(player:Player,events:Player.Events){for(i in 0 until events.size())eventFlags+=events.get(i)}
        })
    }
    // Replaced at generation only to bind the released baseline's actual sequential entrypoint.
    private fun createPlayer():Player = ListeningServicePlayer(output,graph,grants,jobs,3000,{item,factory->sourceFactory=factory;output.setMediaItem(item)},{_,_->AutoCloseable{}},rolling)
    fun install(){player.setMediaItems(items,0,0);player.prepare();player.play()}
    fun ready(){settle{preparationSettled && (outputItems>0 || player.playerError!=null)};assertNull(player.playerError?.cause?.stackTraceToString(),player.playerError);physicalState=Player.STATE_READY;listeners.toList().forEach{it.onPlaybackStateChanged(physicalState)}}
    fun present(p:Long,state:Int=Player.STATE_READY){global=p;physicalState=state;listeners.toList().forEach{it.onPlaybackStateChanged(state)};reconcile()}
    private fun reconcile(){(player as ListeningServicePlayer).reconcile()}
    fun render():DataSource=sourceFactory!!.createDataSource()
    fun onCompletion(block:(String)->Unit){(player as ListeningServicePlayer).addCompletionListener{block(it.mediaId)}}
    private val consumers by lazy {ActualListeningConsumers(graph,player,grants,jobs)}
    fun likeTrack():Long? {if(!localOnly){runBlocking(Dispatchers.IO){graph.library.reconcileLike(scope,TrackId(8))}};return consumers.likeTrack()}
    fun saveAndRead():QueueSnapshot {consumers.save();settle{consumers.file().exists() && consumers.saveJob?.isCompleted==true};return runBlocking {consumers.read()!!}}
    fun restore(saved:QueueSnapshot){consumers.restore(saved);settle{outputItems==0 && player.currentMediaItemIndex==saved.selected && player.currentPosition==saved.position && player.repeatMode==when(saved.loopMode){SavedRepeatMode.Off->Player.REPEAT_MODE_OFF;SavedRepeatMode.One->Player.REPEAT_MODE_ONE;SavedRepeatMode.All->Player.REPEAT_MODE_ALL}}}
    fun bindModePersistence(){consumers.bindModes()}
    fun startup(saved:QueueSnapshot){consumers.startup(saved);settle{player.mediaItemCount==saved.items.size && player.repeatMode==when(saved.loopMode){SavedRepeatMode.Off->Player.REPEAT_MODE_OFF;SavedRepeatMode.One->Player.REPEAT_MODE_ONE;SavedRepeatMode.All->Player.REPEAT_MODE_ALL}}}
    fun persistedMode():QueueSnapshot {settle{consumers.file().exists() && consumers.saveJob?.isCompleted==true};return runBlocking{consumers.read()!!}}
    val preparationSettled get()=(player as ListeningServicePlayer).preparationSettled
    fun awaitAcquisition()=entered.await(5,TimeUnit.SECONDS)
    fun releaseAcquisition(){release.countDown()}
    fun seedDownloads() {runBlocking(Dispatchers.IO){
        graph.downloads.load(scope)
        for(id in listOf(7L,8L)){val ticket=graph.downloads.claim(scope,Track(TrackId(id),"Fixture",durationMs=10000)){true}!!;graph.downloads.transfer(ticket)}
        assertTrue(graph.downloads.state.value.rows.all{it.status==com.soundq.android.data.offline.DownloadStatus.Complete})
    }}
    fun seedTemporary() {
        graph.storagePreferences.setTemporaryAudio(graph.storagePreferences.capture()!!,true){true}
        for((id,name) in listOf(7L to "a",8L to "b")){val bytes=File(fixture,"$name.opus").readBytes();val stage=graph.temporaryAudio.begin(scope,TrackId(id),bytes.size.toLong())!!;stage.append(bytes,0,bytes.size);stage.finish()}
    }
    val requestCount get()=tls.server.requestCount
    fun privateFiles()=graph.directory.listFiles()?.count{it.name.startsWith("listening-")} ?: 0
    fun decoded(name:String)=ByteBuffer.wrap(File(fixture,"$name.decoded").readBytes()).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().let{b->FloatArray(b.remaining()).also{b.get(it)}}
    fun assertOrdinaryNetwork(){assertEquals(4,requestCount);repeat(4){val r=tls.server.takeRequest();if(r.target.contains("/media/"))assertNull(r.headers["Authorization"]) else assertNotNull(r.headers["Authorization"])};assertEquals(0L,graph.temporaryAudio.status().bytes)}
    fun settle(done:()->Boolean){val end=System.nanoTime()+10_000_000_000;while(!done()&&System.nanoTime()<end){shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(5));Thread.sleep(2)};shadowOf(Looper.getMainLooper()).idle();assertTrue(done())}
    override fun close(){release.countDown();player.release();jobs.cancel();graph.close();tls.close();graph.directory.deleteRecursively();shadowOf(Looper.getMainLooper()).idle()}
    private fun timeline(items:List<MediaItem>)=object:Timeline() {
        override fun getWindowCount()=items.size
        override fun getPeriodCount()=items.size
        override fun getIndexOfPeriod(uid:Any)=items.indexOfFirst{it.mediaId==uid}
        override fun getUidOfPeriod(index:Int):Any=items[index].mediaId
        override fun getWindow(index:Int,w:Window,projection:Long):Window=w.set(items[index].mediaId,items[index],null,C.TIME_UNSET,C.TIME_UNSET,C.TIME_UNSET,true,false,null,0,10000000,index,index,0)
        override fun getPeriod(index:Int,p:Period,setIds:Boolean):Period=p.set(items[index].mediaId,items[index].mediaId,index,10000000,0)
    }
}

internal fun DataSource.use(block:(DataSource)->Unit){try{block(this)}finally{close()}}
