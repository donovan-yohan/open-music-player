package com.soundq.android.product.playlists

import androidx.compose.material3.Checkbox
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import com.soundq.android.data.TrackId
import com.soundq.android.data.playlists.*
import com.soundq.designsystem.*

/** The sheet edits only a captured selection. The repository owns every mutation. */
@Composable fun PlaylistBatchSheet(target: PlaylistManagementTarget, actions: PlaylistManagementActions, onDismiss: () -> Unit) {
    var selected by remember(target) {mutableStateOf(setOf<TrackId>())}
    var confirmation by remember(target) {mutableStateOf<PlaylistBatchConfirmation?>(null)}
    val live=actions.capture()?.let {it.detail===target.detail} == true
    fun toggle(id: TrackId) {selected=if(id in selected)selected-id else if(selected.size<100)selected+id else selected}
    val pending=confirmation
    if(pending!=null) {
        fun cancel() {actions.cancelRemove(pending);confirmation=null}
        SoundQSheet("Remove selected tracks?",::cancel) {
            Text("Remove ${pending.count} tracks from “${pending.name}”? Music stays in your Library and listening queue.")
            SoundQButton("Cancel",::cancel,variant=SoundQButtonVariant.Secondary)
            SoundQButton("Remove selected tracks",{actions.confirmRemove(pending);onDismiss()})
        }
    } else SoundQSheet("Select tracks",onDismiss) {
        Text("${selected.size} selected · up to 100 per removal",style=SoundQ.typography.caption)
        SoundQButton("Remove selected tracks",{actions.askRemove(target,selected.toList())?.let {confirmation=it}},enabled=live&&selected.isNotEmpty())
        SoundQButton("Cancel",onDismiss,variant=SoundQButtonVariant.Quiet)
        target.detail.tracks.forEach {track->
            val enabled=live&&(track.id in selected||selected.size<100)
            SoundQRow(track.title,track.artist,track.id in selected,{toggle(track.id)},enabled=enabled,
                leading={SoundQIcon(SoundQIcon.List,null)},
                trailing={Checkbox(track.id in selected,{toggle(track.id)},enabled=enabled)})
        }
    }
}
