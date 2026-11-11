package com.soundq.android

import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.MediaSession
import com.soundq.android.playback.PlaybackProjection
import com.soundq.android.playback.QueueOrigin
import com.soundq.android.product.ProductViewModel
import org.json.JSONArray
import org.json.JSONObject

/** Equality is observation readiness, not an assertion that manual/origin is correct. */
internal data class QueueFields(val occurrenceId:String,val trackId:Long,val manual:Boolean,val origin:String,val durationMs:Long)
internal data class QueueReadback(
    val projected:List<QueueFields>,val service:List<QueueFields>,val controller:List<QueueFields>,
    val projectedSelected:String?,val serviceSelected:String?,val controllerSelected:String?,
    val projectedPlaying:Boolean,val servicePlaying:Boolean,val controllerPlaying:Boolean,
    val servicePlayWhenReady:Boolean,val controllerPlayWhenReady:Boolean,
    val pendingMasking:Int,val pendingOutput:Int,val pendingInfo:Boolean,val connected:Boolean
) {
    fun acknowledged(expectedSize:Int,expectedSelected:String?):Boolean =
        connected && pendingMasking==0 && pendingOutput==0 && !pendingInfo &&
        service.size==expectedSize && service==controller && service==projected &&
        projectedSelected==expectedSelected && serviceSelected==expectedSelected && controllerSelected==expectedSelected &&
        !projectedPlaying && !servicePlaying && !controllerPlaying && !servicePlayWhenReady && !controllerPlayWhenReady
}

internal data class AcknowledgedQueueObservation(val projection:PlaybackProjection,val readback:QueueReadback,val diagnostic:JSONObject)

/** Read the pinned same-process Media3 1.11.1 shapes on their main application looper.
 * No commands, listeners, publication calls or positive cursor requirement. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal fun acknowledgedQueueObservation(model:ProductViewModel):AcknowledgedQueueObservation {
    check(android.os.Looper.myLooper()==android.os.Looper.getMainLooper())
    fun field(owner:Any,name:String):Any? = owner.javaClass.getDeclaredField(name).apply {isAccessible=true}.get(owner)
    val sessions=MediaSession::class.java.getDeclaredField("SESSION_ID_TO_SESSION_MAP").apply {isAccessible=true}.get(null) as Map<*,*>
    val service=(sessions.values.single() as MediaSession).player
    val controller=checkNotNull(field(model.controller,"controller") as MediaController?) {"Queue controller unavailable"}
    val impl=checkNotNull(field(controller,"impl"))
    check(impl.javaClass.name=="androidx.media3.session.MediaControllerImplBase") {"Unsupported queue controller shape"}
    var output=service
    val visited=java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Player,Boolean>())
    while(output is androidx.media3.common.ForwardingPlayer) {
        check(visited.size<16 && visited.add(output)) {"Unsupported queue output wrapper chain"}
        output=output.wrappedPlayer
    }
    val pendingOutput=when(output.javaClass.name) {
        "androidx.media3.exoplayer.ExoPlayerImpl" -> field(output,"pendingOperationAcks") as Int
        "com.soundq.android.playback.nativeengine.NativeCallbackPlayer" -> nativePausedOutputPending(output)
        else -> error("Unsupported queue output shape: ${output.javaClass.name}")
    }
    fun fields(player:Player)=(0 until player.mediaItemCount).map {i->
        val item=player.getMediaItemAt(i);val e=item.mediaMetadata.extras;val manual=e?.getBoolean("manual")==true
        QueueFields(item.mediaId,e?.getLong("trackId") ?: 0,manual,QueueOrigin.read(e?.getString("origin"),manual).name,e?.getLong("durationMs") ?: 0)
    }
    fun items(values:List<QueueFields>)=JSONArray(values.map {v->JSONObject().put("occurrenceId",v.occurrenceId)
        .put("trackId",v.trackId).put("manual",v.manual).put("origin",v.origin).put("durationMs",v.durationMs)})
    fun raw(player:Player)=JSONArray((0 until player.mediaItemCount).map {i->
        val item=player.getMediaItemAt(i);val e=item.mediaMetadata.extras
        JSONObject().put("occurrenceId",item.mediaId).put("metadataManualPresent",e?.containsKey("manual")==true)
            .put("metadataOrigin",e?.getString("origin") ?: JSONObject.NULL)
            .put("requestManual",item.requestMetadata.extras?.getBoolean("manual")==true)
    })
    val projection=model.playback.value
    val readback=QueueReadback(projection.queue.map {QueueFields(it.occurrenceId,it.trackId,it.manual,it.origin.name,it.durationMs)},
        fields(service),fields(controller),projection.selectedOccurrence,service.currentMediaItem?.mediaId,controller.currentMediaItem?.mediaId,
        projection.isPlaying,service.isPlaying,controller.isPlaying,service.playWhenReady,controller.playWhenReady,
        (field(impl,"pendingMaskingSequencedFutureNumbers") as Collection<*>).size,
        pendingOutput,field(impl,"pendingPlayerInfo")!=null,controller.isConnected)
    val diagnostic=JSONObject().put("projected",items(readback.projected)).put("service",items(readback.service))
        .put("controller",items(readback.controller)).put("serviceRaw",raw(service)).put("controllerRaw",raw(controller))
        .put("projectedSelected",readback.projectedSelected ?: JSONObject.NULL).put("serviceSelected",readback.serviceSelected ?: JSONObject.NULL)
        .put("controllerSelected",readback.controllerSelected ?: JSONObject.NULL).put("projectedPlaying",readback.projectedPlaying)
        .put("servicePlaying",readback.servicePlaying).put("controllerPlaying",readback.controllerPlaying)
        .put("servicePlayWhenReady",readback.servicePlayWhenReady).put("controllerPlayWhenReady",readback.controllerPlayWhenReady)
        .put("pendingMasking",readback.pendingMasking).put("pendingOutput",readback.pendingOutput).put("pendingInfo",readback.pendingInfo)
        .put("connected",readback.connected).put("queueRevision",projection.queueRevision)
        .put("controllerQueueRevision",field(model.controller,"queueRevision")).put("projectedRevision",field(model.controller,"projectedRevision"))
    return AcknowledgedQueueObservation(projection,readback,diagnostic)
}
