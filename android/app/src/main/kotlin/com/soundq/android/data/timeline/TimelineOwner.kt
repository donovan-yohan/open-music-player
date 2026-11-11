package com.soundq.android.data.timeline

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

enum class EditKind { Placement, TrimIn, TrimOut }
enum class SnapMode { Free, Beat, Bar }
@Serializable data class TimelineDocument(val revision: Long = 0, val clips: List<TimelineClip> = emptyList(), val phaseLink:PhaseLink?=null,
    val tempoRamps:List<TempoRampIntent> = emptyList(),
    val playbackTempos:List<TempoPlaybackIntent> = emptyList(),val autoBpmCrossfade:Boolean=false)
/** Whole immutable transaction. Repository separately owns live source/route qualification. */
data class TimelineTempoEdit(val original:TimelineDocument,val candidate:TimelineDocument)

/** Rebuild transient maps from durable intent. Never infer a new policy from old rates/fades. */
fun projectTempoDocument(document:TimelineDocument):TimelineDocument {
    require(document.tempoRamps.size<=250) {"Too many tempo transitions."}
    require(document.playbackTempos.size<=500 && document.playbackTempos.map {it.source.occurrence}.distinct().size==document.playbackTempos.size) {"Duplicate playback tempo."}
    var clips=document.clips.map {c->
        val held=document.playbackTempos.singleOrNull {it.source.occurrence==c.occurrence}
        if(held==null)c.copy(tempoMap=null,heldTempo=null) else {
            val s=held.source
            require(s.track==c.track&&s.durationMs==c.sourceDurationMs&&s.occurrence==c.occurrence) {"Playback source changed."}
            require(s.supportsTempoOnly()) {"Source BPM needed."}
            require(held.playbackBpm.isFinite()&&held.playbackBpm in 10.0..600.0&&held.playbackBpm/s.sourceBpm in 0.8..1.5) {"Playback BPM exceeds the supported stretch range."}
            require(c.rates.segments.isEmpty()&&document.phaseLink?.contains(c.occurrence)!=true) {"Remove the separate timing automation before editing playback BPM."}
            c.copy(tempoMap=null,heldTempo=held,rates=RateAutomation(held.playbackBpm/s.sourceBpm))
        }
    }
    require(document.playbackTempos.all {held->clips.any {it.occurrence==held.source.occurrence}}) {"A playback tempo source left the arrangement. Saved intent is retained."}
    val used=mutableSetOf<String>()
    for(intent in document.tempoRamps) {
        val a=clips.single {it.occurrence==intent.outgoing.occurrence};val b=clips.single {it.occurrence==intent.incoming.occurrence}
        require(used.add(a.occurrence)&&used.add(b.occurrence)) {"Connected tempo ramps need one common component law."}
        require(document.phaseLink?.let {it.contains(a.occurrence)||it.contains(b.occurrence)}!=true) {"Phase link is a separate policy. Unlock it before authoring a ramp."}
        require(a.track==intent.outgoing.track&&b.track==intent.incoming.track&&a.sourceDurationMs==intent.outgoing.durationMs&&b.sourceDurationMs==intent.incoming.durationMs) {"Captured tempo source changed."}
        require(listOf(intent.outgoing.sourceBpm,intent.incoming.sourceBpm,intent.outgoingEffectiveStartBpm,intent.target.customBpm ?: intent.incoming.sourceBpm).all {it.isFinite()&&it in 10.0..600.0}) {"Tempo is outside the native producer's supported BPM range."}
        val start=intent.overlapStartMs
        require(a.rates.segments.none {it.endMs>start}&&b.rates.segments.isEmpty()) {"A ramp cannot overwrite another rate automation."}
        val effective=a.rates.rateAtExact(start)*intent.outgoing.sourceBpm
        fun fit(c:TimelineClip,s:TempoSourceIdentity)=TempoParticipantFit(s,c.globalStartMs.toDouble(),c.sourceInMs.toDouble(),c.sourceOutMs.toDouble(),c.sourceAtExact(start),0.8,1.5)
        val ordinal=if(intent.policy==TempoRampPolicy.SharedRampV1)kotlin.math.round((a.sourceAtExact(start)-intent.outgoing.beatAnchorMs)*intent.outgoing.sourceBpm/60000).toLong() else 0L
        val context=TempoFitContext(fit(a,intent.outgoing),fit(b,intent.incoming),clips.filter {it!==a&&it!==b}.map {TempoVoiceWindow(it.occurrence,it.globalStartMs.toDouble(),it.globalEndMs.toDouble())},4,start,intent.overlapEndMs,effective,ordinal)
        val result=if(intent.policy==TempoRampPolicy.AutoSourceBoundsV1)planSourceBoundsTempoTransition(intent,context) else planTempoTransition(intent,context)
        require(result is TempoPlanResult.Valid) {(result as TempoPlanResult.Invalid).detail}
        val plan=result.plan
        if(intent.policy==TempoRampPolicy.SharedRampV1)require(a.fadeOutMs==kotlin.math.round(intent.overlapEndMs-start).toLong()&&b.fadeInMs==a.fadeOutMs) {"Tempo and gain must share the full overlap."}
        clips=clips.map {when(it.occurrence) {
            a.occurrence->it.copy(tempoMap=ClipTempoMap(intent,intent.outgoing.sourceBpm,plan.outgoing.sourceAtOverlapStartMs))
            b.occurrence->it.copy(tempoMap=ClipTempoMap(intent,intent.incoming.sourceBpm,plan.incoming.sourceAtOverlapStartMs))
            else->it
        }}
    }
    return document.copy(clips=clips)
}
fun validateTempoDocument(document:TimelineDocument):String? = try {projectTempoDocument(document);null}catch(e:Exception){e.message ?: "Invalid tempo transition."}
@Serializable private data class SavedTimeline(val version:Int=1,val document:TimelineDocument)
enum class TimelineContext { Supported, OrdinaryQueueTooLarge }
data class TimelineState(val document: TimelineDocument = TimelineDocument(), val canUndo: Boolean = false, val message: String? = null, val writable: Boolean = true,
    val context:TimelineContext = TimelineContext.Supported)
