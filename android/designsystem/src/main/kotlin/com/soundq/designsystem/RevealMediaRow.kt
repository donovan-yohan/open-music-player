package com.soundq.designsystem

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.IndicationNodeFactory
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.InteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.*
import androidx.compose.ui.input.pointer.*
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.*
import androidx.compose.foundation.border
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.node.DelegatableNode
import androidx.compose.ui.unit.Dp
import androidx.compose.foundation.background
import kotlin.math.abs
import soundq.design.generated.SoundQComposeTokens as T

/** A recognized swipe owns feedback; do not leave a tap ripple on just the front. */
private object SwipeTrackingIndication:IndicationNodeFactory {
    override fun create(interactionSource:InteractionSource):DelegatableNode=object:Modifier.Node(){}
    override fun equals(other:Any?):Boolean=other===this
    override fun hashCode():Int=System.identityHashCode(this)
}

/** Observe outside downs without consuming scrolling, child More or native click handling. */
fun Modifier.closeRowRevealOutside(owner:RowRevealOwner):Modifier=pointerInput(owner) {
    awaitEachGesture {
        val down=awaitFirstDown(requireUnconsumed=false,pass=PointerEventPass.Initial)
        owner.outside(down.position.x,down.position.y)
    }
}

/** Shared pointer owner. Only the front layer moves; arbitrary row content stays mounted. */
@Composable fun SoundQSwipeQueue(
    title:String,state:RowRevealState,enabled:Boolean,onQueue:()->Unit,modifier:Modifier=Modifier,
    liked:Boolean?=null,likeEnabled:Boolean=false,onLike:()->Unit={},
    explicitQueue:()->Unit=onQueue,current:Boolean=false,content:@Composable (Modifier,()->Boolean)->Unit,
) {
    val density=LocalDensity.current
    val slop=with(density){T.MOTION_GESTURE_SLOP.toPx()}
    var size by remember(state){mutableStateOf(androidx.compose.ui.unit.IntSize.Zero)}
    val rowHeight=if(size.height>0)with(density){size.height.toDp()}else SoundQ.sizes.mediaRow
    val geometry=swipeQueueGeometry(rowHeight,likeEnabled)
    val reveal=with(density){geometry.reveal.toPx()}
    val fits=geometry.fits(with(density){size.width.toDp()})
    val arm=if(fits)with(density){geometry.arm.toPx()}else Float.POSITIVE_INFINITY
    val maximum=if(fits)with(density){geometry.maximum.toPx()}else reveal
    val view=androidx.compose.ui.platform.LocalView.current
    val latestQueue by rememberUpdatedState(onQueue)
    val duration=if(SoundQ.motion.reduced)T.MOTION_DURATION_REDUCED else T.MOTION_DURATION_SETTLE
    val animated=remember(state){Animatable(0f)}
    var animatedTicket by remember(state){mutableLongStateOf(-1L)}
    val ticket=state.revision
    val phase=state.phase
    val rowBackground=mediaRowBackground(current)
    val displayedOffset=when {
        phase==RowRevealPhase.Dragging->state.offset
        phase==RowRevealPhase.Settling&&animatedTicket!=ticket->state.settleStart ?: animated.value
        else->animated.value
    }
    DisposableEffect(state) {onDispose {state.dispose()}}
    LaunchedEffect(enabled) {if(!enabled)state.close()}
    LaunchedEffect(ticket,reveal) {
        if(state.phase==RowRevealPhase.Dragging)animated.stop()
        else if(state.phase==RowRevealPhase.Settling) {
            state.settleStart?.let {animated.snapTo(it)}
            animatedTicket=ticket
            animated.animateTo(if(state.targetOpen)-reveal else 0f,tween(duration,easing=T.MOTION_EASING_STANDARD))
            state.complete(ticket,reveal)
        }
        else if(state.phase==RowRevealPhase.Open)animated.snapTo(-reveal)
    }
    val latestEnabled by rememberUpdatedState(enabled)
    Box(modifier.fillMaxWidth().background(rowBackground).clipToBounds().mediaRowBottomRule()
            .onSizeChanged {size=it}
            .pointerInput(state,enabled,size,geometry,slop,arm,maximum,density) {
                if(!enabled)return@pointerInput
                awaitEachGesture {
                    val down=awaitFirstDown(requireUnconsumed=false)
                    val capturedQueue=latestQueue
                    val start=down.position
                    var dragging=false
                    var total=Offset.Zero
                    var previous=down.position
                    var time=down.uptimeMillis
                    var velocity=0f
                    try {
                        while(true) {
                            val event=awaitPointerEvent()
                            if(event.changes.count {it.pressed}>1)break
                            val change=event.changes.firstOrNull {it.id==down.id} ?: break
                            if(change.isConsumed)break
                            if(!change.pressed) {
                                if(dragging){change.consume();if(state.end(reveal,T.MOTION_ROW_COMMIT_PROGRESS,velocity,T.MOTION_SHEET_DISMISS_VELOCITY/2)&&latestEnabled)capturedQueue()}
                                dragging=false;break
                            }
                            total=change.position-start
                            if(!dragging) {
                                if(total.getDistance()<slop)continue
                                if(abs(total.y)>abs(total.x)*T.MOTION_GESTURE_AXIS_RATIO)break
                                if(abs(total.x)<=abs(total.y)*T.MOTION_GESTURE_AXIS_RATIO)continue
                                dragging=state.begin(animated.value,arm)
                            }
                            if(dragging) {
                                val elapsed=change.uptimeMillis-time
                                velocity=if(elapsed>0)(change.position.x-previous.x)/elapsed/density.density else 0f
                                previous=change.position;time=change.uptimeMillis
                                if(state.follow(total.x,maximum))runCatching {view.performHapticFeedback(android.view.HapticFeedbackConstants.CLOCK_TICK)}
                                change.consume()
                            }
                        }
                    } finally {
                        if(dragging)state.end(reveal,T.MOTION_ROW_COMMIT_PROGRESS,0f,T.MOTION_SHEET_DISMISS_VELOCITY/2,cancel=true)
                    }
                }
            }
        .onGloballyPositioned {coordinates->val bounds=coordinates.boundsInRoot();state.contains={x,y->bounds.contains(Offset(x,y))}}
        .semantics {
            stateDescription=if(state.armed)"Release to queue" else when(phase){RowRevealPhase.Closed->"Actions closed";RowRevealPhase.Dragging->"Revealing actions";RowRevealPhase.Settling->"Settling actions";RowRevealPhase.Open->"Actions open"}
            customActions=listOf(CustomAccessibilityAction("Add $title to listening queue"){if(enabled){explicitQueue();true}else false},CustomAccessibilityAction("Reveal actions for $title"){if(enabled){state.request(true);true}else false},
                CustomAccessibilityAction("Close actions for $title"){state.close();true})
        }
        .onPreviewKeyEvent {event->
            if(event.type!=KeyEventType.KeyDown)false else when(event.key) {
                Key.DirectionLeft->{if(enabled)state.request(true);true}
                Key.DirectionRight,Key.Escape->{state.close();true}
                else->false
            }
        }) {
        // Only the front travels. The touching square cells stay fixed through overtravel.
        // Both actions stay mounted across threshold, retreat, release and settle.
        Row(Modifier.align(AbsoluteAlignment.CenterRight)
            .requiredWidth(geometry.reveal).height(geometry.cellSize)
            .background(rowBackground).semantics {isTraversalGroup=true}
            .then(if(phase==RowRevealPhase.Closed)Modifier.clearAndSetSemantics {} else Modifier)) {
            if(likeEnabled)SwipeActionCell(SoundQIcon.Heart,if(liked==true)"Unlike $title" else "Like $title",
                geometry.cellSize,rowBackground,selected=liked==true,enabled=enabled&&state.actionable,available=enabled) {
                if(latestEnabled&&likeEnabled&&state.admit(ticket))onLike()
            }
            SwipeActionCell(SoundQIcon.AddQueue,"Add $title to listening queue",geometry.cellSize,rowBackground,
                selected=state.armed,enabled=enabled&&state.actionable,available=enabled,queueReadiness=true) {
                if(latestEnabled&&state.admit(ticket))explicitQueue()
            }
        }
        Box(Modifier.fillMaxWidth()) {
            CompositionLocalProvider(LocalIndication provides if(phase==RowRevealPhase.Dragging)SwipeTrackingIndication else LocalIndication.current) {
                content(Modifier.graphicsLayer {translationX=displayedOffset}.background(rowBackground)) {state.frontTap()}
            }
        }
    }
}

