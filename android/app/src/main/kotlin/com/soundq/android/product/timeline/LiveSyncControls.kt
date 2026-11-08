package com.soundq.android.product.timeline

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import com.soundq.android.data.timeline.*
import com.soundq.android.playback.*
import com.soundq.android.product.ProductViewModel
import com.soundq.designsystem.*

/** Live performance intent is separate from saved draft timing and Undo. */
@Composable internal fun LiveSyncControls(model:ProductViewModel,waves:Map<Long,TrackWaveform>,valid:()->Boolean) {
    val playback by model.playback.collectAsState()
    val accepted=playback.arrangement
    var reference by remember(accepted?.identity){mutableStateOf<String?>(null)}
    var incoming by remember(accepted?.identity){mutableStateOf<String?>(null)}
    var beats by remember {mutableIntStateOf(1)}
    var manual by remember {mutableStateOf(false)}
    var message by remember {mutableStateOf<String?>(null)}
    var pending by remember(accepted?.identity){mutableStateOf(false)}
    var unlinking by remember(accepted?.identity){mutableStateOf(false)}
    var request by remember(accepted?.identity){mutableLongStateOf(0)}
    val a=accepted?.document?.clips?.firstOrNull {it.occurrence==reference}
    val b=accepted?.document?.clips?.firstOrNull {it.occurrence==incoming}
    var pickA by remember(accepted?.identity,reference,waves[a?.track]?.sourceKey,a?.sourceDurationMs){mutableStateOf<SourceTimingPick?>(null)}
    var pickB by remember(accepted?.identity,incoming,waves[b?.track]?.sourceKey,b?.sourceDurationMs){mutableStateOf<SourceTimingPick?>(null)}
    val alive=remember {java.util.concurrent.atomic.AtomicBoolean(true)}
    DisposableEffect(Unit){onDispose {alive.set(false)}}
    fun grid(clip:TimelineClip,pick:SourceTimingPick?):QualifiedLiveGrid? {
        val wave=waves[clip.track]?.takeIf {it.track.value==clip.track&&it.durationMs==clip.sourceDurationMs} ?: return null
        if(pick==null)return wave.phaseTiming?.takeIf {it.sourceKey==wave.sourceKey}?.let {g->
            QualifiedLiveGrid(60000.0/g.periodMs,g.anchorMs.toDouble(),g.groupOriginMs?.toDouble(),wave.sourceKey,g.revision,"manual_timing_v2")
        }
        if(!pick.matches(clip,wave))return null
        val adopted=pick.adopted
        return QualifiedLiveGrid(pick.bpm.toDoubleOrNull() ?: adopted?.let {60000.0/it.periodMs} ?: return null,
            pick.anchorMs?.toDouble() ?: return null,pick.groupOriginMs?.toDouble(),wave.sourceKey,
            adopted?.revision ?: "local:${pick.bpm}:${pick.anchorMs}:${pick.groupOriginMs}",adopted?.provenance ?: "local_manual").takeIf {it.valid(clip.sourceDurationMs,beats)}
    }
    val ga=a?.let {grid(it,pickA)}
    val gb=b?.let {grid(it,pickB)}
    val deck=playback.performanceDecks[incoming]
    val linked=deck?.syncState?.let {it!=LiveSyncState.Off&&it!=LiveSyncState.Failed}==true
    // Admission is not callback application. Keep the submitted selection frozen
    // across the Off -> Pending publication gap, including synchronous re-taps.
    LaunchedEffect(playback.canPerformArrangement,deck?.syncState,deck?.syncReferenceOccurrence,deck?.syncBeats) {
        if(!playback.canPerformArrangement){request++;pending=false;unlinking=false}
        else if(!unlinking&&(deck?.syncState==LiveSyncState.Failed||
            (deck!=null&&deck.syncReferenceOccurrence==reference&&deck.syncBeats==beats&&linked)))pending=false
    }
    // Explicit Unlink must reach Off before changing an installed grid. Native
    // snapshots do not carry a per-command grid acknowledgement token.
    val canSync=accepted!=null&&playback.canPerformArrangement&&a!=null&&b!=null&&a.occurrence!=b.occurrence&&ga!=null&&gb!=null&&ga.valid(a.sourceDurationMs,beats)&&gb.valid(b.sourceDurationMs,beats)&&!pending&&!linked
    Text("Live sync",style=SoundQ.typography.title)
    LiveOccurrencePicker("Reference",reference,accepted?.document?.clips.orEmpty(),!pending){reference=it;message=null}
    LiveOccurrencePicker("Incoming",incoming,accepted?.document?.clips.orEmpty(),!pending){incoming=it;message=null}
    Row(Modifier.fillMaxWidth()) {
        listOf(1,4,16,32).forEach {value->
            Box(Modifier.weight(1f).heightIn(min=48.dp).semantics {contentDescription="Sync boundary, $value beats";selected=beats==value}
                .clickable(enabled=!pending) {beats=value},contentAlignment=Alignment.Center) {
                Text(value.toString(),style=SoundQ.typography.mono,color=if(beats==value)SoundQ.colors.primary else SoundQ.colors.text)
            }
        }
    }
    Row {
        SoundQIconButton(SoundQIcon.Retry,"Sync Incoming to Reference",{
            val captured=accepted
            if(captured!=null&&canSync&&!pending&&valid()) {
                val ticket=++request
                pending=true;message=null
                model.controller.syncIncoming(captured.identity,a!!.occurrence,b!!.occurrence,beats,ga!!,gb!!) {ok->
                    if(alive.get()&&request==ticket&&model.playback.value.arrangement?.identity==captured.identity&&!ok){pending=false;message="Sync failed"}
                }
            }
        },enabled=canSync)
        SoundQIconButton(SoundQIcon.Close,"Disable live sync",{
            val captured=accepted
            val target=incoming
            if(captured!=null&&target!=null&&!unlinking&&valid()) {
                val ticket=++request
                unlinking=true;pending=true;message=null
                // Keep an explicit escape during the admission/ACK gap. Completion
                // is the controller's observed Off, not merely Unlink admission.
                model.controller.unlinkIncoming(captured.identity,target) {off->
                    if(alive.get()&&request==ticket&&model.playback.value.arrangement?.identity==captured.identity) {
                        unlinking=false
                        if(off)pending=false else message="Sync failed"
                    }
                }
            }
        },enabled=accepted!=null&&incoming!=null&&!unlinking&&playback.performanceDecks[incoming]?.scratching!=true)
        SoundQIconButton(SoundQIcon.Settings,"Set live source timing",{manual=!manual})
    }
    if(manual) {
        a?.let {SourceTimingPicker("Reference",it,waves[it.track],pickA,!pending&&!linked,lifetime=accepted.identity){value->if(!pending&&!linked)pickA=value}}
        b?.let {SourceTimingPicker("Incoming",it,waves[it.track],pickB,!pending&&!linked,lifetime=accepted.identity){value->if(!pending&&!linked)pickB=value}}
    }
    val status=message ?: when {
        pending->"Pending · $beats beats"
        accepted==null||!playback.canPerformArrangement->"Audition an arrangement first"
        deck?.syncState==LiveSyncState.Locked->"Locked · ${deck.syncBeats} beats"
        deck?.syncState==LiveSyncState.Pending->"Pending · ${deck.syncBeats} beats"
        deck?.syncState==LiveSyncState.Rejoining->"Rejoining"
        deck?.syncState==LiveSyncState.ScratchSuspended->"Scratch"
        deck?.syncState==LiveSyncState.Failed->"Sync failed"
        ga==null||gb==null||ga.valid(a?.sourceDurationMs ?: 0,beats)!=true||gb.valid(b?.sourceDurationMs ?: 0,beats)!=true->"Timing needed"
        else->"Ready"
    }
    Text(status,style=SoundQ.typography.caption)
    SoundQDivider()
}

@Composable private fun LiveOccurrencePicker(label:String,selected:String?,clips:List<TimelineClip>,enabled:Boolean=true,choose:(String)->Unit) {
    var open by remember {mutableStateOf(false)}
    Box {
        val i=clips.indexOfFirst {it.occurrence==selected}
        SoundQButton(if(i<0)"$label · choose" else "$label · ${i+1} · ${clips[i].title}",{open=true},modifier=Modifier.semantics {contentDescription="Live sync $label"},enabled=enabled,variant=SoundQButtonVariant.Quiet)
        DropdownMenu(open,{open=false}) {
            clips.forEachIndexed {index,clip->DropdownMenuItem({Text("${index+1} · ${clip.title}")},{open=false;if(enabled)choose(clip.occurrence)},enabled=enabled,modifier=Modifier.heightIn(min=48.dp))}
        }
    }
}
