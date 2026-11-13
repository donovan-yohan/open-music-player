package com.soundq.android.product.timeline

import androidx.activity.compose.BackHandler
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.selectable
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.drawText
import androidx.compose.foundation.gestures.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.input.key.*
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.pointer.*
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.layout.LocalPinnableContainer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import com.soundq.android.data.TrackId
import com.soundq.android.data.timeline.*
import com.soundq.android.product.ProductViewModel
import com.soundq.android.product.ChronologicalTimeline
import com.soundq.android.product.chronologicalTimeline
import com.soundq.android.product.TimelineDocumentIdentity
import com.soundq.android.product.libraryRowMetadata
import com.soundq.android.product.LibraryMetadataKind
import com.soundq.android.playback.timelineSources
import com.soundq.android.playback.LiveSyncState
import com.soundq.designsystem.*
import kotlinx.coroutines.*
import soundq.design.generated.SoundQComposeTokens as T
import soundq.design.generated.SoundQSpectralTokens as S
import kotlin.math.*

internal data class WaveformCardGeometry(val bodyHeight:Float,val cardHeight:Float)
internal fun waveformCardGeometry(fontScale:Float,expanded:Boolean,contentHeight:Float):WaveformCardGeometry {
    val large=fontScale>1.15f
    val card=maxOf(if(expanded)if(large)100f else 60f else if(large)56f else 48f,contentHeight)
    return WaveformCardGeometry(maxOf(if(large)165f else 125f,8f+card+57f),card)
}
internal data class WaveformFeedbackGeometry(val bodyHeight:Float,val statusTop:Float?,val reasonTop:Float?,val traceTop:Float)
/** Measured feedback lives above a retained 57dp plot gap, not in the trace's text cell. */
internal fun waveformFeedbackGeometry(baseHeight:Float,identityBottom:Float,statusHeight:Float,reasonHeight:Float,traceHeight:Float):WaveformFeedbackGeometry {
    var next=identityBottom+4f
    val statusTop=if(statusHeight>0f)next.also {next+=statusHeight+4f} else null
    val reasonTop=if(reasonHeight>0f)next.also {next+=reasonHeight+4f} else null
    val hasFeedback=statusTop!=null||reasonTop!=null
    val bodyHeight=if(hasFeedback)maxOf(baseHeight,next-4f+57f+traceHeight) else maxOf(baseHeight,identityBottom+traceHeight+4f)
    return WaveformFeedbackGeometry(bodyHeight,statusTop,reasonTop,bodyHeight-traceHeight)
}

/** Follow the resolved app palette, including explicit Light on a dark OS. */
internal fun waveformPlotBacking(colors:SoundQColors):Color = if(colors.background.luminance()<0.5f)S.W10_SPECTRUM_DECK else Color.White

internal fun waveformGuideSegments(height:Float,x:Float,occlusions:List<androidx.compose.ui.geometry.Rect>):List<Pair<Float,Float>> {
    var y=0f
    return buildList {
        occlusions.filter {x>=it.left&&x<=it.right}.sortedBy {it.top}.forEach {rect->
            val top=rect.top.coerceIn(0f,height);val bottom=rect.bottom.coerceIn(0f,height)
            if(top>y)add(y to top)
            y=maxOf(y,bottom)
        }
        if(y<height)add(y to height)
    }
}

/** Observation is qualified by the panel's accepted document/playing deck, never a planned curve. */
internal fun waveformCardFacts(document:TimelineDocument,clip:TimelineClip,source:TempoSourceIdentity?,keyLabel:String?,observedEffectiveBpm:Double?,playheadMs:Long):List<String> {
    val held=heldPlaybackBpm(document,clip,source)
    val law=clip.tempoMap?.law
    val now=observedEffectiveBpm?.takeIf {it.isFinite()&&(law==null||playheadMs.toDouble()>=law.startMs&&playheadMs.toDouble()<law.endMs)}
    return listOfNotNull(
        held?.let {"Held ${java.math.BigDecimal.valueOf(it).setScale(2,java.math.RoundingMode.HALF_UP).toPlainString()} BPM"},
        keyLabel,
        now?.let {"Now ${java.math.BigDecimal.valueOf(it).setScale(1,java.math.RoundingMode.HALF_UP).stripTrailingZeros().toPlainString()} BPM"})
}

