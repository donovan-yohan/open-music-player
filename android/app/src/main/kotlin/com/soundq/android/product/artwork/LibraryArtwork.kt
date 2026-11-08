package com.soundq.android.product.artwork

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.soundq.android.data.*
import com.soundq.android.data.playlists.LibraryTrackCapture
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import okhttp3.*
import java.util.concurrent.*

/** App-owned memory-only artwork. Captured leases remain the authority for every cache read. */
internal class LibraryArtwork(
    private val session:AccountSession,
    mediaClient:OkHttpClient,
    private val decode:(ByteArray)->Bitmap?=::decodeLibraryArtwork,
):AutoCloseable {
    companion object {
        const val MAX_ROWS=32; const val MAX_PLAYERS=4; const val MAX_BYTES=4_000_000
        const val MAX_SIDE=192; const val PLAYER_SIDE=1024
        const val MAX_CACHE_BYTES=8*1024*1024; const val MAX_CACHE_ENTRIES=64
        const val MAX_WORKERS=3; const val MAX_JOBS=MAX_ROWS+MAX_PLAYERS
    }
    private data class Key(val owner:AccountSession,val epoch:Long,val account:String,val url:String,val side:Int)
    private class Cached(val scope:AccountScope,val pixels:Bitmap)
    private val cache=java.util.LinkedHashMap<Key,Cached>(16,0.75f,true)
    private var cacheBytes=0L
    private fun purgeCache() {
        val entries=cache.entries.iterator()
        while(entries.hasNext()) {
            val entry=entries.next()
            if(closed||!session.remoteCurrent(entry.value.scope)) {
                cacheBytes-=entry.value.pixels.allocationByteCount;entries.remove()
            }
        }
    }
    private fun retain(key:Key,scope:AccountScope,image:Bitmap) {
        cache.remove(key)?.let {cacheBytes-=it.pixels.allocationByteCount}
        cache[key]=Cached(scope,image);cacheBytes+=image.allocationByteCount
        val entries=cache.entries.iterator()
        while(cacheBytes>MAX_CACHE_BYTES||cache.size>MAX_CACHE_ENTRIES) {
            val entry=entries.next();cacheBytes-=entry.value.pixels.allocationByteCount;entries.remove()
        }
        // Never recycle. A submitted Compose draw may still hold an evicted bitmap.
    }
    private val client=mediaClient.newBuilder().apply {
        interceptors().clear();networkInterceptors().clear()
        authenticator(Authenticator.NONE);proxyAuthenticator(Authenticator.NONE)
        cookieJar(CookieJar.NO_COOKIES);cache(null);eventListener(EventListener.NONE)
        followRedirects(false);followSslRedirects(false);retryOnConnectionFailure(false)
        callTimeout(15,TimeUnit.SECONDS)
        addNetworkInterceptor {chain ->
            val request=chain.request();val work=request.tag(Work::class.java)
            if(work==null||!work.current()||request.header("Authorization")!=null||request.header("Cookie")!=null)
                throw SafeFailure(SafeFailure.Reason.Retired)
            chain.proceed(request)
        }
    }.build()
    private val executor=ThreadPoolExecutor(MAX_WORKERS,MAX_WORKERS,0,TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(MAX_JOBS-MAX_WORKERS),{r ->Thread(r,"soundq-library-artwork").apply {isDaemon=true}},ThreadPoolExecutor.AbortPolicy())
    private val rows=mutableSetOf<Row>()
    private val flights=mutableMapOf<Key,Work>()
    // Includes cancelled running work until its body really exits, even if decode ignores interruption.
    private val jobs=mutableSetOf<Work>()
    private var closed=false
    /** Aggregate resource observation only. Never exposes source URLs or grants image authority. */
    @Synchronized internal fun pendingWorkCount():Int = jobs.size
    internal data class Resources(val rows:Int,val players:Int,val jobs:Int,val running:Int,val cacheEntries:Int,val cacheBytes:Long)
    @Synchronized internal fun resources():Resources {
        sweep()
        return Resources(rows.count {it.maxSide==MAX_SIDE},rows.count {it.maxSide!=MAX_SIDE},jobs.size,
            jobs.count {it.thread!=null},cache.size,cacheBytes)
    }
    private val observer=CoroutineScope(SupervisorJob()+Dispatchers.Default)
    init {observer.launch(start=CoroutineStart.UNDISPATCHED) {session.scopeRevision.collect {sweep()}};observer.launch(start=CoroutineStart.UNDISPATCHED) {session.state.collect {sweep()}}}
    private fun sweep() = synchronized(this) {purgeCache();rows.toList().forEach {it.current()}}

    /** Capture comes from the acknowledged Library, never a fresh account borrowing old rows. */
    fun open(capture:LibraryTrackCapture?,current:()->Boolean):Row = open(capture?.scope,capture?.track,current)

    /** Scope and immutable metadata are supplied by the accepted route, not recaptured here. */
    @Synchronized fun open(scope:AccountScope?,track:Track?,current:()->Boolean):Row = openBounded(scope,track,current,MAX_SIDE,decode)
    @Synchronized internal fun openPlayer(scope:AccountScope?,track:Track?,current:()->Boolean):Row =
        openBounded(scope,track,current,PLAYER_SIDE,{decodeArtwork(it,PLAYER_SIDE)})
    private fun openBounded(scope:AccountScope?,track:Track?,current:()->Boolean,side:Int,decoder:(ByteArray)->Bitmap?):Row {
        sweep()
        val row=Row(scope,track,current,side,decoder)
        val rowCount=rows.count {it.maxSide==MAX_SIDE}
        val playerCount=rows.size-rowCount
        if(closed||(side==MAX_SIDE&&rowCount>=MAX_ROWS)||(side!=MAX_SIDE&&playerCount>=MAX_PLAYERS)||!row.current())row.close()
        else {rows.add(row);row.readCached()}
        return row
    }
    internal inner class Row(private val scope:AccountScope?,private val track:Track?,private val eligible:()->Boolean,
        internal val maxSide:Int,private val decoder:(ByteArray)->Bitmap?):AutoCloseable {
        private val mutable=MutableStateFlow<Bitmap?>(null)
        val state:StateFlow<Bitmap?> = mutable
        private var alive=true
        private var started=false
        private var work:Work?=null
        private val key=if(scope!=null&&track?.artwork!=null)Key(scope.owner,scope.epoch,scope.accountId,track.artwork,maxSide) else null
        internal fun readCached():Unit = synchronized(this@LibraryArtwork) {
            if(current())key?.let {cache[it]?.let {entry->mutable.value=entry.pixels}}
        }
        fun current():Boolean = synchronized(this@LibraryArtwork) {
            purgeCache()
            if(alive&&(scope==null||track==null||!session.remoteCurrent(scope)||!eligible()||track.artwork?.let(SoundQApi::safeMediaUrl)!=true))close()
            return alive
        }
        fun bitmap():Bitmap?=synchronized(this@LibraryArtwork){if(current())mutable.value else null}
        fun start():Unit = synchronized(this@LibraryArtwork) {
            if(started||!current())return
            started=true
            readCached()
            if(mutable.value!=null)return
            val shared=flights[key]?.takeIf {it.current()}
            if(shared!=null) {
                work=shared;shared.subscribers[this]={mutable.value=it};return
            }
            if(jobs.size>=MAX_JOBS){close();return}
            val next=Work(key!!,scope!!,decoder)
            work=next;next.subscribers[this]={mutable.value=it};flights[key]=next;jobs.add(next)
            try {executor.execute(next)} catch(_:RejectedExecutionException){next.cancel();jobs.remove(next);close()}
        }
        override fun close():Unit = synchronized(this@LibraryArtwork) {
            if(!alive)return
            alive=false;mutable.value=null
            work?.detach(this);work=null;rows.remove(this)
            // No recycle: an already submitted Compose draw may still reference this bitmap.
        }
    }
    private inner class Work(val key:Key,val scope:AccountScope,val decoder:(ByteArray)->Bitmap?):Runnable {
        val subscribers=mutableMapOf<Row,(Bitmap)->Unit>()
        var thread:Thread?=null
        private var call:Call?=null
        private var cancelled=false
        private var finished=false
        fun current():Boolean = synchronized(this@LibraryArtwork) {
            if(cancelled||closed||flights[key]!==this)return false
            subscribers.keys.toList().forEach {it.current()}
            return !cancelled&&subscribers.isNotEmpty()
        }
        fun detach(row:Row) {
            subscribers.remove(row)
            if(subscribers.isEmpty())cancel()
        }
        fun cancel() {
            if(cancelled||finished)return
            cancelled=true
            if(flights[key]===this)flights.remove(key)
            call?.cancel();thread?.interrupt()
            // If already dequeued, run/finally owns removal. Cancellation is not completion.
            if(executor.remove(this))jobs.remove(this)
        }
        override fun run() {
            try {
                val request=synchronized(this@LibraryArtwork) {
                    thread=Thread.currentThread()
                    if(!current())return
                    client.newCall(Request.Builder().url(key.url).tag(Work::class.java,this).build()).also {call=it}
                }
                request.execute().use {response ->
                    if(response.code!=200||response.body.contentLength()>MAX_BYTES||!current())return
                    val source=response.body.source()
                    if(source.request(MAX_BYTES.toLong()+1)||!current())return
                    val data=source.readByteArray()
                    if(data.size>MAX_BYTES||!current())return
                    val image=decoder(data) ?: return
                    if(image.width !in 1..key.side||image.height !in 1..key.side||image.allocationByteCount !in 1..key.side*key.side*4)return
                    synchronized(this@LibraryArtwork) {
                        if(current()) {
                            retain(key,scope,image)
                            subscribers.toList().forEach {(row,publish)->if(row.current())publish(image)}
                        }
                    }
                }
            } catch(_:Exception) { /* Absent, refused, retired or corrupt keeps the same fallback. No URL-bearing errors. */ }
            finally {synchronized(this@LibraryArtwork) {
                finished=true;call=null;thread=null;subscribers.clear();jobs.remove(this)
                if(flights[key]===this)flights.remove(key)
            }}
        }
    }
    override fun close() {
        val old=synchronized(this){if(closed)return;closed=true;purgeCache();rows.toList()}
        old.forEach {it.close()};observer.cancel()
        synchronized(this) {jobs.toList().forEach {it.cancel()};executor.shutdownNow()}
    }
}

/** Hardware decode boundary. Bounds pass precedes allocation and ceil division bounds odd dimensions. */
internal fun decodeLibraryArtwork(data:ByteArray):Bitmap? = decodeArtwork(data,LibraryArtwork.MAX_SIDE)
internal fun decodeArtwork(data:ByteArray,maxSide:Int):Bitmap? {
    if(data.size>LibraryArtwork.MAX_BYTES)return null
    val options=BitmapFactory.Options().apply {inJustDecodeBounds=true}
    BitmapFactory.decodeByteArray(data,0,data.size,options)
    if(options.outWidth<=0||options.outHeight<=0)return null
    options.inSampleSize=1
    while((options.outWidth.toLong()+options.inSampleSize-1)/options.inSampleSize>maxSide ||
        (options.outHeight.toLong()+options.inSampleSize-1)/options.inSampleSize>maxSide)options.inSampleSize*=2
    options.inJustDecodeBounds=false;options.inPreferredConfig=Bitmap.Config.ARGB_8888
    return BitmapFactory.decodeByteArray(data,0,data.size,options)?.takeIf {
        it.width in 1..maxSide&&it.height in 1..maxSide&&it.allocationByteCount<=maxSide*maxSide*4
    }
}
