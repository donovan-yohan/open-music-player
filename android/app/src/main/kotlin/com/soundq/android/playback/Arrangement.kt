package com.soundq.android.playback

import com.soundq.android.data.mix.*
import com.soundq.android.data.timeline.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.util.UUID

/** Installed by the service, not an optimistic UI selection or audible-output ACK. */
@Serializable data class ArrangementIdentity(val service:String,val accountEpoch:Long,val queue:String,val revision:Long,val install:String)
@Serializable data class AcceptedArrangement(val identity:ArrangementIdentity,val document:TimelineDocument,val sources:List<QueueOccurrence>)

/** No gain, stem or rate fields may disappear when crossing into the rate-one renderer. */
fun TimelineDocument.arrangementPlan(name:String="Arrangement"):SavedMix {
    require(clips.isNotEmpty() && revision>=0)
    require(tempoRamps.isEmpty()&&playbackTempos.isEmpty()&&!autoBpmCrossfade) {"Server v1 cannot preserve tempo transitions. Keep this local draft or explicitly remove its ramp before saving."}
    val schedule=compileSchedule(this)
    require(schedule.clips.all {it.rates.baseRate==1.0 && it.rates.segments.all {s->s.startRate==1.0&&s.endRate==1.0}}) {"Mixed audition currently supports rate-one arrangements only."}
    val mapped=schedule.clips.map {c -> MixJson.clip(buildJsonObject {
        put("clipId",c.occurrence);put("queueItemId",c.occurrence);put("trackId",c.track)
        put("sourceStartMs",c.sourceInMs);put("sourceEndMs",c.sourceOutMs);put("timelineStartMs",c.globalStartMs)
        put("gainDb",0);put("pitchMode","preserve");put("tempoPolicy","volumeOnly")
        if(c.fadeInMs!=0L)put("fadeInMs",c.fadeInMs)
        if(c.fadeOutMs!=0L)put("fadeOutMs",c.fadeOutMs)
    })}
    MixJson.draft(name,mapped)
    val plan=SavedMix(UUID.randomUUID().toString(),1,name,mapped)
    return plan
}

/** Readback adoption is exact and refuses fields the waveform editor cannot represent. */
fun TimelineDocument.matchesArrangement(plan:SavedMix):Boolean = runCatching {
    if(phaseLink!=null)return false
    val expected=arrangementPlan(plan.name)
    expected.clips==plan.clips
}.getOrDefault(false)

fun PlaybackProjection.timelineSources():List<TimelineSource>? {
    if(connection!=PlaybackProjection.Connection.Connected)return null
    val sources=when(source) {
        PlaybackSource.Arrangement -> arrangement?.sources ?: return null
        PlaybackSource.SavedMix -> return null
        PlaybackSource.Queue -> queue
    }
    if(sources.any {it.trackId<=0 || it.durationMs<=0})return null
    return sources.map {TimelineSource(it.occurrenceId,it.trackId,it.title,it.durationMs,when(it.origin){QueueOrigin.Manual->QueueSegment.Manual;QueueOrigin.Continuation->QueueSegment.Continuation;QueueOrigin.Context->QueueSegment.Context})}
}

fun AcceptedArrangement.sourcePositions(globalMs:Long):Map<String,Long> = projectTempoDocument(document).clips
    .filter {globalMs>=it.globalStartMs && globalMs<it.globalEndMs}
    .associate {it.occurrence to it.sourceAt(globalMs)}

/** Durable JSON omits derived maps. Rebuild before admission/equality, never infer new intent. */
fun AcceptedArrangement.withProjectedDocument():AcceptedArrangement=copy(document=projectTempoDocument(document))