data class TimelineEdit(val revision: Long, val original: TimelineClip, val kind: EditKind, val valueMs: Long)
data class EditDecision(val accepted: Boolean, val reason: String? = null)
/** Captures actual occurrence objects, not track IDs or a reconstructed document incarnation. */
data class TimelineFadeEdit(val revision:Long,val outgoing:TimelineClip,val incoming:TimelineClip,val durationMs:Long) {
    val startMs:Long get()=incoming.globalStartMs
    val endMs:Long get()=outgoing.globalEndMs
}

fun TimelineEdit.candidate(): TimelineClip = when(kind) {
    EditKind.Placement -> original.copy(globalStartMs=valueMs,explicitPlacement=true,rates=original.rates.copy(segments=original.rates.segments.map {s ->
        val delta=valueMs-original.globalStartMs;s.copy(startMs=s.startMs+delta,endMs=s.endMs+delta)
    }))
    EditKind.TrimIn -> original.copy(sourceInMs=valueMs)
    EditKind.TrimOut -> original.copy(sourceOutMs=valueMs)
}
internal fun TimelineEdit.authoredFadeTrimReason():String? =
    if(kind!=EditKind.Placement&&(original.fadeInMs!=0L||original.fadeOutMs!=0L)&&candidate()!=original)
        "This trim would move an authored fade. Undo the fade before trimming." else null
