package com.soundq.android.product

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.RectangleShape
import com.soundq.android.data.AccountScope
import com.soundq.android.data.deviceaudio.DeviceAudio
import com.soundq.android.data.originalimport.*
import com.soundq.designsystem.SoundQ
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Mounted on the existing phone-song actions; opening or dismissing never sends bytes. */
@Composable internal fun OriginalImportActionContent(model: ProductViewModel, row: DeviceAudio, current: () -> Boolean) {
    val graph = model.graph
    val repository = graph.originalImports
    val snapshot by repository.state.collectAsState()
    val version = graph.session.version()
    val scope = remember(version) { graph.session.capture() } ?: return
    if (!snapshot.ready || !repository.ready(scope)) return
    val latestCurrent by rememberUpdatedState(current)
    var confirmation by remember(scope, row.owner) { mutableStateOf<OriginalImportRepository.Choice?>(null) }
    var busy by remember(scope, row.owner) { mutableStateOf(false) }
    var message by remember(scope, row.owner) { mutableStateOf<String?>(null) }
    val entries = repository.entries(scope)
    val pending = entries.singleOrNull { it.phase in activeImportPhases }
    val added = entries.firstOrNull { it.intent.original == row.owner && it.phase == OriginalImportPhase.Added }
    val membershipRevision by repository.membershipRevision.collectAsState()
    val addedVerified = remember(scope, added, membershipRevision) { added?.let {
        repository.association(scope, requireNotNull(it.commit).track, it.intent.operation) != null
    } == true }
    val closed = entries.any { it.intent.original.revision == row.revision && it.phase == OriginalImportPhase.Closed }
    val removalPending = entries.any { it.intent.original.revision == row.revision && it.phase == OriginalImportPhase.RemovalPending }
    val absent = entries.any { it.intent.original.revision == row.revision && it.phase == OriginalImportPhase.Removed }
    val supportedSize = row.revision.byteLength in 1..ORIGINAL_IMPORT_MAX_BYTES
    when {
        addedVerified -> Text("Added to Library · Original stays on this phone", style = SoundQ.typography.caption)
        added != null -> Text("Upload saved · Library membership not verified", style = SoundQ.typography.caption)
        pending != null -> {
            if (pending.intent.original == row.owner) OriginalImportRecovery(model, scope, latestCurrent)
            else Text("Check the pending import in Library before adding another file.", style = SoundQ.typography.caption)
        }
        closed -> Text("Upload closed. This upload cannot be retried.", style = SoundQ.typography.caption)
        removalPending -> Text(originalImportMessage(OriginalImportRepository.Action.RemovalUnconfirmed), style = SoundQ.typography.caption)
        absent -> Text(originalImportMessage(OriginalImportRepository.Action.Absent), style = SoundQ.typography.caption)
        repository.writeReady(scope) -> SongActionRow("Add to Library", {
            if (!busy && latestCurrent()) {
                val capture = captureOriginalImportDisplay(row.owner,
                    graph.phoneAudio.observed(graph.phoneAudio.reference(row)))
                confirmation = capture?.let { repository.choose(scope, it.source, it.text, it.overrideRevision) { latestCurrent() } }
                if (confirmation == null) message = "The selected original is not available for upload."
            }
        }, enabled = !busy && row.available && supportedSize, opensDestination = true)
    }
    if (!supportedSize) Text("This file is outside the supported upload size. You can still play it locally.", style = SoundQ.typography.caption)
    message?.let { Text(it, style = SoundQ.typography.caption) }
    confirmation?.let { choice ->
        val destination = choice.intent.destination
        AlertDialog(
            onDismissRequest = { confirmation = null }, shape = RectangleShape, containerColor = SoundQ.colors.sheet,
            title = { Text("Add to Library?", style = SoundQ.typography.title) },
            text = { Column(Modifier.verticalScroll(rememberScrollState())) {
                Text("Upload this audio file and the track details below to your private Library. It won’t be published or shared.")
                Text("Server: ${destination.endpoint}")
                Text("Account: ${destination.account}")
                Text("File: ${row.metadata.filename}")
                Text("Title: ${choice.intent.display.title}")
                Text("Artist: ${choice.intent.display.artist.ifBlank { "Not set" }}")
                Text("Album: ${choice.intent.display.album.ifBlank { "Not set" }}")
                Text("Artwork you applied in SoundQ is not included in this upload. Artwork embedded in the original file stays in the file.")
                Text("Your server will analyze the audio. This won’t look up metadata, prepare stems, or change what’s playing.")
            } },
            dismissButton = { TextButton({ confirmation = null }) { Text("Cancel") } },
            confirmButton = { TextButton({
                if (!busy && latestCurrent() && graph.session.remoteCurrent(scope)) {
                    confirmation = null; busy = true; message = "Uploading to your Library…"
                    graph.io.launch {
                        val result = try { repository.confirm(choice) }
                        catch (_: CancellationException) {
                            currentCoroutineContext().ensureActive()
                            OriginalImportRepository.Action.Retired
                        }
                        withContext(Dispatchers.Main) {
                            busy = false
                            if (graph.session.current(scope)) message = originalImportMessage(result)
                        }
                    }
                }
            }) { Text("Upload & add") } },
        )
    }
}