/** Host performs IO; visual lanes below receive immutable state and feature-owned actions. */
@Composable internal fun TimelinePanel(model:ProductViewModel,selected:String?,onSelect:(String)->Unit,valid:()->Boolean,onAdmission:((()->Boolean)->Unit)?=null,modifier:Modifier=Modifier,
    presentation:ChronologicalTimeline,onPreviewDocument:(TimelineDocument,TimelineDocument?,Any)->Unit,
    viewport:MutableState<TimelineViewport> = remember {mutableStateOf(TimelineViewport(1,1f))},listState:LazyListState=rememberLazyListState(),
    expanded:Map<String,Boolean> = emptyMap(),onExpanded:(String,Boolean)->Unit={_,_->},
    overview:WaveformOverview=remember {WaveformOverview()},snapState:MutableState<SnapMode> = remember {mutableStateOf(SnapMode.Free)}) {
    val state by model.timeline.collectAsState()
    if(state.context==TimelineContext.OrdinaryQueueTooLarge) {
        SideEffect {onAdmission?.invoke {false}}
        Box(modifier.fillMaxSize().padding(20.dp),contentAlignment=Alignment.CenterStart) {
            Text(state.message.orEmpty(),style=SoundQ.typography.caption)
        }
        return
    }
    val document=state.document
    val documentIdentity=TimelineDocumentIdentity(document)
    val chronology=chronologicalTimeline(document,presentation)
    val phasePreview=chronology.shown.takeUnless {it===document}
    val latestPreviewDocument by rememberUpdatedState(onPreviewDocument)
    DisposableEffect(document){onDispose {latestPreviewDocument(document,null,document)}}
    val playback by model.playback.collectAsState()
    val library by model.library.collectAsState()
    val notation by model.graph.keyNotationPreferences.state.collectAsState()
    val currentId=if(playback.arrangement!=null)null else playback.selectedOccurrence
    val observed=remember {mutableLongStateOf(0)}
    LaunchedEffect(model,document) {
        model.playback.collect {p ->
            val current=document.clips.firstOrNull {it.occurrence==p.selectedOccurrence}
            observed.longValue=if(p.arrangement!=null)p.positionMs else current?.globalAt(p.positionMs) ?: 0L
        }
    }
    val phaseWaves=remember {mutableStateMapOf<Long,TrackWaveform>()}
    LaunchedEffect(document.clips.map {it.track}){phaseWaves.keys.retainAll(document.clips.map {it.track}.toSet())}

    var phaseMovement by remember {mutableStateOf<TimelineEdit?>(null)}
    var snap by snapState
    var busy by remember {mutableStateOf(false)}
    val worker=rememberCoroutineScope()
    val scope=remember(model){model.graph.session.capture()}
    val live=remember {java.util.concurrent.atomic.AtomicBoolean(true)}
    DisposableEffect(Unit){onDispose{live.set(false)}}
    val lifecycle=androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    val lifecycleState by lifecycle.currentStateFlow.collectAsState()
    val lifetime=remember(lifecycle){ArrangementLifetime(lifecycle)}
    DisposableEffect(lifetime){lifecycle.addObserver(lifetime);onDispose{lifetime.close();lifecycle.removeObserver(lifetime)}}
    val admitted:()->Boolean=lifetime.capture {model.timeline.value.context==TimelineContext.Supported&&model.timeline.value.document===document&&lifecycleState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED)&&live.get()&&valid()&&scope?.let(model.graph.session::current)==true&&document.matchesOccurrences(model.playback.value.queue.map {it.occurrenceId to it.trackId})}
    SideEffect {onAdmission?.invoke(admitted)}
    // Waveform reads do not borrow a captured edit/Apply capability. Keys are
    // stable lifecycle + accepted source descriptors, never predicate identities or clocks.
    var readEpoch by remember(lifecycle){mutableLongStateOf(0)}
    DisposableEffect(lifecycle) {
        var resumed=lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED)
        val observer=androidx.lifecycle.LifecycleEventObserver {_,_ ->
            val next=lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED)
            if(resumed&&!next)readEpoch++
            resumed=next
        }
        lifecycle.addObserver(observer)
        onDispose {lifecycle.removeObserver(observer)}
    }
    val readSources=playback.timelineSources()
    val qualified=readSources!=null&&document.clips.map {Triple(it.occurrence,it.track,it.sourceDurationMs)}==readSources.map {Triple(it.occurrence,it.track,it.durationMs)}
    val readReady=lifecycleState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED)&&live.get()&&valid()&&scope?.let(model.graph.session::remoteCurrent)==true&&playback.accountEpoch==scope.epoch&&qualified
    val readAdmission=lifetime.capture {readReady&&live.get()&&valid()&&model.graph.session.remoteCurrent(scope)}
    val latestReadAdmission by rememberUpdatedState(readAdmission)
    val readKey=listOf(scope,readEpoch,lifecycleState,readReady,readSources,document.clips.map {Triple(it.occurrence,it.track,it.sourceDurationMs)})

    val traceBpms=remember(document,phaseWaves.toMap()) {document.clips.flatMap {c->
        val law=c.tempoMap?.law
        if(law!=null)listOf(law.startBpm,law.targetBpm) else listOfNotNull(heldPlaybackBpm(document,c,model.graph.timeline.tempoSource(c)))
    }}
    val traceRange=traceBpms.takeIf {it.isNotEmpty()}?.let {it.minOrNull()!! to it.maxOrNull()!!}
    var viewportMore by remember {mutableStateOf(false)}
    var bpmClip by remember {mutableStateOf<TimelineClip?>(null)}
    var bpmDocument by remember {mutableStateOf<TimelineDocument?>(null)}
    val bpmFocus=remember {mutableMapOf<String,FocusRequester>()}
    SideEffect {bpmFocus.keys.retainAll(document.clips.map {it.occurrence}.toSet())}
    var restoreBpmFocus by remember {mutableStateOf<String?>(null)}
    LaunchedEffect(restoreBpmFocus) {
        restoreBpmFocus?.let {id->withFrameNanos {};runCatching {bpmFocus[id]?.requestFocus()};restoreBpmFocus=null}
    }
    var bpmMessage by remember {mutableStateOf<String?>(null)}
    var timingClip by remember {mutableStateOf<TimelineClip?>(null)}
    var timingDocument by remember {mutableStateOf<TimelineDocument?>(null)}
    LaunchedEffect(documentIdentity) {
        if(bpmDocument!==document) {bpmClip=null;bpmDocument=null}
        if(timingDocument!==document) {timingClip=null;timingDocument=null}
    }
    var performanceMore by remember {mutableStateOf(false)}
    var fadeMore by remember {mutableStateOf(false)}
    suspend fun readTempoWave(clip:TimelineClip):TrackWaveform? {
        val attempt=readAdmission
        return withContext(Dispatchers.IO) {
            scope?.let {model.graph.timeline.waveform(it,TrackId(clip.track),clip.sourceDurationMs,valid={attempt()&&latestReadAdmission()})}
        }
    }
    // Fetch timing independently from lazy lane composition. Active overlaps cannot borrow visible rows.
    LaunchedEffect(readKey,document.revision) {
        if(readReady)coroutineScope {
            (tempoEditorOverlaps(document).flatMap {listOf(it.outgoing,it.incoming)}+document.clips.filter {it.occurrence==selected}).distinctBy {it.track}.map {clip->async(Dispatchers.IO) {
                val wave=try {readTempoWave(clip)}catch(cancel:CancellationException){throw cancel}catch(_:Exception){null}
                if(wave!=null&&latestReadAdmission())withContext(Dispatchers.Main) {phaseWaves[clip.track]=wave.copy(tiers=emptyList(),beats=emptyList(),downbeats=emptyList(),transients=emptyList())}
            }}.awaitAll()
        } else phaseWaves.clear()
    }
    var activeCancel by remember {mutableStateOf<(() -> Unit)?>(null)}
    val identityBounds=remember {mutableStateMapOf<String,androidx.compose.ui.geometry.Rect>()}
    var stackOrigin by remember {mutableStateOf(Offset.Zero)}
    LaunchedEffect(document,readKey,readReady) {
        if(!admitted()) {activeCancel?.invoke();latestPreviewDocument(document,null,document)}
    }
    var heldX by remember {mutableStateOf<Float?>(null)}
    var follow by remember {mutableStateOf(false)}
    val scrubPreview=remember {mutableStateOf<Long?>(null)}
    var scratchArmed by remember {mutableStateOf<String?>(null)}
    val scratchContact=remember {java.util.concurrent.atomic.AtomicReference<LiveScratchContact?>(null)}
    val installedIdentity=playback.arrangement?.identity
    fun retireContact(){scratchContact.getAndSet(null)?.retire()}
    DisposableEffect(installedIdentity,lifecycle) {
        val observer=androidx.lifecycle.LifecycleEventObserver {_,event->
            if(event==androidx.lifecycle.Lifecycle.Event.ON_PAUSE||event==androidx.lifecycle.Lifecycle.Event.ON_STOP) {
                retireContact();scratchArmed=null
            }
        }
        lifecycle.addObserver(observer)
        onDispose {retireContact();lifecycle.removeObserver(observer)}
    }
    LaunchedEffect(installedIdentity){retireContact();scratchArmed=null}
    val density=LocalDensity.current
    val edge=with(density){T.MOTION_QUEUE_EDGE_ZONE.toPx()}
    val speed=T.MOTION_QUEUE_EDGE_SCROLL_SPEED*density.density
    val duration=maxOf(1L,document.clips.maxOfOrNull {it.globalEndMs} ?: 1L)
    LaunchedEffect(duration){viewport.value=viewport.value.copy(durationMs=duration).pan(0f)}
    // One mounted frame-clock owner. It moves only the viewport, never advances audio time.
    LaunchedEffect(heldX,follow) {
        var previous=0L
        while(heldX!=null||follow) {
            withFrameNanos {now ->
                val dt=if(previous==0L)0f else ((now-previous)/1_000_000f).coerceAtMost(50f);previous=now
                val v=viewport.value;val x=heldX
                if(x!=null) {
                    val direction=when {x<edge ->-(1-x/edge).coerceIn(0f,1f);x>v.widthPx-edge ->((x-v.widthPx+edge)/edge).coerceIn(0f,1f);else->0f}
                    if(direction!=0f)viewport.value=v.pan(direction*speed*dt)
                } else if(follow) {
                    val px=v.x(observed.longValue)
                    if(px<0||px>v.widthPx*0.8f)viewport.value=v.pan(px-v.widthPx*0.25f)
                }
            }
        }
    }
    BackHandler(activeCancel!=null){activeCancel?.invoke()}
    Box(modifier.fillMaxSize()) {
      Column(Modifier.fillMaxSize().onPreviewKeyEvent {if(it.key==Key.Escape&&activeCancel!=null){activeCancel?.invoke();true}else false}) {
       Box(Modifier.weight(1f).fillMaxWidth().onGloballyPositioned {stackOrigin=it.positionInRoot()}) {
        Column(Modifier.fillMaxSize()) {
        if(document.clips.isEmpty()) {
            Box(Modifier.weight(1f).fillMaxWidth().padding(horizontal=20.dp),contentAlignment=Alignment.CenterStart) {
                Text("Track timing unavailable",style=SoundQ.typography.caption)
            }
        } else {
            TimelineRuler(viewport,observed,!busy,scrubPreview,onScrub={ms ->
                if(admitted()) {
                    val accepted=model.playback.value.arrangement
                    if(accepted!=null)model.controller.seekArrangement(accepted.identity,ms)
                    else {
                        val clip=document.clips.firstOrNull {it.globalStartMs<=ms&&it.globalEndMs>ms}
                        if(clip!=null)model.controller.seekOccurrence(clip.occurrence,clip.sourceAt(ms).coerceIn(clip.sourceInMs,clip.sourceOutMs))
                    }
                }
            })
            LazyColumn(Modifier.fillMaxWidth().weight(1f).semantics {
                contentDescription="Waveform timeline"
                horizontalScrollAxisRange=ScrollAxisRange(
                    value={viewport.value.offsetMs.toFloat()},
                    maxValue={(viewport.value.durationMs-viewport.value.visibleMs).coerceAtLeast(0).toFloat()})
            }.waveformViewportGestures(viewport) {activeCancel?.invoke()}.onSizeChanged {
                viewport.value=overview.update(viewport.value,chronology.clips,it.width.toFloat())
            },state=listState,userScrollEnabled=activeCancel==null) {
                items(chronology.clips,key={it.occurrence}) {shownClip ->
                    // Gesture keys and admission always retain the captured originals, never preview copies.
                    val clip=document.clips.single {it.occurrence==shownClip.occurrence}
                    // Keep the qualified preview visible until persistence publishes or refuses it.
                    var committing by remember(documentIdentity,clip){mutableStateOf(false)}
                    val bpmRequester=remember(clip.occurrence){FocusRequester()}
                    SideEffect {bpmFocus[clip.occurrence]=bpmRequester}
                    DisposableEffect(clip.occurrence,bpmRequester) {onDispose {
                        if(bpmFocus[clip.occurrence]===bpmRequester)bpmFocus.remove(clip.occurrence)
                    }}
                    var retry by remember(clip.track,clip.sourceDurationMs){mutableIntStateOf(0)}
                    val load by produceState<WaveformLoad>(WaveformLoad.Waiting,readKey,clip.track,clip.sourceDurationMs,retry) {
                        value=if(readReady)WaveformLoad.Loading else WaveformLoad.Waiting
                        val attemptAdmission=readAdmission
                        value=withContext(Dispatchers.IO) {
                            val ready={attemptAdmission()&&latestReadAdmission()}
                            loadWaveform(ready) {
                                scope?.let {model.graph.timeline.waveform(it,TrackId(clip.track),clip.sourceDurationMs,refresh=retry>0,valid=ready)}
                            }
                        }
                    }
                    // Do not retain old measured data across a read-lifetime retirement.
                    val wave=(load as? WaveformLoad.Loaded)?.wave?.takeIf {readReady}
                    val sourcePublished=phaseWaves[clip.track]
                    val acceptedTempoSource=remember(sourcePublished,wave,document) {model.graph.timeline.tempoSource(clip)}
                    LaunchedEffect(wave,readKey){if(wave==null)phaseWaves.remove(clip.track) else phaseWaves[clip.track]=wave.copy(tiers=emptyList(),beats=emptyList(),downbeats=emptyList(),transients=emptyList())}
                    val commit:(TimelineEdit)->Unit={edit ->
                        if(document.phaseLink?.contains(edit.original.occurrence)==true && edit.kind==EditKind.Placement) {
                            if(admitted()&&model.graph.timeline.preview(edit).accepted){phaseMovement=edit;timingDocument=document;timingClip=clip}
                        } else if(!busy&&admitted()) {
                            committing=true;busy=true;model.controller.pause()
                            worker.launch {try {withContext(Dispatchers.IO){model.graph.timeline.commit(edit,admitted)}}finally{committing=false;busy=false;latestPreviewDocument(document,null,clip)}}
                        }
                    }
                    TimelineLane(clip,document.revision,selected==clip.occurrence,clip.occurrence==currentId,wave,viewport,observed,snap,busy||!state.writable||load is WaveformLoad.Loading,
                        {onSelect(clip.occurrence)},{edit->if(admitted())model.graph.timeline.preview(edit) else EditDecision(false,"Arrangement changed. Try the edit again.")},commit,model.graph.timeline::window,
                        {cancel->activeCancel=cancel},{x->heldX=x}, {retry++},
                        phaseDocument=phasePreview ?: document,phaseIsPreview=phasePreview!=null,
                        onPhasePreview={edit ->if(!committing)latestPreviewDocument(document,edit?.let {model.graph.timeline.previewDocument(document,it,admitted)},clip)},
                        loadState=load,laneNumber=document.clips.indexOf(clip)+1,
                        onArrangement={timingDocument=document;timingClip=clip},onBpm={onSelect(clip.occurrence);bpmDocument=document;bpmClip=clip},bpmFocusRequester=bpmRequester,tempoSource=acceptedTempoSource,tempoRange=traceRange,
                        observedEffectiveBpm=playback.performanceDecks[clip.occurrence]?.takeIf {it.playing&&playback.arrangement?.document==document}?.effectiveBpm,scratch=installedIdentity?.let {identity->
                            val deck=playback.performanceDecks[clip.occurrence]
                            val isReference=playback.performanceDecks.values.any {it.syncReferenceOccurrence==clip.occurrence&&it.syncState!=LiveSyncState.Off}
                            val canGrab=playback.canPerformArrangement&&deck?.ready==true&&!isReference
                            WaveformScratch(scratchArmed==clip.occurrence,canGrab,
                                sourceRate=deck?.rate?.takeIf {it>0} ?: 1.0,
                                status=when {isReference->"Scratch Incoming or disable live sync";!canGrab->"Audition this occurrence first";deck?.scratching==true->"Scratch";deck?.syncState==LiveSyncState.Rejoining->"Rejoining";scratchArmed==clip.occurrence->"Scratch armed";else->"Ready"},
                                arm={retireContact();scratchArmed=if(scratchArmed==clip.occurrence)null else clip.occurrence},
                                begin={time->
                                    retireContact();follow=false;heldX=null
                                    val contact=LiveScratchContact(model.controller,identity,clip.occurrence) {
                                        valid()&&lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.RESUMED)&&model.playback.value.arrangement?.identity==identity
                                    }
                                    scratchContact.set(contact);contact.begin(time)
                                },
                                move={rate,time->scratchContact.get()?.move(rate,time)},
                                finish={time,cancel->scratchContact.getAndSet(null)?.finish(time,cancel)},
                                audibleSourceMs={model.playback.value.performanceDecks[clip.occurrence]?.sourcePositionMs})
                        },modifier=if(SoundQ.motion.reduced)Modifier else Modifier.animateItem(),captureKey=documentIdentity,
                        expanded=expanded[clip.occurrence] ?: false,onExpanded={onExpanded(clip.occurrence,it)},
                        artist=playback.queue.singleOrNull {it.occurrenceId==clip.occurrence}?.artist ?: model.graph.track(TrackId(clip.track))?.artist.orEmpty(),
                        keyLabel=libraryRowMetadata(0,library.analysis[TrackId(clip.track)],notation).singleOrNull {it.kind==LibraryMetadataKind.Key}?.display,
                        actionValid=admitted,onIdentityBounds={bounds->if(bounds==null)identityBounds.remove(clip.occurrence) else identityBounds[clip.occurrence]=bounds},
                        artwork={com.soundq.android.product.artwork.TrackArtwork(model.graph,scope,model.graph.track(TrackId(clip.track)),readAdmission,Modifier.fillMaxSize(),sourceOwner=documentIdentity to clip.occurrence)})
                }
            }
        }
        }
        TimelineGuides(viewport,observed,scrubPreview,phasePreview ?: document,phasePreview!=null,Modifier.matchParentSize(),identityBounds.values.map {it.translate(-stackOrigin)})
       }
        AutoBpmCrossfadeControl(document,!busy&&state.writable,busy,bpmMessage,{enabled->
            if(!busy&&admitted()) {
                busy=true;bpmMessage=null;model.controller.pause()
                worker.launch {try {
                    val sourceCaptures=withContext(Dispatchers.IO) {
                        val pairs=tempoEditorOverlaps(document)
                        val participants=pairs.flatMap {listOf(it.outgoing,it.incoming)}.distinctBy {it.occurrence}
                        participants.mapNotNull {clip->
                            if(enabled)readTempoWave(clip) ?: return@mapNotNull null
                            val source=model.graph.timeline.tempoSource(clip) ?: return@mapNotNull null
                            source to model.graph.timeline.captureTempoSources(listOf(source))
                        }
                    }
                    val ids=sourceCaptures.map {it.first}
                    if(admitted()&&model.graph.timeline.state.value.document===document) {
                        val capture={sourceCaptures.all {it.second()}}
                        val next=runCatching {document.withAutoBpmCrossfade(enabled,ids)}
                        if(next.isFailure)bpmMessage=next.exceptionOrNull()?.message else {
                            val accepted=withContext(Dispatchers.IO){model.graph.timeline.commit(TimelineTempoEdit(document,next.getOrThrow())){admitted()&&capture()}}
                            if(!accepted)bpmMessage=model.graph.timeline.state.value.message ?: "BPM change was refused. Refresh the sources and retry."
                        }
                    }
                }catch(cancel:CancellationException){throw cancel}catch(_:Exception){bpmMessage="Source unavailable. Retry Auto BPM crossfade."}finally{busy=false}}
            }
        })
        val toolInk=SoundQ.colors.text
        Row(Modifier.fillMaxWidth().height(48.dp).background(SoundQ.colors.surface),verticalAlignment=Alignment.CenterVertically) {
            TimelineTool("Zoom out",{viewport.value=viewport.value.zoom(0.5f,viewport.value.widthPx/2)},!busy) {
                Canvas(Modifier.size(20.dp)) {drawLine(toolInk,Offset(2.dp.toPx(),size.height/2),Offset(size.width-2.dp.toPx(),size.height/2),2.dp.toPx())}
            }
            TimelineTool("Zoom in",{viewport.value=viewport.value.zoom(2f,viewport.value.widthPx/2)},!busy) {SoundQIcon(SoundQIcon.Plus,null)}
            Text("${timelineTime(viewport.value.offsetMs)}–${timelineTime(viewport.value.offsetMs+viewport.value.visibleMs)}",Modifier.weight(1f).padding(horizontal=20.dp),style=SoundQ.typography.mono,maxLines=1,overflow=TextOverflow.Ellipsis)
            Box {
                TimelineTool("Timeline options",{viewportMore=true}) {SoundQIcon(SoundQIcon.More,null)}
                DropdownMenu(viewportMore,{viewportMore=false}) {
                    DropdownMenuItem({Text("Pan earlier")},{viewport.value=viewport.value.pan(-viewport.value.widthPx/2);viewportMore=false},enabled=!busy)
                    DropdownMenuItem({Text("Pan later")},{viewport.value=viewport.value.pan(viewport.value.widthPx/2);viewportMore=false},enabled=!busy)
                    DropdownMenuItem({Text(if(follow)"Stop following" else "Follow playhead")},{follow=!follow;viewportMore=false})
                    DropdownMenuItem({Text("Snap: ${snap.name}")},{snap=SnapMode.entries[(snap.ordinal+1)%SnapMode.entries.size];viewportMore=false},enabled=!busy)
                    DropdownMenuItem({Text("Volume crossfade")},{fadeMore=true;viewportMore=false})
                    DropdownMenuItem({Text("Live performance")},{performanceMore=true;viewportMore=false})
                    DropdownMenuItem({Text("Edit clip timing")},{timingDocument=document;timingClip=document.clips.firstOrNull {it.occurrence==selected} ?: document.clips.firstOrNull();viewportMore=false})
                    DropdownMenuItem({Text("Undo timing edit")},{if(admitted())worker.launch(Dispatchers.IO){model.graph.timeline.undo(admitted)};viewportMore=false},enabled=state.canUndo&&!busy)
                }
            }
        }
      }
    }
    if(fadeMore)SoundQSheet("Volume crossfade",{fadeMore=false}) {
        TimelineFadeControls(model,document,admitted,{busy=it},busy)
    }
    if(performanceMore)SoundQSheet("Live performance",{performanceMore=false}) {
        LiveSyncControls(model,phaseWaves,admitted)
        LinkedPhaseControls(document,phaseWaves,busy,state.canUndo,admitted,model.graph.timeline::preview,
            {model.graph.timeline.commit(it,admitted)},{model.graph.timeline.commit(it,admitted)},
            {model.graph.timeline.unlock(it,admitted)},{model.graph.timeline.undo(admitted)},phaseMovement,
            {phaseMovement=null},{latestPreviewDocument(document,it,document)},{busy=it})
    }
    bpmClip?.let {clip->
        key(clip.occurrence) {
            WaveformBpmEditor(bpmDocument ?: document,clip,model.graph.timeline,scope,admitted,::readTempoWave,{bpmClip=null;restoreBpmFocus=clip.occurrence},onBeforeSave={model.controller.pause()},controller=model.controller)
        }
    }
    timingClip?.let {held->
        val clip=document.clips.singleOrNull {it.occurrence==held.occurrence}
        if(clip!=null)SoundQSheet("Clip timing",{timingClip=null;restoreBpmFocus=clip.occurrence}) {
            Text(clip.title,style=SoundQ.typography.title)
            TimingInspector(clip,document.revision,busy,phaseWaves[clip.track]) {edit->
                if(!busy&&admitted()) {
                    busy=true;model.controller.pause()
                    worker.launch {try {withContext(Dispatchers.IO){model.graph.timeline.commit(edit,admitted)}}finally{busy=false}}
                }
            }
            state.message?.let {Text(it,color=SoundQ.colors.error,style=SoundQ.typography.caption)}
        }
    }
}

