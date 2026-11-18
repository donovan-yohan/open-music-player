package com.soundq.android.product.playlists
import androidx.compose.runtime.Composable
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import com.soundq.android.data.playlists.PlaylistSourceSyncState
import com.soundq.designsystem.*

@Composable fun PlaylistSourceSyncControls(state:PlaylistSourceSyncState,onSync:()->Unit,onRead:()->Unit) {
 val source=state.observation
 if(source==null){if(state.error){Text("Could not read source status.",style=SoundQ.typography.caption);SoundQButton("Read sync status",onRead,enabled=!state.busy,variant=SoundQButtonVariant.Secondary)};return}
 Column {
  if(source.eligible)SoundQButton(if(state.uncertain)"Retry sync request"else "Sync source",onSync,enabled=!state.busy&&source.operation?.let {it.active&&!it.accepted}!=true,variant=SoundQButtonVariant.Secondary)
  else Text("Source unavailable—relink required",style=SoundQ.typography.caption)
  source.operation?.let {op->
   val text=when {
    op.status=="superseded"->"A newer manual sync replaced this operation. Read current source status."
    !op.accepted&&op.status=="failed"->"Source could not be synchronized. This operation did not change playlist membership."
    !op.accepted->"Reading source…"
    op.active->"Source membership updated: ${op.added} added, ${op.removed} removed. ${op.pending} acquisitions pending."
    op.failed>0->"Source membership updated: ${op.added} added, ${op.removed} removed; ${op.failed} entries unavailable or failed."
    else->"Source membership synchronized: ${op.added} added, ${op.removed} removed"+(if(op.reordered)"; order updated."else ".")
   }
   Text(text,style=SoundQ.typography.caption)
  }
  if(state.error||state.readbackFailed||state.uncertain||source.operation?.status=="superseded"){
   if(state.error||state.readbackFailed||state.uncertain)Text(if(state.uncertain)"Sync acknowledgement is unknown. Read its status or retry the same request."else "Could not read synchronized playlist state. Read status to recover.",style=SoundQ.typography.caption)
   SoundQButton("Read sync status",onRead,enabled=!state.busy,variant=SoundQButtonVariant.Secondary)
  }
 }
}
