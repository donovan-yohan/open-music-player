package com.soundq.android.product.discovery

import android.graphics.Bitmap
import androidx.compose.runtime.*
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.soundq.android.data.discovery.*
import com.soundq.android.product.artwork.ArtworkPaint
import com.soundq.android.product.artwork.decodeArtwork
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.withPermit
import okhttp3.OkHttpClient
import java.util.concurrent.atomic.AtomicBoolean

/** Memory-only public pixels; each subscriber retains its own terminal accepted-Radar authority. */
internal class RadarArtworkPool(
    private val decode:(ByteArray)->Bitmap?={decodeArtwork(it,192)},
    private val reader:(OkHttpClient)->CaaArtworkRead={CaaArtworkRead(it)},
) {
    companion object {const val MAX_LEASES=64;const val MAX_JOBS=32;const val MAX_CACHE_ENTRIES=16;const val MAX_CACHE_BYTES=2*1024*1024}
    internal data class Key(val client:OkHttpClient,val ref:CaaArtworkRef)
    private data class Cached(val pixels:Bitmap?,val until:Long)
    private val cache=java.util.LinkedHashMap<Key,Cached>(16,0.75f,true)
    private var cacheBytes=0L
    private val leases=mutableSetOf<Lease>()
    private val flights=mutableMapOf<Key,Work>()
    private val jobs=mutableSetOf<Work>()
    // Dispatchers.IO + the SAME semaphore as source thumbnails, never another executor/pool.
    private val scope=CoroutineScope(SupervisorJob()+Dispatchers.IO)
    @Synchronized internal fun resources():List<Int> = listOf(leases.size,jobs.size,cache.size,cacheBytes.toInt())
    private fun retain(key:Key,image:Bitmap?) {
        cache.remove(key)?.pixels?.let {cacheBytes-=it.allocationByteCount}
        cache[key]=Cached(image,if(image==null)System.nanoTime()+10_000_000_000L else Long.MAX_VALUE)
        cacheBytes+=image?.allocationByteCount ?: 0
        val entries=cache.entries.iterator()
        while(cache.size>MAX_CACHE_ENTRIES||cacheBytes>MAX_CACHE_BYTES) {
            cacheBytes-=entries.next().value.pixels?.allocationByteCount ?: 0;entries.remove()
        }
        // Never recycle: a submitted native draw may still hold evicted pixels.
    }
    @Synchronized fun open(client:OkHttpClient,ref:CaaArtworkRef?,valid:()->Boolean):Lease {
        leases.toList().forEach {it.current()}
        return Lease(if(ref==null)null else Key(client,ref),valid).also {
            if(leases.size>=MAX_LEASES||!it.current())it.close() else leases.add(it)
        }
    }
    internal inner class Lease internal constructor(private val key:Key?,private val valid:()->Boolean):AutoCloseable {
        private var alive=true
        private var started=false
        private var work:Work?=null
        private val mutable=MutableStateFlow<Bitmap?>(null)
        val state:StateFlow<Bitmap?> = mutable
        fun current():Boolean=synchronized(this@RadarArtworkPool) {
            if(alive&&(key==null||!valid()))close()
            alive
        }
        fun bitmap():Bitmap?=synchronized(this@RadarArtworkPool){if(current())mutable.value else null}
        @OptIn(DelicateCoroutinesApi::class)
        fun start():Unit=synchronized(this@RadarArtworkPool) {
            if(started||!current())return
            started=true
            val k=key!!
            cache[k]?.takeIf {System.nanoTime()<it.until}?.let {mutable.value=it.pixels;return}
            val shared=flights[k]?.takeIf {it.current()}
            if(shared!=null){work=shared;shared.subscribers.add(this);return}
            if(jobs.size>=MAX_JOBS){close();return}
            val next=Work(k);work=next;next.subscribers.add(this);jobs.add(next);flights[k]=next
            // ATOMIC guarantees entry into run's try/finally even if a queued subscriber closes
            // before this coroutine is dispatched. Its first semaphore suspension remains cancellable.
            next.task=scope.launch(start=CoroutineStart.ATOMIC) {next.run()}
        }
        override fun close():Unit=synchronized(this@RadarArtworkPool) {
            if(!alive)return
            alive=false;mutable.value=null;leases.remove(this)
            work?.let {it.subscribers.remove(this);if(it.subscribers.isEmpty())it.cancel()};work=null
        }
        internal fun publish(image:Bitmap?){if(current())mutable.value=image}
    }
    private inner class Work(val key:Key) {
        val subscribers=mutableSetOf<Lease>()
        private var closed=false
        private var running=false
        var task:Job?=null
        private var read:CaaArtworkRead?=null
        fun current():Boolean=synchronized(this@RadarArtworkPool) {
            if(closed||flights[key]!==this)return false
            subscribers.toList().forEach {it.current()}
            !closed&&subscribers.isNotEmpty()
        }
        fun cancel() {closed=true;read?.close();if(!running)task?.cancel();if(flights[key]===this)flights.remove(key)}
        suspend fun run() {
            try {
                discoveryArtworkWorkers.withPermit {
                    val end=System.nanoTime()+CaaArtworkRead.DEADLINE_NANOS
                    fun valid()=System.nanoTime()<end&&current()
                    val source=synchronized(this@RadarArtworkPool){if(!valid())return@withPermit;running=true;reader(key.client).also {read=it}}
                    source.use {
                        val bytes=it.load(key.ref,::valid)
                        val image=if(bytes!=null&&valid())decode(bytes)?.takeIf {b->b.width in 1..192&&b.height in 1..192&&b.allocationByteCount in 1..192*192*4}else null
                        synchronized(this@RadarArtworkPool) {
                            if(valid()) {retain(key,image);subscribers.toList().forEach {lease->lease.publish(image)}}
                        }
                    }
                }
            }catch(_:Exception){/* Stable note fallback; no URL-bearing diagnostic or automatic retry. */}
            finally {synchronized(this@RadarArtworkPool) {
                read=null;task=null;jobs.remove(this);subscribers.clear()
                if(flights[key]===this)flights.remove(key)
            }}
            // Cancellation never removes a running job or releases its permit before this finally.
        }
    }
}

