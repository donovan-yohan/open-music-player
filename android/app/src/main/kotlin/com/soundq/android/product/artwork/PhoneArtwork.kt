package com.soundq.android.product.artwork

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.soundq.android.AppGraph
import com.soundq.android.playback.PlaybackRef
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Semaphore

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import java.util.concurrent.atomic.AtomicBoolean

private val phoneArtworkReaders=Semaphore(2)
private val phoneThumbnailReads=ThumbnailReadGate(phoneArtworkReaders)
/** A source-owned local override, or original embedded artwork. This surface never uses the network. */
@Composable internal fun PhoneArtwork(graph:AppGraph,ref:PlaybackRef.Device,size:Dp,current:()->Boolean,modifier:Modifier=Modifier,
    onReadCompleted:((decoded:Boolean)->Unit)?=null) {
    val version=graph.session.version()
    val latest by rememberUpdatedState(current)
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    val foreground=remember(lifecycle){mutableStateOf<Any?>(null)}
    DisposableEffect(lifecycle) {
        val observer=LifecycleEventObserver {_,event->
            when(event) {
                Lifecycle.Event.ON_RESUME -> foreground.value=Any()
                Lifecycle.Event.ON_PAUSE -> foreground.value=null
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        onDispose {foreground.value=null;lifecycle.removeObserver(observer)}
    }
    val visit=foreground.value
    val sourceCurrent={latest()&&graph.phoneAudio.current(version)&&graph.phoneAudio.observed(ref)!=null}
    val accepted by produceState(graph.phoneAudio.observed(ref)?.displayOverride?.artwork,graph,ref,version) {
        graph.phoneAudio.state.map {graph.phoneAudio.observed(ref)?.displayOverride?.artwork}
            .distinctUntilChanged().collect {value=it}
    }
    val cover=accepted
    val readable=visit!=null&&sourceCurrent()
    val pixels=remember(graph,ref,version,visit,readable,cover){MutableStateFlow<Bitmap?>(null)}
    val alive=remember(pixels){AtomicBoolean(true)}
    // Observe the foreground visit from draw itself: a live predicate alone cannot
    // invalidate already recorded pixels. A resumed visit cannot reuse the old read.
    val valid={alive.get()&&visit!=null&&foreground.value===visit&&sourceCurrent()&&
        graph.phoneAudio.observed(ref)?.displayOverride?.artwork==cover}
    val visible=com.soundq.designsystem.LocalSoundQThumbnailVisible.current
    DisposableEffect(alive){onDispose {alive.set(false);pixels.value=null}}
    // Rows remain composed behind sheets and before Resume. A refused first read
    // is not a permanent artwork miss; retry only when this caller becomes current.
    LaunchedEffect(pixels) {
        if(!readable)return@LaunchedEffect
        val bitmap=withContext(Dispatchers.IO){phoneThumbnailReads.read(visible(),{snapshotFlow {visible()}.first {it}}) {
            if(!valid())return@read null
            val row=graph.phoneAudio.observed(ref) ?: return@read null
            val locator=row.aliases.firstOrNull {it.state==com.soundq.android.data.deviceaudio.AccessState.AVAILABLE}?.locator?.value ?: return@read null
            if(cover!=null) {
                val applied=decodeArtwork(cover.jpeg(),if(size<=72.dp)LibraryArtwork.MAX_SIDE else LibraryArtwork.PLAYER_SIDE)
                if(applied!=null) {onReadCompleted?.invoke(true);return@read applied}
            }
            val retriever=MediaMetadataRetriever()
            val decoded=try {
                retriever.setDataSource(graph.applicationContext,Uri.parse(locator))
                retriever.embeddedPicture?.takeIf {it.size<=LibraryArtwork.MAX_BYTES}?.let {decodeArtwork(it,if(size<=72.dp)LibraryArtwork.MAX_SIDE else LibraryArtwork.PLAYER_SIDE)}
            }catch(_:Exception){null}finally{retriever.release()}
            // Default-off observation only: original extraction/decode and retriever release have
            // completed on IO. The caller/source-valid publication check below has NOT run yet.
            onReadCompleted?.invoke(decoded!=null)
            decoded
        }}
        if(valid())pixels.value=bitmap
    }
    ArtworkPaint(pixels,{pixels.value.takeIf {valid()}},alive,size,modifier)
}
