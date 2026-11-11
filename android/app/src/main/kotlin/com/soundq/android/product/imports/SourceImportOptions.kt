package com.soundq.android.product.imports

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.soundq.android.data.imports.ImportView
import com.soundq.android.product.ProductViewModel
import com.soundq.designsystem.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** Optional destination for one captured source. Closing does not submit anything. */
@Composable fun SourceImportOptions(model:ProductViewModel,view:ImportView?) {
    val repository=model.graph.imports
    val state by repository.state.collectAsStateWithLifecycle()
    val plan=state.sourcePlan ?: return
    val owner=view ?: return
    val work=rememberCoroutineScope()
    SoundQSheet("Import source",{repository.cancelSourcePlan(owner,plan)}) {
        Text(plan.choice.candidate.title,style=SoundQ.typography.title)
        if(plan.choice.candidate.artist.isNotBlank())Text(plan.choice.candidate.artist)
        Text(plan.choice.candidate.provider.label)
        SelectionContainer {Text(plan.choice.candidate.source.url,style=SoundQ.typography.mono)}
        Text("Add to playlist",style=SoundQ.typography.title)
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            Column(Modifier.requiredWidth(maxWidth+SoundQ.spacing.gutter*2).align(Alignment.Center)) {
                SoundQRow("Library only","No playlist",state.chosenPlaylist==null,{repository.chooseSourcePlaylist(owner,plan,null)},enabled=!state.loading)
                state.playlistChoices.forEach {row->
                    key(row.id) {SoundQRow(row.name,"${row.trackCount} songs",state.chosenPlaylist===row,{repository.chooseSourcePlaylist(owner,plan,row)},enabled=!state.loading)}
                }
            }
        }
        if(state.playlistTotal==null||state.playlistChoices.size<state.playlistTotal!!)SoundQButton(if(state.playlistTotal==null)"Choose playlist" else "More playlists",{work.launch(Dispatchers.IO){repository.loadSourcePlaylists(owner,plan,state.playlistTotal!=null)}},enabled=!state.loading,variant=SoundQButtonVariant.Secondary)
        if(state.loading)SoundQFeedback("Loading playlists",FeedbackKind.Loading)
        state.error?.let {SoundQFeedback("Could not load playlists",FeedbackKind.Error,it.message,action="Try again",onAction={work.launch(Dispatchers.IO){repository.loadSourcePlaylists(owner,plan)}})}
        SoundQButton(if(state.chosenPlaylist==null)"Import to Library" else "Import to selected playlist",{model.confirmSourceImport(owner,plan)},enabled=!state.loading&&!state.pending)
    }
}
