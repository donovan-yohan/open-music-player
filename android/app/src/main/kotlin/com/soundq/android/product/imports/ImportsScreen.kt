package com.soundq.android.product.imports

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.input.*
import androidx.compose.ui.unit.dp
import com.soundq.android.data.imports.*
import com.soundq.designsystem.*

// Snapshot of the mounted caller, not the mutable framework click node.
internal data class ImportSubmitBinding(val editor:TextFieldValue,val draft:ImportDraft,val submit:()->Unit)
internal val ImportSubmitBindingKey=SemanticsPropertyKey<ImportSubmitBinding>("ImportSubmitBinding")

/** Product composition only. All imports go to the server Library, not device storage. */
@Composable fun ImportsScreen(state:ImportsState,onEdit:(String)->Unit,onSubmit:()->Unit,onCheck:()->Unit,onRecent:()->Unit,onSelect:(ImportJob)->Unit,onAnother:()->Unit,onOpenLibrary:()->Unit,onClose:()->Unit,onAccount:()->Unit,onRecoverSource:(com.soundq.android.data.discovery.SourceImportReceipt)->Unit={},onRetrySource:(com.soundq.android.data.discovery.SourceImportReceipt)->Unit={},onRecoverDurable:(com.soundq.android.data.acquisition.IntakeReceipt)->Unit={},onRetryDurable:(com.soundq.android.data.acquisition.IntakeReceipt)->Unit={},onOpenPlaylist:((ImportPlaylistConfirmation)->Unit)?=null) {
    val focus=LocalFocusManager.current
    var editor by remember {mutableStateOf(TextFieldValue(state.draft.text))}
    var details by remember(state.draft) {mutableStateOf<String?>(null)}
    LaunchedEffect(state.draft) {if(editor.text!=state.draft.text)editor=TextFieldValue(state.draft.text)}
    LazyColumn(Modifier.fillMaxWidth(),contentPadding=PaddingValues(0.dp)) {
        importBand {Row {
            Text("Imports",Modifier.weight(1f).semantics {heading()},style=SoundQ.typography.heading)
            SoundQIconButton(SoundQIcon.Settings,"Account and settings",onAccount,outlined=false)
            SoundQIconButton(SoundQIcon.Close,"Close Imports",onClose,outlined=false)
        }}
        state.durableReceipt?.let {receipt->importBand {
            Text(if(receipt.phase in setOf("pending","uncertain"))"Import not confirmed" else "Saved import",style=SoundQ.typography.title)
            SoundQButton("Check import",{onRecoverDurable(receipt)},enabled=!state.pending&&!state.loading,variant=SoundQButtonVariant.Secondary)
            if(receipt.decisionId!=null&&receipt.job==null)SoundQButton("Retry saved source publication",{onRetryDurable(receipt)},enabled=!state.pending&&!state.loading)
            SoundQIconButton(SoundQIcon.Info,"Import details",{details="Request ${receipt.operation}\n${receipt.kind} · ${receipt.phase}\n${receipt.job.orEmpty()}\n${receipt.decisionId.orEmpty()}"},outlined=false)
        }}
        if(state.sourceReceipt!=null)importBand {com.soundq.android.product.discovery.SourceImportContinuation(state,onRecoverSource,onRetrySource,onAnother)}
        if(state.sourceReceipt==null)importBand {
            Text("Import from link",style=SoundQ.typography.title)
            SoundQEntryField(editor,{value->val changed=value.text!=editor.text;editor=value;if(changed)onEdit(value.text)},"Source URL",enabled=!state.consumed,
                error=if(state.invalidLink)"Use a supported HTTPS YouTube or SoundCloud link without sign-in details." else null,
                keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Uri,imeAction=ImeAction.Done))
            // Explicit submission commits the visible native composition. Focus changes do not
            // replace the repository draft or allow a second submission of an uncertain request.
            val submit:()->Unit={editor=editor.copy(composition=null);focus.clearFocus();onSubmit()}
            SoundQButton("Import",submit,modifier=Modifier.semantics {this[ImportSubmitBindingKey]=ImportSubmitBinding(editor,state.draft,submit)},enabled=!state.consumed&&!state.pending)
        }
        importBand {
            if(state.pending)SoundQFeedback("Submitting import",FeedbackKind.Loading)
            val selected=state.selected
            val id=selected?.id ?: state.acknowledgement?.id
            val status=selected?.status ?: state.acknowledgement?.status
            if(id!=null) {
                Text(importStatus(status),style=SoundQ.typography.title)
                selected?.let {Text("${it.progress}%",style=SoundQ.typography.mono)}
                Row {
                    SoundQButton("Check import",onCheck,enabled=!state.pending&&!state.loading,variant=SoundQButtonVariant.Secondary)
                    SoundQIconButton(SoundQIcon.Info,"Import details",{details="${id.value}\n${status?.wire.orEmpty()}\n${selected?.track?.let {"Library track ${it.value}"}.orEmpty()}"},outlined=false)
                }
                if(selected?.status==ImportStatus.Complete && selected.track!=null)SoundQButton("Open in Library",onOpenLibrary,enabled=!state.loading)
            }
            state.playlistConfirmation?.let {confirmation->
                Text(when(confirmation.phase) {
                    ImportPlaylistPhase.AwaitingImport->"Waiting for import"
                    ImportPlaylistPhase.AwaitingLibrary->"Checking Library addition"
                    ImportPlaylistPhase.AwaitingMembership->"Playlist addition not confirmed"
                    ImportPlaylistPhase.Confirmed->"Added to selected playlist"
                })
                if(confirmation.phase==ImportPlaylistPhase.Confirmed&&onOpenPlaylist!=null)SoundQButton("Open playlist",{onOpenPlaylist(confirmation)},enabled=!state.loading&&!state.pending,variant=SoundQButtonVariant.Secondary)
            }
            if(state.loading)SoundQFeedback("Checking import",FeedbackKind.Loading)
            state.error?.let {SoundQFeedback(if(state.consumed&&id==null)"Import not confirmed" else "Could not update import",FeedbackKind.Error,it.message,"Recent imports",onRecent)}
            if(state.sourceReceipt==null&&state.consumed&&!state.pending)SoundQButton("Another link",onAnother,variant=SoundQButtonVariant.Secondary)
        }
        importBand {Row {
            Text("Recent imports",Modifier.weight(1f),style=SoundQ.typography.title)
            SoundQIconButton(SoundQIcon.Retry,"Refresh recent imports",onRecent,enabled=!state.pending&&!state.loading,outlined=false)
        }}
        items(state.recent,key={it.id.value}) {job ->
            SoundQRow(if(job.provider=="youtube")"YouTube import" else "SoundCloud import","${importStatus(job.status)} · ${job.progress}%",state.selected===job,{onSelect(job)})
        }
    }
    details?.let {captured->SoundQSheet("Import details",{details=null}) {SelectionContainer {Text(captured,style=SoundQ.typography.mono)}}}
}

private fun LazyListScope.importBand(content:@Composable ColumnScope.()->Unit)=item {
    Column(Modifier.fillMaxWidth().padding(SoundQ.spacing.gutter),verticalArrangement=Arrangement.spacedBy(SoundQ.spacing.small),content=content)
}
internal fun importStatus(status:ImportStatus?)=when(status) {
    ImportStatus.Complete->"Import finished"
    ImportStatus.Failed->"Import failed"
    ImportStatus.Downloading->"Fetching source"
    ImportStatus.Processing->"Processing audio"
    ImportStatus.Uploading->"Saving to Library"
    else->"Queued"
}
