package com.soundq.android.product.discovery

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.soundq.android.data.discovery.SourceArtworkRead
import com.soundq.android.product.artwork.decodeArtwork
import com.soundq.designsystem.SoundQArtworkSlot
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient

private val artworkWorkers=Semaphore(3)

/** Only the accepted DTO's URL, fenced by its row/view and foreground lifetime. */
@Composable internal fun DiscoveryArtwork(client:OkHttpClient,url:String?,owner:Any,valid:()->Boolean) {
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    var foreground by remember(lifecycle) {mutableStateOf(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))}
    DisposableEffect(lifecycle) {
        val observer=LifecycleEventObserver {_,_->foreground=lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)}
        lifecycle.addObserver(observer);onDispose {lifecycle.removeObserver(observer)}
    }
    val reader=remember(owner,url,foreground) {if(foreground&&url!=null)SourceArtworkRead(client)else null}
    var bitmap by remember(reader) {mutableStateOf<Bitmap?>(null)}
    DisposableEffect(reader) {onDispose {reader?.close()}}
    LaunchedEffect(reader) {
        if(reader!=null&&url!=null) {
            val image=artworkWorkers.withPermit {withContext(Dispatchers.IO) {reader.load(url,valid)?.let {decodeArtwork(it,192)}}}
            if(valid()&&foreground)bitmap=image
        }
    }
    val image=bitmap.takeIf {foreground&&valid()}
    if(image==null)SoundQArtworkSlot()
    else Image(image.asImageBitmap(),null,Modifier.fillMaxSize(),contentScale=ContentScale.Crop)
}
