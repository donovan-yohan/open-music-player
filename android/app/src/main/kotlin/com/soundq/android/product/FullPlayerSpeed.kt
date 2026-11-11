package com.soundq.android.product

import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import com.soundq.android.playback.*
import com.soundq.designsystem.*

/** One request receipt for the captured track identity. Never shown as accepted fact. */
private class SpeedReceipt(val requested:Double) {
    var pending by mutableStateOf(true)
    var rejected by mutableStateOf(false)
}
internal class FullPlayerSpeed(val cell:SoundQSpeedCell?,val content:(@Composable ()->Unit)?)

internal fun listeningSpeedReason(reason:ListeningSpeedUnavailable?):String? = when(reason) {
    ListeningSpeedUnavailable.Arrangement->"Speed is set by the Mix while it plays."
    ListeningSpeedUnavailable.Jam->"Speed follows the Jam host."
    ListeningSpeedUnavailable.Source->"Speed changes aren't available for this track."
    null->null
}

/** Presentation binding for the full player. The accepted rate comes only from the service
 * projection; a selection/source change retires any draft, pending receipt or rejection. */
@Composable internal fun rememberFullPlayerSpeed(
    p:PlaybackProjection,
    request:(PlaybackProjection,Double,()->Boolean,(Boolean)->Unit)->Unit,
):FullPlayerSpeed {
    var expanded by rememberSaveable {mutableStateOf(false)}
    val speed=p.listeningSpeed ?: return FullPlayerSpeed(null,null)
    val identity=listOf(p.selectedOccurrence,p.sourceQueueIncarnation,p.sessionIdentity,p.source,p.accountEpoch,p.selectionIncarnation,p.connection)
    var receipt by remember(identity) {mutableStateOf<SpeedReceipt?>(null)}
    val live=remember {java.util.concurrent.atomic.AtomicBoolean(true)}
    DisposableEffect(live) {onDispose {live.set(false)}}
    val currentIdentity by rememberUpdatedState(identity)
    val send:(Double)->Unit={rate->
        val admitted=SpeedReceipt(rate)
        receipt=admitted
        val valid={live.get()&&receipt===admitted&&currentIdentity==identity}
        request(p,rate,valid) {ok->
            if(valid()) {if(ok)receipt=null else {admitted.pending=false;admitted.rejected=true}}
        }
    }
    val current=receipt
    val state=when {
        speed.unavailable!=null->SoundQSpeedPanelState.Unavailable
        current?.pending==true->SoundQSpeedPanelState.Pending
        current?.rejected==true->SoundQSpeedPanelState.Rejected
        else->SoundQSpeedPanelState.Ready
    }
    val cell=SoundQSpeedCell(speed.accepted,speed.unavailable==null,expanded) {expanded=!expanded}
    return FullPlayerSpeed(cell) {
        SoundQPlaybackSpeedPanel(speed.accepted,current?.takeIf {it.pending}?.requested,speed.min,speed.max,state,
            listeningSpeedReason(speed.unavailable),onRequest=send,onReset={send(1.0)},identity=identity,
            rejected=current?.takeIf {it.rejected}?.requested)
    }
}
