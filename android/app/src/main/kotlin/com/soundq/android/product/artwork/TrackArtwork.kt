package com.soundq.android.product.artwork

import android.graphics.Bitmap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.*
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import com.soundq.designsystem.*
import kotlinx.coroutines.flow.StateFlow
import java.util.concurrent.atomic.AtomicBoolean

/** Remember compares source identity, not data-class equality across accepted row replacements. */
private class ArtworkTrackIdentity(val track:Track?) {
    override fun equals(other:Any?)=other is ArtworkTrackIdentity&&track===other.track
    override fun hashCode()=System.identityHashCode(track)
}

/** The source owner keys terminal route/read lifetimes independently of immutable track metadata. */
@Composable internal fun TrackArtwork(graph:AppGraph,scope:AccountScope?,track:Track?,current:()->Boolean,modifier:Modifier=Modifier,sourceOwner:Any?=null) {
    val row=remember(graph.libraryArtwork,scope,ArtworkTrackIdentity(track),sourceOwner){graph.libraryArtwork.open(scope,track,current)}
    val mounted=remember(row){AtomicBoolean(true)}
    DisposableEffect(row){row.start();onDispose {mounted.set(false);row.close()}}
    ArtworkPaint(row.state,row::bitmap,mounted,72.dp,modifier)
}

/** One paint body for Library, Home, queue, playlist, compact and full player. */
@Composable internal fun ArtworkPaint(state:StateFlow<Bitmap?>,bitmap:()->Bitmap?,mounted:AtomicBoolean,size:Dp,modifier:Modifier=Modifier) {
    val pixels by state.collectAsState()
    val background=SoundQ.colors.raised
    SoundQArtworkSlot(modifier.clearAndSetSemantics {},size,artwork={
        Box(Modifier.fillMaxSize(),contentAlignment=Alignment.Center) {
            SoundQIcon(SoundQIcon.Note,null,tint=SoundQ.colors.muted)
            Canvas(Modifier.fillMaxSize()) {
                // The predicate is rechecked at actual draw, not only at asynchronous publication.
                if(pixels!=null&&mounted.get())bitmap()?.let {image->
                    val side=minOf(image.width,image.height)
                    drawRect(background)
                    drawImage(image.asImageBitmap(),
                        srcOffset=IntOffset((image.width-side)/2,(image.height-side)/2),
                        srcSize=IntSize(side,side),
                        dstSize=IntSize(this.size.width.toInt().coerceAtLeast(1),this.size.height.toInt().coerceAtLeast(1)))
                }
            }
        }
    })
}
