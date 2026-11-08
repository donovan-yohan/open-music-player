package com.soundq.android.product.playlists

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.material3.Checkbox
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.TextFieldValue
import com.soundq.android.data.MutationOutcome
import com.soundq.android.data.TrackId
import com.soundq.android.data.playlists.*
import com.soundq.designsystem.*

/** Feature composition of canonical typed visual primitives; callbacks carry captured authority. */
@Composable fun PlaylistManagementFeedback(state: PlaylistManagementState, actions: PlaylistManagementActions) {
    val targetName = state.playlist?.name ?: return
    val title = when {
        state.loading -> "Checking $targetName"
        state.reconciled -> if(state.missing) "$targetName is no longer available" else "Playlist state refreshed"
        state.outcome == MutationOutcome.Pending -> "Saving $targetName"
        state.outcome == MutationOutcome.Uncertain -> "Change not confirmed: $targetName"
        state.outcome == MutationOutcome.ReadbackFailed -> if(state.kind==PlaylistManagementKind.Undo) "Undo incomplete: $targetName" else "Change saved; playlist could not be refreshed"
        state.outcome == MutationOutcome.Refused -> "Change refused: $targetName"
        state.kind == PlaylistManagementKind.Delete -> "Playlist deleted"
        state.kind in listOf(PlaylistManagementKind.Remove,PlaylistManagementKind.BatchRemove) -> "Removed from $targetName"
        state.kind == PlaylistManagementKind.Undo -> "Restored to $targetName"
        state.kind == PlaylistManagementKind.Add -> if(state.ack?.added?.isNotEmpty()==true) "Added to $targetName" else "Already in $targetName"
        else -> "Playlist updated"
    }
    val recovery = !state.reconciled && state.outcome in listOf(MutationOutcome.Uncertain,MutationOutcome.ReadbackFailed)
    val recover=actions.recoveryAction()
    SoundQFeedback(title,if(state.outcome in listOf(MutationOutcome.Uncertain,MutationOutcome.ReadbackFailed,MutationOutcome.Refused)) FeedbackKind.Error else FeedbackKind.Notice,
        detail=when {
            state.reconciled -> "Review the refreshed playlist before making another change."
            state.kind==PlaylistManagementKind.Delete && state.outcome==MutationOutcome.Confirmed -> "Your Library and listening queue are unchanged."
            state.kind==PlaylistManagementKind.Undo && recovery -> "The track may be restored without its original position. Reload the playlist to check."
            recovery -> "Reload $targetName to check whether the change was saved."
            else -> state.error?.message
        },action=if(recovery && !state.loading) "Reload playlist state" else null,onAction=if(recovery && !state.loading) recover else null)
    val undo=actions.captureUndo()
    if(undo!=null) SoundQButton("Undo removal",{actions.undo(undo)},variant=SoundQButtonVariant.Secondary)
}

@Composable fun PlaylistManagementMenu(target: PlaylistManagementTarget, actions: PlaylistManagementActions, onDismiss: () -> Unit, onRename: () -> Unit, onDelete: (PlaylistDeleteConfirmation) -> Unit, onSelect: () -> Unit = {}) {
    SoundQSheet("Playlist actions",onDismiss) {
        SoundQRow("Rename playlist",target.playlist.name,false,onRename,leading={SoundQIcon(SoundQIcon.Info,null)})
        SoundQRow("Select tracks","Remove multiple playlist members",false,onSelect,leading={SoundQIcon(SoundQIcon.List,null)})
        SoundQRow("Delete playlist","Music stays in your Library",false,{actions.askDelete(target)?.let(onDelete)},leading={SoundQIcon(SoundQIcon.Trash,null)})
    }
}
@Composable fun PlaylistMemberMenu(target: PlaylistManagementTarget, track: TrackId, title: String, actions: PlaylistManagementActions, onDismiss: () -> Unit) {
    SoundQSheet("Playlist track",onDismiss) {
        Text(title,style=SoundQ.typography.title)
        SoundQRow("Remove from playlist",target.playlist.name,false,{actions.remove(target,track);onDismiss()},leading={SoundQIcon(SoundQIcon.Trash,null)})
    }
}
@Composable fun PlaylistRenameSheet(target: PlaylistManagementTarget, state: PlaylistManagementState, actions: PlaylistManagementActions, onDismiss: () -> Unit) {
    var name by remember(target) {mutableStateOf(TextFieldValue(target.playlist.name))}
    var description by remember(target) {mutableStateOf(TextFieldValue(target.playlist.draft.description))}
    var cover by remember(target) {mutableStateOf(TextFieldValue(target.playlist.draft.coverUrl))}
    var public by remember(target) {mutableStateOf(target.playlist.draft.isPublic)}
    var validation by remember(target) {mutableStateOf<String?>(null)}
    val enabled=state.outcome!=MutationOutcome.Pending && !state.loading && (state.reconciled || state.outcome !in listOf(MutationOutcome.Uncertain,MutationOutcome.ReadbackFailed))
    val submitTarget=actions.capture()?.takeIf {it.detail===target.detail}
    SoundQSheet("Edit playlist",onDismiss) {
        // Recovery precedes the locked field so it remains reachable at enlarged text.
        if(state.outcome!=null) PlaylistManagementFeedback(state,actions)
        SoundQEntryField(name,{name=it;validation=null},"Playlist name",enabled=enabled,error=validation)
        SoundQEntryField(description,{description=it},"Description",enabled=enabled)
        SoundQEntryField(cover,{cover=it},"Cover URL",enabled=enabled)
        SoundQRow("Public playlist",if(public)"Public" else "Private",public,{public=!public},enabled=enabled,
            trailing={Checkbox(public,{public=it},enabled=enabled)})
        val draft=if(name.text.isNotBlank()) PlaylistDraft(name.text,description.text,cover.text,public) else null
        SoundQButton("Save changes",{if(draft==null)validation="Enter a playlist name." else submitTarget?.let {actions.update(it,draft)}},enabled=enabled && submitTarget!=null && draft!=target.playlist.draft)
        SoundQButton("Cancel",onDismiss,variant=SoundQButtonVariant.Quiet)
    }
}
@Composable fun PlaylistDeleteSheet(value: PlaylistDeleteConfirmation, actions: PlaylistManagementActions, onDismiss: () -> Unit) {
    fun cancel() {actions.cancelDelete(value);onDismiss()}
    SoundQSheet("Delete playlist?",::cancel) {
        Text("Delete “${value.name}”? This deletes the playlist, not the music in your Library. Your listening queue is unchanged.")
        SoundQButton("Cancel",::cancel,variant=SoundQButtonVariant.Secondary)
        SoundQRow("Delete playlist","This cannot be undone",false,{actions.confirmDelete(value);onDismiss()},leading={SoundQIcon(SoundQIcon.Trash,null)})
    }
}
