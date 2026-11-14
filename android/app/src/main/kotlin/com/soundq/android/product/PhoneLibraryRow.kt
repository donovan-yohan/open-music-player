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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import androidx.compose.material3.ButtonDefaults
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.launch
import com.soundq.android.data.device.PhoneFileTarget
import com.soundq.android.data.device.FileDeleteOutcome

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
    val playback by model.playback.collectAsState()
    val version=model.graph.session.version();val ref=model.graph.phoneAudio.reference(row)
    val alive=remember(ref,version){AtomicBoolean(true)}
    DisposableEffect(alive){onDispose {alive.set(false)}}
    val lifetime={alive.get()&&model.graph.phoneAudio.current(version)}
    val valid={lifetime()&&model.graph.phoneAudio.observed(ref)!=null}
    val scope=rememberCoroutineScope()
    val context=LocalContext.current
    val deleteUnavailable=model.graph.phoneFiles.deleteUnavailableReason
    var speed by remember(ref,version){mutableStateOf(false)}
    var busy by remember(ref,version){mutableStateOf(false)}
    var confirmation by remember(ref,version){mutableStateOf<PhoneFileTarget?>(null)}
    var deleting by remember(ref,version){mutableStateOf(false)}
    var message by remember(ref,version){mutableStateOf<String?>(null)}
    var savedSpeed by remember(ref,version){mutableStateOf<String?>(null)}
    LaunchedEffect(ref,version,speed) {
        if(!speed)model.controller.songSpeed(ref,version,null,valid) {state->if(valid())savedSpeed=state?.let {SoundQSpeedScale.label(it.speed)}}
    }
    SoundQSheet(row.metadata.displayTitle,onDismiss) {
        if(speed)SongSpeedEditor(model,ref,valid){speed=false}
        else Column {
            row.metadata.artist?.takeIf {it.isNotBlank()}?.let {Text(it)}
            row.metadata.album?.takeIf {it.isNotBlank()}?.let {Text(it)}
            Text(row.metadata.filename,style=SoundQ.typography.caption)
            if(!row.available)Text(phoneRowUnavailableLabel(row),style=SoundQ.typography.caption)
            SongActionRow("Play / resume",{if(valid()){model.controller.playDevice(ref,valid);onDismiss()}},SoundQIcon.Play,enabled=valid()&&!busy)
            SongActionRow("Play next",{if(valid()){model.controller.enqueueDevice(ref,true,valid);onDismiss()}},SoundQIcon.Next,enabled=valid()&&!busy)
            SongActionRow("Add to listening queue",{if(valid()){model.controller.enqueueDevice(ref,false,valid);onDismiss()}},SoundQIcon.AddQueue,enabled=valid()&&!busy)
            SoundQDivider()
            SongActionRow("Playback speed",{speed=true},value=savedSpeed,opensDestination=true,enabled=valid()&&!busy)
            SongActionRow("Open in file browser",{
                busy=true;message=null
                scope.launch {
                    val target=runCatching {model.graph.phoneFiles.capture(ref,valid)}.getOrNull()
                    val opened=target!=null&&runCatching {model.graph.phoneFiles.open(target,valid)}.getOrDefault(false)
                    if(lifetime()){busy=false;if(opened)onDismiss()else message="No file manager can open this location."}
                }
            },opensDestination=true,enabled=valid()&&!busy)
            SongActionRow("Local audio",onManage,SoundQIcon.Settings,opensDestination=true)
            SoundQDivider()
            SongActionRow("Delete file",{
                busy=true;message=null
                scope.launch {
                    val target=runCatching {model.graph.phoneFiles.capture(ref,valid)}.getOrNull()
                    if(lifetime()){busy=false;confirmation=target;if(target==null)message="File changed or unavailable. Nothing was deleted."}
                }
            },SoundQIcon.Trash,value=deleteUnavailable,enabled=valid()&&!busy&&deleteUnavailable==null,destructive=true)
            message?.let {Text(it,style=SoundQ.typography.caption,color=SoundQ.colors.error)}
        }
    }
    confirmation?.let {target->
        AlertDialog(onDismissRequest={if(!deleting)confirmation=null},shape=RectangleShape,
            containerColor=SoundQ.colors.sheet,title={Text("Delete file from phone?",style=SoundQ.typography.title)},
            text={Column(Modifier.verticalScroll(rememberScrollState())) {
                Text(row.metadata.displayTitle);Text(target.path)
                Text("This deletes the original file from your phone. Other apps will lose access. SoundQ can't undo this.")
                if(playback.queue.singleOrNull {it.occurrenceId==playback.selectedOccurrence}?.ref==ref)
                    Text("Playback will stop. Another song won't start automatically.")
                if(deleting)Text("Deleting file…")
            }},
            dismissButton={TextButton({if(!deleting)confirmation=null},enabled=!deleting){Text("Cancel")}},
            confirmButton={TextButton({
                if(!deleting){deleting=true;busy=true
                    model.deletePhoneFile(target,lifetime) {result->
                        if(lifetime()) {
                            deleting=false;busy=false;confirmation=null
                            if(result==FileDeleteOutcome.Deleted){android.widget.Toast.makeText(context,"File deleted from phone",android.widget.Toast.LENGTH_SHORT).show();onDismiss()}
                            else message=when(result) {
                                FileDeleteOutcome.Changed->"File changed. Nothing was deleted."
                                FileDeleteOutcome.Missing->"File is no longer available."
                                FileDeleteOutcome.Unconfirmed->"Couldn't confirm the library update. Refresh Local audio."
                                else->"Couldn't delete file. Check file access and try again."
                            }
                        }
                    }
                }
            },enabled=!deleting,colors=ButtonDefaults.textButtonColors(contentColor=SoundQ.colors.error)){Text("Delete file")}})
    }
}
