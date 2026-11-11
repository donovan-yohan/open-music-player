package com.soundq.designsystem

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlin.math.abs
import kotlin.math.roundToLong

/** Utility-row cell showing the ACCEPTED listening speed. Null cell means the build/owner has
 * no speed capability; a runtime-unavailable owner keeps the cell with available=false. */
@Immutable data class SoundQSpeedCell(val accepted:Double,val available:Boolean,val expanded:Boolean,val onToggle:()->Unit)

enum class SoundQSpeedPanelState { Ready, Pending, Rejected, Unavailable }

/** Pure centre-origin mapping, quantisation and copy. 1.0x is always the slider centre. */
object SoundQSpeedScale {
    const val STEP = 0.05
    fun rateAt(fraction:Float,min:Double,max:Double):Double {
        val f=fraction.toDouble().coerceIn(0.0,1.0)
        return if(f<0.5)min+(1-min)*(f/0.5) else 1+(max-1)*((f-0.5)/0.5)
    }
    fun fractionOf(rate:Double,min:Double,max:Double):Float {
        val r=rate.coerceIn(min,max)
        return (if(r<1)0.5*(r-min)/(1-min) else 0.5+0.5*(r-1)/(max-1)).toFloat()
    }
    fun quantise(rate:Double,min:Double,max:Double):Double =
        ((rate/STEP).roundToLong()*STEP*100).roundToLong().div(100.0).coerceIn(min,max)
    /** Drag detent: within ±0.03x of normal snaps to 1.0x. */
    fun snapped(rate:Double)=if(abs(rate-1)<=0.03+1e-9)1.0 else rate
    fun label(rate:Double):String {
        val hundredths=(rate*100).roundToLong()
        val whole=hundredths/100;val part=hundredths%100
        return if(part%10==0L)"$whole.${part/10}x" else "$whole.${part.toString().padStart(2,'0')}x"
    }
    fun spoken(rate:Double)=label(rate).removeSuffix("x").removeSuffix(".0")+" times"
}

/** Speed cell for [SoundQPlayerUtilities]. Text is the glyph; teal ink when not normal. */
@Composable internal fun RowScope.SpeedUtility(cell:SoundQSpeedCell,first:Boolean) {
    val colors=SoundQ.colors
    val ink=when {!cell.available->colors.disabled;cell.accepted!=1.0->colors.focus;else->colors.text}
    val rule=with(LocalDensity.current){SoundQ.sizes.border.toPx()}
    val border=colors.border
    val interactions=remember {MutableInteractionSource()}
    val focused by interactions.collectIsFocusedAsState()
    val spokenState=(if(!cell.available)"Unavailable" else if(cell.accepted==1.0)"Normal, 1 times" else SoundQSpeedScale.spoken(cell.accepted))+
        if(cell.expanded)", expanded" else ", collapsed"
    Box(Modifier.weight(1f).fillMaxHeight().testTag("player-speed-cell")
        .drawWithRule(first,border,rule)
        .semantics {
            contentDescription="Playback speed";stateDescription=spokenState
            if(cell.expanded)collapse {cell.onToggle();true} else expand {cell.onToggle();true}
        }
        .clickable(interactionSource=interactions,indication=androidx.compose.foundation.LocalIndication.current,role=Role.Button,onClick=cell.onToggle)
        .soundQCellFocus(focused),contentAlignment=Alignment.Center) {
        Text(SoundQSpeedScale.label(cell.accepted),style=SoundQ.typography.title,color=ink)
        if(cell.expanded)Box(Modifier.align(Alignment.BottomCenter).padding(horizontal=12.dp).fillMaxWidth().offset(y=(-4).dp).height(2.dp).background(ink))
    }
}
private fun Modifier.drawWithRule(first:Boolean,color:Color,rule:Float)=drawBehindRule(first,color,rule)
private fun Modifier.drawBehindRule(first:Boolean,color:Color,rule:Float)=this.drawBehind {
    if(!first)drawLine(color,Offset.Zero,Offset(0f,size.height),rule)
}

