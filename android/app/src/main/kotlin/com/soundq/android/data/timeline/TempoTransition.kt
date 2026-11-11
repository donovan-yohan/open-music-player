package com.soundq.android.data.timeline

import kotlinx.serialization.Serializable

@Serializable enum class TempoCurve { LinearTime, SmoothTime }
@Serializable enum class TempoTargetKind { Original, Custom }
@Serializable data class TempoTarget(val kind: TempoTargetKind, val customBpm: Double?)
@Serializable enum class TempoGainLaw { Linear, EqualPower }
/** Tempo precision is independent of the older integer-millisecond phase-link grid. */
data class TempoSourceTiming(val sourceKey:String,val revision:String,val provenance:String,val sourceBpm:Double,val beatAnchorMs:Double,val law:Int=1,val beatAnchorKnown:Boolean=true) {
    init {
        require(sourceKey.isNotBlank()&&sourceKey.length<=512&&revision.isNotBlank()&&revision.length<=512)
        require((if(beatAnchorKnown)provenance in setOf("local_manual","manual_timing_v2") else provenance in setOf("analysis_bpm","local_bpm")&&beatAnchorMs==0.0)&&sourceBpm.isFinite()&&sourceBpm in 10.0..600.0&&beatAnchorMs.isFinite()&&beatAnchorMs>=0.0&&law==1)
    }
    fun identity(clip:TimelineClip):TempoSourceIdentity {
        require(beatAnchorMs<=clip.sourceDurationMs)
        return TempoSourceIdentity(clip.occurrence,clip.track,sourceKey,clip.sourceDurationMs,revision,provenance,sourceBpm,beatAnchorMs,law,beatAnchorKnown)
    }
}
/** Frozen constant-period qualification. Revisions are opaque, never track-ID substitutes. */
@Serializable data class TempoSourceIdentity(
    val occurrence: String, val track: Long, val sourceKey: String, val durationMs: Long,
    val gridRevision: String, val gridProvenance: String, val sourceBpm: Double,
    val beatAnchorMs: Double, val gridLaw: Int, val beatAnchorKnown:Boolean=true,
)
/** Structural validity only. Repository separately verifies the current producer or local confirmation. */
internal fun TempoSourceIdentity.supportsTempoOnly():Boolean = track>0&&occurrence.isNotBlank()&&occurrence.length<=512&&durationMs in 1..604800000L&&
    runCatching {TempoSourceTiming(sourceKey,gridRevision,gridProvenance,sourceBpm,beatAnchorMs,gridLaw,beatAnchorKnown)}.isSuccess&&beatAnchorMs<=durationMs
