package com.soundq.android.product

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import com.soundq.android.playback.PlaybackProjection
import com.soundq.designsystem.*

/** A one-shot confirmation over the observed queue, never over recording IDs alone. */
internal class QueueClearCapture(private val captured:PlaybackProjection) {
    private var active=true
    fun confirm(current:PlaybackProjection,valid:()->Boolean,clear:()->Unit):Boolean {
        if(!active)return false
        active=false
        if(!valid()||captured.queue.isEmpty()||current.connection!=PlaybackProjection.Connection.Connected||
            current.source!=com.soundq.android.playback.PlaybackSource.Queue||current.source!=captured.source||
            current.connection!=captured.connection||current.accountEpoch!=captured.accountEpoch||
            current.sessionIdentity!=captured.sessionIdentity||current.sourceQueueIncarnation!=captured.sourceQueueIncarnation||
            current.queueRevision!=captured.queueRevision||current.selectionIncarnation!=captured.selectionIncarnation||
            current.selectedOccurrence!=captured.selectedOccurrence||current.queue!=captured.queue)return false
        clear();return true
    }
}

/** Route and account incarnation are captured before gesture/animation work can delay a command. */
@Composable internal fun QueuePanel(model:ProductViewModel,playback:PlaybackProjection,accountEpoch:Long,onDismiss:()->Unit,onPlayer:()->Unit,onSave:()->Unit) {
    val scope=remember(model,accountEpoch) {model.graph.session.capture()}
    val mixed=playback.source!=com.soundq.android.playback.PlaybackSource.Queue
    val route=remember(model,scope,playback.queueRevision,playback.connection,mixed) {
        if(mixed)null else model.controller.captureReorder {scope!=null&&model.graph.session.current(scope)}
    }
    DisposableEffect(route) {onDispose {route?.close()}}
    var editorSelection by remember {mutableStateOf<String?>(null)}
    var showTimeline by remember {mutableStateOf(false)}
    val alive=remember {java.util.concurrent.atomic.AtomicBoolean(true)}
    DisposableEffect(Unit){onDispose{alive.set(false)}}
    val valid:()->Boolean={alive.get()&&scope!=null&&model.graph.session.current(scope)}
    val gesture=remember {QueueGestureState()}
    val timelineAdmission=remember {java.util.concurrent.atomic.AtomicReference<()->Boolean>({false})}
    var auditionRequest by remember {mutableStateOf<String?>(null)}
    var auditionMessage by remember {mutableStateOf<String?>(null)}
    DisposableEffect(Unit){onDispose{auditionRequest?.let(model.graph.timeline::retireAudition)}}
    fun primaryAction() {
        if(auditionRequest!=null) {
            auditionRequest?.let(model.graph.timeline::retireAudition);auditionRequest=null
            model.controller.pause();return
        }
        // A native install can still be waiting for its cursor ACK after the
        // custom-command receipt clears auditionRequest. That is Cancel, not a
        // Play toggle: playWhenReady may still be false during BUFFERING.
        if(playback.preparing) {model.controller.pause();return}
        if(!showTimeline||playback.isPlaying) {model.controller.toggle();return}
        val document=model.timeline.value.document
        if(playback.arrangement?.document==document) {model.controller.toggle();return}
        val admission=timelineAdmission.get()
        if(!playback.canAuditionArrangement||!valid()||!admission()) {
            auditionMessage="Arrangement playback unavailable";return
        }
        val captured=scope ?: return
        val request=model.graph.timeline.captureAudition(captured,document,admission) ?: return
        auditionMessage=null;auditionRequest=request
        model.controller.applyArrangement(document,request,{valid()&&admission()&&model.graph.timeline.accepts(captured,document)}) {accepted ->
            if(auditionRequest==request) {
                auditionRequest=null
                if(accepted==null){model.graph.timeline.retireAudition(request);if(valid())auditionMessage="Could not play arrangement"}
            }
        }
    }
    var menu by remember {mutableStateOf(false)}
    var clear by remember {mutableStateOf<QueueClearCapture?>(null)}
    var queueMessage by remember {mutableStateOf<String?>(null)}
    val rows=remember(playback.queue,playback.selectedOccurrence) {playback.queue.map {item -> QueueRowVisual(item.occurrenceId,item.title,item.artist,item.occurrenceId==playback.selectedOccurrence,item.durationMs)}}
    SoundQWorkspaceSheet("Queue",onDismiss,queueGesture=gesture,actions={
        Box {
            SoundQIconButton(SoundQIcon.More,"Queue actions",{menu=true},outlined=false)
            DropdownMenu(menu,{menu=false}) {
                DropdownMenuItem(text={Text("Save queue as playlist")},onClick={menu=false;route?.close();onSave()},enabled=!mixed&&rows.isNotEmpty())
                DropdownMenuItem(text={Text("Undo queue change")},onClick={menu=false;model.controller.undo()},enabled=playback.canUndo)
                DropdownMenuItem(text={Text("Clear listening queue")},onClick={menu=false;gesture.cancel();queueMessage=null;clear=QueueClearCapture(playback)},enabled=!mixed&&rows.isNotEmpty()&&valid())
                if(mixed&&playback.arrangement!=null)DropdownMenuItem(text={Text("Return to source queue")},onClick={menu=false;model.controller.returnToSources()})
            }
        }
    }) {
        Row(Modifier.fillMaxWidth()) {
            listOf("List","Waveforms").forEachIndexed {index,label ->
                Box(Modifier.weight(1f).heightIn(min=48.dp).semantics {selected=showTimeline==(index==1)}
                    .clickable {gesture.cancel();showTimeline=index==1},contentAlignment=Alignment.Center) {
                    Text(label,style=SoundQ.typography.caption,color=if(showTimeline==(index==1))SoundQ.colors.primary else SoundQ.colors.muted)
                }
            }
        }
        SoundQDivider()
        Box(Modifier.weight(1f).fillMaxWidth()) {
            if(showTimeline)com.soundq.android.product.timeline.TimelinePanel(model,editorSelection,{editorSelection=it},valid,onAdmission={timelineAdmission.set(it)},modifier=Modifier.fillMaxSize())
            else if(mixed)ArrangementQueueList(model,playback,scope,valid,{editorSelection=it;showTimeline=true})
            else SoundQOccurrenceQueue(rows,
                model.controller::select,{_,_->},model.controller::remove,modifier=Modifier.fillMaxSize(),revision=route ?: playback.connection,gestureState=gesture,
                onReorder={intent -> route?.move(intent.occurrence,intent.originalOrder,intent.to)==true},bounded=true,
                metadata={row->LibraryMetadataContent(memberDurationMetadata(row.durationMs))},artwork={occurrence->
                    val item=playback.queue.singleOrNull {it.occurrenceId==occurrence}
                    val rowValid={valid()&&model.playback.value.let {now->now.connection==playback.connection&&now.source==playback.source&&now.accountEpoch==playback.accountEpoch&&now.sessionIdentity==playback.sessionIdentity&&now.sourceQueueIncarnation==playback.sourceQueueIncarnation&&now.queue.singleOrNull {it.occurrenceId==occurrence}==item}}
                    com.soundq.android.product.artwork.TrackArtwork(model.graph,scope,item?.trackId?.let {model.graph.track(com.soundq.android.data.TrackId(it))},rowValid,
                        sourceOwner=listOf(playback.connection,playback.source,playback.accountEpoch,playback.sessionIdentity,playback.sourceQueueIncarnation,item))
                })
        }
        SoundQDivider()
        auditionMessage?.let {Text(it,Modifier.padding(horizontal=20.dp),style=SoundQ.typography.caption,color=SoundQ.colors.error)}
        queueMessage?.let {Text(it,Modifier.padding(horizontal=20.dp),style=SoundQ.typography.caption,color=SoundQ.colors.error)}
        SoundQCompactPlayer(playback.title ?: "Queue empty",playback.artist,playback.isPlaying,
            if(showTimeline)playback.canAuditionArrangement||playback.isPlaying||playback.preparing else playback.canPlay,
            playback.preparing||auditionRequest!=null,onPlayer,::primaryAction,{gesture.cancel();showTimeline=false},
            timing=compactSongTiming(playback),artwork={com.soundq.android.product.artwork.PlayerArtwork(model.graph,playback,72.dp,valid)})
    }
    clear?.let {capture->
        AlertDialog(onDismissRequest={clear=null},shape=androidx.compose.ui.graphics.RectangleShape,containerColor=SoundQ.colors.background,
            title={Text("Clear listening queue?")},text={Text("Playback stops. Library songs, downloads and server imports stay.")},
            confirmButton={SoundQButton("Clear queue",{
                clear=null
                if(!capture.confirm(model.playback.value,valid,model.controller::clear))queueMessage="Queue changed. Review it before clearing."
            })},dismissButton={SoundQButton("Keep queue",{clear=null},variant=SoundQButtonVariant.Secondary)})
    }
}

