package com.soundq.android.product.discovery

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import com.soundq.android.data.discovery.*
import com.soundq.android.data.imports.ImportsState
import com.soundq.designsystem.*

/** Retained intake evidence; not a second repository or job projection. */
@Composable fun SourceImportContinuation(state:ImportsState,onCheck:(SourceImportReceipt)->Unit,onRetry:(SourceImportReceipt)->Unit,onAnother:()->Unit) {
    val receipt=state.sourceReceipt ?: return
    Text(receipt.choice.candidate.title,style=SoundQ.typography.title)
    val title=when(receipt.phase) {
        SourceImportPhase.SavingDecision->"Saving source choice"
        SourceImportPhase.Queueing->"Adding source to Imports"
        SourceImportPhase.DecisionUncertain->"Source choice not confirmed"
        SourceImportPhase.DecisionRefused->"Source choice unavailable"
        SourceImportPhase.QueueUncertain->"Import not confirmed"
        SourceImportPhase.QueueRefused->"Source choice saved"
        SourceImportPhase.ReadbackFailed->"Status could not be checked"
        SourceImportPhase.Accepted->"Import accepted"
    }
    val detail=when(receipt.phase) {
        SourceImportPhase.DecisionRefused->"Run a fresh search before choosing again."
        SourceImportPhase.Accepted->"A job was acknowledged. Check Imports for progress; no playback has started."
        SourceImportPhase.QueueRefused->"The saved decision is retained. Retry only the import step, without saving another choice."
        else->"This captured source stays locked until its outcome is known. Do not import it again."
    }
    SoundQFeedback(title,if(state.pending||state.loading)FeedbackKind.Loading else if(receipt.phase==SourceImportPhase.Accepted)FeedbackKind.Notice else FeedbackKind.Error,detail)
    if(!state.pending&&receipt.phase !in setOf(SourceImportPhase.Accepted,SourceImportPhase.DecisionRefused)) {
        SoundQButton("Check source status",{onCheck(receipt)},enabled=!state.loading,variant=SoundQButtonVariant.Secondary)
        if(receipt.decision!=null)SoundQButton("Retry saved import",{onRetry(receipt)},enabled=!state.loading,variant=SoundQButtonVariant.Secondary)
    }
    if(!state.pending&&receipt.phase in setOf(SourceImportPhase.Accepted,SourceImportPhase.DecisionRefused))SoundQButton("Another source",onAnother,variant=SoundQButtonVariant.Secondary)
}