/** Inline panel under the utility row. Pure presentation: owns only the draft, quantisation,
 * keyboard debounce and haptics; emits [onRequest] (rate) or [onReset]. [accepted] is the only
 * value shown as fact; [requested] marks a pending request (hollow needle). */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable fun SoundQPlaybackSpeedPanel(
    accepted:Double,requested:Double?,min:Double,max:Double,
    state:SoundQSpeedPanelState,reason:String?,onRequest:(Double)->Unit,onReset:()->Unit,
    modifier:Modifier=Modifier,identity:Any?=null,measuredBpm:Double?=null,
    shortcuts:List<Double> = listOf(0.75,1.0,1.25,1.5),
    rejected:Double?=null,
) {
    val colors=SoundQ.colors
    val enabled=state!=SoundQSpeedPanelState.Unavailable&&min<1.0&&max>1.0
    var draft by remember(identity) {mutableStateOf<Double?>(null)}
    var pointer by remember(identity) {mutableStateOf(false)}
    var gesture by remember(identity) {mutableStateOf(false)}
    var keyboardPending by remember(identity) {mutableStateOf<Double?>(null)}
    val interactions=remember(identity) {MutableInteractionSource()}
    LaunchedEffect(interactions) {
        var active=0
        interactions.interactions.collect {
            when(it) {is PressInteraction.Press,is DragInteraction.Start->{active++;gesture=true}
                is PressInteraction.Release,is PressInteraction.Cancel,is DragInteraction.Stop,is DragInteraction.Cancel->active=(active-1).coerceAtLeast(0)}
            pointer=active>0
        }
    }
    val haptics=LocalHapticFeedback.current
    fun commit(rate:Double) {
        draft=null;keyboardPending=null
        if(!enabled)return
        val value=SoundQSpeedScale.quantise(rate,min,max)
        if(value==(requested ?: accepted))return
        if(value==1.0)onReset() else onRequest(value)
    }
    LaunchedEffect(keyboardPending) {
        val value=keyboardPending ?: return@LaunchedEffect
        delay(500);commit(value)
    }
    val shown=draft ?: requested ?: accepted
    val inkFor={rate:Double->if(!enabled)colors.disabled else if(rate!=1.0)colors.focus else colors.text}
    Column(modifier.fillMaxWidth().testTag("player-speed-panel").semantics {paneTitle="Playback speed"}
        .topRule(colors.border)) {
        FlowRow(Modifier.fillMaxWidth().heightIn(min=48.dp).padding(horizontal=8.dp),
            horizontalArrangement=Arrangement.SpaceBetween,verticalArrangement=Arrangement.Center) {
            Text("Playback speed",Modifier.align(Alignment.CenterVertically).semantics {heading()},style=SoundQ.typography.title,color=colors.text)
            Text(SoundQSpeedScale.label(accepted),Modifier.align(Alignment.CenterVertically).testTag("player-speed-accepted"),style=SoundQ.typography.title,color=inkFor(accepted))
        }
        val status=when {
            !enabled->reason ?: "Speed changes aren't available for this track."
            draft!=null&&pointer->"Release to set ${SoundQSpeedScale.label(draft!!)}"
            state==SoundQSpeedPanelState.Pending&&requested!=null->"Applying ${SoundQSpeedScale.label(requested)}…"
            state==SoundQSpeedPanelState.Rejected&&rejected!=null->"Couldn't change speed to ${SoundQSpeedScale.label(rejected)}. Still playing at ${SoundQSpeedScale.label(accepted)}."
            else->null
        }
        if(status!=null)Text(status,Modifier.fillMaxWidth().padding(horizontal=8.dp).testTag("player-speed-status").semantics {liveRegion=LiveRegionMode.Polite},
            style=SoundQ.typography.caption,color=if(state==SoundQSpeedPanelState.Rejected&&enabled)colors.error else colors.muted)
        val pending=state==SoundQSpeedPanelState.Pending&&requested!=null
        val spoken=if(!enabled)"Unavailable. ${reason ?: "Speed changes aren't available for this track."}"
            else SoundQSpeedScale.spoken(accepted)+if(pending)", applying ${SoundQSpeedScale.spoken(requested)}" else ""
        val steps=((max-min)/SoundQSpeedScale.STEP).roundToLong().toInt()-1
        Slider(SoundQSpeedScale.fractionOf(shown,min,max),{f->
                if(!enabled)return@Slider
                val raw=SoundQSpeedScale.quantise(SoundQSpeedScale.rateAt(f,min,max),min,max)
                val next=if(pointer)SoundQSpeedScale.snapped(raw) else raw
                val before=draft ?: accepted
                if(listOf(1.0,1.25,1.5).any {mark->(before<mark)!=(next<mark)||before==mark!=(next==mark)})
                    haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
                draft=next
                // Pointer input commits on release; keyboard/D-pad adjusts debounce 500 ms.
                keyboardPending=if(pointer||gesture)null else next
            },
            Modifier.fillMaxWidth().heightIn(min=48.dp).padding(horizontal=8.dp).testTag("player-speed-slider").clearAndSetSemantics {
                contentDescription="Playback speed";stateDescription=spoken
                progressBarRangeInfo=ProgressBarRangeInfo(accepted.toFloat(),min.toFloat()..max.toFloat(),steps.coerceAtLeast(0))
                if(enabled) {
                    setProgress {v->keyboardPending=SoundQSpeedScale.quantise(v.toDouble(),min,max);draft=keyboardPending;true}
                    customActions=listOf(CustomAccessibilityAction("Reset to normal speed") {draft=null;keyboardPending=null;if(accepted!=1.0||requested!=null)onReset();true})
                } else disabled()
            },
            enabled=enabled,onValueChangeFinished={val value=draft;if(value!=null&&gesture){gesture=false;commit(value)}},
            interactionSource=interactions,
            thumb={SpeedNeedle(if(!enabled)colors.disabled else colors.focus,hollow=pending&&draft==null)},
            track={SpeedTrack(accepted,min,max,enabled)})
        Box(Modifier.fillMaxWidth().padding(horizontal=20.dp).clearAndSetSemantics {}) {
            Text(SoundQSpeedScale.label(min),Modifier.align(Alignment.CenterStart),style=SoundQ.typography.mono,color=colors.muted)
            Text("1.0x",Modifier.align(Alignment.Center),style=SoundQ.typography.mono,color=colors.muted)
            Text(SoundQSpeedScale.label(max),Modifier.align(Alignment.CenterEnd),style=SoundQ.typography.mono,color=colors.muted)
        }
        if(measuredBpm!=null&&measuredBpm.isFinite()&&measuredBpm>0) {
            val plays=(measuredBpm*accepted).roundToLong();val measured=measuredBpm.roundToLong()
            Text("Analysed $measured BPM · plays at $plays BPM",Modifier.fillMaxWidth().padding(horizontal=8.dp,vertical=4.dp)
                .clearAndSetSemantics {contentDescription="Analysed $measured BPM, plays at $plays BPM"},style=SoundQ.typography.mono,color=colors.muted)
        }
        Spacer(Modifier.height(8.dp))
        SpeedShortcuts(shortcuts.filter {it==1.0||it in min..max}.let {if(1.0 in it)it else listOf(1.0)+it},accepted,enabled) {rate->
            draft=null;keyboardPending=null
            if(rate==1.0) {if(accepted!=1.0||requested!=null)onReset()}
            else if(rate!=(requested ?: accepted))onRequest(rate)
        }
    }
}
private fun Modifier.topRule(color:Color)=this.drawBehind {drawLine(color,Offset.Zero,Offset(size.width,0f),1.dp.toPx())}

