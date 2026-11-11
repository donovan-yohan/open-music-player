package com.soundq.android.product.artwork

import androidx.compose.runtime.*
import androidx.compose.ui.unit.dp
import com.soundq.android.data.playlists.LibraryTrackCapture
import java.util.concurrent.atomic.AtomicBoolean

/** Keep acknowledged Library capture guards. Share the same draw-time checked paint body. */
@Composable internal fun LibraryRowArtwork(loader:LibraryArtwork,capture:LibraryTrackCapture?,current:()->Boolean) {
    val row=remember(loader,capture){loader.open(capture,current)}
    val mounted=remember(row){AtomicBoolean(true)}
    DisposableEffect(row){row.start();onDispose {mounted.set(false);row.close()}}
    ArtworkPaint(row.state,row::bitmap,mounted,72.dp)
}