/** All fields deliberately required. Absence in older documents MUST NOT enable a ramp. */
@Serializable enum class TempoRampPolicy { SharedRampV1, AutoSourceBoundsV1 }
@Serializable data class TempoPlaybackIntent(val source:TempoSourceIdentity,val playbackBpm:Double)
@Serializable data class TempoRampIntent(
    val version: Int, val policy: TempoRampPolicy, val outgoing: TempoSourceIdentity, val incoming: TempoSourceIdentity,
    val outgoingEffectiveStartBpm: Double, val target: TempoTarget, val curve: TempoCurve,
    val overlapStartMs: Double, val overlapEndMs: Double,
    val startSharedBeat: Long, val lengthBeats: Int, val gainLaw: TempoGainLaw,
)
data class TempoParticipantFit(
    val source: TempoSourceIdentity, val globalStartMs: Double,
    val sourceInMs: Double, val sourceOutMs: Double, val sourceAtOverlapStartMs: Double,
    val minRate: Double, val maxRate: Double,
)
data class TempoVoiceWindow(val occurrence: String, val startMs: Double, val endMs: Double)
data class TempoFitContext(
    val outgoing: TempoParticipantFit, val incoming: TempoParticipantFit,
    val otherWindows: List<TempoVoiceWindow>, val maxVoices: Int,
    val overlapStartMs: Double, val overlapEndMs: Double, val outgoingEffectiveStartBpm: Double, val startSharedBeat: Long,
)
enum class TempoFitReason { InvalidIntent, IdentityChanged, TimingNeeded, StretchLimit, SourceBounds, GeometryMismatch, BeatPhaseMismatch, BeatCountMismatch, ConnectedConflict, Capacity }
sealed interface TempoPlanResult {
    data class Invalid(val reason: TempoFitReason, val detail: String, val occurrences: List<String> = emptyList()): TempoPlanResult
    data class Valid(val plan: TempoTransitionPlan): TempoPlanResult
}
class TempoTransitionPlan(val intent: TempoRampIntent, val law: SharedTempoLaw, val outgoing: TempoParticipantFit, val incoming: TempoParticipantFit, val incomingEndMs: Double) {
    fun outgoingSourceAt(globalMs: Double): Double = outgoing.sourceAtOverlapStartMs+law.sourceDeltaMs(law.startMs,globalMs,outgoing.source.sourceBpm)
    fun incomingSourceAt(globalMs: Double): Double = incoming.sourceAtOverlapStartMs+law.sourceDeltaMs(law.startMs,globalMs,incoming.source.sourceBpm)
    fun incomingGlobalAt(sourceMs: Double): Double = law.globalForSourceDeltaMs(law.startMs,sourceMs-incoming.sourceAtOverlapStartMs,incoming.source.sourceBpm)
}
fun planTempoTransition(intent: TempoRampIntent, context: TempoFitContext): TempoPlanResult {
    fun invalid(reason: TempoFitReason, detail: String, ids: List<String> = emptyList()) = TempoPlanResult.Invalid(reason,detail,ids)
    fun positive(v: Double)=v.isFinite()&&v>0.0
    fun same(a: Double,b: Double)=a.isFinite()&&b.isFinite()&&kotlin.math.abs(a-b)<=1e-6
    val a=context.outgoing; val b=context.incoming
    val start=intent.overlapStartMs; val end=intent.overlapEndMs
    if(intent.policy!=TempoRampPolicy.SharedRampV1 || intent.version!=1 || !positive(intent.outgoingEffectiveStartBpm) || !start.isFinite() || !end.isFinite() || start<0.0 || end<=start || end>302400000000.0 ||
        intent.lengthBeats !in 1..65536 || !(intent.outgoingEffectiveStartBpm+(intent.target.customBpm ?: intent.incoming.sourceBpm)).isFinite() || intent.startSharedBeat !in -1000000000L..1000000000L ||
        intent.outgoing.occurrence==intent.incoming.occurrence ||
        (intent.target.kind==TempoTargetKind.Original&&intent.target.customBpm!=null) ||
        (intent.target.kind==TempoTargetKind.Custom&&!positive(intent.target.customBpm ?: Double.NaN)))
        return invalid(TempoFitReason.InvalidIntent,"Supply an explicit supported ramp, positive tempos and finite beat/time bounds.")
    if(intent.outgoing!=a.source || intent.incoming!=b.source || !same(intent.outgoingEffectiveStartBpm,context.outgoingEffectiveStartBpm))
        return invalid(TempoFitReason.IdentityChanged,"Source, grid or upstream effective tempo changed. Qualify again.")
    for(p in listOf(a,b)) {
        val s=p.source
        if(s.occurrence.isBlank()||s.occurrence.length>512||s.track<=0||s.sourceKey.isBlank()||s.sourceKey.length>512||s.gridRevision.isBlank()||s.gridRevision.length>512||
            s.durationMs !in 1..604800000L||s.gridLaw!=1||!s.beatAnchorKnown||s.gridProvenance !in setOf("local_manual","manual_timing_v2")||!positive(s.sourceBpm)||
            !s.beatAnchorMs.isFinite()||s.beatAnchorMs<0.0||s.beatAnchorMs>s.durationMs)
            return invalid(TempoFitReason.TimingNeeded,"Constant qualified source timing is needed.",listOf(s.occurrence))
        if(!p.globalStartMs.isFinite()||p.globalStartMs<0.0||!p.sourceInMs.isFinite()||!p.sourceOutMs.isFinite()||!p.sourceAtOverlapStartMs.isFinite()||
            p.sourceInMs<0.0||p.sourceOutMs<=p.sourceInMs||p.sourceOutMs>s.durationMs||p.sourceAtOverlapStartMs<p.sourceInMs||p.sourceAtOverlapStartMs>p.sourceOutMs)
            return invalid(TempoFitReason.SourceBounds,"Source selection is outside qualified audio.",listOf(s.occurrence))
    }
    if(intent.startSharedBeat!=context.startSharedBeat||!same(start,context.overlapStartMs)||!same(end,context.overlapEndMs)||a.globalStartMs>start||!same(b.globalStartMs,start)||!same(b.sourceInMs,b.sourceAtOverlapStartMs))
        return invalid(TempoFitReason.GeometryMismatch,"Keep the existing full overlap; moving boundaries requires an explicit placement edit.")
    val target=if(intent.target.kind==TempoTargetKind.Original)intent.incoming.sourceBpm else intent.target.customBpm!!
    for(p in listOf(a,b)) {
        val low=minOf(intent.outgoingEffectiveStartBpm,target)/p.source.sourceBpm
        val high=maxOf(intent.outgoingEffectiveStartBpm,target)/p.source.sourceBpm
        if(!positive(p.minRate)||!positive(p.maxRate)||p.maxRate<p.minRate||low<p.minRate||high>p.maxRate)
            return invalid(TempoFitReason.StretchLimit,"The shared pulse exceeds a participant's qualified stretch range.",listOf(p.source.occurrence))
        val phase=(p.sourceAtOverlapStartMs-p.source.beatAnchorMs)*p.source.sourceBpm/60000.0
        if(kotlin.math.abs(phase-kotlin.math.round(phase))>1e-7)
            return invalid(TempoFitReason.BeatPhaseMismatch,"Both overlap starts must be on qualified source beats.",listOf(p.source.occurrence))
    }
    val law=SharedTempoLaw(start,end,intent.outgoingEffectiveStartBpm,target,intent.curve)
    if(kotlin.math.abs(law.beatsAt(end)-intent.lengthBeats)>1e-7)
        return invalid(TempoFitReason.BeatCountMismatch,"Beat length and tempo do not fit the existing overlap duration.")
    val aEnd=a.sourceAtOverlapStartMs+law.sourceDeltaMs(start,end,a.source.sourceBpm)
    val bEnd=b.sourceAtOverlapStartMs+law.sourceDeltaMs(start,end,b.source.sourceBpm)
    if(aEnd>a.sourceOutMs+1e-6||bEnd>b.sourceOutMs+1e-6)
        return invalid(TempoFitReason.SourceBounds,"The shared law would run beyond selected source audio.")
    if(!same(aEnd,a.sourceOutMs))return invalid(TempoFitReason.GeometryMismatch,"Outgoing EOF does not coincide with overlap end. No source was trimmed.")
    if(context.maxVoices !in 2..4)return invalid(TempoFitReason.Capacity,"The shared pulse requires two available voices.")
    if(context.otherWindows.size>500 || context.otherWindows.any {it.occurrence.isBlank()||it.occurrence in listOf(a.source.occurrence,b.source.occurrence)||!it.startMs.isFinite()||!it.endMs.isFinite()||it.startMs<0.0||it.endMs<=it.startMs} || context.otherWindows.map {it.occurrence}.distinct().size!=context.otherWindows.size)
        return invalid(TempoFitReason.InvalidIntent,"Supply complete unique half-open peer windows.")
    val connected=context.otherWindows.filter {it.startMs<end&&it.endMs>start}
    if(connected.isNotEmpty())return invalid(TempoFitReason.ConnectedConflict,"A connected overlap needs one common multi-participant pulse; pairwise planning refused.",connected.map {it.occurrence})
    val incomingEnd=law.globalForSourceDeltaMs(start,b.sourceOutMs-b.sourceAtOverlapStartMs,b.source.sourceBpm)
    if(!incomingEnd.isFinite()||incomingEnd>302400000000.0)return invalid(TempoFitReason.SourceBounds,"Incoming target hold exceeds the supported timeline.")
    val windows=context.otherWindows+listOf(TempoVoiceWindow(a.source.occurrence,a.globalStartMs,end),TempoVoiceWindow(b.source.occurrence,start,incomingEnd))
    val edges=windows.flatMap {listOf(it.startMs to 1,it.endMs to -1)}.sortedWith(compareBy<Pair<Double,Int>> {it.first}.thenBy {it.second})
    var count=0
    for(edge in edges){count+=edge.second;if(count>context.maxVoices)return invalid(TempoFitReason.Capacity,"The target hold would exceed voice capacity.")}
    val heldPeers=context.otherWindows.filter {it.startMs<incomingEnd&&it.endMs>start}
    if(heldPeers.isNotEmpty())return invalid(TempoFitReason.ConnectedConflict,"The held target enters another overlap. Resolve one common component law first.",heldPeers.map {it.occurrence})
    return TempoPlanResult.Valid(TempoTransitionPlan(intent,law,a,b,incomingEnd))
}