@Composable private fun SpeedNeedle(color:Color,hollow:Boolean) {
    Box(Modifier.size(6.dp,28.dp).testTag(if(hollow)"player-speed-needle-pending" else "player-speed-needle")
        .then(if(hollow)Modifier.border(2.dp,color) else Modifier.background(color)))
}
@Composable private fun SpeedTrack(accepted:Double,min:Double,max:Double,enabled:Boolean) {
    val colors=SoundQ.colors
    Canvas(Modifier.fillMaxWidth().height(28.dp)) {
        val y=size.height/2
        fun x(rate:Double)=SoundQSpeedScale.fractionOf(rate,min,max)*size.width
        drawLine(colors.progressTrack,Offset(0f,y),Offset(size.width,y),2.dp.toPx())
        listOf(min,0.75,1.25,1.5,max).distinct().filter {it in min..max&&it!=1.0}.forEach {tick(x(it),12.dp,1.dp,colors.muted)}
        tick(x(1.0),24.dp,2.dp,if(enabled)colors.text else colors.disabled)
        if(enabled&&accepted!=1.0)drawLine(colors.focus,Offset(x(1.0),y),Offset(x(accepted),y),4.dp.toPx())
    }
}
private fun DrawScope.tick(x:Float,height:Dp,width:Dp,color:Color) {
    val h=height.toPx()/2
    drawLine(color,Offset(x,size.height/2-h),Offset(x,size.height/2+h),width.toPx())
}

