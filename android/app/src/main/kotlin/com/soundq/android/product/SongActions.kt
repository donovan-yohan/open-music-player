package com.soundq.android.product

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import com.soundq.android.playback.PlaybackRef
import com.soundq.android.playback.SongSpeedState
import com.soundq.designsystem.*
import java.util.concurrent.atomic.AtomicBoolean

/** One unboxed action list; song capabilities and mutation ownership stay in the caller. */
@Composable internal fun SongActionRow(
    label: String, onClick: () -> Unit, icon: SoundQIcon? = null, value: String? = null,
    opensDestination: Boolean = false, enabled: Boolean = true, destructive: Boolean = false,
) {
    val ink = if (!enabled) SoundQ.colors.disabled else if (destructive) SoundQ.colors.error else SoundQ.colors.text
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp)
        .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
        .semantics(mergeDescendants = true) { value?.let { stateDescription = it } }
        .padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) { icon?.let { SoundQIcon(it, null, tint = ink) } }
        Column(Modifier.weight(1f)) {
            Text(label, style = SoundQ.typography.body, color = ink)
            value?.let { Text(it, style = SoundQ.typography.caption, color = SoundQ.colors.muted) }
        }
        if (opensDestination) SoundQIcon(SoundQIcon.Arrow, null, tint = ink)
    }
}

/** Captures an arbitrary song, never the mutable current occurrence. */
@Composable internal fun SongSpeedEditor(model: ProductViewModel, ref: PlaybackRef, valid: () -> Boolean, onBack: () -> Unit) {
    val version = remember(ref) { model.graph.session.version() }
    val alive = remember(ref, version) { AtomicBoolean(true) }
    DisposableEffect(alive) { onDispose { alive.set(false) } }
    var state by remember(ref, version) { mutableStateOf<SongSpeedState?>(null) }
    var pending by remember(ref, version) { mutableStateOf<Double?>(null) }
    var message by remember(ref, version) { mutableStateOf<String?>(null) }
    var receipt by remember(ref, version) { mutableLongStateOf(0) }
    val active = { alive.get() && valid() && model.graph.session.owns(version) }
    fun request(rate: Double?) {
        val token = ++receipt
        pending = rate; message = null
        model.controller.songSpeed(ref, version, rate, active) { result ->
            if (active() && token == receipt) {
                pending = null
                if (result == null) message = "Couldn't change speed. Try again."
                else {
                    state = result
                    if (rate != null) message = if (result.persisted) "Saved for this song" else "Set for now. Not saved for restart."
                }
            }
        }
    }
    LaunchedEffect(ref, version) { request(null) }
    BackHandler(onBack = onBack)
    Row(verticalAlignment = Alignment.CenterVertically) {
        SoundQIconButton(SoundQIcon.Back, "Back to song actions", onBack)
        Text("Song actions", style = SoundQ.typography.body)
    }
    val accepted = state
    if (accepted == null) {
        Text(message ?: "Loading speed…", style = SoundQ.typography.caption)
        if (message != null) SongActionRow("Retry", { request(null) })
    } else {
        SoundQPlaybackSpeedPanel(accepted.speed, pending, accepted.min, accepted.max,
            if (accepted.unavailable != null) SoundQSpeedPanelState.Unavailable else if (pending != null) SoundQSpeedPanelState.Pending else SoundQSpeedPanelState.Ready,
            listeningSpeedReason(accepted.unavailable), onRequest = { request(it) }, onReset = { request(1.0) }, identity = ref,
            pendingVerb = if (accepted.current) "Applying" else "Saving")
        SongActionRow("Reset to normal", { request(1.0) }, enabled = pending == null && accepted.unavailable == null)
        message?.let { Text(it, style = SoundQ.typography.caption, color = SoundQ.colors.muted) }
    }
}
