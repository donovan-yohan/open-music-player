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
import com.soundq.android.data.timeline.TimelineContext
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
    val hasPhone=playback.queue.any {it.ref is com.soundq.android.playback.PlaybackRef.Device}
    val mixed=playback.source!=com.soundq.android.playback.PlaybackSource.Queue
    val route=remember(model,scope,playback.queueRevision,playback.connection,mixed) {
        if(mixed)null else model.controller.captureReorder {(scope?.let(model.graph.session::current)==true||model.graph.phoneAudio.current(accountEpoch))}
    }
    DisposableEffect(route) {onDispose {route?.close()}}
    var editorSelection by remember {mutableStateOf<String?>(null)}
    var showTimeline by remember {mutableStateOf(false)}
    val timelineVisible=showTimeline&&!hasPhone
    var sourceContext by remember {mutableStateOf(false)}
    val timeline by model.timeline.collectAsState()
    var preview by remember(model,accountEpoch) {mutableStateOf<ChronologicalTimeline?>(null)}
    var previewOwner by remember(model,accountEpoch) {mutableStateOf<Any?>(null)}
    val presentation=remember(TimelineDocumentIdentity(timeline.document),preview) {
        preview?.let {chronologicalTimeline(timeline.document,it)} ?: chronologicalTimeline(timeline.document)
    }
    val timelineViewport=remember(model,accountEpoch) {mutableStateOf(com.soundq.android.data.timeline.TimelineViewport(1,1f))}
    val timelineOverview=remember(model,accountEpoch){com.soundq.android.product.timeline.WaveformOverview()}
    val timelineSnap=remember(model,accountEpoch){mutableStateOf(com.soundq.android.data.timeline.SnapMode.Free)}
    val timelineList=rememberLazyListState()
    val arrangementList=rememberLazyListState()
    val expanded=remember(model,accountEpoch){mutableStateMapOf<String,Boolean>()}
    SideEffect {expanded.keys.retainAll(timeline.document.clips.map {it.occurrence}.toSet())}
    var editorReturnView by remember {mutableStateOf(false)}
    val alive=remember {java.util.concurrent.atomic.AtomicBoolean(true)}
    DisposableEffect(Unit){onDispose{alive.set(false)}}
    val valid:()->Boolean={alive.get()&&(scope?.let(model.graph.session::current)==true||model.graph.phoneAudio.current(accountEpoch))}
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
        if(!timelineVisible||playback.isPlaying) {model.controller.toggle();return}
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
                DropdownMenuItem(text={Text(if(sourceContext)"Return to arrangement" else "Listening queue")},onClick={
                    menu=false;gesture.cancel();preview=null
                    if(sourceContext) {sourceContext=false;showTimeline=editorReturnView}
                    else {editorReturnView=showTimeline;showTimeline=false;sourceContext=true}
                },enabled=!mixed&&timeline.context==TimelineContext.Supported)
                DropdownMenuItem(text={Text("Save queue as playlist")},onClick={menu=false;route?.close();onSave()},enabled=!mixed&&rows.isNotEmpty())
                DropdownMenuItem(text={Text("Undo queue change")},onClick={menu=false;model.controller.undo()},enabled=playback.canUndo)
                DropdownMenuItem(text={Text("Clear listening queue")},onClick={menu=false;gesture.cancel();queueMessage=null;clear=QueueClearCapture(playback)},enabled=!mixed&&rows.isNotEmpty()&&valid())
                if(mixed&&playback.arrangement!=null)DropdownMenuItem(text={Text("Return to source queue")},onClick={menu=false;preview=null;showTimeline=false;sourceContext=true;model.controller.returnToSources()})
            }
        }
    }) {
        Row(Modifier.fillMaxWidth()) {
            listOf("List","Waveforms").forEachIndexed {index,label ->
                Box(Modifier.weight(1f).heightIn(min=48.dp).semantics {selected=timelineVisible==(index==1)}
                    .clickable {gesture.cancel();preview=null;showTimeline=index==1;if(index==1)sourceContext=false},contentAlignment=Alignment.Center) {
                    Text(label,style=SoundQ.typography.caption,color=if(timelineVisible==(index==1))SoundQ.colors.primary else SoundQ.colors.muted)
                }
            }
        }
        SoundQDivider()
        if(!timelineVisible&&(sourceContext||timeline.context!=TimelineContext.Supported)&&!mixed)
            Text("Listening queue",Modifier.fillMaxWidth().padding(horizontal=20.dp,vertical=4.dp),style=SoundQ.typography.caption,color=SoundQ.colors.muted)
        Box(Modifier.weight(1f).fillMaxWidth()) {
            if(timelineVisible)com.soundq.android.product.timeline.TimelinePanel(model,editorSelection,{editorSelection=it},valid,onAdmission={timelineAdmission.set(it)},modifier=Modifier.fillMaxSize(),
                presentation=presentation,viewport=timelineViewport,overview=timelineOverview,snapState=timelineSnap,listState=timelineList,expanded=expanded.toMap(),onExpanded={id,value->expanded[id]=value},onPreviewDocument={base,candidate,owner->
                    if(model.timeline.value.document===base) {
                        if(candidate!=null&&valid()) {previewOwner=owner;preview=chronologicalTimeline(base,candidate)}
                        else if(previewOwner===owner) {preview=null;previewOwner=null}
                    }
                })
            else if(mixed||(!hasPhone&&!sourceContext&&timeline.context==TimelineContext.Supported))ArrangementQueueList(model,playback,presentation,scope,valid,{editorSelection=it;showTimeline=true;sourceContext=false},arrangementList)
            else SoundQOccurrenceQueue(rows,
                model.controller::select,{_,_->},model.controller::remove,modifier=Modifier.fillMaxSize(),revision=route ?: playback.connection,gestureState=gesture,
                onReorder={intent -> route?.move(intent.occurrence,intent.originalOrder,intent.to)==true},bounded=true,
                metadata={row->LibraryMetadataContent(memberDurationMetadata(row.durationMs))},artwork={occurrence->
                    val item=playback.queue.singleOrNull {it.occurrenceId==occurrence}
                    val rowValid={valid()&&model.playback.value.let {now->now.connection==playback.connection&&now.source==playback.source&&now.accountEpoch==playback.accountEpoch&&now.sessionIdentity==playback.sessionIdentity&&now.sourceQueueIncarnation==playback.sourceQueueIncarnation&&now.queue.singleOrNull {it.occurrenceId==occurrence}==item}}
                    val device=item?.ref as? com.soundq.android.playback.PlaybackRef.Device
                    if(device!=null)com.soundq.android.product.artwork.PhoneArtwork(model.graph,device,72.dp,rowValid)
                    else com.soundq.android.product.artwork.TrackArtwork(model.graph,scope,item?.trackId?.takeIf {it>0}?.let {model.graph.track(com.soundq.android.data.TrackId(it))},rowValid,
                        sourceOwner=listOf(playback.connection,playback.source,playback.accountEpoch,playback.sessionIdentity,playback.sourceQueueIncarnation,item))
                })
        }
        SoundQDivider()
        auditionMessage?.let {Text(it,Modifier.padding(horizontal=20.dp),style=SoundQ.typography.caption,color=SoundQ.colors.error)}
        queueMessage?.let {Text(it,Modifier.padding(horizontal=20.dp),style=SoundQ.typography.caption,color=SoundQ.colors.error)}
        SoundQCompactPlayer(playback.title ?: "Queue empty",playback.artist,playback.isPlaying,
            if(timelineVisible)playback.canAuditionArrangement||playback.isPlaying||playback.preparing else playback.canPlay,
            playback.preparing||auditionRequest!=null,onPlayer,::primaryAction,{gesture.cancel();preview=null;editorReturnView=showTimeline;showTimeline=false;sourceContext=true},
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

@Composable private fun ArrangementQueueList(model:ProductViewModel,playback:PlaybackProjection,presentation:ChronologicalTimeline,scope:com.soundq.android.data.AccountScope?,valid:()->Boolean,onEdit:(String)->Unit,listState:LazyListState) {
    val accepted=playback.arrangement
    val rows=arrangementQueueRows(presentation,accepted,playback.positionMs,accepted?.sources ?: playback.queue)
    val reduced=SoundQ.motion.reduced
    LazyColumn(Modifier.fillMaxSize().semantics {contentDescription="Arrangement tracks, ${rows.size} songs"},state=listState) {
        items(rows,key={it.occurrence}) {row->
            val rowValid={valid()&&model.timeline.value.document===presentation.base}
            val seekValid={rowValid()&&row.seekMs!=null&&accepted!=null&&model.playback.value.arrangement?.identity==accepted.identity&&model.playback.value.arrangement?.document==presentation.shown}
            var menu by remember(TimelineDocumentIdentity(presentation.base),accepted?.identity,row.occurrence){mutableStateOf(false)}
            Box(if(reduced)Modifier else Modifier.animateItem()) {
                SoundQMediaRow(row.title,row.artist,row.current||(accepted==null&&row.occurrence==playback.selectedOccurrence),
                    {if(seekValid())model.controller.seekArrangement(accepted!!.identity,row.seekMs!!) else if(rowValid())onEdit(row.occurrence)},{menu=true},enabled=rowValid(),
                    artwork={com.soundq.android.product.artwork.TrackArtwork(model.graph,scope,model.graph.track(com.soundq.android.data.TrackId(row.track)),rowValid,sourceOwner=presentation.base)},
                    metadata={LibraryMetadataContent(listOf(LibraryMetadataField("${queueTime(row.startMs)}–${queueTime(row.endMs)}","Arrangement position ${queueTime(row.startMs)} to ${queueTime(row.endMs)}")))})
                DropdownMenu(menu,{menu=false}) {
                    DropdownMenuItem(text={Text("Go to track")},onClick={menu=false;if(seekValid())model.controller.seekArrangement(accepted!!.identity,row.seekMs!!)},enabled=seekValid())
                    DropdownMenuItem(text={Text("Edit waveform")},onClick={menu=false;if(rowValid())onEdit(row.occurrence)},enabled=rowValid())
                }
            }
        }
    }
}
private fun queueTime(ms:Long):String {val seconds=ms/1000;return if(ms>=0)formatSongTime(ms) else "${seconds/60}:${(seconds%60).toString().padStart(2,'0')}"}
