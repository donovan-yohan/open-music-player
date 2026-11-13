package com.soundq.android.product.trackdetails

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import kotlinx.coroutines.launch
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.*
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import com.soundq.android.data.*
import com.soundq.android.data.preferences.KeyNotation
import com.soundq.android.data.trackdetails.*
import com.soundq.designsystem.*

/** Presentation only. The captured repository claim remains the sole write authority. */
@Composable fun TrackDetailsSheet(state:TrackDetailsState,onAction:(TrackDetails,DetailsAction)->Unit,onReload:()->Unit,onDismiss:()->Unit,keyNotation:KeyNotation=KeyNotation.Camelot) {
    val editor=remember {DetailsEditor()}
    editor.observe(state)
    val fields=remember {List(3){FocusRequester()}}
    val bring=remember {List(3){BringIntoViewRequester()}}
    val scope=rememberCoroutineScope()
    var focused by remember {mutableIntStateOf(0)}
    var restoreFocus by remember {mutableIntStateOf(0)}
    val keyboard=LocalSoftwareKeyboardController.current
    val detail=state.detail
    val canWrite=detail!=null&&!state.loading&&state.error==null&&!state.missing&&state.outcome!=MutationOutcome.Pending&&!editor.saving&&(state.reconciled||state.outcome !in listOf(MutationOutcome.Uncertain,MutationOutcome.ReadbackFailed))
    fun navigate(destination:DismissDestination) {if(destination==DismissDestination.Closed)onDismiss() else {editor.page=DetailsPage.Read;editor.error=null;editor.invalidField=null}}
    fun request(destination:DismissDestination) {if(editor.requestDismiss(destination))navigate(destination)}
    fun dispatch(observed:TrackDetails,action:DetailsAction) {
        if(!canWrite||editor.saving)return
        if(state.detail!==observed||(action is DetailsAction.Analysis&&state.analysis!==action.observed)) {editor.error="Details changed. Review the current values before saving.";return}
        if(action is DetailsAction.Metadata||action is DetailsAction.Analysis)editor.submitted(action,observed,state.analysis)
        onAction(observed,action)
    }
    fun saveMetadata() {
        if(!canWrite||!editor.metadataDirty)return
        val currentDetail=detail
        val composing=editor.metadata.indexOfFirst {it.composition!=null}
        val tooLong=editor.metadata.indexOfFirst {it.text.codePointCount(0,it.text.length)>500}
        val invalid=if(composing>=0)composing else tooLong
        if(invalid>=0) {editor.invalidField=invalid;editor.error=if(composing>=0)"Finish composing before saving." else "Each field must contain 500 characters or fewer.";fields[invalid].requestFocus();return}
        editor.metadataAction()?.let {editor.error=null;editor.invalidField=null;dispatch(currentDetail,it);keyboard?.hide()}
    }
    val title=when(editor.page) {DetailsPage.Read->"Song details";DetailsPage.Metadata->"Edit metadata";DetailsPage.Analysis->"Correct analysis";DetailsPage.Matching->"Verification & matching"}
    SoundQSheet(title,onDismiss={request(DismissDestination.Closed)},dismissAdmission={
        if(editor.confirmation!=null) {editor.confirmation=null;false}
        else if(editor.dismissDestination!=null)false
        else editor.requestDismiss(DismissDestination.Closed)
    }) {
        // Back handling lives in the modal window. The platform IME consumes its first Back.
        BackHandler {if(editor.confirmation!=null)editor.confirmation=null else if(editor.dismissDestination!=null){editor.keepEditing();restoreFocus++} else request(if(editor.page==DetailsPage.Read)DismissDestination.Closed else DismissDestination.Read)}
        if(editor.page!=DetailsPage.Read)SoundQIconButton(SoundQIcon.Back,"Back to Song details",{request(DismissDestination.Read)})
        if(state.loading)SoundQFeedback("Loading song details",FeedbackKind.Loading)
        state.error?.let {SoundQFeedback("Could not load song details",FeedbackKind.Error,it.message,"Reload song details",onReload)}
        when(state.outcome) {
            MutationOutcome.Pending->SoundQFeedback("Saving change",FeedbackKind.Loading)
            MutationOutcome.Confirmed->SoundQFeedback("Change saved",FeedbackKind.Notice)
            MutationOutcome.Refused->SoundQFeedback("Change refused",FeedbackKind.Error,"Your changes were not saved.")
            MutationOutcome.Uncertain->SoundQFeedback("Change not confirmed",FeedbackKind.Error,"Reload to check before saving again.","Reload song details",onReload)
            MutationOutcome.ReadbackFailed->SoundQFeedback("Change accepted, refresh failed",FeedbackKind.Error,"Reload to check the saved details.","Reload song details",onReload)
            null->Unit
        }
        if(state.missing)SoundQFeedback("Track is not in your Library",FeedbackKind.Notice)
        if(editor.invalidField==null)editor.error?.let {SoundQFeedback(it,FeedbackKind.Error)}
        detail?.let {observed->
            Text("In your Library",style=SoundQ.typography.caption,color=SoundQ.colors.focus)
            Text(observed.track.title,style=SoundQ.typography.heading,modifier=Modifier.semantics {heading()})
            Text(observed.track.artist.ifBlank {"Unknown artist"},color=SoundQ.colors.muted)
            if(editor.page==DetailsPage.Read) {
                Text(observed.track.album.ifBlank {"Unknown album"},color=SoundQ.colors.muted)
                Text(if(observed.edited)"Edited for your Library" else "Original metadata",style=SoundQ.typography.caption)
            }
        }
        when(editor.page) {
            DetailsPage.Read->detail?.let {observed->
                SoundQDivider()
                Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(SoundQ.spacing.medium)) {
                    DetailsFact("Duration",detailsDuration(observed.track.durationMs),Modifier.weight(1f))
                    // The owned Library contract does not publish a release year. Never infer it from a title or another edition.
                    DetailsFact("Year","Not available",Modifier.weight(1f))
                }
                Text(if(observed.verified)"MusicBrainz verified" else "MusicBrainz unverified",style=SoundQ.typography.caption)
                observed.recording?.let {SelectionContainer {DetailsFact("Recording MBID",it.value)}}
                SoundQDivider()
                Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(SoundQ.spacing.medium)) {
                    Text("Source quality",Modifier.weight(1f),style=SoundQ.typography.caption)
                    Text(observed.sourceQuality?:"Not available",Modifier.weight(1f),style=SoundQ.typography.mono)
                }
                SelectionContainer {DetailsFact("Source",observed.sourceUrl?.takeIf {it.isNotBlank()}?:"Not available")}
                SoundQDivider()
                AnalysisSummary(state.analysis,keyNotation)
                if(state.analysisAbsent||state.analysisError!=null)Text("Analysis unavailable for this track.",style=SoundQ.typography.caption)
                SoundQDivider()
                Column {
                    DetailsButton("Edit metadata",SoundQIcon.Note,{editor.page=DetailsPage.Metadata},enabled=canWrite)
                    DetailsButton("Verification & matching",SoundQIcon.Check,{editor.page=DetailsPage.Matching},enabled=canWrite)
                    DetailsButton("Correct analysis",SoundQIcon.Settings,{editor.page=DetailsPage.Analysis},enabled=state.analysis!=null&&canWrite)
                    DetailsButton("Remove from Library",SoundQIcon.Trash,{
                        editor.confirmation=DetailsConfirmation("Remove from Library?","This removes the song from your Library, not the current listening queue or a device copy.","Confirm Library removal",observed,DetailsAction.Remove)
                    },enabled=canWrite,destructive=true)
                }
            }
            DetailsPage.Metadata->{
                Text("Blank fields use the original metadata.")
                listOf("Title","Artist","Album").forEachIndexed {i,label->
                    SoundQEntryField(editor.metadata[i],{editor.metadata[i]=it;editor.error=null;editor.invalidField=null},label,
                        Modifier.focusRequester(fields[i]).bringIntoViewRequester(bring[i]).onFocusChanged {if(it.isFocused){focused=i;scope.launch {bring[i].bringIntoView()}}},enabled=canWrite,
                        error=editor.error.takeIf {editor.invalidField==i},keyboardOptions=KeyboardOptions(imeAction=if(i==2)ImeAction.Done else ImeAction.Next),
                        keyboardActions=KeyboardActions(onNext={if(i<2)fields[i+1].requestFocus()},onDone={saveMetadata()}))
                }
                DetailsButton("Save metadata",SoundQIcon.Check,{saveMetadata()},primary=true,enabled=canWrite)
                DetailsButton("Reset to original",SoundQIcon.Retry,{
                    detail?.let {editor.confirmation=DetailsConfirmation("Reset metadata?","Use the original title, artist and album for your Library. Shared source metadata stays unchanged.","Confirm metadata reset",it,DetailsAction.Metadata(MetadataDraft()))}
                },enabled=canWrite&&detail.edited)
                DetailsButton("Cancel",SoundQIcon.Close,{request(DismissDestination.Read)})
                LaunchedEffect(restoreFocus) {if(restoreFocus>0)fields[focused].requestFocus()}
            }
            DetailsPage.Analysis->AnalysisCorrectionControls(state.analysis,canWrite,editor=editor,onCancel={request(DismissDestination.Read)},onReset={
                if(detail!=null&&state.analysis!=null)editor.confirmation=DetailsConfirmation("Reset corrections?","Remove manual analysis corrections. Generated analysis stays unchanged.","Confirm analysis reset",detail,DetailsAction.Analysis(state.analysis,AnalysisCorrection(reset=true)))
            }) {correction->if(detail!=null&&state.analysis!=null)dispatch(detail,DetailsAction.Analysis(state.analysis,correction))}
            DetailsPage.Matching->detail?.let {observed->VerificationControls(observed,canWrite,editor)}
        }
        if(editor.page==DetailsPage.Read)DetailsButton("Reload details",SoundQIcon.Retry,onReload,enabled=!state.loading&&state.outcome!=MutationOutcome.Pending&&!editor.saving)
        editor.confirmation?.let {confirmation->
            val cancel=when(confirmation.action) {DetailsAction.Remove->"Cancel removal";is DetailsAction.Metadata,is DetailsAction.Analysis->"Cancel reset";is DetailsAction.Verification->"Cancel matching change"}
            DetailsDialog(confirmation.title,confirmation.explanation,confirmation.label,cancel,canWrite,
                {editor.confirmation=null},{editor.confirmation=null;dispatch(confirmation.observed,confirmation.action)})
        }
        if(editor.dismissDestination!=null)DetailsDialog("Discard changes?","Your unsaved changes will be lost.","Discard","Keep editing",true,
            {editor.keepEditing();restoreFocus++},{editor.discard()?.let(::navigate)})
    }
}

