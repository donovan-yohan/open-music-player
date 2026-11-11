package com.soundq.android.product.offline

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import com.soundq.android.data.*
import com.soundq.android.data.offline.*
import com.soundq.android.product.ProductViewModel
import com.soundq.designsystem.*
import java.util.concurrent.atomic.AtomicBoolean

private fun LazyListScope.downloadHeader(content:@Composable ()->Unit) {
    item {Column(Modifier.fillMaxWidth().padding(horizontal=SoundQ.spacing.gutter,vertical=SoundQ.spacing.small)) {content()}}
}
/** Device-copy actions retain their captured account and row lifetime. */
@Composable fun DownloadsScreen(model:ProductViewModel,state:DownloadsState,scope:AccountScope,onBack:()->Unit) {
    val remote=model.graph.session.remoteCurrent(scope)
    val playback by model.playback.collectAsState()
    val active=remember(scope){AtomicBoolean(true)}
    val valid=remember(scope,active){{active.get()&&model.graph.session.current(scope)}}
    DisposableEffect(active){onDispose {active.set(false)}}
    LaunchedEffect(scope){model.loadDownloads(scope,valid)}
    var confirmation by remember(scope){mutableStateOf<List<DeviceDownload>?>(null)}
    var options by remember(scope){mutableStateOf(false)}
    val revealOwner=remember(scope){RowRevealOwner()}
    LazyColumn(Modifier.fillMaxSize().closeRowRevealOutside(revealOwner)) {
        downloadHeader {Text("Downloads",style=SoundQ.typography.heading,modifier=Modifier.semantics {heading()})}
        downloadHeader {Text("Saved on this device.",style=SoundQ.typography.caption)}
        downloadHeader {SoundQButton(if(remote)"Back to Library" else "Go online",onBack,variant=SoundQButtonVariant.Secondary)}
        playback.error?.let {error ->downloadHeader {SoundQFeedback(error,FeedbackKind.Error,"The device copy is unavailable. Check device storage before trying again.","Refresh downloads",{model.loadDownloads(scope,valid)})}}
        if(!state.ready)downloadHeader {SoundQFeedback("Checking device copies",FeedbackKind.Loading)}
        if(state.rejected)downloadHeader {SoundQFeedback("Device storage could not be validated",FeedbackKind.Error,"Saved files have not been changed. No downloads or removals are allowed until storage is readable.","Check storage again",{model.loadDownloads(scope,valid)})}
        if(state.ready&&!state.rejected&&state.rows.isEmpty())downloadHeader {SoundQFeedback("No device downloads",FeedbackKind.Empty,if(remote)"Open a Library track menu and choose Download to device." else "Connect and sign in to download tracks from your Library.")}
        items(state.rows,key={it.track.id.value}) {row ->
            val lifetime=com.soundq.android.product.rememberTrackRowLifetime(com.soundq.android.product.RowIdentity(row))
            val rowValid={valid()&&lifetime.current()}
            val queueEnabled=!state.rejected&&row.status==DownloadStatus.Complete
            val reveal=remember(scope,row,lifetime){RowRevealState(revealOwner)}
            val queue={model.enqueueDownload(scope,row,rowValid);Unit}
            val quickQueue={model.quickQueueDownload(scope,row,rowValid);Unit}
            var menu by remember(scope,row.track.id,row.status){mutableStateOf(false)}
            val status=downloadStatus(row)
            val current=playback.source==com.soundq.android.playback.PlaybackSource.Queue&&playback.queue.any {it.occurrenceId==playback.selectedOccurrence&&it.trackId==row.track.id.value}
            SoundQSwipeQueue(row.track.title,reveal,queueEnabled,quickQueue,explicitQueue=queue,current=current) {front,admit->
                SoundQMediaRow(row.track.title,row.track.artist,current,{
                    if(admit()) {
                        if(queueEnabled)model.playDownload(scope,row,rowValid) else menu=true
                    }
                },onMore={reveal.close();menu=true},modifier=front,
                    artwork={com.soundq.android.product.artwork.TrackArtwork(model.graph,scope,row.track,
                        {rowValid()&&!model.playback.value.localOnly},sourceOwner=lifetime to playback.localOnly)},
                    supporting=status,metadata={com.soundq.android.product.LibraryMetadataContent(com.soundq.android.product.memberDurationMetadata(row.track.durationMs))},enabled=!state.rejected)
            }
            if(menu)SoundQSheet("Device copy",{menu=false}) {
                Text(row.track.title,style=SoundQ.typography.title)
                Text(downloadStatus(row,compact=false),style=SoundQ.typography.caption)
                com.soundq.android.product.LibraryMetadataContent(com.soundq.android.product.memberDurationMetadata(row.track.durationMs))
                when(row.status){
                    // Progress replaces a row, not its transfer. Store cancellation checks transferId.
                    DownloadStatus.Downloading->SoundQButton("Cancel download",{if(valid())model.cancelDownload(scope,row,valid);menu=false},enabled=!state.rejected,variant=SoundQButtonVariant.Secondary)
                    DownloadStatus.Complete->{
                        SoundQButton("Play device copy",{model.playDownload(scope,row,rowValid);menu=false},enabled=!state.rejected)
                        SoundQButton("Queue",{queue();menu=false},enabled=queueEnabled,variant=SoundQButtonVariant.Secondary)
                        SoundQButton("Play next",{model.enqueueDownload(scope,row,rowValid,next=true);menu=false},enabled=queueEnabled,variant=SoundQButtonVariant.Secondary)
                    }
                    else->if(remote)SoundQButton("Retry download",{model.retryDownload(scope,row,rowValid);menu=false},enabled=!state.rejected)
                }
                if(row.status!=DownloadStatus.Downloading)SoundQButton("Remove device copy",{if(rowValid())confirmation=listOf(row);menu=false},enabled=!state.rejected,variant=SoundQButtonVariant.Secondary)
            }
        }
        if(state.rows.isNotEmpty())downloadHeader {SoundQButton("Clear device downloads",{confirmation=state.rows.toList()},enabled=!state.rejected&&state.rows.none {it.status==DownloadStatus.Downloading},variant=SoundQButtonVariant.Secondary)}
        if(!remote)downloadHeader {SoundQButton("More options",{options=true},variant=SoundQButtonVariant.Quiet)}
    }
    if(options)SoundQSheet("More options",{options=false}) {
        SoundQButton("Sign out",{if(valid())model.logout();options=false},variant=SoundQButtonVariant.Quiet)
    }
    confirmation?.let {captured ->SoundQSheet(if(captured.size==1)"Remove device copy?" else "Clear device downloads?",{confirmation=null}) {
        Text("Only these device copies will be removed. Your Library and listening queue stay unchanged. A copy already in use is kept until playback releases it.")
        SoundQButton("Confirm removal",{model.removeDownloads(scope,captured,valid);confirmation=null})
        SoundQButton("Keep downloads",{confirmation=null},variant=SoundQButtonVariant.Secondary)
    }}
}
