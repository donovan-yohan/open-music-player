package com.soundq.android.product.playlists

import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.text.input.TextFieldValue
import com.soundq.android.data.MutationOutcome
import com.soundq.android.data.playlists.*
import com.soundq.designsystem.*

@Composable fun QueuePlaylistSheet(state:QueuePlaylistState,actions:QueuePlaylistActions,onDismiss:()->Unit) {
    var choice by remember(actions,state.snapshot,state.outcome) {mutableStateOf<QueuePlaylistTarget?>(null)}
    var name by remember(actions) {mutableStateOf(TextFieldValue(state.draft?.name.orEmpty()))}
    var description by remember(actions) {mutableStateOf(TextFieldValue(state.draft?.description.orEmpty()))}
    SoundQSheet("Save queue as playlist",onDismiss) {
        Text("Save the captured queue without changing what is playing.",style=SoundQ.typography.caption)
        state.snapshot?.let {Text("${it.occurrences.size} queue entries · ${it.tracks.size} supported entries · ${it.omittedOccurrences} unsupported omitted · ${it.duplicateOccurrences} repeats sent",style=SoundQ.typography.mono)}
        when(state.outcome) {
            MutationOutcome.Pending->SoundQFeedback("Saving captured queue",FeedbackKind.Loading,"Closing does not cancel a sent request.")
            MutationOutcome.Uncertain->SoundQFeedback("Save not confirmed",FeedbackKind.Error,"The request may have completed. It will not be sent again.")
            MutationOutcome.ReadbackFailed->SoundQFeedback("Playlist created — queue save incomplete",FeedbackKind.Error,"“${state.created?.name.orEmpty()}” was created. Adding tracks was not confirmed. Check before starting a new save.")
            MutationOutcome.Refused->SoundQFeedback("Save refused",FeedbackKind.Error,"Choose the destination again to make a new request.")
            else->Unit
        }
        state.ack?.let {ack->SoundQFeedback("Saved to “${ack.playlist.name}”",FeedbackKind.Notice,"${ack.added.size} added · ${ack.skipped.size} already present")}
        if(state.loading)SoundQFeedback("Reading playlists",FeedbackKind.Loading)
        if(state.error!=null && state.outcome in listOf(MutationOutcome.Uncertain,MutationOutcome.ReadbackFailed))Text(state.error.message,style=SoundQ.typography.caption)
        if(state.error!=null && state.outcome==null)SoundQFeedback("Could not load private playlists",FeedbackKind.Error,"Unsupported entries are omitted. The captured queue is unchanged.","Retry playlists",actions::reload)
        if(state.outcome in listOf(MutationOutcome.Uncertain,MutationOutcome.ReadbackFailed)&&!state.reconciled) {
            val recover=actions.recoveryAction()
            SoundQButton("Check saved playlist state",{recover?.invoke()},enabled=recover!=null&&!state.loading,variant=SoundQButtonVariant.Secondary)
        }
        if(state.reconciled)Text(if(state.target==null)"Playlists checked. A missing create acknowledgement cannot be matched safely by name. Check Playlists before starting again." else "Playlist checked. The original save is still not acknowledged.")
        if(state.snapshot!=null && (state.outcome==null || state.outcome==MutationOutcome.Refused)) {
            state.rows.filter {!it.draft.isPublic}.forEach {row->SoundQRow(row.name,"${row.trackCount} tracks",choice?.playlist===row,{choice=actions.select(row)},enabled=!state.loading,leading={SoundQIcon(SoundQIcon.List,null)})}
            if(state.total==0)SoundQFeedback("No playlists yet",FeedbackKind.Empty,"Create a private playlist below.")
            if(!state.loading&&state.total?.let {state.rows.size<it}==true)SoundQButton("Load more playlists",actions::more,variant=SoundQButtonVariant.Secondary)
            choice?.let {target->SoundQButton("Save to “${target.playlist!!.name}”",{actions.save(target)},enabled=!state.loading)}
            SoundQDivider()
            SoundQEntryField(name,{name=it;choice=null},"Playlist name",enabled=!state.loading)
            SoundQEntryField(description,{description=it;choice=null},"Description",enabled=!state.loading)
            Text("New playlists are private.",style=SoundQ.typography.caption)
            SoundQButton("Create playlist and save queue",{
                if(name.text.isNotBlank())actions.newTarget(PlaylistDraft(name.text,description.text))?.let(actions::save)
            },enabled=name.text.isNotBlank()&&!state.loading)
        }
        if(state.outcome==MutationOutcome.Confirmed||state.reconciled)SoundQButton("Start a new queue save",{
            if(actions.startNew()&&actions.capture()){name=TextFieldValue();description=TextFieldValue();actions.reload()}
        },variant=SoundQButtonVariant.Secondary)
    }
}
@Composable fun PlaylistOrderFeedback(state:PlaylistOrderState,actions:PlaylistOrderActions) {
    when(state.outcome) {
        MutationOutcome.Pending->SoundQFeedback("Saving playlist order",FeedbackKind.Loading)
        MutationOutcome.Confirmed->SoundQFeedback("Playlist order saved",FeedbackKind.Notice)
        MutationOutcome.Refused->SoundQFeedback("Reorder refused",FeedbackKind.Error,"The acknowledged member order is unchanged. Try moving the track again.")
        MutationOutcome.Uncertain-> {
            SoundQFeedback("Order not confirmed for “${state.playlist?.name.orEmpty()}”",FeedbackKind.Error,"The prior order is retained until checked. Reorder will not be sent again.")
            if(state.loading)SoundQFeedback("Checking playlist order",FeedbackKind.Loading)
            else if(state.error!=null)Text(state.error.message,style=SoundQ.typography.caption)
            val read=actions.recoveryAction()
            if(!state.reconciled)SoundQButton("Check playlist order",{read?.invoke()},enabled=read!=null&&!state.loading,variant=SoundQButtonVariant.Secondary)
            else Text("Playlist checked. This is observed order, not a reorder acknowledgement.")
        }
        else->Unit
    }
}
