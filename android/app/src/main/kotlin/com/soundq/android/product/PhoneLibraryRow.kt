package com.soundq.android.product

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.soundq.android.data.deviceaudio.DeviceAudio
import com.soundq.android.playback.PlaybackRef
import com.soundq.designsystem.*
import java.util.concurrent.atomic.AtomicBoolean

@Composable internal fun PhoneLibraryRow(model:ProductViewModel,row:DeviceAudio,selected:Boolean,revealOwner:RowRevealOwner,current:()->Boolean,onMore:()->Unit) {
    val phone by model.graph.phoneAudio.state.collectAsState()
    val history=phone.snapshot?.history?.singleOrNull {it.key==com.soundq.android.data.deviceaudio.HistoryKey.Device(row.id)}
    val saved=history?.bookmark?.takeIf {it.owner==row.owner}?.positionMs
    val ref=model.graph.phoneAudio.reference(row)
    val version=model.graph.session.version()
    val alive=remember(ref,version){AtomicBoolean(true)}
    val reveal=remember(ref,version){RowRevealState(revealOwner)}
    DisposableEffect(alive){onDispose {alive.set(false);reveal.dispose()}}
    val valid={alive.get()&&current()&&model.graph.phoneAudio.current(version)&&model.graph.phoneAudio.observed(ref)!=null}
    if(!row.available) {
        SoundQMediaRow(row.metadata.displayTitle,row.metadata.artist.orEmpty(),false,onMore,onMore,
            supporting=phoneRowUnavailableLabel(row),metadata={LibraryMetadataContent(memberDurationMetadata(row.durationMs ?: 0))})
        return
    }
    SoundQRevealMediaRow(row.metadata.displayTitle,row.metadata.artist.orEmpty(),selected,reveal,valid(),null,false,
        {},{if(valid())model.controller.enqueueDevice(ref,false,valid)},
        {if(valid())model.controller.playDevice(ref,valid)},onMore,
        metadata={LibraryMetadataContent(memberDurationMetadata(row.durationMs ?: 0))},
        artwork={com.soundq.android.product.artwork.PhoneArtwork(model.graph,ref,72.dp,valid)},
        onQuickQueue={if(valid())model.controller.enqueueDevice(ref,model.graph.swipeQueuePreferences.state.value.mode==com.soundq.android.data.preferences.SwipeQueue.PlayNext,valid)},
        supporting=if(saved!=null)"Phone file · Resume at ${formatSongTime(saved)}"else "Phone file")
}

@Composable internal fun PhoneTrackSheet(model:ProductViewModel,row:DeviceAudio,onDismiss:()->Unit,onManage:()->Unit) {
    val version=model.graph.session.version();val ref=model.graph.phoneAudio.reference(row)
    val alive=remember(ref,version){AtomicBoolean(true)}
    DisposableEffect(alive){onDispose {alive.set(false)}}
    val valid={alive.get()&&model.graph.phoneAudio.current(version)&&model.graph.phoneAudio.observed(ref)!=null}
    SoundQSheet(row.metadata.displayTitle,onDismiss) {
        Text(row.metadata.artist.orEmpty());row.metadata.album?.let {Text(it)}
        Text("Phone file · ${row.metadata.filename}",style=SoundQ.typography.caption)
        Text("Your original file stays on this phone. Playback does not upload it.",style=SoundQ.typography.caption)
        if(!row.available)Text(phoneRowUnavailableLabel(row),style=SoundQ.typography.caption)
        SoundQButton("Play / resume",{if(valid()){model.controller.playDevice(ref,valid);onDismiss()}},enabled=valid())
        SoundQButton("Play next",{if(valid()){model.controller.enqueueDevice(ref,true,valid);onDismiss()}},enabled=valid(),variant=SoundQButtonVariant.Secondary)
        SoundQButton("Add to listening queue",{if(valid()){model.controller.enqueueDevice(ref,false,valid);onDismiss()}},enabled=valid(),variant=SoundQButtonVariant.Secondary)
        SoundQButton("Local audio",onManage,variant=SoundQButtonVariant.Secondary)
    }
}
