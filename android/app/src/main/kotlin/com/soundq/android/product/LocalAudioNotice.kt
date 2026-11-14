package com.soundq.android.product

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.soundq.android.data.LibraryQuery
import com.soundq.android.data.device.PhoneAudioState
import com.soundq.designsystem.*

/** Why phone audio is missing from the visible Library, from the phone owner's published state only. */
internal enum class LocalAudioNotice { AccessOff, Finding, NoneFound }

internal fun localAudioNotice(phone:PhoneAudioState,query:LibraryQuery,source:LibrarySource,rowsEmpty:Boolean):LocalAudioNotice? {
    if(source==LibrarySource.Server)return null
    val snapshot=phone.snapshot?.takeIf {phone.ready} ?: return null
    // These refinements never include phone files, so phone access cannot explain their results.
    if(query.liked||query.verified!=null||query.genre.isNotBlank())return null
    if(source!=LibrarySource.Local&&!rowsEmpty)return null
    if(!phone.permission)return LocalAudioNotice.AccessOff
    if(!rowsEmpty)return null
    if(phone.refreshing)return LocalAudioNotice.Finding
    // "None found" needs a finished, whole all-files scan and no query that could have hidden files.
    val scanned=phone.scan?.let {it.indexed&&it.storage&&it.complete}==true
    return if(scanned&&source==LibrarySource.Local&&query.text.isBlank()&&query.collection==null&&snapshot.files.none {it.available})LocalAudioNotice.NoneFound else null
}

/** Resume refresh is for an actual access change, not every resume: a refresh re-proves every file's bytes.
 * Compare live access with what a finished scan observed; the published flag alone is re-read by any journal
 * publication without scanning. A running refresh publishes the access it was admitted with. Before first
 * publication the startup refresh owns the scan. */
internal fun localAudioAccessChanged(phone:PhoneAudioState,storageAllowed:Boolean):Boolean {
    if(!phone.ready||phone.snapshot==null)return false
    if(phone.refreshing)return phone.permission!=storageAllowed
    return (phone.scan?.storage ?: false)!=storageAllowed
}

@Composable internal fun LocalAudioNoticeContent(notice:LocalAudioNotice,onAllow:()->Unit) {
    Column(Modifier.fillMaxWidth().padding(bottom=SoundQ.spacing.large),verticalArrangement=Arrangement.spacedBy(SoundQ.spacing.medium)) {
        when(notice) {
            LocalAudioNotice.AccessOff->{
                SoundQFeedback("File access is off",FeedbackKind.Empty)
                SoundQButton("Allow file access",onAllow)
            }
            LocalAudioNotice.Finding->SoundQFeedback("Finding audio on this phone",FeedbackKind.Loading)
            LocalAudioNotice.NoneFound->SoundQFeedback("No audio found on this phone",FeedbackKind.Empty)
        }
    }
}
