package com.soundq.android.product.timeline

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.text.drawText
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.soundq.android.data.AccountScope
import com.soundq.android.data.timeline.*
import com.soundq.designsystem.*
import com.soundq.android.playback.*
import kotlinx.coroutines.*

internal fun bpmText(bpm:Double):String=java.math.BigDecimal.valueOf(bpm).stripTrailingZeros().toPlainString()
private fun observedBpmText(bpm:Double)=java.math.BigDecimal.valueOf(bpm).setScale(1,java.math.RoundingMode.HALF_UP).stripTrailingZeros().toPlainString()
internal fun heldPlaybackBpm(document:TimelineDocument,clip:TimelineClip,source:TempoSourceIdentity?):Double? =
    document.playbackTempos.singleOrNull {it.source.occurrence==clip.occurrence}?.playbackBpm ?: clip.tempoMap?.law?.let {law->if(clip.occurrence==clip.tempoMap.intent.incoming.occurrence)law.targetBpm else law.startBpm} ?: source?.sourceBpm

/** Read-only trace samples use the exact same original-source law as native scheduling. */
internal fun tempoTraceSamples(clip:TimelineClip,source:TempoSourceIdentity?,viewport:TimelineViewport):List<Pair<Float,Double>> {
    val first=maxOf(clip.globalStartMs,viewport.offsetMs).toDouble()
    val last=minOf(clip.globalEndMs,viewport.offsetMs+viewport.visibleMs).toDouble()
    val bpm=clip.heldTempo?.source?.sourceBpm ?: source?.sourceBpm ?: clip.tempoMap?.sourceBpm ?: return emptyList()
    if(last<=first)return emptyList()
    val law=clip.tempoMap?.law
    return (0..48).map {i->val time=first+(last-first)*i/48.0
        ((time-viewport.offsetMs)*viewport.pixelsPerSecond/1000).toFloat() to (law?.bpmAt(time) ?: bpm*clip.rates.rateAtExact(time))}
}

@Composable internal fun WaveformBpmButton(document:TimelineDocument,clip:TimelineClip,source:TempoSourceIdentity?,playhead:State<Long>,enabled:Boolean,onClick:()->Unit,modifier:Modifier=Modifier,observedEffectiveBpm:Double?=null) {
    val original=clip.heldTempo?.source ?: source ?: clip.tempoMap?.intent?.let {if(it.outgoing.occurrence==clip.occurrence)it.outgoing else it.incoming}
    val held=heldPlaybackBpm(document,clip,original)
    val law=clip.tempoMap?.law
    val now=observedEffectiveBpm?.takeIf {it.isFinite()&&(law==null||playhead.value.toDouble()>=law.startMs&&playhead.value.toDouble()<law.endMs)}
    Column(modifier.width(112.dp).height(48.dp).background(SoundQ.colors.surface)
        .semantics(mergeDescendants=true) {contentDescription="Playback BPM for ${clip.title}";stateDescription=held?.let {"Set ${bpmText(it)} BPM"} ?: "Source BPM needed"}
        .clickable(enabled=enabled,role=Role.Button,onClick=onClick).padding(horizontal=8.dp),verticalArrangement=Arrangement.Center) {
        Text(if(held==null)"Set BPM" else if(now!=null)"Now ${observedBpmText(now)}" else "${bpmText(held)} BPM",style=SoundQ.typography.mono,maxLines=1,overflow=TextOverflow.Ellipsis)
        Text(if(original==null)"Source BPM needed" else if(now!=null)"Set ${bpmText(held!!)} · original ${bpmText(original.sourceBpm)}" else "Original ${bpmText(original.sourceBpm)}",style=SoundQ.typography.caption,color=SoundQ.colors.muted,maxLines=1,overflow=TextOverflow.Ellipsis)
    }
}

