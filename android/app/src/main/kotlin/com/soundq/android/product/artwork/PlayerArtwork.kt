package com.soundq.android.product.artwork

import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import com.soundq.android.AppGraph
import com.soundq.android.data.TrackId
import com.soundq.android.playback.PlaybackProjection
import java.util.concurrent.atomic.AtomicBoolean

/** Same accepted source adapter for compact and full slots. Progress is not a lease key. */
@Composable internal fun PlayerArtwork(
    graph:AppGraph,
    observed:PlaybackProjection,
    size:Dp,
    current:()->Boolean,
    modifier:Modifier=Modifier,
) {
    val loader=graph.playerArtwork
    val scopeRevision by graph.session.scopeRevision.collectAsState()
    val source=selectedArtworkSource(observed)
    val artwork=source?.trackId?.let {graph.track(TrackId(it))?.artwork}
    val lease=remember(loader,scopeRevision,observed.accountEpoch,observed.connection,observed.source,
        observed.sessionIdentity,observed.sourceQueueIncarnation,observed.selectionIncarnation,
        observed.arrangement?.identity,observed.selectedOccurrence,observed.localOnly,source?.occurrenceId,source?.trackId,artwork) {
        loader.open(observed,current)
    }
    val mounted=remember(lease){AtomicBoolean(true)}
    DisposableEffect(lease){lease.start();onDispose {mounted.set(false);lease.close()}}
    ArtworkPaint(lease.state,lease::bitmap,mounted,size,modifier)
}
