package com.soundq.android.product.playlists

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import com.soundq.android.data.MutationOutcome
import com.soundq.android.data.playlists.*
import com.soundq.designsystem.*

// Immutable business bindings for lifecycle checks; framework OnClick belongs to its mutable node.
internal val PlaylistCreateBinding=SemanticsPropertyKey<()->Unit>("PlaylistCreateBinding")
internal val PlaylistReloadBinding=SemanticsPropertyKey<()->Unit>("PlaylistReloadBinding")

/** Forms retain their draft across Cancel/reopen, but never across destination/account replacement. */
@Composable fun PlaylistsScreen(state: PlaylistState, capture: PlaylistListCapture?, onCreate: (PlaylistListCapture, PlaylistDraft) -> Unit, onReload: () -> Unit, onStartNew: (PlaylistDraft) -> Unit, onOpen: (PlaylistListCapture, PlaylistSummary) -> Unit, management: @Composable () -> Unit = {}, onRefine: (PlaylistQuery) -> Unit = {}) {
    val scope = capture?.scope
    val endpoint = scope?.owner?.endpoint?.identity.orEmpty()
    val account = scope?.accountId.orEmpty()
    val formSaver = remember(endpoint, account) { Saver<PlaylistCreateForm, Any>(
        save = { saveCreateForm(endpoint, account, it) },
        restore = { value -> (value as? List<*>)?.let { restoreCreateForm(endpoint, account, it) } }) }
    var form by rememberSaveable(endpoint, account, stateSaver = formSaver) { mutableStateOf(PlaylistCreateForm()) }
    val name = form.name
    val description = form.description
    val creating = form.open
    var search by remember(scope, state.query.text) { mutableStateOf(state.query.text) }
    var sorting by remember(scope) { mutableStateOf(false) }
    if (sorting) SoundQSheet("Sort playlists", { sorting = false }) {
        Column {
            PlaylistSort.entries.forEach { sort ->
                SoundQRow(sort.label, "", state.query.sort == sort, {
                    onRefine(state.query.copy(sort = sort, ascending = sort == PlaylistSort.Name)); sorting = false
                })
            }
            SoundQRow("Ascending", "", state.query.ascending, { onRefine(state.query.copy(ascending = true)); sorting = false })
            SoundQRow("Descending", "", !state.query.ascending, { onRefine(state.query.copy(ascending = false)); sorting = false })
        }
    }
    val pending = state.mutation?.outcome == MutationOutcome.Pending
    val draft = name.takeIf { it.isNotBlank() }?.let { PlaylistDraft(it, description) }
    if (creating) {
        SoundQSheet("Create playlist", { form = form.copy(open = false) }) {
            SoundQTextField(name, { form = form.copy(name = it) }, "Playlist name")
            SoundQTextField(description, { form = form.copy(description = it) }, "Playlist description")
            Text("Private playlist", style = SoundQ.typography.caption)
            val create:()->Unit = {if (capture != null && draft != null && state.canCreate(draft)) onCreate(capture, draft)}
            SoundQButton(if (pending) "Creating playlist" else "Create playlist", create,
                modifier=Modifier.semantics {this[PlaylistCreateBinding]=create},
                enabled = capture != null && draft?.let(state::canCreate) == true)
            if (state.mutation?.outcome == MutationOutcome.Uncertain && state.reconciled) {
                SoundQButton("Start a different playlist", { draft?.let(onStartNew) },
                    enabled = capture != null && draft?.let(state::canStartNew) == true, variant = SoundQButtonVariant.Secondary)
            }
            PlaylistCreateFeedback(state, onReload)
            if (state.mutation?.outcome in setOf(MutationOutcome.Uncertain, MutationOutcome.ReadbackFailed)) {
                SoundQButton("Reload playlists", onReload, modifier=Modifier.semantics {this[PlaylistReloadBinding]=onReload},
                    enabled = !state.loading && !pending, variant = SoundQButtonVariant.Secondary)
            }
            if (state.mutation == null) SoundQButton("Cancel", { form = form.copy(open = false) }, variant = SoundQButtonVariant.Quiet)
            else SoundQButton("Close", { form = form.copy(open = false) }, variant = SoundQButtonVariant.Quiet)
        }
    }
    LazyColumn(Modifier.fillMaxSize()) {
        item {
            Column {
                Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Text("Playlists", style = SoundQ.typography.heading,
                        modifier = Modifier.weight(1f).padding(horizontal = SoundQ.spacing.gutter).semantics { heading() })
                    SoundQIconButton(SoundQIcon.Retry, "Reload playlists", onReload,
                        modifier=Modifier.size(48.dp).semantics {this[PlaylistReloadBinding]=onReload}, enabled = !pending && !state.loading, outlined = false)
                    SoundQIconButton(SoundQIcon.Plus, "Create playlist", { form = form.copy(open = true) },
                        modifier = Modifier.size(48.dp), enabled = capture != null, outlined = false)
                }
                SoundQDivider()
            }
        }
        item {
            Row(Modifier.fillMaxWidth().padding(horizontal = SoundQ.spacing.gutter, vertical = SoundQ.spacing.small),
                verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                SoundQTextField(search, { search = it }, "Search playlists", Modifier.weight(1f), enabled = !pending)
                SoundQIconButton(SoundQIcon.Search, "Search playlists", { onRefine(state.query.copy(text = search)) },
                    Modifier.size(48.dp), enabled = capture != null && !pending, outlined = false)
                SoundQIconButton(SoundQIcon.Sort, "Sort playlists", { sorting = true }, Modifier.size(48.dp),
                    enabled = capture != null && !pending, outlined = false)
            }
        }
        item { Column(Modifier.padding(horizontal = SoundQ.spacing.gutter)) { management() } }
        if (!creating && state.mutation != null) item {
            Column(Modifier.padding(SoundQ.spacing.gutter)) { PlaylistCreateFeedback(state, onReload) }
        }
        if (state.loading) item { Box(Modifier.padding(SoundQ.spacing.gutter)) { SoundQFeedback("Loading playlists", FeedbackKind.Loading) } }
        state.error?.let { error -> item { Box(Modifier.padding(SoundQ.spacing.gutter)) { SoundQFeedback("Playlists unavailable", FeedbackKind.Error, error.message, "Reload playlists", onReload) } } }
        if (!state.loading && state.error == null && state.total == 0) item { Box(Modifier.padding(SoundQ.spacing.gutter)) { SoundQFeedback("No playlists yet", FeedbackKind.Empty) } }
        state.total?.let { total -> item { Text("$total playlists", style = SoundQ.typography.mono, modifier = Modifier.padding(SoundQ.spacing.gutter)) } }
        items(state.rows, key = { it.id.value }) { playlist ->
            val open = { capture?.let { onOpen(it, playlist) }; Unit }
            // No authorized collection-image loader is supplied here: use the shared square fallback.
            SoundQMediaRow(playlist.name, "${playlist.trackCount} tracks · ${if (playlist.draft.isPublic) "Public" else "Private"}", false,
                open, open, enabled = capture != null && !state.loading && state.error == null)
        }
    }
}

@Composable private fun PlaylistCreateFeedback(state: PlaylistState, onReload: () -> Unit) {
    state.mutation?.let { mutation ->
        when (mutation.outcome) {
            MutationOutcome.Pending -> SoundQFeedback("Creating playlist", FeedbackKind.Loading)
            MutationOutcome.Confirmed -> SoundQFeedback("Playlist created", FeedbackKind.Notice, state.created?.name)
            MutationOutcome.ReadbackFailed -> SoundQFeedback("Playlist created; list could not reload", FeedbackKind.Error, "Do not create it again. Reload to view your playlist.", "Reload playlists", onReload)
            MutationOutcome.Uncertain -> SoundQFeedback("Creation not confirmed", FeedbackKind.Error, if (state.reconciled) "Previous creation remains unconfirmed. Enter different details, then choose Start a different playlist." else "Reload before starting a different playlist. This request will not be repeated.", "Reload playlists", onReload)
            MutationOutcome.Refused -> SoundQFeedback("Playlist was not created", FeedbackKind.Error, "Check the name and try again.")
        }
    }
}