/** Source-bounds policy deliberately does not claim beat alignment. Legacy planner remains strict. */
fun planSourceBoundsTempoTransition(intent:TempoRampIntent,context:TempoFitContext):TempoPlanResult {
    fun bad(reason:TempoFitReason,detail:String)=TempoPlanResult.Invalid(reason,detail)
    val a=context.outgoing;val b=context.incoming
    val start=intent.overlapStartMs;val end=intent.overlapEndMs
    val target=if(intent.target.kind==TempoTargetKind.Original)b.source.sourceBpm else intent.target.customBpm ?: Double.NaN
    if(intent.version!=1||intent.policy!=TempoRampPolicy.AutoSourceBoundsV1||intent.outgoing!=a.source||intent.incoming!=b.source||a.source.occurrence==b.source.occurrence)
        return bad(TempoFitReason.IdentityChanged,"The overlap source changed.")
    if(listOf(start,end,target,intent.outgoingEffectiveStartBpm).any {!it.isFinite()}||start<0||end<=start||end>302400000000.0||target !in 10.0..600.0||intent.outgoingEffectiveStartBpm !in 10.0..600.0||
        kotlin.math.abs(context.outgoingEffectiveStartBpm-intent.outgoingEffectiveStartBpm)>1e-7||kotlin.math.abs(b.globalStartMs-start)>1e-7||a.globalStartMs>start)
        return bad(TempoFitReason.GeometryMismatch,"Keep the incoming start inside the outgoing source.")
    for(p in listOf(a,b)) {
        val s=p.source
        if(!s.supportsTempoOnly())return bad(TempoFitReason.TimingNeeded,"Confirm the source BPM first.")
        if(listOf(p.sourceInMs,p.sourceOutMs,p.sourceAtOverlapStartMs).any {!it.isFinite()}||p.sourceInMs<0||p.sourceOutMs>s.durationMs||p.sourceOutMs<=p.sourceInMs||p.sourceAtOverlapStartMs !in p.sourceInMs..p.sourceOutMs)
            return bad(TempoFitReason.SourceBounds,"Selected source audio changed.")
        if(minOf(target,intent.outgoingEffectiveStartBpm)/s.sourceBpm<0.8||maxOf(target,intent.outgoingEffectiveStartBpm)/s.sourceBpm>1.5)return bad(TempoFitReason.StretchLimit,"The shared BPM exceeds a track's stretch range.")
    }
    if(context.maxVoices !in 2..4||context.otherWindows.size>500||context.otherWindows.any {it.occurrence.isBlank()||it.occurrence in listOf(a.source.occurrence,b.source.occurrence)||!it.startMs.isFinite()||!it.endMs.isFinite()||it.startMs<0||it.endMs<=it.startMs}||context.otherWindows.map {it.occurrence}.distinct().size!=context.otherWindows.size)
        return bad(TempoFitReason.InvalidIntent,"Complete current occurrence windows are required.")
    val law=SharedTempoLaw(start,end,intent.outgoingEffectiveStartBpm,target,intent.curve)
    if(kotlin.math.abs(a.sourceAtOverlapStartMs+law.sourceDeltaMs(start,end,a.source.sourceBpm)-a.sourceOutMs)>1e-6)
        return bad(TempoFitReason.GeometryMismatch,"The shared BPM must reach the selected outgoing EOF exactly.")
    if(kotlin.math.abs(b.sourceAtOverlapStartMs-b.sourceInMs)>1e-7||b.sourceAtOverlapStartMs+law.sourceDeltaMs(start,end,b.source.sourceBpm)>b.sourceOutMs+1e-6)
        return bad(TempoFitReason.SourceBounds,"Not enough incoming audio for this crossfade.")
    val incomingEnd=law.globalForSourceDeltaMs(start,b.sourceOutMs-b.sourceInMs,b.source.sourceBpm)
    if(!incomingEnd.isFinite()||incomingEnd>302400000000.0)return bad(TempoFitReason.SourceBounds,"Playback duration exceeds the timeline limit.")
    val windows=context.otherWindows+listOf(TempoVoiceWindow(a.source.occurrence,a.globalStartMs,end),TempoVoiceWindow(b.source.occurrence,start,incomingEnd))
    var count=0
    for(edge in windows.flatMap {listOf(it.startMs to 1,it.endMs to -1)}.sortedWith(compareBy<Pair<Double,Int>> {it.first}.thenBy {it.second})) {
        count+=edge.second;if(count>context.maxVoices)return bad(TempoFitReason.Capacity,"This BPM would create a fifth overlapping track. No edits were saved.")
    }
    if(context.otherWindows.any {it.startMs<end&&it.endMs>start})return bad(TempoFitReason.ConnectedConflict,"Auto BPM currently needs an overlap with only these two tracks.")
    if(context.otherWindows.any {it.startMs<incomingEnd&&it.endMs>start})return bad(TempoFitReason.ConnectedConflict,"This BPM would enter another overlap. Choose a different target or edit placement first; nothing was moved or trimmed.")
    return TempoPlanResult.Valid(TempoTransitionPlan(intent,law,a,b,incomingEnd))
}

