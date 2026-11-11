package com.soundq.android.product.timeline

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import com.soundq.android.data.timeline.*
import com.soundq.designsystem.*
import java.util.Locale

/** Host must revalidate all three fields, current source qualifications and route lifetime. */
data class TempoEditCapture(val arrangementIdentity: String, val documentRevision: Long, val overlapId: String)
enum class TempoTransitionStatus { Ready, TimingNeeded, Conflict, Unsupported, Pending, Accepted, Failed, ScratchSuspended, Rejoining }
enum class TempoTransitionPolicy { VolumeOnly, ConstantLock, SharedRampV1 }
data class TempoOverlapChoice(val id: String, val label: String, val startMs: Double, val endMs: Double)
/** Actual readiness is supplied by parent; neither the graph nor Save synthesizes acceptance. */
data class TempoTransitionControlsState(
    val capture: TempoEditCapture, val choices: List<TempoOverlapChoice>,
    val policy: TempoTransitionPolicy, val supportedPolicies: Set<TempoTransitionPolicy>,
    val outgoingLabel: String, val incomingLabel: String,
    val outgoingSourceBpm: Double?, val incomingSourceBpm: Double?,
    val effectiveStartBpm: Double?, val target: TempoTarget, val curve: TempoCurve,
    val gainLaw: TempoGainLaw, val startSharedBeat: Long, val lengthBeats: Int,
    val law: SharedTempoLaw?, val upstreamOwnerId: String?,
    val status: TempoTransitionStatus, val reason: String?,
    val minBpm: Double?, val maxBpm: Double?, val canEdit: Boolean,
    val canSave: Boolean, val canRetry: Boolean, val dirty: Boolean,
    val pendingCommandId: String?, val acceptedCommandId: String?,
    val observedEffectiveBpm: Double? = null,
)
sealed interface TempoTransitionAction {
    data class SelectOverlap(val id: String): TempoTransitionAction
    data class SetPolicy(val policy: TempoTransitionPolicy): TempoTransitionAction
    data class SetPreOverlapEffectiveBpm(val bpm: Double): TempoTransitionAction
    data class OpenUpstreamOwner(val id: String): TempoTransitionAction
    data class SetTarget(val target: TempoTarget): TempoTransitionAction
    data class SetAlignedRange(val startSharedBeat: Long, val lengthBeats: Int): TempoTransitionAction
    data class SetTempoCurve(val curve: TempoCurve): TempoTransitionAction
    data class SetGainLaw(val law: TempoGainLaw): TempoTransitionAction
    data object OpenTiming: TempoTransitionAction
    data object InspectConflict: TempoTransitionAction
    data object RetryQualifiedPreview: TempoTransitionAction
    data object SaveRampIntent: TempoTransitionAction
    data object RestoreTransitionDefaults: TempoTransitionAction
}
/** Pure validation reused by both numeric sheets. No parsing/clamping in the host action. */
fun tempoBpmInputError(text: String, min: Double?, max: Double?): String? {
    val value=text.toDoubleOrNull()
    return when {
        min==null||max==null||!min.isFinite()||!max.isFinite()||min<=0.0||max<min -> "Qualified tempo limits are needed."
        value==null||!value.isFinite()||value<=0.0 -> "Enter a positive BPM."
        value<min||value>max -> "Use ${tempoNumber(min)}–${tempoNumber(max)} BPM."
        else -> null
    }
}
private fun tempoNumber(value: Double?): String = value?.takeIf {it.isFinite()}?.let {String.format(Locale.ROOT,"%.1f",it)} ?: "—"
private enum class TempoProperty { Start, Target, Range, Curve, Gain }