/** Resolve names against occurrence identity, not recording ID, using the accepted compiled spans. */
fun TimelineDocument.arrangementMetadata(globalMs:Long, sourceMetadata:(String)->Pair<String,String>?):ArrangementMetadata {
    return arrangementMetadata(clips.map {clip ->
        val names=sourceMetadata(clip.occurrence)
        ArrangementMetadataClip(clip.occurrence,names?.first?.takeIf {it.isNotBlank()} ?: clip.title,
            names?.second.orEmpty(),clip.globalStartMs,clip.globalEndMs)
    },globalMs)
}

/** Source spans are not output duration when tempo changes. */
fun TimelineDocument.arrangementSeekTarget(globalMs:Long):Long=globalMs.coerceIn(0,projectTempoDocument(this).clips.maxOf {it.globalEndMs})

data class NativeArrangementPayload(val values:LongArray,val tempo:DoubleArray?,val durationMs:Long)

/** Native V2 is explicit; no server/rate-one mapper may discard a preserved law. */
fun TimelineDocument.nativeArrangementPayload():NativeArrangementPayload {
    require(clips.isNotEmpty() && revision>=0)
    val projected=projectTempoDocument(this)
    val schedule=compileSchedule(projected)
    val values=projected.clips.flatMap {listOf(it.globalStartMs,it.sourceInMs,it.sourceOutMs,it.fadeInMs,it.fadeOutMs,
        if(it.sourceOutMs==it.sourceDurationMs)it.sourceDurationMs else 0L)}.toLongArray()
    if(tempoRamps.isEmpty()&&playbackTempos.isEmpty()) {
        copy(autoBpmCrossfade=false).arrangementPlan()
        return NativeArrangementPayload(values,null,schedule.clips.maxOf {it.globalEndMs})
    }
    val tempo=projected.clips.flatMap {clip ->
        val map=clip.tempoMap
        if(map==null) {
            val held=playbackTempos.singleOrNull {it.source.occurrence==clip.occurrence}
            if(held==null) {
                require(clip.rates.baseRate==1.0&&clip.rates.segments.isEmpty()) {"Plain native clips require qualified playback BPM."}
                List(8){0.0}
            } else {
                require(clip.rates.segments.isEmpty()) {"Playback BPM cannot replace rate automation."}
                listOf(held.source.sourceBpm,held.playbackBpm,held.playbackBpm,clip.globalStartMs.toDouble(),clip.globalStartMs+1.0,held.source.beatAnchorMs,2.0,0.0)
            }
        } else {
            val intent=map.intent
            require(intent.gainLaw==TempoGainLaw.EqualPower) {"Native key-lock supports equal-power gain only."}
            require(clip.rates.segments.isEmpty()) {"Native key-lock cannot replace pre-overlap rate automation."}
            val source=if(clip.occurrence==intent.outgoing.occurrence)intent.outgoing else intent.incoming
            val law=map.law
            // V2 integrates one shared law from trimIn, including the held prefix.
            // The editor must not show a different map before the ramp begins.
            if(clip.globalStartMs.toDouble()<law.startMs)require(kotlin.math.abs(clip.rates.baseRate-law.startBpm/source.sourceBpm)<1e-9) {"Pre-overlap tempo differs from the native shared law."}
            require(kotlin.math.abs(clip.sourceInMs+law.sourceDeltaMs(clip.globalStartMs.toDouble(),law.startMs,source.sourceBpm)-map.sourceAtStartMs)<1e-6) {"Native original-source mapping differs from editor timing."}
            // V2 field 6 is an exact policy discriminator, not a boolean.
            val policy=when(intent.policy){TempoRampPolicy.SharedRampV1->1.0;TempoRampPolicy.AutoSourceBoundsV1->3.0}
            listOf(source.sourceBpm,law.startBpm,law.targetBpm,law.startMs,law.endMs,source.beatAnchorMs,policy,
                when(intent.curve){TempoCurve.LinearTime->0.0;TempoCurve.SmoothTime->1.0})
        }
    }.toDoubleArray()
    return NativeArrangementPayload(values,tempo,schedule.clips.maxOf {it.globalEndMs})
}
