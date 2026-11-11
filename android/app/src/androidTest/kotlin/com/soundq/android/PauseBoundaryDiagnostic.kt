package com.soundq.android

import androidx.media3.common.Player
import androidx.media3.common.ForwardingPlayer
import androidx.media3.session.MediaSession
import com.soundq.android.product.ProductViewModel
import org.json.JSONArray
import org.json.JSONObject

/** Bounded, read-only test diagnostic. No dispatch, seek, retry or relaxed admission. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class PauseBoundaryDiagnostic(private val model:ProductViewModel,private val accountVersion:()->Long):AutoCloseable {
    private val player:Player=run {
        val field=MediaSession::class.java.getDeclaredField("SESSION_ID_TO_SESSION_MAP").apply {isAccessible=true}
        @Suppress("UNCHECKED_CAST")
        (field.get(null) as Map<String,MediaSession>).values.single().player
    }
    private val events=ArrayDeque<JSONObject>()
    private var dropped=0
    private var prePause:JSONObject?=null
    private var closed=false
    private val listener=object:Player.Listener {
        override fun onEvents(source:Player,changed:Player.Events) {record("service-events",JSONObject().put("codes",JSONArray((0 until changed.size()).map {changed.get(it)})))}
        override fun onPositionDiscontinuity(old:Player.PositionInfo,next:Player.PositionInfo,reason:Int) {
            record("discontinuity",JSONObject().put("reason",reason).put("oldMs",old.positionMs).put("newMs",next.positionMs).put("oldOccurrence",old.mediaItem?.mediaId).put("newOccurrence",next.mediaItem?.mediaId))
        }
        override fun onMediaItemTransition(item:androidx.media3.common.MediaItem?,reason:Int) {record("transition",JSONObject().put("reason",reason).put("occurrence",item?.mediaId))}
    }
    init {player.addListener(listener);record("attached")}
    private fun field(owner:Any,name:String):Any?=owner.javaClass.getDeclaredField(name).apply {isAccessible=true}.get(owner)
    private fun snapshot(stage:String):JSONObject {
        val projection=model.playback.value
        val chain=mutableListOf<String>();var output=player
        val visited=java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Player,Boolean>())
        while(output is ForwardingPlayer) {
            check(visited.size<16&&visited.add(output));chain.add(output.javaClass.name);output=output.wrappedPlayer
        }
        chain.add(output.javaClass.name)
        val c=field(model.controller,"controller")
        val impl=c?.let {field(it,"impl")}
        return JSONObject().put("stage",stage).put("uptimeMs",android.os.SystemClock.uptimeMillis())
            .put("accountVersion",accountVersion()).put("serviceState",player.playbackState)
            .put("servicePositionMs",player.currentPosition).put("serviceDurationMs",player.duration)
            .put("serviceIndex",player.currentMediaItemIndex).put("serviceOccurrence",player.currentMediaItem?.mediaId)
            .put("servicePlaying",player.isPlaying).put("servicePlayWhenReady",player.playWhenReady)
            .put("serviceQueue",JSONArray((0 until player.mediaItemCount).map {player.getMediaItemAt(it).mediaId}))
            .put("projectionPositionMs",projection.positionMs).put("projectionDurationMs",projection.durationMs)
            .put("projectionPlaying",projection.isPlaying).put("projectionOccurrence",projection.selectedOccurrence)
            .put("projectionQueue",JSONArray(projection.queue.map {it.occurrenceId}))
            .put("outputPositionMs",output.currentPosition).put("outputState",output.playbackState)
            .put("outputPlaying",output.isPlaying).put("wrapperChain",JSONArray(chain))
            .put("outputPendingAcks",if(output.javaClass.name=="androidx.media3.exoplayer.ExoPlayerImpl")field(output,"pendingOperationAcks") else "unsupported-output")
            .put("controllerPendingAcks",impl?.let {(field(it,"pendingMaskingSequencedFutureNumbers") as Collection<*>).size} ?: -1)
            .put("controllerPendingInfo",impl?.let {field(it,"pendingPlayerInfo")!=null} ?: true)
    }
    private fun observe(stage:String):JSONObject=try {snapshot(stage)} catch(failure:Throwable) {
        // A diagnostic reflection gap must not intercept service delivery or the original Pause.
        JSONObject().put("stage",stage).put("diagnosticFailure",failure.javaClass.name)
    }
    private fun record(stage:String,extra:JSONObject?=null) {
        if(closed)return
        if(events.size==128){events.removeFirst();dropped++}
        events.addLast(observe(stage).put("event",extra))
    }
    /** Separate reserved snapshots cannot be evicted by a busy service event stream. */
    fun beforePause(){prePause=observe("immediately-before-pause")}
    override fun close() {
        if(closed)return
        val terminal=observe("terminal");closed=true;player.removeListener(listener)
        val report=JSONObject().put("beforePause",prePause)
            .put("terminal",terminal).put("droppedEvents",dropped).put("events",JSONArray(events.toList()))
        // Keep complete JSON outside logcat's per-line limit, with only bounded local test data.
        val context=androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext
        context.filesDir.resolve("pause-boundary-diagnostic.json").writeText(report.toString())
        android.util.Log.i("SoundQPauseBoundary",JSONObject().put("beforePause",prePause).put("terminal",terminal).put("droppedEvents",dropped).put("retainedEvents",events.size).toString())
    }
}