@OptIn(ExperimentalLayoutApi::class)
@Composable private fun SpeedShortcuts(values:List<Double>,accepted:Double,enabled:Boolean,onSelect:(Double)->Unit) {
    val measurer=rememberTextMeasurer()
    val style=SoundQ.typography.body.copy(fontWeight=FontWeight.Medium)
    val widest=with(LocalDensity.current) {values.maxOf {measurer.measure(SoundQSpeedScale.label(it),style).size.width}.toDp()}
    BoxWithConstraints(Modifier.fillMaxWidth().topRule(SoundQ.colors.border)) {
        val banded=values.size>2&&maxWidth<(widest+24.dp)*values.size
        val rows=if(banded)values.chunked((values.size+1)/2) else listOf(values)
        Column(Modifier.fillMaxWidth().selectableGroup()) {
            rows.forEachIndexed {r,row->
                Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).then(if(r>0)Modifier.topRule(SoundQ.colors.border) else Modifier)) {
                    row.forEachIndexed {i,rate->SpeedShortcut(rate,rate==accepted,enabled,i==0) {onSelect(rate)}}
                }
            }
        }
    }
}
@Composable private fun RowScope.SpeedShortcut(rate:Double,selected:Boolean,enabled:Boolean,first:Boolean,onClick:()->Unit) {
    val colors=SoundQ.colors
    val ink=if(!enabled)colors.disabled else if(selected)colors.focus else colors.text
    val interactions=remember {MutableInteractionSource()}
    val focused by interactions.collectIsFocusedAsState()
    val label=if(rate==1.0)"Normal speed, 1 times. Resets this track" else SoundQSpeedScale.spoken(rate)
    Box(Modifier.weight(1f).heightIn(min=56.dp).drawBehindRule(first,colors.border,with(LocalDensity.current){SoundQ.sizes.border.toPx()})
        .semantics {contentDescription=label;this.selected=selected}
        .clickable(interactionSource=interactions,indication=androidx.compose.foundation.LocalIndication.current,enabled=enabled,role=Role.RadioButton,onClick=onClick)
        .soundQCellFocus(focused).testTag("player-speed-shortcut-${SoundQSpeedScale.label(rate)}"),contentAlignment=Alignment.Center) {
        Text(SoundQSpeedScale.label(rate),Modifier.padding(horizontal=12.dp,vertical=8.dp),color=ink,
            style=SoundQ.typography.body.copy(fontWeight=if(selected)FontWeight.Medium else FontWeight.Normal))
        if(selected)Box(Modifier.align(Alignment.BottomCenter).padding(horizontal=12.dp).fillMaxWidth().offset(y=(-4).dp).height(2.dp).background(ink))
    }
}