/** Insert directly below existing stacked lanes. No transport, clock, IO or DSP owner. */
@Composable fun TempoTransitionControls(
    state: TempoTransitionControlsState,
    onAction: (TempoEditCapture,TempoTransitionAction)->Unit,
    modifier: Modifier = Modifier,
) {
    val c=SoundQ.colors
    val latest by rememberUpdatedState(state)
    val latestAction by rememberUpdatedState(onAction)
    val captured=state.capture
    var property by remember(captured){mutableStateOf<TempoProperty?>(null)}
    val live=remember(captured){java.util.concurrent.atomic.AtomicBoolean(true)}
    DisposableEffect(captured){onDispose {live.set(false)}}
    val editing=state.canEdit&&state.status!=TempoTransitionStatus.Pending&&state.pendingCommandId==null
    fun dispatch(action: TempoTransitionAction, mutation: Boolean=true) {
        val now=latest
        if(live.get()&&now.capture==captured&&(!mutation||(now.canEdit&&now.status!=TempoTransitionStatus.Pending&&now.pendingCommandId==null)))latestAction(captured,action)
    }
    LaunchedEffect(editing){if(!editing)property=null}
    Column(modifier.fillMaxWidth().background(c.background)) {
        if(state.choices.size>1) {
            var choosing by remember(captured){mutableStateOf(false)}
            Box {
                SoundQButton(state.choices.firstOrNull {it.id==captured.overlapId}?.label ?: "Choose overlap",{choosing=true},variant=SoundQButtonVariant.Quiet,enabled=editing)
                DropdownMenu(choosing,{choosing=false}) {
                    state.choices.forEach {choice->DropdownMenuItem({Text(choice.label)},{choosing=false;dispatch(TempoTransitionAction.SelectOverlap(choice.id))})}
                }
            }
        }
        Row(Modifier.fillMaxWidth()) {
            TempoTransitionPolicy.entries.forEach {policy->
                val title=when(policy){TempoTransitionPolicy.VolumeOnly->"Volume";TempoTransitionPolicy.ConstantLock->"Tempo lock";TempoTransitionPolicy.SharedRampV1->"Tempo ramp"}
                TempoCell(title,Modifier.weight(1f),editing&&policy in state.supportedPolicies,state.policy==policy){dispatch(TempoTransitionAction.SetPolicy(policy))}
            }
        }
        if(state.policy==TempoTransitionPolicy.SharedRampV1) {
            Row(Modifier.fillMaxWidth().padding(SoundQ.spacing.medium),horizontalArrangement=Arrangement.SpaceBetween) {
                Text("Shared tempo",style=SoundQ.typography.caption)
                state.observedEffectiveBpm?.let {Text("${tempoNumber(it)} BPM",style=SoundQ.typography.mono,color=c.secondary)}
            }
            Row(Modifier.fillMaxWidth()) {
                TempoEndpoint("Start · outgoing effective",state.effectiveStartBpm,"Original ${tempoNumber(state.outgoingSourceBpm)}",Modifier.weight(1f),editing){
                    state.upstreamOwnerId?.let {dispatch(TempoTransitionAction.OpenUpstreamOwner(it),false)} ?: run {property=TempoProperty.Start}
                }
                val original=state.target.kind==TempoTargetKind.Original
                TempoEndpoint(if(original)"End · original incoming" else "End · custom held",if(original)state.incomingSourceBpm else state.target.customBpm,
                    if(original)"Original target" else "Held after overlap",Modifier.weight(1f),editing){property=TempoProperty.Target}
            }
            SharedTempoLane(state.law,Modifier.fillMaxWidth().height(72.dp))
            Row(Modifier.fillMaxWidth()) {
                TempoCell("Beat ${state.startSharedBeat} → ${state.startSharedBeat+state.lengthBeats} · ${state.lengthBeats} beats",Modifier.weight(1f),editing){property=TempoProperty.Range}
                val curve=if(state.curve==TempoCurve.LinearTime)"Linear BPM" else "Smooth"
                val seconds=state.law?.let {(it.endMs-it.startMs)/1000.0}
                TempoCell("$curve · ${tempoNumber(seconds)} s",Modifier.weight(1f),editing){property=TempoProperty.Curve}
            }
            Row(Modifier.fillMaxWidth()) {
                TempoCell("Gain · ${if(state.gainLaw==TempoGainLaw.EqualPower)"equal power" else "linear"}",Modifier.weight(1f),editing){property=TempoProperty.Gain}
                TempoCell("Restore defaults",Modifier.weight(1f),editing){dispatch(TempoTransitionAction.RestoreTransitionDefaults)}
            }
        }
        val status=when(state.status) {
            TempoTransitionStatus.Ready->"Ready"
            TempoTransitionStatus.TimingNeeded->"Timing needed"
            TempoTransitionStatus.Conflict->"Overlap conflict"
            TempoTransitionStatus.Unsupported->"Key lock unsupported"
            TempoTransitionStatus.Pending->"Pending"
            TempoTransitionStatus.Accepted->"Accepted"
            TempoTransitionStatus.Failed->"Preview failed"
            TempoTransitionStatus.ScratchSuspended->"Scratch · tempo suspended"
            TempoTransitionStatus.Rejoining->"Rejoining"
        }
        Column(Modifier.padding(SoundQ.spacing.medium).semantics {liveRegion=LiveRegionMode.Polite}) {
            Text(status,color=if(state.status in setOf(TempoTransitionStatus.Failed,TempoTransitionStatus.Conflict))c.error else c.secondary,style=SoundQ.typography.caption)
            state.reason?.let {Text(it,color=c.muted,style=SoundQ.typography.caption)}
        }
        when(state.status) {
            TempoTransitionStatus.TimingNeeded->SoundQButton("Set source timing",{dispatch(TempoTransitionAction.OpenTiming,false)},variant=SoundQButtonVariant.Quiet)
            TempoTransitionStatus.Conflict->SoundQButton("Inspect overlap",{dispatch(TempoTransitionAction.InspectConflict,false)},variant=SoundQButtonVariant.Quiet)
            TempoTransitionStatus.Failed->SoundQButton("Retry preview",{if(latest.canRetry)dispatch(TempoTransitionAction.RetryQualifiedPreview,false)},enabled=state.canRetry,variant=SoundQButtonVariant.Quiet)
            else->Unit
        }
        if(state.policy==TempoTransitionPolicy.SharedRampV1)SoundQButton("Save ramp intent",{
            if(latest.canSave&&latest.dirty)dispatch(TempoTransitionAction.SaveRampIntent)
        },enabled=editing&&state.canSave&&state.dirty,variant=SoundQButtonVariant.Quiet)
        SoundQDivider()
    }
    property?.let {selected->
        key(captured,selected) {
            TempoPropertySheet(selected,state,{property=null}) {action->dispatch(action);property=null}
        }
    }
}

