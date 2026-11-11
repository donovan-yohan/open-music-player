package com.soundq.designsystem

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationVector1D
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.*
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.*
import androidx.compose.ui.platform.*
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import soundq.design.generated.SoundQComposeTokens as T

@Immutable data class QueueRowVisual(val occurrence:String,val title:String,val subtitle:String,val current:Boolean,val durationMs:Long=0)

/** Ephemeral gesture cancellation shared with its modal host; no feature authority. */
@Stable class QueueGestureState {
    internal var cancelGesture:(()->Unit)?=null
    fun cancel():Boolean {val cancel=cancelGesture ?: return false;cancel();return true}
    private var escapeUp=false
    fun onKey(event:KeyEvent):Boolean {
        if(event.key!=Key.Escape)return false
        if(event.type==KeyEventType.KeyUp&&escapeUp){escapeUp=false;return true}
        if(event.type==KeyEventType.KeyDown&&cancel()){escapeUp=true;return true}
        return false
    }
}

/** Real lazy queue; only preview geometry is local. Service order remains the input. */
@Composable fun SoundQOccurrenceQueue(
    rows:List<QueueRowVisual>,onSelect:(String)->Unit,onMove:(String,Int)->Unit,onRemove:(String)->Unit,
    modifier:Modifier=Modifier,revision:Any=rows.map {it.occurrence},
    gestureState:QueueGestureState=remember {QueueGestureState()},onReorder:((QueueMoveIntent)->Boolean)?=null,bounded:Boolean=false,
    metadata:(@Composable (QueueRowVisual)->Unit)?=null,
    artwork:@Composable (String)->Unit={SoundQArtworkSlot()},
) {
    val order=rows.map {it.occurrence}
    val list=rememberLazyListState()
    val density=LocalDensity.current
    val motion=SoundQ.motion.queue
    val edge=with(density){T.MOTION_QUEUE_EDGE_ZONE.toPx()}
    // Canonical reference Dp/ms -> actual pixels/ms, not px/s.
    val speed=T.MOTION_QUEUE_EDGE_SCROLL_SPEED*density.density
    val slop=with(density){T.MOTION_GESTURE_SLOP.toPx()}
    val platformConfiguration=LocalViewConfiguration.current
    val configuration=remember(platformConfiguration,slop) {object:ViewConfiguration by platformConfiguration {override val touchSlop=slop}}
    var active by remember {mutableStateOf<QueueDragSession?>(null)}
    var settling by remember {mutableStateOf(false)}
    var pulse by remember {mutableIntStateOf(0)}
    var listTop by remember {mutableFloatStateOf(0f)}
    var menu by remember {mutableStateOf<String?>(null)}
    var focusAfter by remember {mutableStateOf<QueueMoveIntent?>(null)}
    var focusViewport by remember {mutableStateOf<Pair<Int,Int>?>(null)}
    val focus=remember {mutableMapOf<String,FocusRequester>()}
    val offsets=remember(order) {order.associateWith {Animatable(0f)}}
    var lifted by remember {mutableStateOf(Animatable(0f))}
    val measured=remember {mutableMapOf<String,QueueItemBounds>()}
    var pin by remember {mutableStateOf<PinnableContainer.PinnedHandle?>(null)}
    val latestReorder by rememberUpdatedState(onReorder)
    val latestMove by rememberUpdatedState(onMove)
    fun dispatch(intent:QueueMoveIntent) {
        if(intent.to !in order.indices||intent.to==order.indexOf(intent.occurrence))return
        val viewport=list.firstVisibleItemIndex to list.firstVisibleItemScrollOffset
        val accepted=latestReorder?.invoke(intent) ?: run {latestMove(intent.occurrence,intent.to);true}
        if(accepted){focusViewport=viewport;focusAfter=intent}
    }
    fun cancel() {
        active?.cancel();active=null;settling=false;pin?.release();pin=null
    }
    fun sample(g:QueueDragSession):List<QueueItemBounds> {
        list.layoutInfo.visibleItemsInfo.forEach {item ->
            val id=item.key as? String ?: return@forEach
            measured[id]=QueueItemBounds(id,item.index,item.offset+g.scroll,item.size.toFloat())
        }
        return measured.values.toList()
    }
    DisposableEffect(revision,order) {onDispose {cancel()}}
    DisposableEffect(active,gestureState) {
        gestureState.cancelGesture=if(active!=null)({cancel()}) else null
        onDispose {gestureState.cancelGesture=null}
    }
    LaunchedEffect(order,focusAfter) {
        val intent=focusAfter ?: return@LaunchedEffect
        if(order==intent.insertedOrder()) {
            val index=order.indexOf(intent.occurrence)
            if(index>=0) {
                // A keyed LazyColumn otherwise follows a moved first row. Retain
                // the numeric viewport for this acknowledged local insertion only.
                focusViewport?.let {list.requestScrollToItem(it.first,it.second)}
                // Let the committed keyed order reach layout before checking its viewport.
                withFrameNanos { }
                val info=list.layoutInfo
                val item=info.visibleItemsInfo.firstOrNull {it.key==intent.occurrence&&it.index==index}
                val fullyVisible=item!=null&&item.offset>=info.viewportStartOffset&&item.offset+item.size<=info.viewportEndOffset
                if(!fullyVisible) {
                    list.scrollToItem(index)
                    withFrameNanos { }
                }
                focus[intent.occurrence]?.requestFocus()
            }
            focusAfter=null;focusViewport=null
        } else if(order!=intent.originalOrder){focusAfter=null;focusViewport=null}
    }
    val g=active
    val target=if(g!=null){pulse;g.target}else -1
    // One completion owner. Retargeting/cancel/disposal cancels this whole group.
    LaunchedEffect(g,target,settling,motion) {
        if(g==null) {
            offsets.values.forEach {it.snapTo(0f)}
            return@LaunchedEffect
        }
        coroutineScope {
            offsets.forEach {(id,animation)->launch {animation.animateTo(g.neighborOffset(order.indexOf(id)),motion)}}
            if(settling)launch {
                lifted.snapTo(g.translation)
                lifted.animateTo(g.settleOffset(measured.values.toList()),motion)
            }
        }
        if(settling&&active===g) {
            val intent=g.complete()
            active=null;settling=false;pin?.release();pin=null
            if(intent!=null)dispatch(intent)
        }
    }
    // A held pointer is sufficient; no additional move event is needed to scroll.
    LaunchedEffect(g,settling,edge,speed) {
        if(g==null||settling)return@LaunchedEffect
        var previous=withFrameNanos {it}
        while(active===g&&!settling) {
            val now=withFrameNanos {it}
            val info=list.layoutInfo
            val delta=g.edgeStep(info.viewportStartOffset.toFloat(),info.viewportEndOffset.toFloat(),edge,speed,(now-previous)/1_000_000f)
            previous=now
            if(delta!=0f) {
                g.scrolled(list.scrollBy(delta))
                g.follow(g.pointer,sample(g));pulse++
            }
        }
    }
    val queueSize=if(bounded)Modifier.fillMaxSize() else Modifier.heightIn(max=T.SEMANTIC_DIMENSION_APP_MAX*T.MOTION_SHEET_MEDIUM)
    SoundQMediaListRules(list) {rules -> LazyColumn(modifier.fillMaxWidth().then(queueSize)
        .onGloballyPositioned {listTop=it.positionInRoot().y}
        .onPreviewKeyEvent(gestureState::onKey).then(rules),state=list,userScrollEnabled=active==null) {
        itemsIndexed(rows,key={_,r->r.occurrence}) {index,row ->
            val requester=remember(row.occurrence) {focus.getOrPut(row.occurrence){FocusRequester()}}
            val pinnable=LocalPinnableContainer.current
            var coordinates by remember {mutableStateOf<LayoutCoordinates?>(null)}
            val actions=buildList {
                if(index>0)add(CustomAccessibilityAction("Move earlier") {if(active==null)dispatch(QueueMoveIntent(row.occurrence,order,index-1));active==null})
                if(index<rows.lastIndex)add(CustomAccessibilityAction("Move later") {if(active==null)dispatch(QueueMoveIntent(row.occurrence,order,index+1));active==null})
                add(CustomAccessibilityAction("Remove from queue") {if(active==null)onRemove(row.occurrence);active==null})
            }
            Row(Modifier.fillMaxWidth().zIndex(if(g?.occurrence==row.occurrence)1f else 0f)
                .graphicsLayer {
                    pulse
                    translationY=if(g?.occurrence==row.occurrence) {if(settling)lifted.value else g.translation} else offsets[row.occurrence]?.value ?: 0f
                }.background(mediaRowBackground(row.current))
                .mediaRowBottomRule()
                .semantics {customActions=actions},verticalAlignment=Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) {SoundQMediaRow(row.title,row.subtitle,row.current,{if(active==null)onSelect(row.occurrence)},{if(active==null)menu=row.occurrence},artwork={artwork(row.occurrence)},metadata=metadata?.let {slot->{slot(row)}})}
                CompositionLocalProvider(LocalViewConfiguration provides configuration) {
                    Box(Modifier.size(SoundQ.sizes.mediaRow)
                        .onGloballyPositioned {coordinates=it}
                        .semantics {
                            contentDescription="Reorder ${row.title}"
                            stateDescription=if(g?.occurrence==row.occurrence)"${if(settling)"Settling" else "Moving"} to position ${g.target+1}" else "Position ${index+1} of ${rows.size}"
                            customActions=actions
                        }.focusRequester(requester).onPreviewKeyEvent {event ->
                            if(gestureState.onKey(event))true
                            else if(event.type==KeyEventType.KeyDown&&event.isAltPressed&&(event.key==Key.DirectionUp||event.key==Key.DirectionDown)) {
                                val to=index+if(event.key==Key.DirectionUp)-1 else 1
                                if(active==null&&to in rows.indices)dispatch(QueueMoveIntent(row.occurrence,order,to))
                                true
                            }else false
                        }.focusable().pointerInput(row.occurrence,order,revision) {
                            // This detector may see another gesture while the admitted one settles.
                            // Only a positively admitted session owns follow/end/cancel callbacks.
                            var admitted:QueueDragSession?=null
                            try {
                                detectDragGestures(orientationLock=null,onDragStart={down,_,_ ->
                                    admitted=null
                                    if(active==null) {
                                        val item=list.layoutInfo.visibleItemsInfo.firstOrNull {it.key==row.occurrence}
                                        val y=coordinates?.localToRoot(down.position)?.y?.minus(listTop)
                                        if(item!=null&&y!=null) {
                                            measured.clear()
                                            val started=QueueDragSession(order,row.occurrence,y,item.offset.toFloat(),item.size.toFloat())
                                            sample(started);active=started;admitted=started;settling=false;pin=pinnable?.pin();requester.requestFocus()
                                        }
                                    }
                                },onDragCancel={
                                    val ended=admitted;admitted=null
                                    if(ended!=null&&active===ended&&!settling&&!ended.settling)cancel()
                                },onDragEnd={
                                    val ended=admitted;admitted=null
                                    if(ended!=null&&active===ended&&!settling&&!ended.settling) {
                                        lifted=Animatable(ended.translation);ended.release();settling=true
                                    }
                                }) {change,_ ->
                                    admitted?.takeIf {active===it&&!settling&&!it.settling}?.let {current ->
                                        change.consume()
                                        coordinates?.localToRoot(change.position)?.y?.minus(listTop)?.let {y ->current.follow(y,sample(current));pulse++}
                                    }
                                }
                            } finally {
                                // pointerInput cancellation on revision/disposal retires this detector.
                                admitted=null
                            }
                        },contentAlignment=Alignment.Center) {
                        SoundQIcon(SoundQIcon.Drag,null,tint=if(g?.occurrence==row.occurrence)SoundQ.colors.primary else SoundQ.colors.muted)
                    }
                }
                DropdownMenu(expanded=menu==row.occurrence,onDismissRequest={menu=null},shape=RectangleShape) {
                    DropdownMenuItem(text={Text("Play")},onClick={onSelect(row.occurrence);menu=null},enabled=active==null)
                    DropdownMenuItem(text={Text("Move earlier")},onClick={dispatch(QueueMoveIntent(row.occurrence,order,index-1));menu=null},enabled=index>0&&active==null)
                    DropdownMenuItem(text={Text("Move later")},onClick={dispatch(QueueMoveIntent(row.occurrence,order,index+1));menu=null},enabled=index<rows.lastIndex&&active==null)
                    DropdownMenuItem(text={Text("Remove from queue")},onClick={onRemove(row.occurrence);menu=null},enabled=active==null)
                }
            }
        }
    }}
}
/** Future stacked waveform arrangement seam. Horizontal placement is NOT row reveal/reorder. */
@Immutable data class TimelineViewportVisual(val originMs:Long,val spanMs:Long,val playheadMs:Long)
@Immutable data class TimelineClipVisual(val occurrence:String,val timelineStartMs:Long,val sourceStartMs:Long,val sourceEndMs:Long,val peaks:List<Float>,val pending:Boolean)
sealed interface TimelineClipIntent {
    data class PreviewPlacement(val occurrence:String,val timelineStartMs:Long):TimelineClipIntent
    data class CommitPlacement(val occurrence:String,val timelineStartMs:Long):TimelineClipIntent
    data class CancelPlacement(val occurrence:String):TimelineClipIntent
}
