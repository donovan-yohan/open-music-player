package com.soundq.android.product

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.soundq.android.data.LibraryQuery
import com.soundq.android.data.device.PhoneAudioState
import com.soundq.android.data.deviceaudio.AccessState
import com.soundq.android.data.deviceaudio.GrantKind
import com.soundq.designsystem.*

/** Why phone audio is missing from the visible Library, from the phone owner's published state only. */
internal enum class LocalAudioNotice { AccessOff, AddedOnly, Finding, NoneFound }

internal fun localAudioNotice(phone:PhoneAudioState,query:LibraryQuery,localFiles:Boolean,rowsEmpty:Boolean):LocalAudioNotice? {
    val snapshot=phone.snapshot?.takeIf {phone.ready} ?: return null
    // These refinements never include phone files, so phone access cannot explain their results.
    if(query.liked||query.verified!=null||query.genre.isNotBlank())return null
    if(!localFiles&&!rowsEmpty)return null
    if(!phone.permission)return if(snapshot.grants.any {it.kind!=GrantKind.INDEXED&&it.state==AccessState.AVAILABLE})LocalAudioNotice.AddedOnly else LocalAudioNotice.AccessOff
    if(!rowsEmpty)return null
    if(phone.refreshing)return LocalAudioNotice.Finding
    // "None found" needs a finished, fully proved indexed scan and no query that could have hidden files.
    val scanned=phone.scan?.let {it.indexed&&it.complete}==true
    return if(scanned&&localFiles&&query.text.isBlank()&&query.collection==null&&snapshot.files.none {it.available})LocalAudioNotice.NoneFound else null
}

/** Resume refresh is for an actual access change (e.g. back from system Settings), not every resume:
 * a refresh re-proves every file's bytes. Compare against access a finished scan observed; the published
 * permission flag alone is re-read by any journal publication without scanning. A running refresh records
 * the access it was admitted with. Before first publication the startup refresh owns the scan. */
internal fun localAudioAccessChanged(phone:PhoneAudioState,indexedAllowed:Boolean):Boolean {
    if(!phone.ready||phone.snapshot==null)return false
    if(phone.refreshing)return phone.permission!=indexedAllowed
    return (phone.scan?.indexed ?: false)!=indexedAllowed
}

@Composable internal fun LocalAudioNoticeContent(notice:LocalAudioNotice,onAllow:()->Unit,onFolder:()->Unit,onFile:()->Unit) {
    when(notice) {
        LocalAudioNotice.AccessOff->{
            SoundQFeedback("Audio access is off",FeedbackKind.Empty,"Allow access to show music saved on this phone.","Allow audio access",onAllow)
            LocalAudioPickerActions(onFolder,onFile)
        }
        LocalAudioNotice.AddedOnly->SoundQFeedback("Audio access is off",FeedbackKind.Notice,"Showing only files and folders you added.","Allow audio access",onAllow)
        LocalAudioNotice.Finding->SoundQFeedback("Finding audio on this phone",FeedbackKind.Loading)
        LocalAudioNotice.NoneFound->{
            SoundQFeedback("No audio found on this phone",FeedbackKind.Empty)
            LocalAudioPickerActions(onFolder,onFile)
        }
    }
}

@Composable private fun LocalAudioPickerActions(onFolder:()->Unit,onFile:()->Unit) {
    FlowRow(Modifier.padding(bottom=SoundQ.spacing.large),horizontalArrangement=Arrangement.spacedBy(SoundQ.spacing.medium)) {
        SoundQButton("Add folder",onFolder,variant=SoundQButtonVariant.Quiet)
        SoundQButton("Open audio file",onFile,variant=SoundQButtonVariant.Quiet)
    }
}