@Composable internal fun DetailsButton(label:String,icon:SoundQIcon,onClick:()->Unit,modifier:Modifier=Modifier,enabled:Boolean=true,primary:Boolean=false,destructive:Boolean=false) {
    val colors=SoundQ.colors
    Column {
        Button(onClick,modifier.fillMaxWidth().heightIn(min=SoundQ.sizes.target),enabled=enabled,shape=RectangleShape,
            colors=ButtonDefaults.buttonColors(containerColor=if(primary)colors.primary else colors.background,contentColor=if(primary)colors.onPrimary else if(destructive)colors.error else colors.text,disabledContainerColor=colors.disabledSurface,disabledContentColor=colors.disabled),
            contentPadding=PaddingValues(SoundQ.spacing.medium)) {
            SoundQIcon(icon,null);Spacer(Modifier.width(SoundQ.spacing.medium));Text(label,Modifier.weight(1f),style=SoundQ.typography.body)
        }
        SoundQDivider()
    }
}
internal fun detailsDuration(ms:Long?):String {
    if(ms==null||ms<=0)return "Not available"
    return formatSongTime(ms)
}
@Composable internal fun DetailsFact(label:String,value:String,modifier:Modifier=Modifier) {
    Column(modifier) {Text(label,style=SoundQ.typography.caption,color=SoundQ.colors.muted);Text(value,style=SoundQ.typography.body)}
}
@Composable private fun DetailsDialog(title:String,text:String,confirm:String,cancel:String,enabled:Boolean,onCancel:()->Unit,onConfirm:()->Unit) {
    AlertDialog(onDismissRequest=onCancel,shape=RectangleShape,containerColor=SoundQ.colors.background,
        title={Text(title,style=SoundQ.typography.heading)},text={Text(text,style=SoundQ.typography.body)},
        confirmButton={SoundQButton(confirm,onConfirm,enabled=enabled)},dismissButton={SoundQButton(cancel,onCancel,variant=SoundQButtonVariant.Secondary)})
}
@Composable internal fun AnalysisSummary(analysis:AnalysisDetail?,keyNotation:KeyNotation=KeyNotation.Camelot) {
    Text("Analysis",style=SoundQ.typography.title,modifier=Modifier.semantics {heading()})
    if(analysis==null)return
    val tempo=analysis.number("bpm")?.let {"$it BPM"}?:"Not set"
    val key=formatAnalysisKey(analysis.text("key"),analysis.text("camelot"),keyNotation)?:"Not set"
    Column(verticalArrangement=Arrangement.spacedBy(SoundQ.spacing.medium)) {
        Row(horizontalArrangement=Arrangement.spacedBy(SoundQ.spacing.medium)) {
            AnalysisFact("Tempo",tempo,Modifier.weight(1f));AnalysisFact("Key",key,Modifier.weight(1f))
        }
        Row(horizontalArrangement=Arrangement.spacedBy(SoundQ.spacing.medium)) {
            AnalysisFact("Energy",analysis.number("energy")?.toString()?:"Not set",Modifier.weight(1f))
            AnalysisFact("Loudness",analysis.number("loudness","integrated_lufs")?.let {"$it LUFS"}?:"Not set",Modifier.weight(1f))
        }
    }
}
@Composable private fun AnalysisFact(label:String,value:String,modifier:Modifier) {Column(modifier) {Text(label,style=SoundQ.typography.caption,color=SoundQ.colors.muted);Text(value,style=SoundQ.typography.mono)}}
