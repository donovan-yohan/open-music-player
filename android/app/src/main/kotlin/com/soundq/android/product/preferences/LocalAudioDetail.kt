package com.soundq.android.product.preferences

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.*
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.soundq.android.AppGraph
import com.soundq.android.data.device.PhoneAudioState
import com.soundq.designsystem.*

/** Plain Local audio states from the phone owner's published state only. */
internal enum class LocalAudioStatus { Off, Scanning, Failed, Empty, Found }
internal fun localAudioStatus(state:PhoneAudioState):LocalAudioStatus? = when {
    !state.ready->null
    !state.permission->LocalAudioStatus.Off
    state.refreshing->LocalAudioStatus.Scanning
    state.snapshot==null||state.scan?.indexed==false->LocalAudioStatus.Failed
    state.snapshot.files.none {it.available}->if(state.scan==null)null else LocalAudioStatus.Empty
    else->LocalAudioStatus.Found
}
internal fun localAudioSongs(state:PhoneAudioState):Int = state.snapshot?.files?.count {it.available} ?: 0

/** Settings → Local audio. One access action; scanning belongs to the single phone-audio owner. */
@Composable internal fun LocalAudioDetail(graph: AppGraph) {
    val owner = graph.phoneAudio
    val state by owner.state.collectAsStateWithLifecycle()
    val version = remember { graph.session.version() }
    val alive = remember { java.util.concurrent.atomic.AtomicBoolean(true) }
    DisposableEffect(Unit) { onDispose { alive.set(false) } }
    val valid = { alive.get() && owner.current(version) }
    val pickers = rememberAudioPickers(graph,
        { uri, flags, current -> owner.selected(uri, flags, false) { valid() && current() } },
        { uri, flags, current -> owner.selected(uri, flags, true) { valid() && current() } },
        { if (valid()) owner.refresh(valid) })
    val status = localAudioStatus(state)
    SoundQSettingsSectionLabel("Access", first = true)
    SoundQSettingsRow("File access", value = if (state.permission) "Allowed" else "Off")
    if (status == LocalAudioStatus.Off || !state.ready) {
        SoundQSettingsBlock(Modifier.padding(top = SoundQ.spacing.large)) {
            SoundQButton("Allow file access", pickers.permission, Modifier.fillMaxWidth(), enabled = state.ready)
        }
        return
    }
    SoundQSettingsSectionLabel("Library")
    when (status) {
        LocalAudioStatus.Scanning -> SoundQSettingsBlock(Modifier.heightIn(min = SoundQSettingsMetrics.rowMin)) {
            Row(Modifier.heightIn(min = SoundQSettingsMetrics.rowMin).semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(SoundQ.spacing.medium)) {
                CircularProgressIndicator(Modifier.size(SoundQ.sizes.icon), color = SoundQ.colors.primary, strokeWidth = SoundQ.sizes.focus)
                Text("Scanning…", style = SoundQ.typography.title, color = SoundQ.colors.text)
            }
        }
        LocalAudioStatus.Failed -> {
            if (localAudioSongs(state) > 0) SoundQSettingsRow("Songs", value = "${localAudioSongs(state)}")
            SoundQSettingsBlock { SoundQFeedback("Couldn’t scan audio", FeedbackKind.Error, action = "Try again", onAction = { owner.refresh(valid) }) }
            return
        }
        LocalAudioStatus.Empty -> SoundQSettingsBlock(Modifier.heightIn(min = SoundQSettingsMetrics.rowMin)) {
            Box(Modifier.heightIn(min = SoundQSettingsMetrics.rowMin), contentAlignment = Alignment.CenterStart) {
                Text("No audio found", style = SoundQ.typography.title, color = SoundQ.colors.text, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
            }
        }
        else -> SoundQSettingsRow("Songs", value = "${localAudioSongs(state)}")
    }
    SoundQSettingsBlock(Modifier.padding(top = SoundQ.spacing.large)) {
        SoundQButton("Scan again", { owner.refresh(valid) }, Modifier.fillMaxWidth(), variant = SoundQButtonVariant.Secondary, enabled = status != LocalAudioStatus.Scanning)
    }
}
