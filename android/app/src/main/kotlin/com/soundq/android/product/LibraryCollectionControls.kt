package com.soundq.android.product

import androidx.compose.foundation.layout.*
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import com.soundq.android.data.LibraryState
import com.soundq.designsystem.*

/** Fixed chrome above the same flat Library media rows. */
@Composable internal fun LibraryCollectionControls(state:LibraryState,onClear:()->Unit,onPlay:()->Unit,onShuffle:()->Unit) {
    val collection=state.query.collection
    if(collection!=null||state.query.liked) {
        Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {
            Column(Modifier.weight(1f).padding(horizontal=SoundQ.spacing.gutter)) {
                Text(if(collection?.album!=null)collection.album else collection?.artist ?: "Liked",style=SoundQ.typography.title)
                if(collection?.artist!=null&&collection.album!=null)Text(collection.artist,style=SoundQ.typography.caption,color=SoundQ.colors.muted)
            }
            val enabled=!state.loading&&state.error==null&&!state.collectionLoading&&state.rows.isNotEmpty()
            SoundQIconButton(SoundQIcon.Play,"Play collection",onPlay,enabled=enabled,outlined=false)
            SoundQIconButton(SoundQPlayerIcon.Shuffle,"Shuffle collection",onShuffle,enabled=enabled,outlined=false)
            if(collection!=null)SoundQIconButton(SoundQIcon.Close,"Clear collection",onClear,outlined=false)
        }
        HorizontalDivider(color=SoundQ.colors.border)
    }
    if(state.sortError)SoundQFeedback("Sort could not be saved",FeedbackKind.Error,"Previous sort retained. Apply refinement to retry.")
    if(state.collectionLoading)SoundQFeedback("Loading collection",FeedbackKind.Loading)
    state.collectionError?.let {SoundQFeedback(it,FeedbackKind.Error)}
}
