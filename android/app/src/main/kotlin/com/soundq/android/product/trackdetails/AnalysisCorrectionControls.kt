package com.soundq.android.product.trackdetails

import android.os.SystemClock
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.*
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.*
import com.soundq.android.data.trackdetails.*
import com.soundq.designsystem.*
import kotlinx.coroutines.launch

@Composable internal fun AnalysisCorrectionControls(analysis:AnalysisDetail?,enabled:Boolean,tapClockMs:()->Long=SystemClock::elapsedRealtime,
    editor:DetailsEditor?=null,onCancel:()->Unit={},onReset:(()->Unit)?=null,onSave:(AnalysisCorrection)->Unit) {
    val draft=editor?:remember {DetailsEditor()}
    val focus=remember {List(7){FocusRequester()}}
    val bring=remember {List(7){BringIntoViewRequester()}}
    val scope=rememberCoroutineScope()
    var lastFocus by remember {mutableIntStateOf(0)}
    var restore by remember {mutableStateOf(false)}
    var resetConfirmation by remember {mutableStateOf(false)}
    val writable=enabled&&analysis!=null
    if(analysis==null)Text("Analysis unavailable. Your draft is kept until you leave this song.")
    if(editor==null&&draft.page!=DetailsPage.Analysis) {
        AnalysisSummary(analysis)
        DetailsButton("Correct analysis",SoundQIcon.Settings,{draft.page=DetailsPage.Analysis},enabled=writable)
        return
    }
    fun showInvalid() {
        draft.invalidField?.let {index->
            if(index in 1..4)draft.timingExpanded=true
            if(index in 5..6)draft.keyExpanded=true
            scope.launch {withFrameNanos {};focus[index].requestFocus();bring[index].bringIntoView()}
        }
    }
    fun save() {if(writable)draft.analysisCorrection()?.let(onSave)?:showInvalid()}
    fun tempo(next:TempoDraft) {
        draft.tempo=next
        draft.correction[0]=TextFieldValue(next.text,TextRange(next.text.length));draft.error=null;draft.invalidField=null
    }
    Text("Enter only what you want to correct. Blank fields keep existing facts.")
    Text("Current: ${analysis?.number("bpm")?.let {"$it BPM"}?:"Tempo not set"} · ${analysis?.text("key")?:"Key not set"} · ${analysis?.text("camelot")?:"Camelot not set"}",style=SoundQ.typography.mono)
    val labels=listOf("Tempo BPM (30–300)","Beat anchor (source ms)","Beats per bar (1–32)","Downbeat phase index (starts at 0)","Phrase length (bars)","Corrected musical key","Corrected Camelot")
    @Composable fun field(index:Int) {
        SoundQEntryField(draft.correction[index],{
            draft.correction[index]=it
            if(index==0)draft.tempo=draft.tempo.typed(it.text)
            draft.error=null;draft.invalidField=null
        },labels[index],Modifier.focusRequester(focus[index]).bringIntoViewRequester(bring[index]).onFocusChanged {if(it.isFocused){lastFocus=index;scope.launch {bring[index].bringIntoView()}}},
            enabled=writable,error=if(draft.invalidField==index)draft.error else if(index==0)draft.tempo.error else null,
            keyboardOptions=KeyboardOptions(keyboardType=if(index==0)KeyboardType.Decimal else if(index<5)KeyboardType.Number else KeyboardType.Text,imeAction=ImeAction.Done),keyboardActions=KeyboardActions(onDone={save()}))
    }
    field(0)
    Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(SoundQ.spacing.small)) {
        SoundQButton("Half BPM",{tempo(draft.tempo.scale(0.5,analysis?.number("bpm")))},Modifier.weight(1f),variant=SoundQButtonVariant.Secondary,enabled=writable)
        SoundQButton("Tap tempo",{tempo(draft.tempo.tap(tapClockMs()))},Modifier.weight(1f),variant=SoundQButtonVariant.Secondary,enabled=writable)
        SoundQButton("Double BPM",{tempo(draft.tempo.scale(2.0,analysis?.number("bpm")))},Modifier.weight(1f),variant=SoundQButtonVariant.Secondary,enabled=writable)
    }
    Text(if(draft.tempo.tapsMs.size<2)"Tap at least twice to measure tempo." else "${draft.tempo.tapsMs.size} taps, using the latest eight.",style=SoundQ.typography.caption)
    Text("These controls only change your draft.",style=SoundQ.typography.caption)
    DetailsButton("Timing & phrasing",if(draft.timingExpanded)SoundQIcon.Up else SoundQIcon.Down,{draft.timingExpanded=!draft.timingExpanded},modifier=Modifier.semantics {stateDescription=if(draft.timingExpanded)"Expanded" else "Collapsed"})
    if(draft.timingExpanded) {
        Text("Source-relative timing. Not device-output calibration.",style=SoundQ.typography.caption)
        Text("Current anchor: ${analysis?.number("beat_grid","offset_ms")?:"Not set"} · Meter: ${analysis?.number("meter","beats_per_bar")?:"Not set"} · Phase: ${analysis?.number("downbeat_phase","index")?:"Not set"}",style=SoundQ.typography.caption)
        (1..4).forEach {field(it)}
    }
    DetailsButton("Key & Camelot",if(draft.keyExpanded)SoundQIcon.Up else SoundQIcon.Down,{draft.keyExpanded=!draft.keyExpanded},modifier=Modifier.semantics {stateDescription=if(draft.keyExpanded)"Expanded" else "Collapsed"})
    if(draft.keyExpanded)(5..6).forEach {field(it)}
    DetailsButton("Save analysis correction",SoundQIcon.Check,{save()},enabled=writable,primary=true)
    DetailsButton("Reset analysis corrections",SoundQIcon.Retry,{
        if(onReset!=null)onReset() else resetConfirmation=true
    },enabled=writable)
    DetailsButton("Cancel",SoundQIcon.Close,{
        if(editor!=null)onCancel() else if(draft.requestDismiss(DismissDestination.Read))draft.page=DetailsPage.Read
    })
    if(editor==null&&resetConfirmation) {
        Text("Remove manual analysis corrections?")
        SoundQButton("Confirm analysis reset",{resetConfirmation=false;onSave(AnalysisCorrection(reset=true))},enabled=writable)
        SoundQButton("Cancel reset",{resetConfirmation=false},variant=SoundQButtonVariant.Secondary)
    }
    if(editor==null&&draft.dismissDestination!=null) {
        SoundQButton("Keep editing",{draft.keepEditing();restore=true},variant=SoundQButtonVariant.Secondary)
        SoundQButton("Discard",{draft.discard();draft.page=DetailsPage.Read},variant=SoundQButtonVariant.Secondary)
    }
    LaunchedEffect(draft.focusRestore,restore) {if(restore||draft.focusRestore>0){focus[lastFocus].requestFocus();bring[lastFocus].bringIntoView();restore=false}}
}