@Composable internal fun WaveformTempoTrace(clip:TimelineClip,source:TempoSourceIdentity?,viewport:TimelineViewport,modifier:Modifier=Modifier,bpmRange:Pair<Double,Double>?=null) {
    val points=remember(clip,source,viewport){tempoTraceSamples(clip,source,viewport)}
    val colors=SoundQ.colors
    val measurer=androidx.compose.ui.text.rememberTextMeasurer()
    val style=SoundQ.typography.caption.copy(color=colors.muted)
    val firstLabel=remember(points,style){points.firstOrNull()?.let {measurer.measure("${observedBpmText(it.second)} BPM",style)}}
    val lastLabel=remember(points,style){points.lastOrNull()?.let {measurer.measure("${observedBpmText(it.second)} BPM",style)}}
    Canvas(modifier.fillMaxWidth().height(24.dp).background(colors.surface).semantics {contentDescription="Tempo trace for ${clip.title}";stateDescription=if(points.isEmpty())"Source timing needed" else "${bpmText(points.first().second)} to ${bpmText(points.last().second)} BPM"}) {
        if(points.isEmpty())return@Canvas
        val min=bpmRange?.first ?: points.minOf {it.second};val max=bpmRange?.second ?: points.maxOf {it.second}
        fun y(bpm:Double)=size.height-4.dp.toPx()-((bpm-min)/maxOf(8.0,max-min)*10.dp.toPx()).toFloat()
        points.zipWithNext().forEach {(a,b)->drawLine(colors.primary,Offset(a.first,y(a.second)),Offset(b.first,y(b.second)),1.5.dp.toPx())}
        val first=points.first();val last=points.last()
        // Text layout is cached outside draw; viewport coordinates are shared with the waveform.
        firstLabel?.let {drawText(it,topLeft=Offset(first.first+2.dp.toPx(),0f))}
        if(last.first-first.first>160.dp.toPx())lastLabel?.let {drawText(it,topLeft=Offset((last.first-it.size.width).coerceAtLeast(first.first),0f))}
    }
}

/** The whole setting is accepted atomically. Preparing is not an optimistic ON state. */
@Composable internal fun AutoBpmCrossfadeControl(document:TimelineDocument,enabled:Boolean,busy:Boolean,message:String?,onToggle:(Boolean)->Unit,modifier:Modifier=Modifier) {
    val overlaps=remember(document){tempoEditorOverlaps(document).isNotEmpty()}
    val preparing=if(busy)"Preparing… Previous accepted settings remain in use." else null
    Column(modifier.fillMaxWidth().heightIn(min=72.dp).background(SoundQ.colors.surface).padding(horizontal=12.dp)) {
        Row(Modifier.fillMaxWidth().heightIn(min=48.dp),verticalAlignment=Alignment.CenterVertically) {
            Text("Auto BPM crossfade",Modifier.weight(1f),style=SoundQ.typography.body)
            if(busy)Text("Preparing…",style=SoundQ.typography.caption)
            Switch(document.autoBpmCrossfade,{onToggle(it)},enabled=enabled&&!busy,modifier=Modifier.semantics {contentDescription="Auto BPM crossfade";stateDescription=if(busy)"Preparing" else if(document.autoBpmCrossfade)"On" else "Off"})
        }
        Text(message ?: preparing ?: if(!overlaps)"No overlaps yet. Songs keep their own BPM." else if(document.autoBpmCrossfade)"Both tracks change tempo together during overlap." else if(document.tempoRamps.any {it.policy==TempoRampPolicy.SharedRampV1})"Saved BPM transitions stay in place. New overlaps keep each track’s BPM." else "Each track keeps its own BPM. Volume fade stays on.",style=SoundQ.typography.caption,color=if(message==null)SoundQ.colors.muted else SoundQ.colors.error)
    }
}

