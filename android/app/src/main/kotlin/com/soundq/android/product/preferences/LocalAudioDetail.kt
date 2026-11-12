package com.soundq.android.product.preferences

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.*
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.soundq.android.AppGraph
import com.soundq.android.data.deviceaudio.*
import com.soundq.designsystem.*

/** Existing Settings detail. All catalog operations dispatch to its single IO owner. */
@Composable internal fun LocalAudioDetail(graph: AppGraph, onBack: () -> Unit) {
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
    var remove by remember { mutableStateOf<ScanGrant?>(null) }
    SoundQButton("Back to Settings", onBack, variant = SoundQButtonVariant.Quiet)
    Text("Phone audio", style = SoundQ.typography.title)
    Text(if (state.permission) "File access allowed" else "File access is off", color = if (state.permission) SoundQ.colors.primary else SoundQ.colors.muted)
    if (!state.permission) SoundQButton("Allow file access", pickers.permission)
    SoundQButton(if (state.refreshing) "Refreshing…" else "Refresh", { owner.refresh(valid) }, enabled = state.ready && !state.refreshing, variant = SoundQButtonVariant.Secondary)
    SoundQButton("Add folder", pickers.folder, enabled = state.ready, variant = SoundQButtonVariant.Secondary)
    SoundQButton("Open audio file", pickers.file, enabled = state.ready, variant = SoundQButtonVariant.Secondary)
    state.message?.let { SoundQFeedback(it, FeedbackKind.Notice) }
    Text("Added locations", style = SoundQ.typography.title)
    val grants = state.snapshot?.grants.orEmpty().filter { it.kind != GrantKind.INDEXED && it.state != AccessState.REMOVED }
    if (grants.isEmpty()) Text("No added locations", color = SoundQ.colors.muted)
    grants.forEach { grant ->
        key(grant.id) {
            SoundQDivider()
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(grant.label, Modifier.weight(1f), style = SoundQ.typography.title)
                SoundQButton("Remove", { if (valid()) remove = grant }, variant = SoundQButtonVariant.Quiet)
            }
            Text(if (grant.state == AccessState.AVAILABLE) (if (grant.persisted) "Available" else "Available for this session") else "Unavailable · access lost", color = if (grant.state == AccessState.AVAILABLE) SoundQ.colors.muted else SoundQ.colors.error)
            if (grant.state != AccessState.AVAILABLE) SoundQButton(if (grant.kind == GrantKind.FOLDER) "Choose folder again" else "Choose file again",
                if (grant.kind == GrantKind.FOLDER) pickers.folder else pickers.file, variant = SoundQButtonVariant.Secondary)
        }
    }
    remove?.let { grant ->
        AlertDialog(onDismissRequest = { remove = null }, title = { Text("Remove ${grant.label}?") },
            text = { Text("SoundQ will stop finding audio through this location. Your files and saved progress won’t be deleted.") },
            confirmButton = { TextButton(onClick = { remove = null; owner.remove(grant, valid) }) { Text("Remove location") } },
            dismissButton = { TextButton(onClick = { remove = null }) { Text("Cancel") } })
    }
}