@Composable private fun ArrangementQueueList(model:ProductViewModel,playback:PlaybackProjection,scope:com.soundq.android.data.AccountScope?,valid:()->Boolean,onEdit:(String)->Unit) {
    val accepted=playback.arrangement
    if(accepted==null) {
        Box(Modifier.fillMaxSize().padding(SoundQ.spacing.gutter)) {SoundQFeedback("Track list unavailable",FeedbackKind.Empty,action="Return to listening queue",onAction=model.controller::returnToSources)}
        return
    }
    val rows=arrangementQueueRows(accepted,playback.positionMs)
    LazyColumn(Modifier.fillMaxSize().semantics {contentDescription="Arrangement tracks, ${rows.size} songs"}) {
        items(rows,key={it.occurrence}) {row->
            val rowValid={valid()&&model.playback.value.arrangement?.identity==accepted.identity&&model.playback.value.arrangement?.document==accepted.document}
            var menu by remember(accepted.identity,row.occurrence){mutableStateOf(false)}
            Box {
                SoundQMediaRow(row.title,row.artist,row.current,
                    {if(rowValid())model.controller.seekArrangement(accepted.identity,row.startMs)},{menu=true},enabled=rowValid(),
                    artwork={com.soundq.android.product.artwork.TrackArtwork(model.graph,scope,model.graph.track(com.soundq.android.data.TrackId(row.track)),rowValid,sourceOwner=accepted.identity to accepted.document)},
                    metadata={LibraryMetadataContent(listOf(LibraryMetadataField("${queueTime(row.startMs)}–${queueTime(row.endMs)}","Arrangement position ${queueTime(row.startMs)} to ${queueTime(row.endMs)}")))})
                DropdownMenu(menu,{menu=false}) {
                    DropdownMenuItem(text={Text("Go to track")},onClick={menu=false;if(rowValid())model.controller.seekArrangement(accepted.identity,row.startMs)},enabled=rowValid())
                    DropdownMenuItem(text={Text("Edit waveform")},onClick={menu=false;if(rowValid())onEdit(row.occurrence)},enabled=rowValid())
                }
            }
        }
    }
}
private fun queueTime(ms:Long):String {val seconds=ms/1000;return "${seconds/60}:${(seconds%60).toString().padStart(2,'0')}"}
