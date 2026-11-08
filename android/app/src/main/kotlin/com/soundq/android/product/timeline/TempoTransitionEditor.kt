package com.soundq.android.product.timeline

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.material3.Text
import com.soundq.android.data.timeline.*
import com.soundq.designsystem.*
import kotlin.math.*

/** Occurrence pair, not a track pair. A repeated recording may have several transitions. */
data class TempoEditorOverlap(val outgoing:TimelineClip,val incoming:TimelineClip) {
    val id:String get()="${outgoing.occurrence.length}:${outgoing.occurrence}${incoming.occurrence}"
}
fun tempoEditorOverlaps(document:TimelineDocument):List<TempoEditorOverlap> = document.clips.flatMap {a->document.clips.filter {b->
    a.occurrence!=b.occurrence && (a.globalStartMs<b.globalStartMs || (a.globalStartMs==b.globalStartMs&&document.clips.indexOf(a)<document.clips.indexOf(b))) &&
        b.globalStartMs<a.globalEndMs && a.globalEndMs<=b.globalEndMs
}.map {TempoEditorOverlap(a,it)}}

/** Disclosure precedes the transaction. Nothing is silently moved or trimmed. */
data class TempoFitProposal(val document:TimelineDocument,val explanation:String,val trimsSource:Boolean)
/** Parent-observed native receipt only. Local Save never constructs this. */
data class TempoEditorNativeObservation(val capture:TempoEditCapture,val status:TempoTransitionStatus,val reason:String?,val pendingCommandId:String?,val acceptedCommandId:String?,val observedEffectiveBpm:Double?=null)
fun fitTempoEditorRamp(document:TimelineDocument,pair:TempoEditorOverlap,draft:TempoRampIntent,requestedStartBeat:Long?=null):TempoFitProposal {
    val a=pair.outgoing.copy(tempoMap=null);val b=pair.incoming.copy(tempoMap=null)
    require(a.rates.segments.isEmpty()) {"Fitting this upstream rate automation is not supported. Existing draft is unchanged."}
    val sa=draft.outgoing;val sb=draft.incoming
    val period=60000.0/sa.sourceBpm;val incomingPeriod=60000.0/sb.sourceBpm
    val endBeat=floor((a.sourceOutMs-sa.beatAnchorMs)/period+1e-8)
    val sourceStart=if(requestedStartBeat==null)sa.beatAnchorMs+(endBeat-draft.lengthBeats)*period else sa.beatAnchorMs+requestedStartBeat*period
    val sourceOut=sourceStart+draft.lengthBeats*period
    require(sourceOut<=a.sourceOutMs+1e-6) {"The requested beat range exceeds the selected outgoing EOF. Choose an earlier start or a shorter ramp; no source was changed."}
    val sourceIn=sb.beatAnchorMs+ceil((b.sourceInMs-sb.beatAnchorMs)/incomingPeriod-1e-8)*incomingPeriod
    require(sourceStart>=a.sourceInMs&&sourceOut>a.sourceInMs&&sourceIn<b.sourceOutMs) {"Not enough selected audio for this beat range. Choose a shorter ramp or edit timing."}
    require(abs(sourceOut-round(sourceOut))<1e-6&&abs(sourceIn-round(sourceIn))<1e-6) {"This grid needs sub-millisecond source trims that the editor cannot represent."}
    val start=a.globalAtExact(sourceStart)
    require(abs(start-round(start))<1e-6) {"This pre-overlap rate needs a fractional placement. Existing source selection was preserved; choose another speed or beat."}
    val effective=a.rates.baseRate*sa.sourceBpm
    val target=if(draft.target.kind==TempoTargetKind.Original)sb.sourceBpm else requireNotNull(draft.target.customBpm)
    val end=start+120000.0*draft.lengthBeats/(effective+target)
    val duration=round(end-start).toLong()
    val intent=draft.copy(outgoingEffectiveStartBpm=effective,overlapStartMs=start,overlapEndMs=end,startSharedBeat=round((sourceStart-sa.beatAnchorMs)/period).toLong())
    val candidate=document.copy(clips=document.clips.map {when(it.occurrence) {
        a.occurrence->a.copy(sourceOutMs=round(sourceOut).toLong(),fadeOutMs=duration)
        b.occurrence->b.copy(sourceInMs=round(sourceIn).toLong(),globalStartMs=round(start).toLong(),fadeInMs=duration,explicitPlacement=true)
        else->it
    }},tempoRamps=document.tempoRamps.filterNot {it.outgoing.occurrence==a.occurrence&&it.incoming.occurrence==b.occurrence}+intent)
    val projected=projectTempoDocument(candidate)
    require(validateTimeline(projected.clips)==null) {validateTimeline(projected.clips).orEmpty()}
    val trims=sourceOut!=a.sourceOutMs.toDouble()||sourceIn!=b.sourceInMs.toDouble()
    val explanation="Move incoming from ${b.globalStartMs} to ${round(start).toLong()} ms; shared tempo and gain end at ${round(end).toLong()} ms. "+
        if(trims)"Explicit source trim required: outgoing end ${a.sourceOutMs} → ${round(sourceOut).toLong()} ms; incoming start ${b.sourceInMs} → ${round(sourceIn).toLong()} ms. The strict beat planner cannot keep an off-beat EOF. Source audio outside these selections is not deleted." else "Both source selections and outgoing pre-overlap rate stay unchanged."
    return TempoFitProposal(projected,explanation,trims)
}

