package com.soundq.android.playback

import androidx.media3.common.*
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import com.soundq.android.data.preferences.EndOfQueue
import com.soundq.android.playback.system.ServiceTransportPlayer
import com.soundq.android.playback.listening.ListeningServicePlayer
import kotlinx.coroutines.*
import java.util.concurrent.atomic.AtomicBoolean

/** Service-private natural-exhaustion capability; never a second queue, clock or output. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class ServiceLibraryContinuation(
    private val player:Player,
    private val transport:ServiceTransportPlayer,
    private val graph:AppGraph,
    private val jobs:CoroutineScope,
    private val resolve:(List<Track>,()->Boolean)->List<MediaItem>,
) {
    private class Attempt(val live:AtomicBoolean=AtomicBoolean(true))
    @Volatile private var attempt:Attempt?=null
    @Volatile private var timelineRevision=0L
    private var armed=false
    private var attempted:String?=null
    private var committing=false
    @Volatile private var closed=false
    private var recentAccount:AccountScope?=null
    private var lastTrack:Long?=null
    private val recent=ArrayDeque<Long>()
    private var inFlight=0
    val pending:Boolean get()=inFlight>0

    fun retire() {attempt?.live?.set(false);attempt=null;armed=false}
    /** Admission revokes only silent work; it must not retire explicit resumption/search reads. */
    fun command() {retire()}
    fun timelineChanged() {if(!committing){timelineRevision++;retire();armed=player.isPlaying && player.playWhenReady;attempted=null}}
    fun positionChanged(reason:Int) {if(!committing && reason==Player.DISCONTINUITY_REASON_SEEK){retire();attempted=null}}
    fun transition() {
        if(!committing)retire()
        armed=player.isPlaying && player.playWhenReady
        attempted=null
        val scope=graph.session.capture()
        if(recentAccount?.let(graph.session::current)!=true){recent.clear();lastTrack=null;recentAccount=scope}
        val id=player.currentMediaItem?.mediaMetadata?.extras?.getLong("trackId")?.takeIf {it>0}
        if(id!=null && id!=lastTrack){recent.remove(id);recent.addLast(id);while(recent.size>20)recent.removeFirst()}
        lastTrack=id
    }
    fun playingChanged(playing:Boolean) {
        if(playing){armed=true;if(lastTrack==null)transition().also {armed=true}}
        else if(!player.playWhenReady)retire()
    }
    fun repeatChanged(){retire();armed=player.isPlaying && player.playWhenReady}
    fun shuffleChanged(){retire();armed=player.isPlaying && player.playWhenReady}
    fun accountRetired(){retire();recent.clear();lastTrack=null;recentAccount=null;attempted=null}
    fun close(){closed=true;accountRetired()}
    fun ended(state:Int) {
        // Listener arguments can lag a successor that is already READY. Check the
        // canonical player before allocating a read, not only before append.
        if(state!=Player.STATE_ENDED || player.playbackState!=Player.STATE_ENDED || !armed || !player.playWhenReady || player.repeatMode!=Player.REPEAT_MODE_OFF || player.hasNextMediaItem() || closed || pending)return
        val scope=graph.session.capture()?.takeIf(graph.session::remoteCurrent) ?: return
        val mode=graph.listeningPreferences.state.value
        if(!mode.ready || mode.error || mode.mode!=EndOfQueue.ShuffleLibrary || player.mediaItemCount==0)return
        if((0 until player.mediaItemCount).any {val item=player.getMediaItemAt(it);item.localConfiguration?.uri?.scheme!="soundq" || item.mediaMetadata.extras?.getBoolean("localOnly")==true})return
        val selected=player.currentMediaItem?.mediaId ?: return
        if(attempted==selected)return
        attempted=selected;armed=false
        val owner=Attempt().also {attempt=it}
        val revision=timelineRevision
        val intent=transport.revision
        val deadline=System.nanoTime()+15_000_000_000L
        val excluded=setOf(player.currentMediaItem!!.mediaMetadata.extras!!.getLong("trackId"))
        val recentIds=recent.toList()
        fun valid()=owner.live.get() && !closed && System.nanoTime()<deadline && graph.session.remoteCurrent(scope) && transport.revision==intent && graph.listeningPreferences.state.value.let {it.ready&&!it.error&&it.mode==EndOfQueue.ShuffleLibrary&&it.revision==mode.revision}
        fun accepted()=valid() && attempt===owner && revision==timelineRevision && player.currentMediaItem?.mediaId==selected && player.playbackState==Player.STATE_ENDED && player.playWhenReady && player.repeatMode==Player.REPEAT_MODE_OFF && !player.hasNextMediaItem()
        inFlight++
        val read=java.util.concurrent.FutureTask {
            LibraryShuffleContinuationSource(graph.api).fetch(scope,excluded,recentIds,20,deadline,::valid)
        }
        val io=jobs.launch(Dispatchers.IO) {read.run()}
        jobs.launch {
            try {
                // Poll completion on the service looper; never await a blocking socket's
                // cancellation acknowledgement beyond the aggregate admission deadline.
                while(!read.isDone && valid())delay(10)
                if(!valid())return@launch
                val tracks=read.get()
                if(!accepted() || tracks.isEmpty() || player.mediaItemCount+tracks.size>QueuePolicy.MAX_CONTEXT_TRACKS)return@launch
                // No await after acceptance: grant creation, append, select, prepare and play
                // execute atomically with respect to newer commands on the player looper.
                if(!accepted())return@launch
                val items=resolve(tracks,::accepted)
                if(!accepted())return@launch
                val start=player.mediaItemCount
                committing=true
                try {
                    if(player is ListeningServicePlayer)player.continueExhaustedQueue(items,::accepted) {
                        valid() && attempt===owner && revision==timelineRevision
                    }?.await()
                    else {player.addMediaItems(items);player.seekTo(start,0);player.prepare();player.play()}
                }finally {committing=false}
            }catch(_:Exception){/* Unrequested work fails silently, without playback error/toast. */}
            finally {read.cancel(true);io.cancel();inFlight--;owner.live.set(false);if(attempt===owner)attempt=null}
        }
    }
}