private fun timelineTime(ms:Long):String {
    return formatSongTime(ms)
}

/** Full 48dp target with native indication/focus semantics; glyph padding is not a cell gap. */
@Composable private fun TimelineTool(label:String,onClick:()->Unit,enabled:Boolean=true,state:String?=null,content:@Composable ()->Unit) {
    Box(Modifier.size(48.dp).semantics {contentDescription=label;if(state!=null)stateDescription=state}
        .clickable(enabled=enabled,role=Role.Button,onClick=onClick),contentAlignment=Alignment.Center) {content()}
}

@Composable private fun TimelineRuler(viewport:MutableState<TimelineViewport>,playhead:State<Long>,enabled:Boolean,previewState:MutableState<Long?>,onScrub:(Long)->Unit) {
    var preview by previewState
    val colors=SoundQ.colors
    val v=viewport.value
    val measurer=rememberTextMeasurer()
    val textStyle=SoundQ.typography.mono.copy(color=colors.muted)
    Canvas(Modifier.fillMaxWidth().height(48.dp).background(colors.surface)
        .semantics {contentDescription="Global timeline ruler";customActions=listOf(
            CustomAccessibilityAction("Seek one second earlier"){onScrub((playhead.value-1000).coerceAtLeast(0));true},
            CustomAccessibilityAction("Seek one second later"){onScrub(playhead.value+1000);true})}
        .pointerInput(v,enabled){if(enabled)detectDragGestures(onDragStart={preview=v.time(it.x).coerceIn(0,v.durationMs)},onDragCancel={preview=null},onDragEnd={preview?.let(onScrub);preview=null}) {change,_->change.consume();preview=v.time(change.position.x).coerceIn(0,v.durationMs)}}) {
        val step=maxOf(1000L,(v.visibleMs/4/1000)*1000)
        var tick=(v.offsetMs/step)*step
        while(tick<=v.offsetMs+v.visibleMs){
            val x=v.x(tick)
            drawLine(colors.border,Offset(x,size.height-10.dp.toPx()),Offset(x,size.height),1f)
            val label=measurer.measure(timelineTime(tick),textStyle)
            if(x>=0f&&x+label.size.width+4.dp.toPx()<=size.width)drawText(label,topLeft=Offset(x+4.dp.toPx(),8.dp.toPx()))
            tick+=step
        }
        drawLine(colors.border,Offset(0f,size.height-1f),Offset(size.width,size.height-1f),1f)
    }
}