/** Host owns pause/persistence. This inline editor owns only an uncommitted captured draft. */
@Composable fun TempoTransitionEditor(
    document:TimelineDocument, selected:String?, waves:Map<Long,TrackWaveform>,
    repository:TimelineRepository, valid:()->Boolean, canEdit:Boolean,
    onCommit:(TimelineTempoEdit,()->Boolean)->Unit,onTiming:()->Unit,
    modifier:Modifier=Modifier,
    nativeObservation:(TempoEditCapture)->TempoEditorNativeObservation?={null},
) {
    val pairs=remember(document){tempoEditorOverlaps(document)}
    val durableState by repository.state.collectAsState()
    val initial=pairs.firstOrNull {it.outgoing.occurrence==selected||it.incoming.occurrence==selected} ?: pairs.firstOrNull()
    var pairId by remember(document){mutableStateOf(initial?.id)}
    val pair=pairs.firstOrNull {it.id==pairId} ?: return
    val scope=repositoryScope(repository) // Identity is local to this mounted editor, not a service ACK.
    var expanded by remember {mutableStateOf(false)}
    val saved=document.tempoRamps.singleOrNull {it.outgoing.occurrence==pair.outgoing.occurrence&&it.incoming.occurrence==pair.incoming.occurrence}
    val a=waves[pair.outgoing.track]?.let {qualifiedTempoSource(pair.outgoing,it)}
    val b=waves[pair.incoming.track]?.let {qualifiedTempoSource(pair.incoming,it)}
    var draft by remember(document,pair.id){mutableStateOf(saved)}
    var candidate by remember(document,pair.id){mutableStateOf<TimelineDocument?>(null)}
    var working by remember(document,pair.id){mutableStateOf(document)}
    var proposal by remember(document,pair.id){mutableStateOf<TempoFitProposal?>(null)}
    var requestedStartBeat by remember(document,pair.id){mutableStateOf<Long?>(null)}
    var message by remember(document,pair.id){mutableStateOf<String?>(null)}
    LaunchedEffect(selected) {
        val chosen=pairs.firstOrNull {it.outgoing.occurrence==selected||it.incoming.occurrence==selected}
        if(chosen!=null&&chosen.id!=pair.id) {
            if(draft==saved&&candidate==null)pairId=chosen.id
            else message="Unsaved transition edits retained. Save or discard them before changing overlap."
        }
    }
    val capture=TempoEditCapture(scope,document.revision,pair.id)
    val alive=remember(document,pair.id){java.util.concurrent.atomic.AtomicBoolean(true)}
    DisposableEffect(document,pair.id){onDispose{alive.set(false)}}
    val admitted=valid
    val sourceAdmission=remember(document,pair.id,a,b) {repository.captureTempoSources(listOfNotNull(a,b))}
    fun current()=alive.get()&&admitted()&&sourceAdmission()&&canEdit&&repository.state.value.document===document
    fun update(next:TempoRampIntent) {
        if(!current())return
        draft=next;proposal=null
        val raw=working.copy(tempoRamps=working.tempoRamps.filterNot {it.outgoing.occurrence==pair.outgoing.occurrence&&it.incoming.occurrence==pair.incoming.occurrence}+next)
        val projected=runCatching {projectTempoDocument(raw)}
        candidate=projected.getOrNull();working=projected.getOrNull() ?: raw
        message=projected.exceptionOrNull()?.message
    }
    Column(modifier.fillMaxWidth()) {
        SoundQButton(if(expanded)"Hide transition controls" else "Transition controls",{expanded=!expanded},variant=SoundQButtonVariant.Quiet)
        if(expanded)Column(Modifier.fillMaxWidth().heightIn(max=176.dp).verticalScroll(rememberScrollState())) {
            val intent=draft
            val law=intent?.let {runCatching {SharedTempoLaw(it.overlapStartMs,it.overlapEndMs,it.outgoingEffectiveStartBpm,if(it.target.kind==TempoTargetKind.Original)it.incoming.sourceBpm else it.target.customBpm!!,it.curve)}.getOrNull()}
            val timing=a!=null&&b!=null
            val compatibility=(candidate ?: document.takeIf {intent==saved})?.let(::validateNativeTempoPlan)
            val fresh=sourceAdmission()
            val identityCurrent=intent==null||(intent.outgoing==a&&intent.incoming==b)
            val receipt=nativeObservation(capture)?.takeIf {it.capture==capture&&draft==saved&&candidate==null&&compatibility==null&&identityCurrent&&timing&&fresh}
            val receiptStatus=receipt?.status?.takeUnless {it==TempoTransitionStatus.Accepted&&receipt.acceptedCommandId.isNullOrBlank()}
            TempoTransitionControls(TempoTransitionControlsState(
                capture,pairs.map {TempoOverlapChoice(it.id,"${it.outgoing.title} → ${it.incoming.title}",it.incoming.globalStartMs.toDouble(),it.outgoing.globalEndMs.toDouble())},
                if(intent==null)TempoTransitionPolicy.VolumeOnly else TempoTransitionPolicy.SharedRampV1,
                setOf(TempoTransitionPolicy.VolumeOnly,TempoTransitionPolicy.SharedRampV1),
                pair.outgoing.title,pair.incoming.title,a?.sourceBpm,b?.sourceBpm,intent?.outgoingEffectiveStartBpm ?: a?.let {pair.outgoing.rates.rateAtExact(pair.incoming.globalStartMs.toDouble())*it.sourceBpm},
                intent?.target ?: TempoTarget(TempoTargetKind.Original,null),intent?.curve ?: TempoCurve.LinearTime,intent?.gainLaw ?: TempoGainLaw.EqualPower,
                intent?.startSharedBeat ?: 0,intent?.lengthBeats ?: 8,law,null,
                when { !timing||!fresh||!identityCurrent->TempoTransitionStatus.TimingNeeded;message!=null->TempoTransitionStatus.Conflict;else->receiptStatus ?: TempoTransitionStatus.Unsupported },
                listOfNotNull(message,compatibility,receipt?.reason,if(!identityCurrent)"Saved source/grid identity changed. Do not overwrite the prior ramp; restore its original timing or explicitly remove it before authoring a new ramp." else null).takeIf {it.isNotEmpty()}?.joinToString(" ") ?: when {
                    !timing||!fresh->"Set constant source timing to use a tempo transition."
                    receipt!=null->null
                    else->"Save this transition, then use Play to audition it."
                },
                if(timing)maxOf(10.0,maxOf(a.sourceBpm,b.sourceBpm)*0.8) else null,if(timing)minOf(600.0,minOf(a.sourceBpm,b.sourceBpm)*1.5) else null,
                canEdit&&valid(),candidate!=null&&timing&&fresh&&identityCurrent,false,candidate!=null&&candidate!=document,receipt?.pendingCommandId,receipt?.acceptedCommandId,receipt?.observedEffectiveBpm,
            ),{held,action->
                if(held!=capture||!current())return@TempoTransitionControls
                when(action) {
                    is TempoTransitionAction.SelectOverlap->{if(draft!=saved||candidate!=null)message="Save or discard this draft before selecting another overlap." else pairId=action.id}
                    is TempoTransitionAction.SetPolicy->when(action.policy) {
                        TempoTransitionPolicy.SharedRampV1->if(a!=null&&b!=null) {
                            val start=pair.incoming.globalStartMs.toDouble();val end=pair.outgoing.globalEndMs.toDouble()
                            val effective=pair.outgoing.rates.rateAtExact(start)*a.sourceBpm
                            update(saved ?: TempoRampIntent(1,TempoRampPolicy.SharedRampV1,a,b,effective,TempoTarget(TempoTargetKind.Original,null),TempoCurve.LinearTime,start,end,
                                round((pair.outgoing.sourceAtExact(start)-a.beatAnchorMs)*a.sourceBpm/60000).toLong(),maxOf(1,round((end-start)*(effective+b.sourceBpm)/120000).toInt()),TempoGainLaw.EqualPower))
                        } else {message="Timing needed. Open the existing source timing controls."}
                        TempoTransitionPolicy.VolumeOnly->{draft=null;candidate=working.copy(tempoRamps=working.tempoRamps.filterNot {it.outgoing.occurrence==pair.outgoing.occurrence&&it.incoming.occurrence==pair.incoming.occurrence},clips=working.clips.map {if(it.occurrence in listOf(pair.outgoing.occurrence,pair.incoming.occurrence))it.copy(tempoMap=null) else it});message="Volume-only draft. Save removal below to keep this explicit change."}
                        TempoTransitionPolicy.ConstantLock->onTiming()
                    }
                    is TempoTransitionAction.SetTarget->intent?.let {update(it.copy(target=action.target))}
                    is TempoTransitionAction.SetTempoCurve->intent?.let {update(it.copy(curve=action.curve))}
                    is TempoTransitionAction.SetGainLaw->intent?.let {update(it.copy(gainLaw=action.law))}
                    is TempoTransitionAction.SetAlignedRange->intent?.let {requestedStartBeat=action.startSharedBeat;update(it.copy(startSharedBeat=action.startSharedBeat,lengthBeats=action.lengthBeats))}
                    is TempoTransitionAction.SetPreOverlapEffectiveBpm->intent?.let {i->
                        val rate=action.bpm/i.outgoing.sourceBpm
                        if(rate in 0.8..1.5&&pair.outgoing.rates.segments.isEmpty()) {
                            draft=i.copy(outgoingEffectiveStartBpm=action.bpm);candidate=null;proposal=null
                            message="Pre-overlap speed draft ${action.bpm} BPM. Review and apply Fit overlap to change speed and placement together."
                        } else message="Existing rate automation owns this start. Edit its upstream timing instead."
                    }
                    TempoTransitionAction.RestoreTransitionDefaults->intent?.let {update(it.copy(target=TempoTarget(TempoTargetKind.Original,null),curve=TempoCurve.LinearTime,outgoingEffectiveStartBpm=pair.outgoing.rates.rateAtExact(it.overlapStartMs)*it.outgoing.sourceBpm))}
                    TempoTransitionAction.SaveRampIntent->candidate?.let {next->onCommit(TimelineTempoEdit(document,next),::current)}
                    TempoTransitionAction.OpenTiming,TempoTransitionAction.InspectConflict,is TempoTransitionAction.OpenUpstreamOwner->onTiming()
                    TempoTransitionAction.RetryQualifiedPreview->Unit
                }
            })
            if(draft!=null) {
                SoundQButton("Review fit to beats",{
                    if(current()) {
                        val i=draft!!
                        val rate=i.outgoingEffectiveStartBpm/i.outgoing.sourceBpm
                        val base=working.copy(clips=working.clips.map {if(it.occurrence==pair.outgoing.occurrence&&it.rates.segments.isEmpty())it.copy(rates=RateAutomation(rate),tempoMap=null) else it})
                        val fitted=runCatching {fitTempoEditorRamp(base,TempoEditorOverlap(base.clips.single {it.occurrence==pair.outgoing.occurrence},base.clips.single {it.occurrence==pair.incoming.occurrence}),i,requestedStartBeat)}
                        proposal=fitted.getOrNull();message=fitted.exceptionOrNull()?.message
                    }
                },enabled=canEdit,variant=SoundQButtonVariant.Secondary)
                proposal?.let {fit->
                    Text(fit.explanation,style=SoundQ.typography.caption)
                    SoundQButton(if(fit.trimsSource)"Apply disclosed trim and placement" else "Apply fitted placement",{
                        if(current()){candidate=fit.document;working=fit.document;draft=fit.document.tempoRamps.last();proposal=null;message="Fitted draft only. Save ramp intent to persist."}
                    },enabled=canEdit,variant=SoundQButtonVariant.Secondary)
                }
            } else if(candidate!=null)SoundQButton("Save volume-only intent",{if(current())candidate?.let {onCommit(TimelineTempoEdit(document,it),::current)}},enabled=canEdit,variant=SoundQButtonVariant.Secondary)
            if(draft!=saved||candidate!=null)SoundQButton("Discard unsaved transition edits",{draft=saved;candidate=null;working=document;proposal=null;requestedStartBeat=null;message=null},variant=SoundQButtonVariant.Quiet)
            durableState.message?.let {Text(it,style=SoundQ.typography.caption)}
            SoundQButton("Manual timing / phase link",onTiming,variant=SoundQButtonVariant.Quiet)
        }
    }
}

@Composable private fun repositoryScope(repository:TimelineRepository):String = remember(repository){java.util.UUID.randomUUID().toString()}
