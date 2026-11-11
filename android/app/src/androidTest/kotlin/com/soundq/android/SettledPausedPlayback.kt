package com.soundq.android

import androidx.compose.ui.test.junit4.ComposeTestRule
import androidx.media3.session.MediaSession
import com.soundq.android.playback.PlaybackProjection
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*

/** Test-only readback of the real same-process session player, not the controller's
 * immediate optimistic pause mask. No pause/seek or other player mutation here.
 * Media3 1.11.1 has no public same-process session lookup; keep reflection in tests. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal data class SettledPausedSnapshot(val projection:PlaybackProjection,val servicePositionMs:Long)

internal fun ComposeTestRule.settledPausedPlayback(model:ProductViewModel):SettledPausedSnapshot {
    var settled:SettledPausedSnapshot?=null
    waitUntil(5000) {
        runOnIdle {
            val session=actualSession()
            val player=session.player
            val projection=model.playback.value
            android.util.Log.i("SoundQPauseProof","serviceMs=${player.currentPosition};serviceReady=${player.playWhenReady};servicePlaying=${player.isPlaying};projectionMs=${projection.positionMs};projectionPlaying=${projection.isPlaying}")
            if(!player.playWhenReady && !player.isPlaying && player.currentPosition>0 &&
                !projection.isPlaying && pendingAcks(model,player)==0 &&
                projection.positionMs==player.currentPosition &&
                projection.selectedOccurrence==player.currentMediaItem?.mediaId &&
                projection.queue.map {it.occurrenceId}==(0 until player.mediaItemCount).map {player.getMediaItemAt(it).mediaId}) {
                settled=SettledPausedSnapshot(projection,player.currentPosition)
                true
            } else false
        }
    }
    return checkNotNull(settled)
}

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal fun assertActualPausedUnchanged(settled:SettledPausedSnapshot) {
    val before=settled.projection
    val player=actualSession().player
    assertFalse(player.playWhenReady);assertFalse(player.isPlaying)
    assertEquals(settled.servicePositionMs,player.currentPosition)
    assertEquals(before.selectedOccurrence,player.currentMediaItem?.mediaId)
    assertEquals(before.queue.map {it.occurrenceId},(0 until player.mediaItemCount).map {player.getMediaItemAt(it).mediaId})
}

private fun pendingAcks(model:ProductViewModel,player:androidx.media3.common.Player):Int {
    fun field(owner:Any,name:String):Any? = owner.javaClass.getDeclaredField(name).apply {isAccessible=true}.get(owner)
    val controller=field(model.controller,"controller") ?: return -1
    val impl=field(controller,"impl") ?: return -1
    val pending=field(impl,"pendingMaskingSequencedFutureNumbers") as Collection<*>
    // Same output player, through the pinned public Media3 wrapper boundary only.
    var output=player
    val visited=java.util.Collections.newSetFromMap(java.util.IdentityHashMap<androidx.media3.common.Player,Boolean>())
    while(output is androidx.media3.common.ForwardingPlayer) {
        check(visited.size<16 && visited.add(output)) {"Unsupported or cyclic paused-service player wrapper chain"}
        output=output.wrappedPlayer
    }
    val playerAcks=when(output.javaClass.name) {
        "androidx.media3.exoplayer.ExoPlayerImpl" -> field(output,"pendingOperationAcks") as Int
        "com.soundq.android.playback.nativeengine.NativeCallbackPlayer" -> nativePausedOutputPending(output)
        else -> error("Unsupported paused-service output player: ${output.javaClass.name}")
    }
    return pending.size+playerAcks+if(field(impl,"pendingPlayerInfo")!=null)1 else 0
}

@Suppress("UNCHECKED_CAST")
private fun actualSession():MediaSession {
    val field=MediaSession::class.java.getDeclaredField("SESSION_ID_TO_SESSION_MAP").apply {isAccessible=true}
    return (field.get(null) as Map<String,MediaSession>).values.single()
}