/** One shared axis across ruler and lanes. Identity glyph regions mask only paint, never input. */
@Composable internal fun TimelineGuides(viewport:State<TimelineViewport>,playhead:State<Long>,preview:State<Long?>,document:TimelineDocument,phaseIsPreview:Boolean,modifier:Modifier,occlusions:List<androidx.compose.ui.geometry.Rect> = emptyList()) {
    val ink=SoundQ.colors.playhead
    Canvas(modifier.semantics {contentDescription="Shared timeline playhead"}) {
        val v=viewport.value
        val x=v.x(preview.value ?: playhead.value)
        if(x in 0f..size.width)waveformGuideSegments(size.height,x,occlusions).forEach {(top,bottom)->drawLine(ink,Offset(x,top),Offset(x,bottom),2f)}
        val link=document.phaseLink
        val guide=link?.guide(document.clips)
        // Shared linked guide consuming paint.
        link?.let {
            val linkedX=v.x(guide!!)
            if(linkedX in 0f..size.width)waveformGuideSegments(size.height,linkedX,occlusions).forEach {(top,bottom)->
                drawLine(if(phaseIsPreview)S.W10_COLOR_LOCK_PREVIEW else S.W10_COLOR_LOCK_ACCEPTED,Offset(linkedX,top),Offset(linkedX,bottom),2.dp.toPx(),
                    pathEffect=if(phaseIsPreview)androidx.compose.ui.graphics.PathEffect.dashPathEffect(floatArrayOf(6.dp.toPx(),4.dp.toPx()))else null)
            }
        }
        // End shared linked guide consuming paint.
    }
}