internal data class CapturedOriginalImportDisplay(
    val source: com.soundq.android.data.deviceaudio.ContentOwner,
    val text: ImportDisplay,
    val overrideRevision: Long?,
)

/** Capture the exact acknowledged selection, not a staged Apply or a provider-folded replacement. */
internal fun captureOriginalImportDisplay(
    selected: com.soundq.android.data.deviceaudio.ContentOwner,
    observed: DeviceAudio?,
): CapturedOriginalImportDisplay? {
    val row = observed?.takeIf { it.owner == selected } ?: return null
    return runCatching {
        CapturedOriginalImportDisplay(row.owner,
            ImportDisplay(row.displayTitle.trim(), row.displayArtist.orEmpty().trim(), row.displayAlbum.orEmpty().trim()),
            row.displayOverride?.revision)
    }.getOrNull()
}

/** Recovery remains reachable even when the selected original went missing or the sheet closed. */
@Composable internal fun OriginalImportRecovery(model: ProductViewModel, scope: AccountScope?, current: () -> Boolean) {
    val graph = model.graph
    val repository = graph.originalImports
    val snapshot by repository.state.collectAsState()
    val work by repository.work.collectAsState()
    if (scope == null || !snapshot.ready || !repository.ready(scope)) return
    val pending = repository.entries(scope).singleOrNull { it.phase in activeImportPhases } ?: return
    val latestCurrent by rememberUpdatedState(current)
    val id = pending.intent.operation
    val activeWork = work[pending.intent.destination]
    var checking by remember(scope, id) { mutableStateOf(false) }
    var message by remember(scope, id) { mutableStateOf<String?>(null) }
    Column {
        Text(message ?: when {
            activeWork == OriginalImportRepository.Work.Upload -> "Uploading to your Library…"
            activeWork == OriginalImportRepository.Work.Check -> "Checking the same upload. No audio is being sent."
            pending.phase == OriginalImportPhase.ReadbackRequired -> "Upload acknowledged. Confirm its Library entry."
            else -> "Upload not confirmed. Your server may already have the file. You can still play the phone file."
        }, style = SoundQ.typography.caption)
        TextButton({
            if (!checking && activeWork == null && latestCurrent()) {
                checking = true; message = null
                graph.io.launch {
                    val result = repository.check(scope, id) { latestCurrent() }
                    withContext(Dispatchers.Main) {
                        if (latestCurrent() && graph.session.current(scope)) { checking = false; message = originalImportMessage(result) }
                    }
                }
            }
        }, enabled = !checking && activeWork == null) { Text(if (checking) "Checking upload…" else "Check status") }
    }
}

private fun originalImportMessage(action: OriginalImportRepository.Action): String = when (action) {
    OriginalImportRepository.Action.Added -> "Added to Library."
    OriginalImportRepository.Action.Unconfirmed -> "Add to Library isn’t confirmed. Check import status in Library."
    OriginalImportRepository.Action.ReadbackRequired -> "Upload acknowledged. Check import status to confirm the Library entry."
    OriginalImportRepository.Action.Closed -> "Upload closed. This upload cannot be retried."
    OriginalImportRepository.Action.RemovalUnconfirmed -> "Library removal isn’t confirmed. You can still play the original on this phone."
    OriginalImportRepository.Action.Absent -> "The server acknowledged the upload, but it isn’t in your Library. You can still play the original."
    OriginalImportRepository.Action.Refused -> "The server didn’t add this file. You can still play it locally."
    OriginalImportRepository.Action.Unavailable -> "The selected original changed or is unavailable. You can scan again in Local audio."
    OriginalImportRepository.Action.StorageUnavailable -> "Couldn’t save import status. No new attempt will start until this is resolved."
    OriginalImportRepository.Action.AlreadyInProgress -> "Another Add to Library is pending. Check its status in Library."
    OriginalImportRepository.Action.Retired -> "This import action is no longer current."
}
