package com.soundq.android.playback.system

import android.os.*
import androidx.media3.common.*
import com.soundq.android.data.*
import kotlinx.coroutines.*

/** Observe the sole service player. HTTP is off-main and never gates audio. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class ServicePlayRecorder(private val player:Player,private val session:AccountSession,private val api:SoundQApi):AutoCloseable {
    private val handler=Handler(Looper.getMainLooper())
    private val io=CoroutineScope(SupervisorJob()+Dispatchers.IO)
    private val decider=PlayEventDecider()
    private var owner:AccountScope?=null
    @Volatile private var closed=false
    private fun observe() {
        val scope=session.capture()
        if(scope==null || !session.remoteCurrent(scope)){owner=null;decider.reset();logicalDeciders.clear();return}
        if(owner?.let(session::current)!=true){owner=scope;decider.reset();logicalDeciders.clear()}
        val item=player.currentMediaItem ?: return decider.reset()
        val track=item.mediaMetadata.extras?.getLong("trackId") ?: return
        if(track<=0 || item.mediaMetadata.extras?.getBoolean("localOnly")==true){decider.reset();return}
        val policy=if(logicalCompletion==null)decider else logicalDecider(item)
        policy.observePosition(item.mediaId,track,player.currentPosition.coerceAtLeast(0))?.let {emit(scope,it)}
    }
    private fun emit(scope:AccountScope,track:Long) {
        // Capability survives track advance but not account retirement; do not retry uncertain POST.
        io.launch {try {if(!closed && session.remoteCurrent(scope))api.recordPlay(scope,TrackId(track)){!closed && session.remoteCurrent(scope)}}catch(_:Exception){/* At most one attempt, no blind retry. */}}
    }
    private fun complete(item:MediaItem?) {
        val scope=owner ?: return
        if(!session.remoteCurrent(scope)||item==null||item.mediaMetadata.extras?.getBoolean("localOnly")==true)return
        val track=item.mediaMetadata.extras?.getLong("trackId") ?: return
        decider.completed(item.mediaId,track)?.let {emit(scope,it)}
    }
    private val logicalCompletion=player as? com.soundq.android.playback.listening.ListeningCompletionPlayer
    private val logicalDeciders=mutableMapOf<String,PlayEventDecider>()
    private fun logicalDecider(item:MediaItem):PlayEventDecider {
        val occurrences=(0 until player.mediaItemCount).map {player.getMediaItemAt(it).mediaId}
        if(logicalDeciders.keys!=occurrences.toSet()) {
            logicalDeciders.clear()
            var lastTrack=0L;var group=PlayEventDecider()
            for(i in 0 until player.mediaItemCount) {
                val row=player.getMediaItemAt(i);val track=row.mediaMetadata.extras?.getLong("trackId") ?: 0
                if(track!=lastTrack){group=PlayEventDecider();lastTrack=track}
                logicalDeciders[row.mediaId]=group
            }
        }
        return logicalDeciders.getValue(item.mediaId)
    }
    private val completionListener:(MediaItem)->Unit={item->
        val scope=owner
        if(scope!=null && session.remoteCurrent(scope) && item.mediaMetadata.extras?.getBoolean("localOnly")!=true) {
            val track=item.mediaMetadata.extras?.getLong("trackId") ?: 0
            if(track>0) {
                val policy=logicalDecider(item)
                policy.observePosition(item.mediaId,track,item.mediaMetadata.extras?.getLong("durationMs") ?: 0)?.let {emit(scope,it)}
                policy.completed(item.mediaId,track)?.let {emit(scope,it)}
            }
        }
    }
    private val listener=object:Player.Listener {
        override fun onIsPlayingChanged(isPlaying:Boolean){observe()}
        override fun onPositionDiscontinuity(oldPosition:Player.PositionInfo,newPosition:Player.PositionInfo,reason:Int) {
            if(logicalCompletion==null && reason==Player.DISCONTINUITY_REASON_AUTO_TRANSITION)complete(oldPosition.mediaItem)
            observe()
        }
        override fun onPlaybackStateChanged(playbackState:Int){if(logicalCompletion==null && playbackState==Player.STATE_ENDED)complete(player.currentMediaItem);observe()}
        override fun onMediaItemTransition(mediaItem:MediaItem?,reason:Int){observe()}
    }
    private val tick=object:Runnable {override fun run(){if(!closed){observe();handler.postDelayed(this,1000)}}}
    init {player.addListener(listener);logicalCompletion?.addCompletionListener(completionListener);observe();handler.post(tick)}
    override fun close(){if(closed)return;closed=true;player.removeListener(listener);logicalCompletion?.removeCompletionListener(completionListener);handler.removeCallbacks(tick);decider.reset();logicalDeciders.clear();owner=null;io.cancel()}
}