private val radarArtworkPool=RadarArtworkPool()

/** Capture the accepted view/page/song/draft AND the caller's route/foreground incarnation.
 * Parent must dispose hidden preview/full rows and change surfaceOwner on every route/foreground visit.
 * Never pass LibraryTrackCapture or a freshly captured account as a replacement for radarCurrent.
 */
@Composable internal fun RadarArtwork(
    client:OkHttpClient,
    repository:DiscoveryRepository,
    view:DiscoveryView,
    page:RadarPage,
    song:RadarSong,
    draft:DiscoveryDraft,
    surfaceOwner:Any,
    pool:RadarArtworkPool=radarArtworkPool,
) {
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    // An identity, not a resumed boolean: A→background→A cannot revive the old capture.
    var visit by remember(lifecycle){mutableStateOf<Any?>(if(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))Any()else null)}
    val foreground=remember(lifecycle){AtomicBoolean(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))}
    val lease=remember(pool,client,repository,view,page,song,draft,surfaceOwner,visit) {
        val captured=visit
        pool.open(client,song.artwork) {
            captured!=null&&foreground.get()&&lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)&&
                repository.radarCurrent(view,page,song,draft)
        }
    }
    val mounted=remember(lease){AtomicBoolean(true)}
    val acceptedRadar by repository.radar.collectAsState()
    val acceptedDraft by repository.state.collectAsState()
    val accountRevision by view.scope.owner.scopeRevision.collectAsState()
    val accountState by view.scope.owner.state.collectAsState()
    LaunchedEffect(lease,acceptedRadar,acceptedDraft.draft,accountRevision,accountState) {lease.current()}
    DisposableEffect(lifecycle,lease) {
        val observer=LifecycleEventObserver {_,_->
            val resumed=lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
            // Retire synchronously before publishing a successor composition visit.
            if(!resumed){foreground.set(false);lease.close();visit=null}
            else if(!foreground.getAndSet(true)){visit=Any()}
        }
        lifecycle.addObserver(observer)
        lease.start()
        onDispose {mounted.set(false);lease.close();lifecycle.removeObserver(observer)}
    }
    ArtworkPaint(lease.state,lease::bitmap,mounted,72.dp)
}
