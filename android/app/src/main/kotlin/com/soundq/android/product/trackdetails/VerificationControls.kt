package com.soundq.android.product.trackdetails

import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.*
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import com.soundq.android.data.trackdetails.*
import com.soundq.designsystem.*

@Composable internal fun VerificationControls(detail:TrackDetails,enabled:Boolean,editor:DetailsEditor) {
    val focus=remember {FocusRequester()}
    Text(if(detail.verified)"MusicBrainz verified" else "MusicBrainz unverified",style=SoundQ.typography.caption)
    detail.recording?.let {SelectionContainer {DetailsFact("Recording MBID",it.value)}}
    Text("Your Library display edits stay separate from MusicBrainz matching.")
    fun confirm(action:VerificationAction,explanation:String) {
        editor.confirmation=DetailsConfirmation("Change shared matching?",explanation,"Confirm matching change",detail,DetailsAction.Verification(action))
    }
    DetailsButton("Find matches again",SoundQIcon.Retry,{confirm(VerificationAction.Rematch,"Run matching again using original source metadata? This updates shared matching, not your personal display edits.")},enabled=enabled)
    if(detail.suggestions.isEmpty())Text("No suggested recording.",style=SoundQ.typography.caption)
    detail.suggestions.forEach {suggestion->
        SoundQDivider()
        Text("${suggestion.title} · ${suggestion.artist}",style=SoundQ.typography.title)
        suggestion.album?.takeIf {it.isNotBlank()}?.let {Text(it,style=SoundQ.typography.body)}
        suggestion.durationMs?.let {DetailsFact("Duration",detailsDuration(it))}
        SelectionContainer {DetailsFact("Recording MBID",suggestion.recording.value)}
        suggestion.release?.let {SelectionContainer {DetailsFact("Release MBID",it.value)}}
        suggestion.confidence?.let {Text("Match confidence: $it",style=SoundQ.typography.caption)}
        DetailsButton("Verify ${suggestion.title}",SoundQIcon.Check,{
            confirm(VerificationAction.Confirm(suggestion),"Verify ${suggestion.title} by ${suggestion.artist}?\nRecording: ${suggestion.recording.value}${suggestion.release?.let {"\nRelease: ${it.value}"}.orEmpty()}\nThis changes shared MusicBrainz identity.")
        },modifier=Modifier.semantics {contentDescription="Verify ${suggestion.title}, recording ${suggestion.recording.value}"},enabled=enabled)
    }
    DetailsButton("Link a recording MBID",if(editor.linkExpanded)SoundQIcon.Up else SoundQIcon.Down,{editor.linkExpanded=!editor.linkExpanded},modifier=Modifier.semantics {stateDescription=if(editor.linkExpanded)"Expanded" else "Collapsed"})
    if(editor.linkExpanded) {
        LaunchedEffect(editor.focusRestore) {if(editor.focusRestore>0)focus.requestFocus()}
        SoundQEntryField(editor.mbid,{editor.mbid=it;editor.error=null},"MusicBrainz recording MBID",Modifier.focusRequester(focus),enabled=enabled,error=editor.error,keyboardOptions=KeyboardOptions(imeAction=ImeAction.Done))
        SoundQRow("Update source metadata from MusicBrainz","Optional shared title, artist and album update.",editor.updateMetadata,{editor.updateMetadata=!editor.updateMetadata},enabled=enabled,trailing={Checkbox(editor.updateMetadata,{editor.updateMetadata=it},enabled=enabled)})
        DetailsButton("Link recording",SoundQIcon.Check,{
            val parsed=if(editor.mbid.composition!=null)null else runCatching {RecordingMbid(editor.mbid.text)}.getOrNull()
            if(parsed==null) {editor.error="Enter the exact hyphenated recording MBID after finishing composition.";focus.requestFocus()}
            else confirm(VerificationAction.Link(parsed,editor.updateMetadata),"Recording: ${parsed.value}\n"+if(editor.updateMetadata)"Link and update shared title, artist and album? Your Library display edits stay separate." else "Link without changing source metadata? This changes shared MusicBrainz identity.")
        },enabled=enabled)
    }
}
