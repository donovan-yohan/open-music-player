package com.soundq.android.product.playlists

import com.soundq.designsystem.*

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


/** Canonical grip geometry adapted for private members. Only preview is local; ACK order is input. */
@Composable fun PlaylistMemberOrderList(
    rows:List<QueueRowVisual>,onSelect:(String)->Unit,onMove:(String,Int)->Unit,onRemove:(String)->Unit,
    modifier:Modifier=Modifier,revision:Any=rows.map {it.occurrence},
    gestureState:PlaylistOrderGesture=remember {PlaylistOrderGesture()},onReorder:((QueueMoveIntent)->Boolean)?=null,
    onQueue:((String)->Unit)?=null,queueEnabled:Boolean=true,revealOwner:RowRevealOwner=remember {RowRevealOwner()},
    artwork:(@Composable (String)->Unit)?=null,
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
    var active by remember {mutableStateOf<PlaylistMemberDragSession?>(null)}
    var settling by remember {mutableStateOf(false)}
    var pulse by remember {mutableIntStateOf(0)}
    var listTop by remember {mutableFloatStateOf(0f)}
    var menu by remember {mutableStateOf<String?>(null)}
    var focusAfter by remember {mutableStateOf<QueueMoveIntent?>(null)}
    val focus=remember {mutableMapOf<String,FocusRequester>()}
    val offsets=remember(order) {order.associateWith {Animatable(0f)}}
    var lifted by remember {mutableStateOf(Animatable(0f))}
    val measured=remember {mutableMapOf<String,QueueItemBounds>()}
    var pin by remember {mutableStateOf<PinnableContainer.PinnedHandle?>(null)}
    val latestReorder by rememberUpdatedState(onReorder)
    val latestMove by rememberUpdatedState(onMove)
    fun dispatch(intent:QueueMoveIntent) {
        if(intent.to !in order.indices||intent.to==order.indexOf(intent.occurrence))return
        val accepted=latestReorder?.invoke(intent) ?: run {latestMove(intent.occurrence,intent.to);true}
        if(accepted)focusAfter=intent
    }
    fun cancel() {
        active?.cancel();active=null;settling=false;pin?.release();pin=null
    }
    fun sample(g:PlaylistMemberDragSession):List<QueueItemBounds> {
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
                list.scrollToItem(index)
                withFrameNanos { }
                focus[intent.occurrence]?.requestFocus()
            }
            focusAfter=null
        } else if(order!=intent.originalOrder)focusAfter=null
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
    SoundQMediaListRules(list) {rules -> LazyColumn(modifier.fillMaxWidth().heightIn(max=T.SEMANTIC_DIMENSION_APP_MAX*T.MOTION_SHEET_MEDIUM)
        .onGloballyPositioned {listTop=it.positionInRoot().y}
        .onPreviewKeyEvent(gestureState::onKey).then(rules),state=list,userScrollEnabled=active==null) {
        itemsIndexed(rows,key={_,r->r.occurrence}) {index,row ->
            val requester=remember(row.occurrence) {focus.getOrPut(row.occurrence){FocusRequester()}}
            val pinnable=LocalPinnableContainer.current
            var coordinates by remember {mutableStateOf<LayoutCoordinates?>(null)}
            val actions=buildList {
                if(index>0)add(CustomAccessibilityAction("Move earlier") {if(active==null)dispatch(QueueMoveIntent(row.occurrence,order,index-1));active==null})
                if(index<rows.lastIndex)add(CustomAccessibilityAction("Move later") {if(active==null)dispatch(QueueMoveIntent(row.occurrence,order,index+1));active==null})
                add(CustomAccessibilityAction("Remove from playlist") {if(active==null)onRemove(row.occurrence);active==null})
            }
            Row(Modifier.fillMaxWidth().zIndex(if(g?.occurrence==row.occurrence)1f else 0f)
                .graphicsLayer {
                    pulse
                    translationY=if(g?.occurrence==row.occurrence) {if(settling)lifted.value else g.translation} else offsets[row.occurrence]?.value ?: 0f
                }.background(mediaRowBackground(row.current))
                .mediaRowBottomRule()
                .semantics {customActions=actions},verticalAlignment=Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) {
                    val reveal=remember(row.occurrence,revision){RowRevealState(revealOwner)}
                    val queue={if(active==null&&queueEnabled)onQueue?.invoke(row.occurrence);Unit}
                    SoundQSwipeQueue(row.title,reveal,onQueue!=null&&queueEnabled&&active==null,queue,current=row.current) {front,admit->
                        SoundQMediaRow(row.title,row.subtitle,row.current,{if(active==null&&admit())onSelect(row.occurrence)},
                            onMore={if(active==null){reveal.close();menu=row.occurrence}},modifier=front,
                            artwork=artwork?.let {slot->{slot(row.occurrence)}},supporting="${index+1}",enabled=active==null,
                            metadata={com.soundq.android.product.LibraryMetadataContent(com.soundq.android.product.memberDurationMetadata(row.durationMs))})
                    }
                }
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
                            var admitted:PlaylistMemberDragSession?=null
                            try {
                                detectDragGestures(orientationLock=null,onDragStart={down,_,_ ->
                                    admitted=null
                                    if(active==null) {
                                        val item=list.layoutInfo.visibleItemsInfo.firstOrNull {it.key==row.occurrence}
                                        val y=coordinates?.localToRoot(down.position)?.y?.minus(listTop)
                                        if(item!=null&&y!=null) {
                                            measured.clear()
                                            val started=PlaylistMemberDragSession(order,row.occurrence,y,item.offset.toFloat(),item.size.toFloat())
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
                    if(onQueue!=null)DropdownMenuItem(text={Text("Add to listening queue")},onClick={if(queueEnabled&&active==null)onQueue(row.occurrence);menu=null},enabled=queueEnabled&&active==null)
                    DropdownMenuItem(text={Text("Move earlier")},onClick={dispatch(QueueMoveIntent(row.occurrence,order,index-1));menu=null},enabled=index>0&&active==null)
                    DropdownMenuItem(text={Text("Move later")},onClick={dispatch(QueueMoveIntent(row.occurrence,order,index+1));menu=null},enabled=index<rows.lastIndex&&active==null)
                    DropdownMenuItem(text={Text("Remove from playlist")},onClick={onRemove(row.occurrence);menu=null},enabled=active==null)
                }
            }
        }
    }}
}

/** Ephemeral gesture cancellation shared with its modal host; no feature authority. */
@Stable class PlaylistOrderGesture {
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

/** Pure preview math and one-shot completion token, consumed by the mounted queue. */
private class PlaylistMemberDragSession(val order:List<String>,val occurrence:String,val startPointer:Float,val startTop:Float,val height:Float) {
    val from=order.indexOf(occurrence)
    var target=from;private set
    var pointer=startPointer;private set
    var scroll=0f;private set
    val translation:Float get()=pointer-startPointer+scroll
    fun scrolled(pixels:Float) {if(!finished&&!settling)scroll+=pixels}
    fun follow(y:Float,bounds:List<QueueItemBounds>) {
        if(finished||settling)return
        pointer=y
        val center=startTop+height/2+translation
        var next=from
        for(item in bounds.sortedBy {it.index}) {
            if(item.index==from)continue
            if(center>item.top+item.height/2)next=maxOf(next,item.index)
            else if(item.index<from){next=item.index;break}
        }
        target=next
    }
    fun neighborOffset(index:Int):Float = when {
        target>from && index in (from+1)..target -> -height
        target<from && index in target until from -> height
        else -> 0f
    }
    var settling=false;private set
    private var finished=false
    fun release():QueueMoveIntent? {if(!finished)settling=true;return null}
    fun edgeStep(top:Float,bottom:Float,zone:Float,pixelsPerMs:Float,elapsedMs:Float):Float {
        if(finished||settling||zone<=0f)return 0f
        val direction=when {pointer<top+zone -> -(1f-(pointer-top)/zone);pointer>bottom-zone -> 1f-(bottom-pointer)/zone;else -> 0f}
        return direction.coerceIn(-1f,1f)*pixelsPerMs*elapsedMs
    }
    fun cancel() {finished=true;settling=false}
    fun complete():QueueMoveIntent? {
        if(!settling||finished)return null
        finished=true;settling=false
        return intent().takeIf {target!=from}
    }
    fun intent()=QueueMoveIntent(occurrence,order,target)
    fun settleOffset(bounds:List<QueueItemBounds>):Float {
        val destination=bounds.firstOrNull {it.index==target} ?: return pointer-startPointer
        return (if(target>from)destination.top+destination.height-height else destination.top)-startTop
    }
}