/** One atomic candidate. Source selection, global starts and gain fades are never rewritten. */
fun TimelineDocument.withPlaybackTempo(intent:TempoPlaybackIntent):TimelineDocument {
    val clip=clips.singleOrNull {it.occurrence==intent.source.occurrence} ?: error("Track left the arrangement.")
    require(clip.track==intent.source.track&&clip.sourceDurationMs==intent.source.durationMs) {"Source changed. Open BPM again."}
    require(tempoRamps.none {it.policy==TempoRampPolicy.SharedRampV1&&(it.outgoing.occurrence==clip.occurrence||it.incoming.occurrence==clip.occurrence)}) {"This saved beat-fitted transition owns playback BPM. Remove it explicitly before changing the target."}
    val next=copy(playbackTempos=playbackTempos.filterNot {it.source.occurrence==clip.occurrence}+intent)
    val ids=(tempoRamps.flatMap {listOf(it.outgoing,it.incoming)}+next.playbackTempos.map {it.source}).associateBy {it.occurrence}.values.toList()
    return next.withAutoBpmCrossfade(autoBpmCrossfade,ids)
}
fun TimelineDocument.withAutoBpmCrossfade(enabled:Boolean,sources:List<TempoSourceIdentity>):TimelineDocument {
    val legacy=tempoRamps.filter {it.policy==TempoRampPolicy.SharedRampV1}
    val base=projectTempoDocument(copy(tempoRamps=legacy,autoBpmCrossfade=enabled))
    if(!enabled)return base.also {require(validateTimeline(it.clips)==null){validateTimeline(it.clips).orEmpty()}}
    val ids=(sources+playbackTempos.map {it.source}).associateBy {it.occurrence}
    val occupied=legacy.flatMap {listOf(it.outgoing.occurrence,it.incoming.occurrence)}.toMutableSet()
    val ramps=mutableListOf<TempoRampIntent>()
    val ordered=base.clips.sortedBy {it.globalStartMs}
    for((a,b) in ordered.zipWithNext()) {
        if(b.globalStartMs>=a.globalEndMs)continue
        if(a.occurrence in occupied||b.occurrence in occupied) {
            require(legacy.any {it.outgoing.occurrence==a.occurrence&&it.incoming.occurrence==b.occurrence}) {"Connected overlaps need one common BPM law. No edits were saved."}
            continue
        }
        require(a.globalStartMs<b.globalStartMs&&a.globalEndMs<=b.globalEndMs) {"Auto BPM needs an outgoing and incoming overlap. No placement was changed."}
        val sa=ids[a.occurrence] ?: error("Source timing needed for ${a.title}.")
        val sb=ids[b.occurrence] ?: error("Source timing needed for ${b.title}.")
        val start=b.globalStartMs.toDouble();val effective=a.rates.baseRate*sa.sourceBpm
        val target=base.playbackTempos.singleOrNull {it.source.occurrence==b.occurrence}?.playbackBpm ?: sb.sourceBpm
        val remaining=a.sourceOutMs-a.sourceAtExact(start)
        val end=start+remaining*sa.sourceBpm*2.0/(effective+target)
        require(end>start) {"No outgoing audio remains for the overlap."}
        ramps+=TempoRampIntent(1,TempoRampPolicy.AutoSourceBoundsV1,sa,sb,effective,TempoTarget(TempoTargetKind.Custom,target),TempoCurve.LinearTime,start,end,0,1,TempoGainLaw.EqualPower)
        require(occupied.add(a.occurrence)&&occupied.add(b.occurrence)) {"Connected BPM changes need a common law. Draft unchanged."}
    }
    val result=projectTempoDocument(base.copy(tempoRamps=legacy+ramps))
    require(validateTimeline(result.clips)==null){validateTimeline(result.clips).orEmpty()}
    return result
}

