package com.soundq.android.product.trackdetails

import androidx.compose.runtime.*
import androidx.compose.ui.text.input.TextFieldValue
import com.soundq.android.data.MutationOutcome
import com.soundq.android.data.trackdetails.*

internal enum class DismissDestination { Read, Closed }
internal enum class DetailsPage { Read, Metadata, Analysis, Matching }
internal data class DetailsConfirmation(val title:String,val explanation:String,val label:String,val observed:TrackDetails,val action:DetailsAction)
private data class SubmittedDetails(val action:DetailsAction,val detail:TrackDetails,val analysis:AnalysisDetail?,val values:List<TextFieldValue>,val publication:TrackDetailsState?)
/** Route-owned native entry values. No executable mutation capability is retained here. */
internal class DetailsEditor {
    var page by mutableStateOf(DetailsPage.Read)
    val metadata=mutableStateListOf(TextFieldValue(),TextFieldValue(),TextFieldValue())
    val correction=mutableStateListOf(*Array(7){TextFieldValue()})
    private var publication:TrackDetailsState?=null
    private var observed:TrackDetails?=null
    private var baseline=listOf("","","")
    private var submission by mutableStateOf<SubmittedDetails?>(null)
    val saving get()=submission!=null
    val metadataDirty get()=metadata.map {it.text}!=baseline
    val dirty get()=metadataDirty||correction.any {it.text.isNotEmpty()}||mbid.text.isNotEmpty()||updateMetadata
    var mbid by mutableStateOf(TextFieldValue())
    var updateMetadata by mutableStateOf(false)
    var tempo by mutableStateOf(TempoDraft())
    var timingExpanded by mutableStateOf(false)
    var keyExpanded by mutableStateOf(false)
    var linkExpanded by mutableStateOf(false)
    var invalidField by mutableStateOf<Int?>(null)
    var error by mutableStateOf<String?>(null)
    var confirmation by mutableStateOf<DetailsConfirmation?>(null)
    var dismissDestination by mutableStateOf<DismissDestination?>(null)

    fun submitted(action:DetailsAction,detail:TrackDetails,analysis:AnalysisDetail?) {
        submission=SubmittedDetails(action,detail,analysis,if(action is DetailsAction.Analysis)correction.toList() else metadata.toList(),publication)
    }
    fun analysisCorrection():AnalysisCorrection? {
        invalidField=null;error=null
        fun invalid(index:Int,message:String):AnalysisCorrection? {invalidField=index;error=message;return null}
        correction.indexOfFirst {it.composition!=null}.takeIf {it>=0}?.let {return invalid(it,"Finish composing before saving.")}
        val values=correction.map {it.text.trim()}
        val bpm=values[0].takeIf {it.isNotBlank()}?.toDoubleOrNull()
        if(values[0].isNotBlank()&&(bpm==null||!bpm.isFinite()||bpm !in 30.0..300.0))return invalid(0,"Tempo must be 30–300 BPM.")
        if(tempo.error!=null)return invalid(0,tempo.error!!)
        val anchor=values[1].takeIf {it.isNotBlank()}?.toLongOrNull()
        if(values[1].isNotBlank()&&(anchor==null||anchor<0))return invalid(1,"Enter a non-negative integer source time.")
        val meter=values[2].takeIf {it.isNotBlank()}?.toIntOrNull()
        if(values[2].isNotBlank()&&(meter==null||meter !in 1..32))return invalid(2,"Beats per bar must be 1–32.")
        val phase=values[3].takeIf {it.isNotBlank()}?.toIntOrNull()
        if(values[3].isNotBlank()&&(phase==null||meter==null||phase !in 0 until meter))return invalid(3,"Enter a phase below the explicitly entered beats per bar.")
        val phrase=values[4].takeIf {it.isNotBlank()}?.toIntOrNull()
        if(values[4].isNotBlank()&&(phrase==null||phrase !in 1..128))return invalid(4,"Phrase length must be 1–128 bars.")
        if(values[5].length>100)return invalid(5,"Key must contain 100 characters or fewer.")
        if(values[6].length>20)return invalid(6,"Camelot must contain 20 characters or fewer.")
        if(values.all {it.isBlank()})return invalid(0,"Enter at least one correction.")
        return AnalysisCorrection(bpm,anchor,meter,phase,phrase,values[5].takeIf {it.isNotBlank()},values[6].takeIf {it.isNotBlank()})
    }
    fun metadataAction():DetailsAction.Metadata?=if(metadata.any {it.composition!=null})null else runCatching {DetailsAction.Metadata(MetadataDraft(metadata[0].text,metadata[1].text,metadata[2].text))}.getOrNull()
    fun requestDismiss(destination:DismissDestination):Boolean {
        if(saving)return false
        if(!dirty)return true
        if(dismissDestination==null)dismissDestination=destination
        return false
    }
    var focusRestore by mutableIntStateOf(0)
    fun keepEditing() {dismissDestination=null;focusRestore++}
    fun discard():DismissDestination? {
        val destination=dismissDestination;dismissDestination=null
        if(destination==DismissDestination.Closed) {resetMetadata();resetCorrection();mbid=TextFieldValue();updateMetadata=false}
        else when(page) {DetailsPage.Metadata->resetMetadata();DetailsPage.Analysis->resetCorrection();DetailsPage.Matching->{mbid=TextFieldValue();updateMetadata=false};DetailsPage.Read->Unit}
        error=null;invalidField=null;return destination
    }
    private fun resetMetadata() {baseline.forEachIndexed {i,text->metadata[i]=TextFieldValue(text)}}
    private fun resetCorrection() {correction.indices.forEach {correction[it]=TextFieldValue()};tempo=TempoDraft()}
    fun observe(state:TrackDetailsState) {
        publication=state
        val next=state.detail?:return
        if(observed?.track?.id!=next.track.id) {
            page=DetailsPage.Read;baseline=listOf(next.track.title,next.track.artist,next.track.album)
            resetMetadata();resetCorrection();mbid=TextFieldValue();updateMetadata=false
            submission=null;confirmation=null;dismissDestination=null;error=null;invalidField=null
            timingExpanded=false;keyExpanded=false;linkExpanded=false
        }
        submission?.takeIf {state!==it.publication}?.let {sent->
            when(state.outcome) {
                MutationOutcome.Refused,MutationOutcome.Uncertain,MutationOutcome.ReadbackFailed->submission=null
                MutationOutcome.Confirmed->when(sent.action) {
                    is DetailsAction.Metadata->if(next!==sent.detail) {
                        baseline=listOf(next.track.title,next.track.artist,next.track.album)
                        if(metadata.toList()==sent.values)resetMetadata()
                        submission=null
                    }
                    is DetailsAction.Analysis->if(state.analysis!=null&&state.analysis!==sent.analysis) {
                        if(correction.toList()==sent.values)resetCorrection()
                        submission=null
                    }
                    else->if(next!==sent.detail) {submission=null;if(sent.action is DetailsAction.Verification){mbid=TextFieldValue();updateMetadata=false}}
                }
                else->Unit
            }
        }
        if(submission==null&&!metadataDirty) {
            val values=listOf(next.track.title,next.track.artist,next.track.album)
            if(values!=baseline) {baseline=values;resetMetadata()}
        }
        observed=next
    }
}
