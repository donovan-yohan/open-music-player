package com.soundq.android.product

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import com.soundq.android.playback.*
import com.soundq.designsystem.*

/** Presentation only. Positions come from accepted playback; no UI timer or optimistic cursor. */
private class ClockSeekReceipt(p:PlaybackProjection,val mode:PlayerClockMode,val destination:ClockDestination) {
    private val scope=listOf(p.accountEpoch,p.arrangementService,p.sourceQueueIncarnation,p.sessionIdentity,p.source,p.localOnly)
    private val origin=p.selectionIncarnation to p.selectedOccurrence
    private var selection=origin
    private var adopted=false
    private var active=true
    var pending by mutableStateOf(true)
    var failure by mutableStateOf(false)
    fun accepts(p:PlaybackProjection,currentMode:PlayerClockMode):Boolean {
        if(!active)return false
        if(currentMode!=mode||p.connection!=PlaybackProjection.Connection.Connected||
            scope!=listOf(p.accountEpoch,p.arrangementService,p.sourceQueueIncarnation,p.sessionIdentity,p.source,p.localOnly)) {
            active=false;return false
        }
        val next=p.selectionIncarnation to p.selectedOccurrence
        if(next==selection)return true
        // Only the captured inverse destination may replace the admitted source once.
        // Controller onMediaItemTransition + publish can retire that selection twice;
        // a further transition (including same-ID ABA) is not this request's destination.
        val delta=p.selectionIncarnation-origin.first
        if(!adopted&&destination.occurrence!=origin.second&&p.selectedOccurrence==destination.occurrence&&delta in 1L..2L) {
            selection=next;adopted=true;return true
        }
        active=false;return false
    }
}
@Composable internal fun FullPlayerClock(p:PlaybackProjection,seek:(PlaybackProjection,PlayerClockMode,Long,()->Boolean,(Boolean)->Unit)->Unit) {
    var mode by rememberSaveable(p.accountEpoch,p.arrangementService) {mutableStateOf(PlayerClockMode.Song)}
    val latestMode by rememberUpdatedState(mode)
    val live=remember {java.util.concurrent.atomic.AtomicBoolean(true)}
    DisposableEffect(live){onDispose {live.set(false)}}
    val clock=projectPlayerClock(p,mode)
    // Source/choice changes retire an in-progress gesture. Harmless clock ticks do not.
    val identity=listOf(mode,p.accountEpoch,p.arrangementService,p.sourceQueueIncarnation,p.selectionIncarnation,p.selectedOccurrence,p.sessionIdentity,p.source,p.connection,p.localOnly)
    // Draft ownership is stricter than an admitted request's expected destination.
    var draft by remember(identity,p.clockAuthority,clock.totalMs){mutableStateOf<Float?>(null)}
    var receipt by remember {mutableStateOf<ClockSeekReceipt?>(null)}
    val currentIdentity by rememberUpdatedState(identity)
    val currentProjection by rememberUpdatedState(p)
    if(receipt?.accepts(p,mode)==false)receipt=null
    val pending=receipt?.pending==true
    val failure=receipt?.failure==true
    val total=clock.totalMs
    val enabled=total!=null&&total>0&&clock.destination(0)!=null&&!pending
    Row(Modifier.selectableGroup().testTag("player-clock-choice"),verticalAlignment=Alignment.CenterVertically) {
        PlayerClockMode.entries.forEach {choice->
            Box(Modifier.widthIn(min=88.dp).heightIn(min=48.dp)
                .semantics {contentDescription=if(choice==PlayerClockMode.Song)"Current song clock" else "Whole queue clock"}
                .selectable(mode==choice,role=Role.RadioButton,onClick={if(mode!=choice){draft=null;receipt=null;mode=choice}}),contentAlignment=Alignment.Center) {
                Text(if(choice==PlayerClockMode.Song)"Song" else "Queue",color=if(mode==choice)SoundQ.colors.focus else SoundQ.colors.muted,style=SoundQ.typography.caption)
            }
        }
    }
    val progress=if(total!=null&&total>0)draft ?: clock.fraction ?: 0f else 0f
    val progressLabel=if(mode==PlayerClockMode.Song)"Playback position" else "Queue playback position"
    val progressSemantics=if(total!=null)Modifier.semantics {contentDescription=progressLabel}
        else Modifier.clearAndSetSemantics {contentDescription=progressLabel;stateDescription="Duration unavailable";disabled();progressBarRangeInfo=ProgressBarRangeInfo.Indeterminate}
    Slider(progress.coerceIn(0f,1f),{if(enabled)draft=it},Modifier.fillMaxWidth().heightIn(min=48.dp).testTag("player-clock-progress").then(progressSemantics),enabled=enabled,onValueChangeFinished={
        val position=if(total!=null)draft?.let {(it.toDouble()*total).toLong()} else null
        draft=null
        if(enabled&&position!=null&&live.get()&&currentIdentity==identity&&receipt?.pending!=true) {
            val destination=clock.destination(position)
            if(destination!=null) {
                val admitted=ClockSeekReceipt(p,mode,destination)
                receipt=admitted
                val valid={live.get()&&receipt===admitted&&admitted.accepts(currentProjection,latestMode)}
                seek(p,mode,position,valid) {ok->if(valid()){admitted.pending=false;admitted.failure=!ok}}
            }
        }
    })
    val elapsed=if(total!=null)draft?.let {(it.toDouble()*total).toLong()} ?: clock.elapsedMs else clock.elapsedMs
    Text("${elapsed?.let(::formatSongTime) ?: "—"} / ${total?.let(::formatSongTime) ?: "—"}",Modifier.testTag("player-clock-time"),style=SoundQ.typography.mono)
    val status=when {pending->"Seeking";failure->"Seek not confirmed. Try again.";clock.elapsedMs==null->if(mode==PlayerClockMode.Queue)"Queue clock unavailable" else "Song clock unavailable";total==null->"Duration unavailable";else->null}
    if(status!=null)Text(status,Modifier.semantics {liveRegion=LiveRegionMode.Polite},style=SoundQ.typography.caption,color=if(failure)SoundQ.colors.error else SoundQ.colors.muted)
}