/** Shared pulse in milliseconds; source BPM is never changed. */
class SharedTempoLaw(
    val startMs: Double, val endMs: Double, val startBpm: Double,
    val targetBpm: Double, val curve: TempoCurve,
) {
    private val durationMs = endMs-startMs
    init {
        require(startMs.isFinite()&&endMs.isFinite()&&durationMs.isFinite()&&durationMs>0.0)
        require(startBpm.isFinite()&&targetBpm.isFinite()&&startBpm>0.0&&targetBpm>0.0&&(startBpm+targetBpm).isFinite())
    }
    fun bpmAt(globalMs: Double): Double {
        require(globalMs.isFinite())
        val u=((globalMs-startMs)/durationMs).coerceIn(0.0,1.0)
        val f=if(curve==TempoCurve.LinearTime)u else u*u*(3.0-2.0*u)
        return startBpm+(targetBpm-startBpm)*f
    }
    fun beatsAt(globalMs: Double): Double {
        require(globalMs.isFinite())
        val elapsed=globalMs-startMs
        if(elapsed<=0.0)return elapsed*startBpm/60000.0
        if(globalMs>=endMs)return durationMs*(startBpm+targetBpm)/120000.0+(globalMs-endMs)*targetBpm/60000.0
        val u=elapsed/durationMs
        val h=if(curve==TempoCurve.LinearTime)u*u/2.0 else u*u*u*(1.0-u/2.0)
        return durationMs*(startBpm*u+(targetBpm-startBpm)*h)/60000.0
    }
    fun sourceDeltaMs(fromMs: Double, toMs: Double, sourceBpm: Double): Double {
        require(sourceBpm.isFinite()&&sourceBpm>0.0)
        return (beatsAt(toMs)-beatsAt(fromMs))*60000.0/sourceBpm
    }
    fun rateAt(globalMs: Double, sourceBpm: Double): Double {
        require(sourceBpm.isFinite()&&sourceBpm>0.0)
        return bpmAt(globalMs)/sourceBpm
    }
    /** First integer millisecond whose rounded integrated source displacement reaches delta. */
    fun globalForRoundedSourceDeltaMs(fromMs: Long, deltaMs: Long, sourceBpm: Double): Long {
        // All integer arithmetic is exact within this explicitly bounded timeline domain.
        require(fromMs in -302400000000L..302400000000L&&deltaMs in -604800000L..604800000L)
        val estimate=globalForSourceDeltaMs(fromMs.toDouble(),deltaMs.toDouble()-0.5,sourceBpm)
        require(estimate.isFinite()&&estimate in -302400000000.0..302400000000.0)
        fun reached(t:Long)=kotlin.math.floor(sourceDeltaMs(fromMs.toDouble(),t.toDouble(),sourceBpm)+0.5)>=deltaMs.toDouble()
        var low=kotlin.math.floor(estimate).toLong()-2L
        var high=kotlin.math.ceil(estimate).toLong()+2L
        var step=4L
        while(reached(low)){high=low;low-=step;step*=2;require(low>=-302400000000L)}
        step=4L
        while(!reached(high)){low=high;high+=step;step*=2;require(high<=302400000000L)}
        while(high-low>1L){val mid=low+(high-low)/2L;if(reached(mid))high=mid else low=mid}
        return high
    }
    fun globalForSourceDeltaMs(fromMs: Double, deltaMs: Double, sourceBpm: Double): Double {
        require(deltaMs.isFinite()&&sourceBpm.isFinite()&&sourceBpm>0.0)
        val target=beatsAt(fromMs)+deltaMs*sourceBpm/60000.0
        require(target.isFinite())
        val total=durationMs*(startBpm+targetBpm)/120000.0
        if(target<=0.0)return startMs+target*60000.0/startBpm
        if(target>=total)return endMs+(target-total)*60000.0/targetBpm
        var low=startMs
        var high=endMs
        repeat(64) {
            val mid=low+(high-low)/2.0
            if(beatsAt(mid)<target)low=mid else high=mid
        }
        return low+(high-low)/2.0
    }
}