/** Drafts belong to this occurrence and mounted route. The repository owns source qualification. */
@Composable internal fun WaveformBpmEditor(document:TimelineDocument,clip:TimelineClip,repository:TimelineRepository,scope:AccountScope?,valid:()->Boolean,readWave:suspend (TimelineClip)->TrackWaveform?,onDismiss:()->Unit,onBeforeSave:()->Unit={},controller:ControllerProjection?=null) {
    val jobs=rememberCoroutineScope()
    val alive=remember {java.util.concurrent.atomic.AtomicBoolean(true)}
    var liveLease by remember { mutableStateOf<TempoPreviewLease?>(null) }
    var beginning by remember { mutableStateOf(false) }
    var liveRequired by remember { mutableStateOf(false) }
    var closePending by remember { mutableStateOf(false) }
    var closeError by remember { mutableStateOf<String?>(null) }
    var interruption by remember { mutableLongStateOf(0L) }
    var controlStatus by remember { mutableStateOf<PrecisionBpmControlStatus?>(null) }
    var resetSubmitted by remember { mutableStateOf(false) }
    var adjustmentOrigin by remember { mutableDoubleStateOf(0.0) }
    val cleanupSent = remember { java.util.concurrent.atomic.AtomicBoolean(false) }
    // Revocation is synchronous, not a Compose effect or a Cancel response. Retained callbacks
    // and a pending Begin must never revive this mounted editor after foreground intent ends.
    fun retireEditor() {
        if (!alive.getAndSet(false)) return
        val lease = liveLease
        liveLease = null; beginning = false; interruption++
        if (cleanupSent.compareAndSet(false, true)) controller?.cancelTempo(lease)
        onDismiss()
    }
    DisposableEffect(Unit) { onDispose {
        alive.set(false)
        val lease = liveLease
        liveLease = null
        // null still invalidates an in-flight Begin. Its adapter cancels any eventual lease.
        if (cleanupSent.compareAndSet(false, true)) controller?.cancelTempo(lease)
    } }
    val routeLifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    DisposableEffect(routeLifecycle) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_PAUSE || event == androidx.lifecycle.Lifecycle.Event.ON_DESTROY) {
                retireEditor()
            }
        }
        routeLifecycle.addObserver(observer)
        onDispose { routeLifecycle.removeObserver(observer) }
    }
    val capturedValid=remember {valid}
    var wave by remember {mutableStateOf<TrackWaveform?>(null)}
    var waveAdmission by remember {mutableStateOf<()->Boolean>({false})}
    var source by remember {mutableStateOf(repository.tempoSource(clip))}
    var sourceAdmission by remember {mutableStateOf(repository.captureTempoSources(listOfNotNull(source)))}
    var playback by remember {mutableStateOf(heldPlaybackBpm(document,clip,source)?.let(::bpmText).orEmpty())}
    var sourceBpm by remember {mutableStateOf("")}
    var editSource by remember {mutableStateOf(false)}
    // Start loading before either effect runs. A fast read may conflate true -> false in
    // one frame; starting false can strand Begin on its original (source, false) keys.
    var pending by remember {mutableStateOf(true)}
    var error by remember {mutableStateOf<String?>(null)}
    var retry by remember {mutableIntStateOf(0)}
    var removeLegacy by remember {mutableStateOf(false)}
    val legacy=document.tempoRamps.filter {it.policy==TempoRampPolicy.SharedRampV1&&(it.outgoing.occurrence==clip.occurrence||it.incoming.occurrence==clip.occurrence)}
    fun current()=alive.get()&&capturedValid()&&repository.state.value.document===document
    LaunchedEffect(retry) {
        pending=true;error=null
        try {wave=readWave(clip);if(current()){waveAdmission=if(scope!=null&&wave!=null)repository.captureWaveformSource(scope,clip,wave!!) else { {false} };source=repository.tempoSource(clip);sourceAdmission=repository.captureTempoSources(listOfNotNull(source));if(playback.isEmpty())playback=heldPlaybackBpm(document,clip,source)?.let(::bpmText).orEmpty()}}catch(cancel:CancellationException){throw cancel}catch(_:Exception){error="Source unavailable. Retry to edit BPM."}finally{pending=false}
        if(wave==null&&error==null)error="Source unavailable. Retry to edit BPM."
    }
    val projection = controller?.state?.collectAsState()?.value
    val liveState = projection?.tempoPreview?.takeIf { it.lease == liveLease }
    val identity = projection?.arrangement?.identity
    val running = projection?.let { it.isPlaying && it.canPerformArrangement && it.arrangement?.document == document } == true
    val terminalPublication = liveState?.phase in listOf(TempoPreviewPhase.Restored, TempoPreviewPhase.Retired)
    val liveOwnerChanged = liveLease?.let { lease ->
        projection?.connection != PlaybackProjection.Connection.Connected || identity != lease.target.identity
    } == true
    val liveControls = !terminalPublication && !liveOwnerChanged && (!liveRequired || liveLease != null)
    fun controlsCurrent(): Boolean {
        if (!current() || closePending) return false
        val lease = liveLease ?: return !liveRequired && !beginning
        val observed = controller?.state?.value ?: return false
        return observed.connection == PlaybackProjection.Connection.Connected &&
            observed.arrangement?.identity == lease.target.identity &&
            observed.tempoPreview?.takeIf { it.lease == lease }?.phase !in
                listOf(TempoPreviewPhase.Restored, TempoPreviewPhase.Retired)
    }
    val began = remember { java.util.concurrent.atomic.AtomicBoolean(false) }
    LaunchedEffect(liveLease, terminalPublication, liveOwnerChanged) {
        if (liveLease != null && (terminalPublication || liveOwnerChanged)) retireEditor()
    }
    // Readiness is observed, not sampled once at source-load completion. A controller publication
    // may arrive after the wave or sheet. Only this still-foreground mounted intent may begin.
    LaunchedEffect(source, pending, identity, running) {
        val captured = source
        if (alive.get() && current() && routeLifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED) &&
            !pending && sourceAdmission() && liveLease == null && captured != null && identity != null && running && began.compareAndSet(false, true)) {
            beginning = true; liveRequired = true
            controller.beginTempo(identity, clip.occurrence, captured) { lease, message ->
                if (!alive.get()) {
                    // cancel(null) already revoked the captured request. Never invalidate a successor
                    // Begin when the adapter delivers the old request's null completion.
                    if (lease != null) controller.cancelTempo(lease)
                } else {
                    beginning = false; liveLease = lease
                    if (lease == null) error = message
                }
            }
        }
    }
    fun dismiss() {
        if (!alive.get() || closePending) return
        interruption++
        val lease = liveLease
        if (lease == null) { retireEditor(); return }
        liveLease = null; closePending = true
        cleanupSent.set(true)
        controller?.cancelTempo(lease) { restored, message ->
            if (alive.get()) {
                closePending = false
                if (restored) { alive.set(false); onDismiss() }
                else closeError = message ?: "Restore did not complete. Saved BPM is unchanged."
            }
        }
    }
    if (!alive.get()) return
    SoundQSheet(if((source==null&&wave!=null&&!pending)||editSource)"Source BPM" else "Playback BPM",{if(!pending||liveLease!=null)dismiss()},dismissAdmission={(!pending||liveLease!=null)&&!closePending}) {
        Text(clip.title,style=SoundQ.typography.title,maxLines=1,overflow=TextOverflow.Ellipsis)
        if(legacy.isNotEmpty()) {
            Text("A saved beat-fitted transition owns this track’s BPM.",style=SoundQ.typography.caption)
            SoundQButton(if(removeLegacy)"Keep saved transition" else "Replace saved transition",{removeLegacy=!removeLegacy},enabled=!pending,variant=SoundQButtonVariant.Quiet)
            if(removeLegacy)Text("Save BPM will remove this beat-fitted transition. Source selections, starts and volume fades stay in place.",style=SoundQ.typography.caption)
        }
        if((source==null&&wave!=null&&!pending)||editSource) {
            val bpm=sourceBpm.toDoubleOrNull()
            val invalid=sourceBpm.isNotEmpty()&&(bpm==null||!bpm.isFinite()||bpm !in 10.0..600.0)
            OutlinedTextField(sourceBpm,{sourceBpm=it;error=null},label={Text("Source BPM")},keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Decimal),singleLine=true,modifier=Modifier.fillMaxWidth().semantics {contentDescription="Source BPM value"},enabled=!pending,isError=invalid,
                supportingText=if(invalid){{Text("Enter a BPM from 10 to 600.")}} else null)
            Text("BPM of the original audio",style=SoundQ.typography.caption)
            Row(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
              SoundQButton("Cancel",{if(editSource)editSource=false else dismiss()},enabled=!pending,variant=SoundQButtonVariant.Secondary)
              SoundQButton("Confirm source BPM",{
                val w=wave
                if(current()&&waveAdmission()&&scope!=null&&w!=null&&bpm!=null) {
                    val confirmed=repository.authorTempoBpm(scope,document,clip,w,bpm,{current()&&waveAdmission()})
                    if(confirmed==null)error="Source changed or BPM is invalid. Retry." else {source=confirmed;sourceAdmission=repository.captureTempoSources(listOf(confirmed));playback=bpmText(bpm);editSource=false;error=null}
                } else error="Source changed. Retry before confirming BPM."
              },enabled=!pending&&wave!=null&&!invalid&&bpm!=null)
            }
        } else if(source!=null) {
            val captured=source!!
            val value=playback.toDoubleOrNull()
            val fieldError=playback.isNotEmpty()&&(value==null||!value.isFinite()||value !in 10.0..600.0||value/captured.sourceBpm !in 0.8..1.5)
            PrecisionBpmControl(value ?: captured.sourceBpm, captured.sourceBpm,
                maxOf(10.0,captured.sourceBpm*0.8)..minOf(600.0,captured.sourceBpm*1.5),
                onDraft = { next ->
                    if (!controlsCurrent()) return@PrecisionBpmControl
                    playback = bpmText(next); error = null
                    // Reset animation owns numbers only. One native smoothstep begins at its rendered origin.
                    if (!resetSubmitted) liveLease?.let { controller?.previewTempo(it,next,0) }
                }, enabled = liveControls && !pending && !beginning && !closePending && error == null,
                interruptionKey = interruption,
                onAdjustmentBegin = { if (controlsCurrent()) { adjustmentOrigin = playback.toDoubleOrNull() ?: captured.sourceBpm; resetSubmitted = false } },
                onAdjustmentEnd = {
                    // The component ends a glide on a new down before the next input begins.
                    // Retire its outstanding audio target at the visible value, not at its old destination.
                    val visible = playback.toDoubleOrNull()
                    if (controlsCurrent() && resetSubmitted && visible != null && visible != captured.sourceBpm && !pending)
                        liveLease?.let { controller?.previewTempo(it,visible,0) }
                },
                onAdjustmentCancel = {
                    if (controlsCurrent() && !pending) { playback = bpmText(adjustmentOrigin); liveLease?.let { controller?.previewTempo(it,adjustmentOrigin,0) } }
                },
                onInputStateChange = { status ->
                    controlStatus = status
                    if (controlsCurrent() && status.isGliding && !resetSubmitted) {
                        resetSubmitted = true
                        liveLease?.let { controller?.previewTempo(it,captured.sourceBpm,450) }
                    }
                }, onCancelRequest = { dismiss() })
            Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {
                Text("Original: ${bpmText(captured.sourceBpm)} BPM",Modifier.weight(1f),style=SoundQ.typography.caption)
                TextButton({if(controlsCurrent()&&!liveRequired){sourceBpm=bpmText(captured.sourceBpm);editSource=true}},enabled=!pending&&!beginning&&!liveRequired&&wave!=null&&liveLease==null,modifier=Modifier.semantics {contentDescription="Edit source BPM"}) {Text("Edit")}
            }
            Text("Playback range: ${bpmText(maxOf(10.0,captured.sourceBpm*0.8))}–${bpmText(minOf(600.0,captured.sourceBpm*1.5))} BPM",style=SoundQ.typography.caption)
            Text(if(liveLease!=null && liveControls) "Live preview. Save keeps playback running; Cancel restores accepted BPM." else if(liveRequired) "Live preview ended. Close and reopen to edit BPM." else "Draft only. Save applies on the next Play.",style=SoundQ.typography.caption)
            liveState?.let { state ->
                Text(state.message ?: when(state.phase) {
                    TempoPreviewPhase.Preparing -> "Preparing live BPM…"
                    TempoPreviewPhase.Applied -> "Playing ${bpmText(state.appliedBpm)} BPM"
                    TempoPreviewPhase.Saving -> "Waiting for rendered BPM before saving…"
                    else -> "Accepted ${bpmText(state.appliedBpm)} BPM"
                },style=SoundQ.typography.caption,color=if(state.phase in listOf(TempoPreviewPhase.Refused,TempoPreviewPhase.Retired))SoundQ.colors.error else SoundQ.colors.muted)
            }
            closeError?.let { Text(it,color=SoundQ.colors.error,style=SoundQ.typography.caption) }
            if(document.tempoRamps.any {it.policy==TempoRampPolicy.AutoSourceBoundsV1&&it.incoming.occurrence==clip.occurrence})Text("Reached at overlap end, then held.",style=SoundQ.typography.caption)
            Row(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                SoundQButton(if(closePending)"Restoring…" else "Cancel",{dismiss()},enabled=!closePending,variant=SoundQButtonVariant.Secondary)
                SoundQButton(if(pending)"Preparing…" else "Save BPM",{
                    if (!controlsCurrent() || beginning) return@SoundQButton
                    val lease = liveLease
                    if (lease != null) {
                        interruption++; pending = true
                        controller?.saveTempo(lease) { saved, message ->
                            if (alive.get() && liveLease == lease) { pending = false; if(saved) { liveLease = null; cleanupSent.set(true); alive.set(false); onDismiss() } else closeError = message }
                        }
                    } else {
                    val bpm=playback.toDoubleOrNull()
                    if(current()&&bpm!=null&&sourceAdmission()) {
                        val admission=sourceAdmission
                        val candidate=runCatching {
                            val base=if(removeLegacy)document.copy(tempoRamps=document.tempoRamps-legacy.toSet()) else document
                            base.withPlaybackTempo(TempoPlaybackIntent(captured,bpm))
                        }
                        if(candidate.isFailure)error=candidate.exceptionOrNull()?.message else {
                            onBeforeSave();pending=true;jobs.launch {try {
                                val accepted=withContext(Dispatchers.IO){repository.commit(TimelineTempoEdit(document,candidate.getOrThrow())){current()&&admission()}}
                                if(accepted)onDismiss() else error=repository.state.value.message ?: "BPM was not saved. Source or arrangement changed."
                            }finally{pending=false}}
                        }
                    } else error="Source or arrangement changed. Retry source before saving."
                    }
                },enabled=liveControls&&!pending&&!beginning&&!closePending&&!fieldError&&value!=null&&error==null&&
                    (!liveRequired||liveLease!=null)&&controlStatus?.canSubmit!=false&&liveState?.phase !in listOf(TempoPreviewPhase.Refused,TempoPreviewPhase.Retired,TempoPreviewPhase.Restoring))
            }
        }
        if(pending)Text("Preparing…",style=SoundQ.typography.caption)
        error?.let {Text(it,Modifier.semantics {liveRegion=LiveRegionMode.Polite},color=SoundQ.colors.error,style=SoundQ.typography.caption);SoundQButton("Retry source",{began.set(false);retry++},enabled=!pending,variant=SoundQButtonVariant.Quiet)}
    }
}
