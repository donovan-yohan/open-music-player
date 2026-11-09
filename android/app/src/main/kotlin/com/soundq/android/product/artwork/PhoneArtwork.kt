package com.soundq.android.product.artwork

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import com.soundq.android.AppGraph
import com.soundq.android.playback.PlaybackRef
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.flow.MutableStateFlow
import java.util.concurrent.atomic.AtomicBoolean

private val phoneArtworkReaders=Semaphore(2)
/** Original embedded artwork only. No URL, network enrichment or source-file mutation. */
@Composable internal fun PhoneArtwork(graph:AppGraph,ref:PlaybackRef.Device,size:Dp,current:()->Boolean,modifier:Modifier=Modifier) {
    val version=graph.session.version()
    val pixels=remember(ref,version){MutableStateFlow<Bitmap?>(null)}
    val alive=remember(ref,version){AtomicBoolean(true)}
    val latest by rememberUpdatedState(current)
    val valid={alive.get()&&latest()&&graph.phoneAudio.current(version)&&graph.phoneAudio.observed(ref)!=null}
    DisposableEffect(alive){onDispose {alive.set(false);pixels.value=null}}
    LaunchedEffect(ref,version) {
        val bitmap=withContext(Dispatchers.IO){phoneArtworkReaders.withPermit {
            if(!valid())return@withPermit null
            val row=graph.phoneAudio.observed(ref) ?: return@withPermit null
            val locator=row.aliases.firstOrNull {it.state==com.soundq.android.data.deviceaudio.AccessState.AVAILABLE}?.locator?.value ?: return@withPermit null
            val retriever=MediaMetadataRetriever()
            try {
                retriever.setDataSource(graph.applicationContext,Uri.parse(locator))
                retriever.embeddedPicture?.takeIf {it.size<=LibraryArtwork.MAX_BYTES}?.let {decodeArtwork(it,LibraryArtwork.PLAYER_SIDE)}
            }catch(_:Exception){null}finally{retriever.release()}
        }}
        if(valid())pixels.value=bitmap
    }
    ArtworkPaint(pixels,{pixels.value.takeIf {valid()}},alive,size,modifier)
}
