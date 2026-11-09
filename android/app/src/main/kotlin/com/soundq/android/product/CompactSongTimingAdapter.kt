package com.soundq.android.product

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import com.soundq.android.playback.*
import com.soundq.designsystem.*

/** Queue identity lookup is retained across the controller's 500ms cursor publications.
 * Arrangement global time is deliberately unavailable: no accepted song-clock selection policy
 * exists for overlap. Decorative artwork selection must not become clock authority. */
@Composable internal fun compactSongTiming(p:PlaybackProjection):CompactSongTiming {
    val row=remember(p.queue,p.source,p.selectedOccurrence) {
        if(p.source==PlaybackSource.Queue)p.queue.singleOrNull {it.occurrenceId==p.selectedOccurrence} else null
    }
    return projectCompactSongTiming(p,row)
}
internal fun projectCompactSongTiming(p:PlaybackProjection,row:QueueOccurrence?):CompactSongTiming {
    val selected=p.connection==PlaybackProjection.Connection.Connected&&p.selectedOccurrence!=null
    val state=when {
        p.error!=null->CompactPlaybackState.Failed
        p.preparing->CompactPlaybackState.Preparing
        !selected->CompactPlaybackState.None
        p.isPlaying->CompactPlaybackState.Playing
        else->CompactPlaybackState.Paused // Projection does not expose STATE_ENDED; do not infer it from time.
    }
    val ordinary=selected&&p.source==PlaybackSource.Queue&&row!=null&&row.occurrenceId==p.selectedOccurrence&&
        row.title==p.title&&row.artist==p.artist
    if(!ordinary)return CompactSongTiming(state=state,selected=selected)
    val source=when(val ref=row.ref) {
        is PlaybackRef.Device->CompactSongSource.Device(ref.id,ref.sha256,ref.bytes,ref.incarnation)
        else->row.trackId.takeIf {it>0}?.let {CompactSongSource.Server(it)}
    } ?: return CompactSongTiming(state=state,selected=selected)
    return CompactSongTiming(CompactSongIdentity(p.accountEpoch,p.sessionIdentity,p.sourceQueueIncarnation,p.selectionIncarnation,row.occurrenceId,source),
        p.positionMs,p.durationMs.takeIf {it>0},state)
}