/** Armed is release readiness, not acknowledgement; drag-time admission does not dim ink. */
@Composable private fun SwipeActionCell(
    icon:SoundQIcon,label:String,cellSize:Dp,background:Color,selected:Boolean,enabled:Boolean,
    available:Boolean,queueReadiness:Boolean=false,onClick:()->Unit,
) {
    val interactions=remember {MutableInteractionSource()}
    val focused by interactions.collectIsFocusedAsState()
    val pressed by interactions.collectIsPressedAsState()
    val active=queueReadiness&&(selected||pressed)
    val colors=SoundQ.colors
    val motion=SoundQ.motion.selection
    val targetFill=if(active)colors.primary else background
    val targetInk=if(active)colors.onPrimary else if(!available)colors.disabled else if(selected)colors.primary else colors.text
    val targetOutline=if(focused)colors.focus else if(active||selected)colors.primary else colors.border
    val fill=if(queueReadiness)key(colors,background) {animateColorAsState(targetFill,tween(motion.durationMillis,easing=motion.easing),label="queue readiness fill").value}else targetFill
    val ink=if(queueReadiness)key(colors,background) {animateColorAsState(targetInk,tween(motion.durationMillis,easing=motion.easing),label="queue readiness ink").value}else targetInk
    val outline=if(queueReadiness)key(colors,background) {animateColorAsState(targetOutline,tween(motion.durationMillis,easing=motion.easing),label="queue readiness outline").value}else targetOutline
    Box(Modifier.requiredSize(cellSize).background(fill).border(SoundQ.sizes.border,outline)
        .semantics {
            contentDescription=label
            this.selected=selected
            if(queueReadiness&&selected)stateDescription="Release to queue"
        }
        .clickable(interactionSource=interactions,indication=LocalIndication.current,enabled=enabled,role=Role.Button,onClick=onClick),contentAlignment=Alignment.Center) {
        SoundQIcon(icon,null,tint=ink)
    }
}

/** Library retains its explicit Like owner and original media-row anatomy. */
@Composable fun SoundQRevealMediaRow(
    title:String,subtitle:String,current:Boolean,state:RowRevealState,enabled:Boolean,
    liked:Boolean?,likeEnabled:Boolean,onLike:()->Unit,onQueue:()->Unit,
    onActivate:()->Unit,onMore:()->Unit,modifier:Modifier=Modifier,supporting:String?=null,onQuickQueue:()->Unit=onQueue,artwork:(@Composable ()->Unit)?=null,metadata:(@Composable ()->Unit)?=null,
) {
    SoundQSwipeQueue(title,state,enabled,onQuickQueue,modifier,liked,likeEnabled,onLike,explicitQueue=onQueue,current=current) {front,admit->
        SoundQMediaRow(title,subtitle,current,{if(enabled&&admit())onActivate()},{state.close();onMore()},modifier=front,supporting=supporting,artwork=artwork,metadata=metadata,enabled=enabled)
    }
}