@Composable private fun TempoCell(label:String,modifier:Modifier=Modifier,enabled:Boolean=true,selected:Boolean=false,onClick:()->Unit) {
    val c=SoundQ.colors
    Box(modifier.heightIn(min=48.dp).background(if(selected)c.raised else c.background)
        .border(SoundQ.sizes.border,if(selected)c.primary else c.border)
        .semantics {this.selected=selected}.clickable(enabled=enabled,role=Role.Button,onClick=onClick)
        .padding(SoundQ.spacing.medium),contentAlignment=Alignment.CenterStart) {
        Text(label,style=SoundQ.typography.caption,color=if(!enabled)c.disabled else if(selected)c.primary else c.text)
    }
}
@Composable private fun TempoEndpoint(label:String,bpm:Double?,caption:String,modifier:Modifier,enabled:Boolean,onClick:()->Unit) {
    val c=SoundQ.colors
    Row(modifier.heightIn(min=80.dp).border(SoundQ.sizes.border,c.border).clickable(enabled=enabled,role=Role.Button,onClick=onClick)
        .padding(SoundQ.spacing.medium),verticalAlignment=Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(label,style=SoundQ.typography.caption,color=c.muted)
            Text(tempoNumber(bpm),style=SoundQ.typography.title,color=if(enabled)c.text else c.disabled)
            Text(caption,style=SoundQ.typography.caption,color=c.muted)
        }
        SoundQIcon(SoundQIcon.Arrow,null,tint=c.muted)
    }
}
/** Relative endpoint scale, not a numeric BPM axis. No synthetic playhead or acceptance. */
@Composable fun SharedTempoLane(law: SharedTempoLaw?,modifier:Modifier=Modifier) {
    val c=SoundQ.colors
    val path=remember(law){Path()}
    Canvas(modifier.padding(horizontal=SoundQ.spacing.medium,vertical=SoundQ.spacing.small)
        .semantics {contentDescription=if(law==null)"Shared tempo, timing needed" else "Both tracks, ${tempoNumber(law.startBpm)} to ${tempoNumber(law.targetBpm)} BPM"}) {
        drawLine(c.border,Offset(0f,size.height-1f),Offset(size.width,size.height-1f))
        if(law!=null) {
            val low=minOf(law.startBpm,law.targetBpm);val span=maxOf(1.0,kotlin.math.abs(law.targetBpm-law.startBpm))
            path.reset()
            for(i in 0..64) {
                val x=i/64f*size.width
                val bpm=law.bpmAt(law.startMs+(law.endMs-law.startMs)*i/64.0)
                val y=(size.height*(0.8-0.6*(bpm-low)/span)).toFloat()
                if(i==0)path.moveTo(x,y) else path.lineTo(x,y)
            }
            drawPath(path,c.secondary,style=Stroke(2.dp.toPx()))
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun TempoPropertySheet(property:TempoProperty,state:TempoTransitionControlsState,onDismiss:()->Unit,onApply:(TempoTransitionAction)->Unit) {
    val target=if(state.target.kind==TempoTargetKind.Original)state.incomingSourceBpm else state.target.customBpm
    var text by remember {mutableStateOf(when(property){TempoProperty.Start->state.effectiveStartBpm?.toString().orEmpty();TempoProperty.Target->target?.toString().orEmpty();else->state.startSharedBeat.toString()})}
    var beats by remember {mutableIntStateOf(state.lengthBeats)}
    var attempted by remember {mutableStateOf(false)}
    val enabled=state.canEdit&&state.status!=TempoTransitionStatus.Pending&&state.pendingCommandId==null
    val heading=when(property){TempoProperty.Start->"Outgoing effective BPM";TempoProperty.Target->"Incoming target BPM";TempoProperty.Range->"Overlap beat range";TempoProperty.Curve->"Tempo curve";TempoProperty.Gain->"Gain law"}
    ModalBottomSheet(onDismissRequest=onDismiss,containerColor=SoundQ.colors.sheet,shape=androidx.compose.ui.graphics.RectangleShape) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).imePadding().padding(SoundQ.spacing.gutter)) {
            Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {
                Text(heading,style=SoundQ.typography.title,modifier=Modifier.weight(1f))
                SoundQIconButton(SoundQIcon.Close,"Close $heading",onDismiss)
            }
            when(property) {
                TempoProperty.Start,TempoProperty.Target->{
                    val isTarget=property==TempoProperty.Target
                    Text(if(isTarget)"${state.incomingLabel} · original ${tempoNumber(state.incomingSourceBpm)} BPM. A custom target stays active afterward."
                        else "${state.outgoingLabel} · original ${tempoNumber(state.outgoingSourceBpm)} BPM. Changes pre-overlap playback tempo; it is not a ramp jump.",style=SoundQ.typography.caption)
                    val error=tempoBpmInputError(text,state.minBpm,state.maxBpm)
                    SoundQTextField(text,{text=it},if(isTarget)"Target BPM" else "Pre-overlap effective BPM",enabled=enabled,error=if(attempted)error else null)
                    if(isTarget)SoundQButton("Use original · ${tempoNumber(state.incomingSourceBpm)}",{onApply(TempoTransitionAction.SetTarget(TempoTarget(TempoTargetKind.Original,null)))},enabled=enabled&&state.incomingSourceBpm!=null,variant=SoundQButtonVariant.Quiet)
                    SoundQButton(if(isTarget)"Apply target" else "Apply start",{
                        attempted=true
                        if(error==null&&enabled)text.toDoubleOrNull()?.let {value->onApply(if(isTarget)TempoTransitionAction.SetTarget(TempoTarget(TempoTargetKind.Custom,value)) else TempoTransitionAction.SetPreOverlapEffectiveBpm(value))}
                    },enabled=enabled)
                }
                TempoProperty.Range->{
                    Text("End = start + length, exclusive. Placement and source fit are checked together.",style=SoundQ.typography.caption)
                    val start=text.toLongOrNull()
                    val error=if(start==null||start !in -1000000000L..1000000000L)"Enter a supported whole shared-beat index." else null
                    SoundQTextField(text,{text=it},"Start shared beat",enabled=enabled,error=if(attempted)error else null)
                    Row(Modifier.fillMaxWidth()){listOf(4,8,16,32).forEach {n->TempoCell("$n",Modifier.weight(1f),enabled,beats==n){beats=n}}}
                    SoundQButton("Apply range",{attempted=true;if(error==null&&enabled&&start!=null)onApply(TempoTransitionAction.SetAlignedRange(start,beats))},enabled=enabled)
                }
                TempoProperty.Curve->TempoCurve.entries.forEach {curve->
                    TempoCell(if(curve==TempoCurve.LinearTime)"Linear BPM" else "Smooth · eased endpoints",Modifier.fillMaxWidth(),enabled,state.curve==curve){onApply(TempoTransitionAction.SetTempoCurve(curve))}
                }
                TempoProperty.Gain->TempoGainLaw.entries.forEach {gain->
                    TempoCell(if(gain==TempoGainLaw.EqualPower)"Equal power" else "Linear",Modifier.fillMaxWidth(),enabled,state.gainLaw==gain){onApply(TempoTransitionAction.SetGainLaw(gain))}
                }
            }
            Spacer(Modifier.height(SoundQ.spacing.large))
        }
    }
}

/** Convenience bridge for already-admitted waveform timing; never fetches/reanalyzes. */
fun qualifiedTempoSource(clip:TimelineClip,wave:TrackWaveform):TempoSourceIdentity? {
    if(wave.track.value!=clip.track||wave.durationMs!=clip.sourceDurationMs)return null
    val timing=wave.tempoTiming ?: wave.phaseTiming?.let {grid->TempoSourceTiming(grid.sourceKey,grid.revision,grid.provenance,60000.0/grid.periodMs,grid.anchorMs.toDouble(),grid.law)} ?: return null
    if(timing.sourceKey!=wave.sourceKey||timing.beatAnchorMs>wave.durationMs)return null
    return timing.identity(clip)
}
