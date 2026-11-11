package com.soundq.android.product.trackdetails

import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import com.soundq.android.data.*
import com.soundq.android.data.trackdetails.*
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.*
import org.junit.Test

class DetailsEditorTest {
    private fun detail(id:Long=7,title:String="First")=TrackDetails(Track(TrackId(id),title,"Artist","Album"),false,false)
    private fun analysis(revision:Long=1)=AnalysisDetail(revision,"analyzed",JsonObject(emptyMap()),JsonObject(emptyMap()),JsonObject(emptyMap()))
    @Test fun sameTrackReloadRetainsNativeSelectionAndCompositionAndDifferentTrackRetiresDraft() {
        val editor=DetailsEditor();val original=detail()
        editor.observe(TrackDetailsState(detail=original));editor.page=DetailsPage.Metadata
        val value=TextFieldValue("My title",TextRange(2,5),TextRange(1,6))
        editor.metadata[0]=value
        editor.observe(TrackDetailsState(detail=original.copy(track=original.track.copy(title="Reloaded")),outcome=MutationOutcome.Uncertain,reconciled=true))
        assertEquals(value,editor.metadata[0]);assertTrue(editor.dirty)
        editor.observe(TrackDetailsState(error=SafeFailure.Reason.Network))
        assertEquals(value,editor.metadata[0])
        editor.observe(TrackDetailsState(detail=detail(8,"Other")))
        assertEquals(DetailsPage.Read,editor.page);assertFalse(editor.dirty);assertEquals("Other",editor.metadata[0].text)
    }
    @Test fun composingSaveIsRefusedAndDirtyDismissRequiresAnExplicitDecision() {
        val editor=DetailsEditor();editor.observe(TrackDetailsState(detail=detail()))
        editor.page=DetailsPage.Metadata
        editor.metadata[0]=TextFieldValue("Personal",TextRange(3),TextRange(0,3))
        assertNull(editor.metadataAction())
        assertFalse(editor.requestDismiss(DismissDestination.Closed))
        assertEquals(DismissDestination.Closed,editor.dismissDestination)
        editor.keepEditing()
        assertNull(editor.dismissDestination);assertEquals("Personal",editor.metadata[0].text)
        editor.metadata[0]=TextFieldValue("Personal",TextRange(3))
        assertEquals(DetailsAction.Metadata(MetadataDraft("Personal","Artist","Album")),editor.metadataAction())
        assertFalse(editor.requestDismiss(DismissDestination.Read))
        assertEquals(DismissDestination.Read,editor.discard())
        assertEquals("First",editor.metadata[0].text);assertFalse(editor.dirty)
    }
    @Test fun correctionOnlySendsEnteredFactsAndRejectsFirstInvalidOrComposingField() {
        val editor=DetailsEditor()
        editor.correction[0]=TextFieldValue("125")
        assertEquals(AnalysisCorrection(bpm=125.0),editor.analysisCorrection())
        editor.correction[1]=TextFieldValue("-1");editor.correction[2]=TextFieldValue("0")
        assertNull(editor.analysisCorrection());assertEquals(1,editor.invalidField)
        editor.correction[1]=TextFieldValue("12");editor.correction[2]=TextFieldValue("4")
        editor.correction[3]=TextFieldValue("4")
        assertNull(editor.analysisCorrection());assertEquals(3,editor.invalidField)
        editor.correction[3]=TextFieldValue("2",TextRange(1),TextRange(0,1))
        assertNull(editor.analysisCorrection())
        editor.correction[3]=TextFieldValue("2")
        assertEquals(AnalysisCorrection(bpm=125.0,anchorMs=12,meter=4,phase=2),editor.analysisCorrection())
    }
    @Test fun previousRefusalCannotReleaseANewSubmissionBeforeAnyNewPublication() {
        val editor=DetailsEditor();val original=detail();val state=TrackDetailsState(detail=original,outcome=MutationOutcome.Refused)
        editor.observe(state);editor.metadata[0]=TextFieldValue("New")
        editor.submitted(editor.metadataAction()!!,original,null)
        editor.observe(state)
        assertTrue(editor.saving)
        editor.observe(state.copy(outcome=MutationOutcome.Pending));assertTrue(editor.saving)
        editor.observe(state.copy(outcome=MutationOutcome.Refused));assertFalse(editor.saving)
        assertEquals("New",editor.metadata[0].text)
    }
    @Test fun acknowledgedReadbackClearsOnlySubmittedEditorAndNeverClearsOnEarlyConfirmedOrUncertain() {
        val editor=DetailsEditor();val original=detail();val a=analysis()
        editor.observe(TrackDetailsState(detail=original,analysis=a));editor.metadata[0]=TextFieldValue("Personal")
        editor.correction[0]=TextFieldValue("125")
        editor.submitted(editor.metadataAction()!!,original,a)
        editor.observe(TrackDetailsState(detail=original,analysis=a,outcome=MutationOutcome.Confirmed))
        assertEquals("Personal",editor.metadata[0].text)
        editor.observe(TrackDetailsState(detail=original.copy(track=original.track.copy(title="Personal")),analysis=a,outcome=MutationOutcome.Confirmed))
        assertEquals("Personal",editor.metadata[0].text);assertTrue(editor.dirty)
        assertFalse(editor.metadataDirty);assertEquals("125",editor.correction[0].text)
    }
}