fun validateTimeline(clips:List<TimelineClip>):String? {
    if(clips.size>500 || clips.map {it.occurrence}.distinct().size!=clips.size)return "Queue occurrence identity changed."
    if(clips.any {it.occurrence.isBlank()||it.track<=0||it.sourceDurationMs !in 1..604800000L||it.globalStartMs !in 0..302400000000L||it.sourceInMs<0||it.sourceOutMs>it.sourceDurationMs||it.sourceOutMs-it.sourceInMs<minOf(1000L,it.sourceDurationMs)})return "Keep the source selection within the track and at least one second."
    if(clips.any {c->
        val length=c.globalEndMs-c.globalStartMs
        c.fadeInMs<0||c.fadeOutMs<0||c.fadeInMs>length||c.fadeOutMs>length-c.fadeInMs||
            (c.tempoMap==null&&c.heldTempo==null&&(c.fadeInMs!=0L||c.fadeOutMs!=0L)&&!c.rateOne())
    })return "Fade lengths must fit the selected rate-one source or qualified tempo output."
    val edges=clips.flatMap {listOf(it.globalStartMs to 1,it.globalEndMs to -1)}.sortedWith(compareBy<Pair<Long,Int>> {it.first}.thenBy {it.second})
    var count=0
    for((_,delta) in edges){count+=delta;if(count>4)return "At most four occurrences may overlap."}
    return null
}
/** Durable draft timing owner. Service remains the only playback/current-position authority. */
class TimelineOwner(private val read: () -> String?, private val write: (String) -> Unit) {
    private val mutable = MutableStateFlow(TimelineState())
    val state: StateFlow<TimelineState> = mutable
    private var loaded=false
    private var durableReadOnly=false
    private var projectionBlocked=false
    // A legal ordinary queue need not be an editable arrangement. Retain the
    // bounded draft separately from the temporary, non-authoring projection.
    private var suspended:TimelineState?=null
    private var previous:TimelineDocument?=null
    private var observed:List<TimelineSource>?=null
    // Current clips are never evicted. Keep up to one maximum queue of absent identities for queue Undo.
    private var absent=emptyMap<String,TimelineClip>()
    @Synchronized fun observe(sources: List<TimelineSource>) {
        if(!loaded && sources.isEmpty())return
        if(sources==observed)return
        if(!loaded) {
            loaded=true
            try {
                read()?.let {raw ->
                    require(raw.length<=2_000_000)
                    val saved=Json.decodeFromString<SavedTimeline>(raw)
                    require(saved.version in 1..5 && (saved.version!=2 || saved.document.clips.any {it.fadeInMs!=0L||it.fadeOutMs!=0L}) && (saved.version>=3 || saved.document.phaseLink==null) && (saved.version>=4 || saved.document.tempoRamps.isEmpty()) && (saved.version>=5 || (saved.document.playbackTempos.isEmpty()&&!saved.document.autoBpmCrossfade)) && (saved.version!=3 || saved.document.phaseLink!=null) && saved.document.revision>=0)
                    val projected=projectTempoDocument(saved.document)
                    require(validateTimeline(projected.clips)==null && validatePhase(projected)==null)
                    mutable.value=TimelineState(projected)
                }
            } catch(_:Exception) {durableReadOnly=true;mutable.value=mutable.value.copy(writable=false,message="Saved arrangement is unreadable. It has not been replaced.")}
        }
        if(sources.size>500) {
            // Capacity refusal is not identity validation or a truncated document.
            require(sources.map {it.occurrence}.toSet().size==sources.size && sources.all {
                it.occurrence.isNotBlank()&&it.track>0&&it.durationMs in 1..604800000L
            })
            if(suspended==null)suspended=mutable.value
            observed=sources.toList();previous=null
            mutable.value=mutable.value.copy(canUndo=false,writable=false,context=TimelineContext.OrdinaryQueueTooLarge,
                message="Arrangement editing supports up to 500 occurrences. The full listening queue is unchanged; your prior draft is retained.")
            return
        }
        suspended?.let {mutable.value=it.copy(canUndo=false);suspended=null}
        val old=mutable.value.document
        val existing=absent+old.clips.associateBy {it.occurrence}
        val defaults=sequentialTimeline(sources)
        val present=defaults.map {it.occurrence}.toSet()
        val missing=existing.filterKeys {it !in present}.values.toList()
        absent=missing.takeLast(500).associateBy {it.occurrence}
        if(missing.size>500)mutable.value=mutable.value.copy(message="Older removed occurrence timing was released. Current arrangement edits are unchanged.")
        var end=0L
        val clips=defaults.map {base ->
            val prior=existing[base.occurrence]?.takeIf {it.track==base.track&&it.sourceDurationMs==base.sourceDurationMs}
            (prior ?: base.copy(globalStartMs=end)).also {end=maxOf(end,it.globalEndMs)}
        }
        observed=sources.toList();previous=null
        val retained=old.phaseLink?.takeIf {link -> listOf(link.reference,link.incoming).all {id -> clips.any {it.occurrence==id} && existing[id]?.let {prior->clips.any {it.occurrence==id&&it.track==prior.track&&it.sourceDurationMs==prior.sourceDurationMs}}==true }}
        val rawNext=old.copy(revision=old.revision+1,clips=clips,phaseLink=retained)
        val projection=runCatching {projectTempoDocument(rawNext).also {require(validateTimeline(it.clips)==null&&validatePhase(it)==null)}}
        val next=projection.getOrNull() ?: rawNext
        if(projection.isFailure&&!durableReadOnly) {
            projectionBlocked=true
            mutable.value=mutable.value.copy(writable=false,message="Saved tempo intent no longer fits these source occurrences. The draft and saved bytes are retained read-only; ordinary playback is unchanged.")
        } else if(projection.isSuccess&&projectionBlocked&&!durableReadOnly) {
            projectionBlocked=false
            mutable.value=mutable.value.copy(writable=true,message=null)
        }
        val retired=old.phaseLink!=null&&retained==null
        val publish={mutable.value=mutable.value.copy(document=next,canUndo=false,message=if(retired)"Linked pair retired because a source occurrence was removed or changed. Positions are retained; select both originals to link again." else mutable.value.message)}
        if(retired&&mutable.value.writable) {
            if(!persist(next,{true},publish)) {
                durableReadOnly=true
                mutable.value=mutable.value.copy(document=next,canUndo=false,writable=false,message="Linked source was removed, but durable retirement failed. Draft is read-only; saved bytes were preserved.")
            }
        } else publish()
    }
    @Synchronized fun preview(edit: TimelineEdit): EditDecision {
        val s=mutable.value
        if(!s.writable)return EditDecision(false,s.message)
        if(edit.revision!=s.document.revision || s.document.clips.none {it==edit.original})return EditDecision(false,"Queue changed. Try the edit again.")
        if(s.document.tempoRamps.any {it.policy==TempoRampPolicy.SharedRampV1&&(it.outgoing.occurrence==edit.original.occurrence||it.incoming.occurrence==edit.original.occurrence)})return EditDecision(false,"This occurrence belongs to a tempo ramp. Use its fitted transition controls or explicitly remove the ramp before moving or trimming.")
        edit.authoredFadeTrimReason()?.let {return EditDecision(false,it)}
        if(s.document.phaseLink?.contains(edit.original.occurrence)==true && s.document.clips.none {it===edit.original})return EditDecision(false,"Source occurrence changed.")
        val candidate=try {s.document.edited(edit)}catch(e:Exception){return EditDecision(false,e.message ?: "Invalid timing.")}
        val error=validateTimeline(candidate.clips) ?: validatePhase(candidate) ?: validateTempoDocument(candidate)
        return EditDecision(error==null,error)
    }
    @Synchronized fun commit(edit: TimelineEdit, valid: () -> Boolean = {true}): Boolean {
        if(!valid())return false
        val decision=preview(edit)
        if(!decision.accepted){mutable.value=mutable.value.copy(message=decision.reason);return false}
        val old=mutable.value.document
        val candidate=old.edited(edit)
        if(candidate==old)return true
        val next=candidate.copy(revision=old.revision+1)
        return persist(next,valid) {previous=old;mutable.value=TimelineState(next,true)}
    }
    @Synchronized fun preview(edit:TimelineFadeEdit):EditDecision {
        val s=mutable.value
        if(!s.writable)return EditDecision(false,s.message)
        if(edit.revision!=s.document.revision || s.document.clips.none {it===edit.outgoing} || s.document.clips.none {it===edit.incoming})
            return EditDecision(false,"Queue or source changed. Select both occurrences again.")
        if(s.document.tempoRamps.any {r->listOf(r.outgoing.occurrence,r.incoming.occurrence).any {it==edit.outgoing.occurrence||it==edit.incoming.occurrence}})return EditDecision(false,"Use the tempo transition's gain controls. Its common fade interval is not an independent rate-one fade.")
        val a=edit.outgoing;val b=edit.incoming
        if(a.occurrence==b.occurrence)return EditDecision(false,"Choose two different occurrences.")
        if(listOf(a,b).any {it.rates.baseRate!=1.0||it.rates.segments.any {s->s.startRate!=1.0||s.endRate!=1.0}})
            return EditDecision(false,"Crossfades currently require rate-one occurrences.")
        // Existing v1 mix envelopes are anchored at selected start/EOF. Admit only their exact common interval.
        val overlap=edit.endMs-edit.startMs
        if(a.globalStartMs>b.globalStartMs || a.globalEndMs>b.globalEndMs || overlap<=0)
            return EditDecision(false,"Place the incoming start before the outgoing end, inside both selected clips.")
        if(edit.durationMs!=overlap)return EditDecision(false,"Use the full overlap of $overlap ms. Change placement before authoring a different duration; no audio was trimmed.")
        val clips=s.document.clips.map {when(it.occurrence){a.occurrence->a.copy(fadeOutMs=overlap);b.occurrence->b.copy(fadeInMs=overlap);else->it}}
        val error=validateTimeline(clips)
        return EditDecision(error==null,error)
    }
    @Synchronized fun commit(edit:TimelineFadeEdit,valid:()->Boolean={true}):Boolean {
        if(!valid())return false
        val decision=preview(edit)
        if(!decision.accepted){mutable.value=mutable.value.copy(message=decision.reason);return false}
        val old=mutable.value.document
        val clips=old.clips.map {when(it.occurrence){edit.outgoing.occurrence->it.copy(fadeOutMs=edit.durationMs);edit.incoming.occurrence->it.copy(fadeInMs=edit.durationMs);else->it}}
        if(clips==old.clips)return true
        val next=old.copy(revision=old.revision+1,clips=clips)
        return persist(next,valid){previous=old;mutable.value=TimelineState(next,true)}
    }
    @Synchronized fun preview(edit:PhaseEdit):EditDecision {
        val s=mutable.value
        if(!s.writable)return EditDecision(false,s.message)
        if(edit.revision!=s.document.revision || s.document.clips.none {it===edit.reference} || s.document.clips.none {it===edit.incoming})return EditDecision(false,"Queue or source changed. Select the occurrences again.")
        if(s.document.tempoRamps.any {r->listOf(r.outgoing.occurrence,r.incoming.occurrence).any {it==edit.reference.occurrence||it==edit.incoming.occurrence}})return EditDecision(false,"Phase link is a separate policy. Explicitly remove this tempo ramp before linking.")
        return try {solvePhase(s.document,edit);EditDecision(true)}catch(e:Exception){EditDecision(false,e.message)}
    }
    @Synchronized fun commit(edit:PhaseEdit,valid:()->Boolean={true}):Boolean {
        if(!valid())return false
        val decision=preview(edit)
        if(!decision.accepted){mutable.value=mutable.value.copy(message=decision.reason);return false}
        val old=mutable.value.document;val solved=solvePhase(old,edit)
        val next=old.copy(revision=old.revision+1,clips=solved.clips,phaseLink=solved.link)
        return persist(next,valid){previous=old;mutable.value=TimelineState(next,true)}
    }
    @Synchronized fun unlock(revision:Long,valid:()->Boolean={true}):Boolean {
        val old=mutable.value.document
        if(old.revision!=revision||old.phaseLink==null||!valid())return false
        val next=old.copy(revision=old.revision+1,phaseLink=null)
        return persist(next,valid){previous=old;mutable.value=TimelineState(next,true)}
    }
    @Synchronized fun preview(edit:TimelineTempoEdit):EditDecision {
        val s=mutable.value
        if(!s.writable)return EditDecision(false,s.message)
        if(edit.original!==s.document)return EditDecision(false,"Arrangement changed. Select the overlap again.")
        if(edit.candidate.clips.map {Triple(it.occurrence,it.track,it.sourceDurationMs)}!=s.document.clips.map {Triple(it.occurrence,it.track,it.sourceDurationMs)})return EditDecision(false,"Source occurrences changed.")
        return try {
            val projected=projectTempoDocument(edit.candidate)
            val error=validateTimeline(projected.clips) ?: validatePhase(projected)
            EditDecision(error==null,error)
        }catch(e:Exception){EditDecision(false,e.message ?: "Invalid tempo fit.")}
    }
    @Synchronized fun commit(edit:TimelineTempoEdit,valid:()->Boolean={true}):Boolean = commitTempo(edit,valid,false)
    @Synchronized fun commitContinuingTempo(edit:TimelineTempoEdit,valid:()->Boolean):Boolean = commitTempo(edit,valid,true)
    private fun commitTempo(edit:TimelineTempoEdit,valid:()->Boolean,continuingPlayback:Boolean):Boolean {
        if(!valid())return false
        val decision=preview(edit)
        if(!decision.accepted){mutable.value=mutable.value.copy(message=decision.reason);return false}
        val old=mutable.value.document
        val next=projectTempoDocument(edit.candidate.copy(revision=old.revision+1))
        return persist(next,valid){previous=old;mutable.value=TimelineState(next,true,if(continuingPlayback)"BPM saved. Playback continues." else "BPM saved. Use Play to listen.")}
    }
    @Synchronized fun undo(valid: () -> Boolean = {true}): Boolean {
        val old=previous ?: return false
        val next=old.copy(revision=mutable.value.document.revision+1)
        return persist(next,valid){previous=null;mutable.value=TimelineState(next)}
    }
    private fun persist(next:TimelineDocument,valid:()->Boolean,publish:()->Unit):Boolean {
        if(!valid()||!mutable.value.writable)return false
        val checked=runCatching {projectTempoDocument(next)}.getOrNull()
        val error=checked?.let {validateTimeline(it.clips) ?: validatePhase(it)} ?: validateTempoDocument(next)
        if(checked==null||error!=null){mutable.value=mutable.value.copy(message=error ?: "Invalid tempo document. Prior draft retained.");return false}
        return try {write(Json.encodeToString(SavedTimeline(version=if(next.playbackTempos.isNotEmpty()||next.autoBpmCrossfade)5 else if(next.tempoRamps.isNotEmpty())4 else if(next.phaseLink!=null)3 else if(next.clips.any {it.fadeInMs!=0L||it.fadeOutMs!=0L})2 else 1,document=next)));if(valid()){publish();true}else false}
        catch(_:Exception){mutable.value=mutable.value.copy(message="Arrangement could not be saved. Your accepted edits are unchanged.");false}
    }
}
