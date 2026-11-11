package com.soundq.android.product.playlists

import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.text.input.TextFieldValue
import com.soundq.android.data.MutationOutcome
import com.soundq.android.data.playlists.*
import com.soundq.designsystem.*

/** Functional membership surface using stable primitives; final playlist visuals remain designer-owned. */
@Composable fun PlaylistMembershipSheet(state: PlaylistMembershipState, actions: MembershipPickerActions, onDismiss: () -> Unit) {
    var choice by remember(actions, state.outcome) { mutableStateOf<MembershipSubmit?>(null) }
    var creating by remember(actions,state.outcome) {mutableStateOf(false)}
    var name by remember(actions) {mutableStateOf(TextFieldValue(""))}
    var description by remember(actions) {mutableStateOf(TextFieldValue(""))}
    var cover by remember(actions) {mutableStateOf(TextFieldValue(""))}
    SoundQSheet("Add to playlist", onDismiss) {
        Text(actions.track.title, style = SoundQ.typography.title)
        when(state.outcome) {
            MutationOutcome.Pending -> SoundQFeedback(if(state.creationDraft!=null) "Creating playlist and adding track" else "Adding to playlist", FeedbackKind.Loading)
            MutationOutcome.Uncertain -> SoundQFeedback(if(state.creationBlocked) "Create not confirmed" else "Add not confirmed", FeedbackKind.Error,
                if(state.creationBlocked) "Check your playlists, then choose the exact playlist. Create will not be sent again." else "The track may have been added. Check this playlist; the request will not be sent again.")
            MutationOutcome.ReadbackFailed -> if(state.ack==null) SoundQFeedback("Playlist created; track not confirmed",FeedbackKind.Error,"Check the created playlist before continuing.")
            MutationOutcome.Refused -> SoundQFeedback("Add refused", FeedbackKind.Error, "No add was confirmed. Choose a playlist again to make a new request.")
            else -> Unit
        }
        state.ack?.let { ack ->
            SoundQFeedback(if(ack.added.isNotEmpty()) "Added to “${ack.playlist.name}”" else "Already in this playlist", FeedbackKind.Notice)
        }
        if(state.loading) SoundQFeedback(if(state.outcome == null) "Loading owned playlists" else "Checking playlist", FeedbackKind.Loading)
        state.error?.let {
            SoundQFeedback(if(state.ack != null) "Add acknowledged — readback failed" else "Could not read playlists", FeedbackKind.Error,
                "Read recovery never sends the add again.", if(state.outcome == null) "Retry playlists" else "Check playlist",
                if(state.outcome == null) actions::reload else actions::recover)
        }
        if(state.outcome != null && state.outcome != MutationOutcome.Pending && state.outcome != MutationOutcome.Refused && !state.loading && state.error == null) {
            SoundQButton("Check playlist", actions::recover, variant = SoundQButtonVariant.Secondary)
            if(state.reconciled) Text(if(state.outcome == MutationOutcome.Uncertain) "Playlist checked. The original add is still not confirmed." else "Playlist membership checked.")
        }
        if(state.canContinueCreated&&!state.loading) SoundQButton("Add track to created playlist",actions::continueCreated)
        if(state.outcome != null && state.outcome != MutationOutcome.Pending && !state.loading && (state.outcome !in listOf(MutationOutcome.Uncertain,MutationOutcome.ReadbackFailed) || state.reconciled)) {
            SoundQButton(if(state.outcome == MutationOutcome.Uncertain) "Choose a different playlist" else "Choose playlist again", { actions.startNew() }, variant = SoundQButtonVariant.Secondary)
        }
        if(state.outcome == null) {
            if(!state.creationBlocked) SoundQButton("Create new playlist",{creating=true;choice=null},enabled=!state.loading&&state.error==null,variant=SoundQButtonVariant.Secondary)
            if(creating) {
                SoundQEntryField(name,{name=it},"New playlist name")
                SoundQEntryField(description,{description=it},"New playlist description")
                SoundQEntryField(cover,{cover=it},"New playlist cover URL")
                SoundQButton("Create and add track",{if(name.text.isNotBlank())actions.create(PlaylistDraft(name.text,description.text,cover.text))},enabled=name.text.isNotBlank()&&!state.loading&&state.error==null)
                SoundQButton("Cancel new playlist",{creating=false},variant=SoundQButtonVariant.Quiet)
            }
            if(!state.loading && state.error == null && state.total == 0) SoundQFeedback("No owned playlists", FeedbackKind.Empty)
            state.rows.forEach { row ->
                SoundQRow(row.name, "${row.trackCount} tracks", choice?.row === row, { choice = actions.select(row) },
                    enabled = !state.loading && state.error == null && state.excludedTarget != row.id,
                    leading = { SoundQIcon(SoundQIcon.List, null) })
            }
            if(!state.loading && state.total?.let {state.rows.size < it} == true) SoundQButton("Load more playlists", actions::more, variant = SoundQButtonVariant.Secondary)
            choice?.let { captured -> SoundQButton("Add track to “${captured.row.name}”", { actions.submit(captured) }, enabled = !state.loading && state.error == null) }
        }
    }
}