/** A stack-level two-contact owner sees fingers on different occurrence lanes.
 * Single-contact input remains with the lane editor or the LazyColumn scroll owner.
 */
@Composable internal fun Modifier.waveformViewportGestures(viewport:MutableState<TimelineViewport>,onTransform:()->Unit={}):Modifier {
    val begin by rememberUpdatedState(onTransform)
    return pointerInput(viewport) {
        awaitEachGesture {
            awaitFirstDown(requireUnconsumed=false,pass=PointerEventPass.Initial)
            var transforming=false
            while(true) {
                val event=awaitPointerEvent(PointerEventPass.Initial)
                val pressed=event.changes.count {it.pressed}
                if(pressed>=2) {
                    if(!transforming){begin();transforming=true}
                    val center=event.calculateCentroid(useCurrent=false)
                    viewport.value=viewport.value.zoom(event.calculateZoom(),center.x).pan(-event.calculatePan().x)
                }
                // After promotion, no surviving finger may resume its old edit or click.
                if(transforming)event.changes.forEach {it.consume()}
                if(pressed==0)break
            }
        }
    }
}

/** Pure state-in/action-out lane. No JSON, network, decode, player or clocks in draw. */
@Composable internal fun TimelineLane(clip:TimelineClip,revision:Long,selected:Boolean,current:Boolean,wave:TrackWaveform?,viewport:MutableState<TimelineViewport>,playhead:State<Long>,snap:SnapMode,busy:Boolean,
    onSelect:()->Unit,validate:(TimelineEdit)->EditDecision,commit:(TimelineEdit)->Unit,window:(TrackWaveform,Long,Long,Int)->PeakWindow,
    onActive:((()->Unit)?)->Unit,onHeld:(Float?)->Unit,onRetry:()->Unit,
    phaseDocument:TimelineDocument?=null,phaseIsPreview:Boolean=false,onPhasePreview:(TimelineEdit?)->Unit={},
    loadState:WaveformLoad=if(wave?.tiers?.isNotEmpty()==true)WaveformLoad.Loaded(wave) else WaveformLoad.Unavailable,
    laneNumber:Int=1,bodyHeight:Dp=125.dp,onArrangement:()->Unit={},scratch:WaveformScratch?=null,onBpm:(()->Unit)?=null,tempoSource:TempoSourceIdentity?=null,tempoRange:Pair<Double,Double>?=null,observedEffectiveBpm:Double?=null,bpmFocusRequester:FocusRequester?=null,modifier:Modifier=Modifier,
    captureKey:Any=revision,expanded:Boolean?=null,onExpanded:((Boolean)->Unit)?=null,artist:String="",keyLabel:String?=null,actionValid:()->Boolean={true},artwork:(@Composable ()->Unit)?=null,
    onIdentityBounds:(androidx.compose.ui.geometry.Rect?)->Unit={}) {
    val latestCommit by rememberUpdatedState(commit)
    val latestValidate by rememberUpdatedState(validate)
    val latestSelected by rememberUpdatedState(selected)
    val latestPhaseDocument by rememberUpdatedState(phaseDocument)
    val latestPhasePreview by rememberUpdatedState(onPhasePreview)
    val latestScratch by rememberUpdatedState(scratch)
    val gesture=remember(captureKey,clip){TimelineGesture({latestValidate(it)},{latestCommit(it)})}
    var preview by remember(gesture){mutableStateOf<TimelineEdit?>(null)}
    var reason by remember(gesture){mutableStateOf<String?>(null)}
    var activePointer by remember(gesture){mutableStateOf(false)}
    fun cancel(){activePointer=false;gesture.cancel();preview=null;latestPhasePreview(null);onHeld(null);onActive(null)}
    DisposableEffect(gesture){onDispose{
        if(gesture.active||activePointer){latestPhasePreview(null);onHeld(null);onActive(null)}
        gesture.cancel()
    }}
    val shown=phaseDocument?.takeIf {phaseIsPreview}?.clips?.firstOrNull {it.occurrence==clip.occurrence} ?: preview?.takeIf {gesture.decision.accepted}?.let {edit ->
        if(phaseDocument?.phaseLink?.contains(clip.occurrence)==true)phaseDocument.clips.single {it.occurrence==clip.occurrence} else edit.candidate()
    } ?: phaseDocument?.clips?.firstOrNull {it.occurrence==clip.occurrence} ?: clip
    val v=viewport.value
    val colors=SoundQ.colors
    val reduced=SoundQ.motion.reduced
    val border by key(colors) {animateColorAsState(if(reason!=null)colors.error else if(selected)colors.primary else colors.border,tween(if(reduced)T.MOTION_DURATION_REDUCED else T.MOTION_DURATION_SETTLE),label="laneSelection")}
    val density=LocalDensity.current
    val slop=with(density){T.MOTION_GESTURE_SLOP.toPx()}
    val target=with(density){T.COMPONENT_ARRANGEMENT_CLIP_TARGET_MIN.toPx()}
    var showMore by remember(captureKey,clip.occurrence){mutableStateOf(false)}
    var disclosureBounds by remember {mutableStateOf<androidx.compose.ui.geometry.Rect?>(null)}
    var moreBounds by remember {mutableStateOf<androidx.compose.ui.geometry.Rect?>(null)}
    var rowOrigin by remember {mutableStateOf(Offset.Zero)}
    val pinnable=LocalPinnableContainer.current
    val label=clip.title
    var localExpanded by remember(clip.occurrence){mutableStateOf(false)}
    val isExpanded=expanded ?: localExpanded
    val latestActionValid by rememberUpdatedState(actionValid)
    val latestIdentityBounds by rememberUpdatedState(onIdentityBounds)
    DisposableEffect(captureKey,clip.occurrence){onDispose {latestIdentityBounds(null)}}
    val actionLife=remember(captureKey){java.util.concurrent.atomic.AtomicBoolean(true)}
    DisposableEffect(actionLife){onDispose {actionLife.set(false)}}
    fun canAct()=actionLife.get()&&latestActionValid()
    val moreFocus=bpmFocusRequester ?: remember(clip.occurrence){FocusRequester()}
    fun closeMenu(){showMore=false;runCatching {moreFocus.requestFocus()}}
    val identityState=listOfNotNull(if(selected)"Selected" else null,if(current)"Current" else null,if(phaseDocument?.phaseLink?.reference==clip.occurrence)"Reference" else null,scratch?.takeIf {it.armed}?.status).joinToString(" · ")
    val availability=when {
        wave?.tiers?.isNotEmpty()==true->"Loaded"
        loadState is WaveformLoad.Loading->"Loading"
        loadState is WaveformLoad.Waiting->"Waiting"
        else->"Unavailable"
    }
    val sourceStart=shown.sourceAt(maxOf(shown.globalStartMs,v.offsetMs)).coerceIn(shown.sourceInMs,shown.sourceOutMs)
    val sourceEnd=shown.sourceAt(minOf(shown.globalEndMs,v.offsetMs+v.visibleMs)).coerceIn(shown.sourceInMs,shown.sourceOutMs)
    val peaks=remember(wave,shown,sourceStart,sourceEnd,v.widthPx,v.pixelsPerSecond) {
        if(wave!=null&&sourceEnd>sourceStart)window(wave,sourceStart,sourceEnd,spectralWindowColumns(shown,v)) else null
    }
    val paint=remember(peaks,shown,v){projectSpectralWaveform(peaks,shown,v)}
    // Fixed complete row: identity overlays paint, never reserves another strip.
    BoxWithConstraints(modifier.fillMaxWidth().onGloballyPositioned {rowOrigin=it.positionInRoot()}) {
      val facts=waveformCardFacts(phaseDocument ?: TimelineDocument(clips=listOf(clip)),shown,tempoSource ?: wave?.let {qualifiedTempoSource(clip,it)},keyLabel,
          observedEffectiveBpm.takeUnless {phaseIsPreview||preview!=null},playhead.value)
      val measurer=rememberTextMeasurer()
      val titleStyle=SoundQ.typography.title
      val artistStyle=SoundQ.typography.caption
      val factStyle=SoundQ.typography.mono
      val contentWidth=with(density){(maxWidth-152.dp).coerceAtLeast(1.dp).roundToPx()}
      val stackFacts=density.fontScale>1.15f||facts.sumOf {measurer.measure(it,factStyle).size.width}+with(density){8.dp.roundToPx()}>contentWidth
      val contentHeight=with(density){(measurer.measure("Ag",titleStyle).size.height+
          (if(isExpanded&&artist.isNotBlank())measurer.measure("Ag",artistStyle).size.height else 0)+
          (if(isExpanded&&facts.isNotEmpty())if(stackFacts)facts.sumOf {measurer.measure(it,factStyle,constraints=androidx.compose.ui.unit.Constraints(maxWidth=contentWidth)).size.height} else facts.maxOf {measurer.measure(it,factStyle).size.height} else 0)).toDp().value}
      val geometry=waveformCardGeometry(density.fontScale,isExpanded,contentHeight)
      val cardHeight by animateDpAsState(geometry.cardHeight.dp,tween(if(reduced)0 else T.MOTION_DURATION_SETTLE),label="waveformDisclosure")
      val status=if(wave?.tiers?.isNotEmpty()==true)null else when(loadState) {
          WaveformLoad.Loading->"Loading waveform…"
          WaveformLoad.Waiting->"Waiting for source"
          is WaveformLoad.Failed->loadState.message
          else->"Waveform unavailable"
      }
      val statusWidth=with(density){(maxWidth-40.dp).coerceAtLeast(1.dp).roundToPx()}
      fun feedbackHeight(text:String?)=text?.let {with(density){measurer.measure(it,artistStyle,constraints=androidx.compose.ui.unit.Constraints(maxWidth=statusWidth)).size.height.toDp().value}} ?: 0f
      val trace=if(onBpm!=null)waveformTempoTraceLayout(shown,tempoSource ?: wave?.let {qualifiedTempoSource(clip,it)},v,with(density){maxWidth.toPx()}) else null
      val traceHeight=trace?.let {with(density){it.labels.height.toDp().value}} ?: 0f
      val feedback=waveformFeedbackGeometry(maxOf(bodyHeight.value,geometry.bodyHeight),8f+maxOf(cardHeight.value,geometry.cardHeight),feedbackHeight(status),feedbackHeight(reason),traceHeight)
      val animatedBody by animateDpAsState(feedback.bodyHeight.dp,tween(if(reduced)0 else T.MOTION_DURATION_SETTLE),label="waveformBody")
      // Growth must be available on the first feedback frame; a tween must not reintroduce overlap.
      val actualBody=maxOf(animatedBody,feedback.bodyHeight.dp)
      Box(Modifier.fillMaxWidth().height(actualBody)) {
        val link=phaseDocument?.phaseLink
        val grid=when(clip.occurrence){link?.reference->link.referenceGrid;link?.incoming->link.incomingGrid;else->null}
        val ticks=remember(shown,v,grid,wave){phaseTicks(shown,v,grid,wave)}
        Box(Modifier.matchParentSize().background(waveformPlotBacking(colors)).onSizeChanged {if(viewport.value.widthPx!=it.width.toFloat())viewport.value=viewport.value.copy(widthPx=it.width.toFloat()).pan(0f)}
            .semantics {this[SemanticsProperties.ContentDescription]=listOf("Waveform ${clip.occurrence}",label)+listOf(identityState).filter {it.isNotEmpty()};stateDescription=availability+" · "+if(preview!=null)"Preview timing edit" else "Accepted timing";this.selected=selected;customActions=listOf(CustomAccessibilityAction("Select for editing"){onSelect();true},CustomAccessibilityAction("Edit timing"){onSelect();showMore=true;true})}
            .pointerInput(captureKey,clip,revision,busy,snap,wave,scratch?.armed,scratch?.ready) {
                awaitEachGesture {
                    val down=awaitFirstDown(requireUnconsumed=false)
                    // Only explicit action cells exclude a body down. Identity is
                    // read-only paint; a captured drag can cross every overlay.
                    if(disclosureBounds?.contains(down.position)==true||moreBounds?.contains(down.position)==true||down.isConsumed)return@awaitEachGesture
                    val initial=viewport.value;val origin=down.position
                    val capturedRowOrigin=rowOrigin
                    val rootOrigin=origin+capturedRowOrigin
                    val capturedScratch=latestScratch?.takeIf {it.armed&&!busy}
                    if(capturedScratch!=null) {
                        val stamp=down.uptimeMillis*1_000_000L
                        if(!capturedScratch.ready||!capturedScratch.begin(stamp))return@awaitEachGesture
                        val stroke=VinylStroke(capturedScratch.sourceRate/initial.pixelsPerSecond)
                        stroke.begin(origin.x,stamp);down.consume()
                        var normalUp=false
                        var terminated=false
                        var terminal=stamp
                        try {
                            while(true) {
                                val event=awaitPointerEvent()
                                val change=event.changes.firstOrNull {it.id==down.id} ?: break
                                terminal=change.uptimeMillis*1_000_000L
                                // ACTION_CANCEL may arrive as a consumed all-up packet.
                                if(change.isConsumed)break
                                if(event.changes.count {it.pressed}>1) {
                                    // Retire audio contact before any two-finger
                                    // viewport action. No regrab until all are up.
                                    capturedScratch.finish(terminal,true);terminated=true
                                    event.changes.forEach {it.consume()}
                                    while(true) {
                                        val zoomEvent=awaitPointerEvent()
                                        val pressed=zoomEvent.changes.count {it.pressed}
                                        if(pressed>=2) {
                                            viewport.value=viewport.value.zoom(zoomEvent.calculateZoom(),zoomEvent.calculateCentroid().x).pan(-zoomEvent.calculatePan().x)
                                        }
                                        zoomEvent.changes.forEach {it.consume()}
                                        if(pressed==0)break
                                    }
                                    break
                                }
                                if(!change.pressed){normalUp=true;change.consume();break}
                                for(sample in change.historical)stroke.move(sample.position.x,sample.uptimeMillis*1_000_000L)?.let {capturedScratch.move(it,sample.uptimeMillis*1_000_000L)}
                                stroke.move(change.position.x,terminal)?.let {capturedScratch.move(it,terminal)}
                                change.consume()
                            }
                        } finally {stroke.end();if(!terminated)capturedScratch.finish(terminal,!normalUp)}
                        return@awaitEachGesture
                    }
                    val left=initial.x(clip.globalStartMs);val right=initial.x(clip.globalEndMs)
                    val kind=when {
                        busy ->null
                        latestSelected&&right-left>=target*3&&abs(origin.x-left)<target/2 ->EditKind.TrimIn
                        latestSelected&&right-left>=target*3&&abs(origin.x-right)<target/2 ->EditKind.TrimOut
                        origin.x in left..right ->EditKind.Placement
                        else ->null
                    }
                    var accepted=false;var editing=false;var pinch=false;var previous=rootOrigin;var total=Offset.Zero
                    var pin:androidx.compose.ui.layout.PinnableContainer.PinnedHandle?=null
                    try {
                        while(true) {
                            val event=awaitPointerEvent()
                            // A parent transform owner or platform ACTION_CANCEL retires this contact.
                            if(event.changes.any {it.isConsumed}){cancel();break}
                            val pressed=event.changes.filter {it.pressed}
                            if(pressed.size>=2) {
                                if(!pinch){cancel();pinch=true}
                                val zoom=event.calculateZoom();val center=event.calculateCentroid();val pan=event.calculatePan()
                                viewport.value=viewport.value.zoom(zoom,center.x).pan(-pan.x);event.changes.forEach {it.consume()};continue
                            }
                            val change=event.changes.firstOrNull {it.id==down.id} ?: break
                            if(!change.pressed){if(accepted&&activePointer&&editing&&!pinch&&kind!=null)gesture.finish() else {gesture.cancel();if(!accepted&&!pinch&&!busy)onSelect()};preview=null;onHeld(null);onActive(null);break}
                            if(pinch)continue
                            if(accepted&&!activePointer)break
                            val rootPosition=change.position+rowOrigin
                            val delta=rootPosition-previous;previous=rootPosition;total+=delta
                            if(!accepted) {
                                if(abs(total.y)>slop&&abs(total.y)>abs(total.x)*T.MOTION_GESTURE_AXIS_RATIO)break
                                if(abs(total.x)<=slop||abs(total.x)<=abs(total.y)*T.MOTION_GESTURE_AXIS_RATIO)continue
                                // Ordinary horizontal motion navigates, even over a loaded clip.
                                // Edge trims stay direct; placement requires a deliberate hold then drag.
                                editing=kind!=null&&(kind!=EditKind.Placement||change.uptimeMillis-down.uptimeMillis>=viewConfiguration.longPressTimeoutMillis)
                                accepted=true;activePointer=true
                                if(editing){pin=pinnable?.pin();onSelect();onActive(::cancel);gesture.begin(revision,clip,kind!!)}
                            }
                            change.consume()
                            if(!editing)viewport.value=viewport.value.pan(-delta.x)
                            else if(kind!=null) {
                                val axisX=rootPosition.x-capturedRowOrigin.x
                                onHeld(axisX)
                                val globalDelta=viewport.value.time(axisX)-initial.time(origin.x)
                                val raw=when(kind) {
                                    EditKind.Placement->clip.globalStartMs+globalDelta
                                    EditKind.TrimIn->clip.sourceInMs+clip.rates.sourceDelta(clip.globalStartMs,clip.globalStartMs+globalDelta)
                                    EditKind.TrimOut->clip.sourceOutMs+clip.rates.sourceDelta(clip.globalEndMs,clip.globalEndMs+globalDelta)
                                }
                                gesture.update(if(latestPhaseDocument?.phaseLink?.contains(clip.occurrence)==true)raw else snapEditValue(clip,kind,raw,snap,wave));preview=gesture.preview;reason=gesture.decision.reason
                                latestPhasePreview(preview?.takeIf {gesture.decision.accepted})
                            }
                        }
                    } finally {pin?.release();gesture.cancel();preview=null;latestPhasePreview(null);onHeld(null);onActive(null)}
                }
            }) {
            Canvas(Modifier.matchParentSize()) {
                clipRect {
                    val left=v.x(shown.globalStartMs);val right=v.x(shown.globalEndMs)
                    // Cached signed spectral columns; draw only scales amplitude, no color/geometry preparation.
                    for(column in paint.columns) {
                        val top=size.height/2-column.maximum*size.height*0.42f
                        val bottom=size.height/2-column.minimum*size.height*0.42f
                        drawRect(column.color,Offset(column.left,top),androidx.compose.ui.geometry.Size(column.right-column.left,maxOf(1f,bottom-top)))
                    }
                    if(latestSelected&&latestScratch?.armed!=true&&right-left>=target*3){drawLine(colors.primary,Offset(left,0f),Offset(left,size.height),4f);drawLine(colors.primary,Offset(right,0f),Offset(right,size.height),4f)}
                    // Linked tick and guide consuming paint, extracted for host regression.
                    for(tick in ticks) {
                        val length=when {tick.downbeat->S.W10_TICK_DOWNBEAT_LENGTH;tick.group==32->S.W10_TICK_GROUP32_LENGTH;tick.group==16->S.W10_TICK_GROUP16_LENGTH;tick.group==4->S.W10_TICK_GROUP4_LENGTH;else->S.W10_TICK_BEAT_LENGTH}
                        val weight=when {tick.downbeat->S.W10_TICK_DOWNBEAT_WEIGHT;tick.group==32->S.W10_TICK_GROUP32_WEIGHT;tick.group==16->S.W10_TICK_GROUP16_WEIGHT;tick.group==4->S.W10_TICK_GROUP4_WEIGHT;else->S.W10_TICK_BEAT_WEIGHT}
                        val x=v.x(tick.globalMs);val y=length.toPx()
                        val ink=if(tick.downbeat)S.W10_COLOR_DOWNBEAT else if(colors.background.luminance()<0.5f)colors.muted else colors.border
                        drawLine(ink,Offset(x,0f),Offset(x,y),weight.toPx())
                        if(tick.downbeat){
                            drawLine(ink,Offset(x-3.dp.toPx(),y-3.dp.toPx()),Offset(x,y),weight.toPx())
                            drawLine(ink,Offset(x+3.dp.toPx(),y-3.dp.toPx()),Offset(x,y),weight.toPx())
                        }
                    }

                    // End linked consuming paint.
                }
            }
            // Progress reads in draw phase, isolated from waveform path generation and metadata.
            Canvas(Modifier.matchParentSize()) {
                latestScratch?.takeIf {it.armed}?.audibleSourceMs?.invoke()?.let {source ->
                    val x=v.x(clip.globalAt(source.toLong()))
                    if(x in 0f..size.width) {
                        drawLine(colors.text,Offset(x,0f),Offset(x,size.height),1.dp.toPx())
                        drawCircle(colors.text,3.dp.toPx(),Offset(x,4.dp.toPx()))
                    }
                }
                if(selected||reason!=null)drawRect(border,style=androidx.compose.ui.graphics.drawscope.Stroke(width=2.dp.toPx()))
                drawLine(colors.border,Offset(0f,size.height-1f),Offset(size.width,size.height-1f),1f)
            }
            status?.let {Text(it,Modifier.fillMaxWidth().padding(horizontal=20.dp).offset(y=feedback.statusTop!!.dp),style=artistStyle,color=colors.muted)}
            reason?.let {Text(it,Modifier.fillMaxWidth().padding(horizontal=20.dp).offset(y=feedback.reasonTop!!.dp).background(colors.surface),color=colors.error,style=artistStyle)}
        }
        trace?.let {WaveformTempoTrace(shown,it,Modifier.align(Alignment.BottomStart),bpmRange=tempoRange)}
        Row(Modifier.align(Alignment.TopStart).fillMaxWidth().padding(8.dp),verticalAlignment=Alignment.Top) {
            // Card paint has no input modifier. Artwork and words remain in the lane's hit plane.
            Row(Modifier.weight(1f).height(cardHeight).background(colors.surface),verticalAlignment=Alignment.Top) {
                Box(Modifier.padding(start=8.dp,top=12.dp).size(24.dp)) {
                    if(artwork!=null)artwork() else SoundQArtworkSlot(Modifier.fillMaxSize(),24.dp)
                }
                Column(Modifier.weight(1f).fillMaxHeight().padding(start=8.dp).onGloballyPositioned {latestIdentityBounds(it.boundsInRoot())},verticalArrangement=Arrangement.Center) {
                    Text(label,style=titleStyle,maxLines=1,overflow=TextOverflow.Ellipsis)
                    if(isExpanded) {
                        if(artist.isNotBlank())Text(artist,style=artistStyle,color=colors.muted,maxLines=1,overflow=TextOverflow.Ellipsis)
                        if(stackFacts)facts.forEach {Text(it,style=factStyle,color=colors.muted)}
                        else Row(horizontalArrangement=Arrangement.spacedBy(8.dp)) {facts.forEach {Text(it,style=factStyle,color=colors.muted,softWrap=false)}}
                    }
                }
                Box(Modifier.onGloballyPositioned {disclosureBounds=it.boundsInRoot().translate(-rowOrigin)}
                    .semantics {stateDescription=if(isExpanded)"Expanded" else "Collapsed"}) {
                    TimelineTool(if(isExpanded)"Collapse ${clip.title}" else "Expand ${clip.title}",{
                        if(onExpanded!=null)onExpanded(!isExpanded) else localExpanded=!isExpanded
                    },state="${if(isExpanded)"Expanded" else "Collapsed"}, occurrence ${clip.occurrence}, starts ${timelineTime(shown.globalStartMs)}") {SoundQIcon(if(isExpanded)SoundQIcon.Up else SoundQIcon.Down,null)}
                }
            }
            Box(Modifier.background(colors.surface).onGloballyPositioned {moreBounds=it.boundsInRoot().translate(-rowOrigin)}) {
                Box(Modifier.focusRequester(moreFocus)) {
                    TimelineTool("More for ${clip.title}",{if(canAct())showMore=true},!busy&&canAct(),state="Occurrence ${clip.occurrence}, starts ${timelineTime(shown.globalStartMs)}") {SoundQIcon(SoundQIcon.More,null)}
                }
                DropdownMenu(showMore&&canAct(),::closeMenu,modifier=Modifier.widthIn(min=236.dp,max=264.dp),shape=RectangleShape,
                    containerColor=colors.surface) {
                    if(onBpm!=null)DropdownMenuItem(text={Text("Set BPM")},onClick={closeMenu();if(canAct())onBpm()},enabled=!busy&&canAct())
                    DropdownMenuItem(text={Text("Edit clip timing")},onClick={closeMenu();if(canAct())onArrangement()},enabled=!busy&&canAct())
                    scratch?.let {control->
                        DropdownMenuItem(text={Text(if(control.armed)"Disable scratch" else "Scratch")},onClick={closeMenu();if(canAct())control.arm()},enabled=canAct()&&(control.ready||control.armed))
                    }
                    DropdownMenuItem(text={Text(if(wave==null)"Retry waveform" else "Refresh source timing")},onClick={closeMenu();if(canAct())onRetry()},enabled=canAct()&&loadState !is WaveformLoad.Loading)
                }
            }
        }
      }
    }
}
@Composable private fun TimingInspector(clip:TimelineClip,revision:Long,busy:Boolean,wave:TrackWaveform?,commit:(TimelineEdit)->Unit) {
    var kind by remember {mutableStateOf(EditKind.Placement)}
    var draft by remember(clip,kind,revision,wave?.sourceKey){mutableLongStateOf(when(kind){EditKind.Placement->clip.globalStartMs;EditKind.TrimIn->clip.sourceInMs;EditKind.TrimOut->clip.sourceOutMs})}
    val alive=remember(clip,revision,wave?.sourceKey){java.util.concurrent.atomic.AtomicBoolean(true)}
    DisposableEffect(alive){onDispose{alive.set(false)}}
    val label=when(kind){EditKind.Placement->"Placement";EditKind.TrimIn->"Crop start";EditKind.TrimOut->"Crop end"}
    SoundQButton("$label · change",{kind=EditKind.entries[(kind.ordinal+1)%EditKind.entries.size]},enabled=!busy,variant=SoundQButtonVariant.Quiet)
    if(kind==EditKind.Placement)TimelinePlacementPicker(clip,wave,draft,!busy,lifetime=revision){if(alive.get())draft=it}
    else SourceMarkerPicker(label,clip,wave,draft,!busy,lifetime=revision){if(alive.get())draft=it}
    Text("${timelineTime(clip.sourceInMs)}–${timelineTime(clip.sourceOutMs)} · source selection",style=SoundQ.typography.caption)
    Row {
        listOf(-1,1).forEach {direction->
            val next=timingBeatNudge(clip,kind,draft,direction,wave)
            SoundQButton(if(direction<0)"−1 beat" else "+1 beat",{if(alive.get()&&next!=null)draft=next},enabled=!busy&&next!=null,variant=SoundQButtonVariant.Secondary)
        }
    }
    SoundQButton("Save timing edit",{if(!busy&&alive.get())commit(TimelineEdit(revision,clip,kind,draft))},enabled=!busy,variant=SoundQButtonVariant.Secondary)
}
