package com.soundq.android.product.timeline

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import com.soundq.android.data.timeline.*
import com.soundq.designsystem.*
import kotlin.math.*

/** Actual source peaks and producer markers; an unqualified source never gains a generated grid. */
@Composable internal fun SourceMarkerPicker(
    label:String,clip:TimelineClip,wave:TrackWaveform?,selected:Long?,enabled:Boolean,
    range:LongRange=0L..clip.sourceDurationMs,lifetime:Any?=clip,onPick:(Long)->Unit,
) {
    Text(label,style=SoundQ.typography.caption)
    val qualified=wave?.takeIf {it.track.value==clip.track&&it.durationMs==clip.sourceDurationMs}
    val identity=listOf(clip.occurrence,clip.track,clip.sourceDurationMs,qualified?.sourceKey,range,label,lifetime)
    val latestPick by rememberUpdatedState(onPick)
    var zoom by remember(identity){mutableIntStateOf(1)}
    var center by remember(identity){mutableLongStateOf(selected ?: (range.first+range.last)/2)}
    val span=maxOf(1L,(range.last-range.first)/zoom)
    val start=(center-span/2).coerceIn(range.first,maxOf(range.first,range.last-span))
    val end=minOf(range.last,start+span)
    val tier=qualified?.tiers?.filter {it.minima.isNotEmpty()&&it.maxima.isNotEmpty()}?.maxByOrNull {minOf(it.minima.size,it.maxima.size)}
    val markers=remember(qualified,start,end){(qualified?.beats.orEmpty()+qualified?.downbeats.orEmpty()).filter {it in start..end}.distinct().sorted()}
    val columns=remember(tier,start,end,qualified?.durationMs){
        if(tier==null)emptyList() else {
            val n=minOf(tier.minima.size,tier.maxima.size)
            (0 until 192).map {column->
                val left=start+(end-start)*column/192.0;val right=start+(end-start)*(column+1)/192.0
                val lo=floor(left/qualified.durationMs*n).toInt().coerceIn(0,maxOf(0,n-1))
                val hi=ceil(right/qualified.durationMs*n).toInt().coerceIn(lo+1,maxOf(lo+1,n))
                var low=0f;var high=0f
                for(i in lo until minOf(n,hi)){low=minOf(low,tier.minima[i]);high=maxOf(high,tier.maxima[i])}
                low to high
            }
        }
    }
    var held by remember(identity,start,end){mutableStateOf<Long?>(null)}
    val alive=remember(identity){java.util.concurrent.atomic.AtomicBoolean(true)}
    DisposableEffect(alive){onDispose{alive.set(false)}}
    val colors=SoundQ.colors
    val downbeats=remember(qualified){qualified?.downbeats.orEmpty().toHashSet()}
    val canPick=enabled&&qualified!=null&&columns.isNotEmpty()&&end>start
    Canvas(Modifier.fillMaxWidth().height(96.dp).background(colors.surface)
        .semantics {
            contentDescription=label
            stateDescription=if(!canPick)"Waveform unavailable" else if(selected==null)"Choose a point" else "Point selected"
            customActions=listOf(
                CustomAccessibilityAction("Previous marker"){markers.lastOrNull {it<(selected ?: end)}?.let {if(canPick&&alive.get()){onPick(it);true}else false} ?: false},
                CustomAccessibilityAction("Next marker"){markers.firstOrNull {it>(selected ?: start)}?.let {if(canPick&&alive.get()){onPick(it);true}else false} ?: false})
        }
        .pointerInput(identity,start,end,canPick){
            if(canPick)awaitEachGesture {
                val down=awaitFirstDown();var normal=false
                held=sourceMarkerAt(down.position.x,size.width.toFloat(),start,end,markers,10.dp.toPx());down.consume()
                try {
                    while(true){
                        val event=awaitPointerEvent()
                        if(event.changes.count {it.pressed}>1)break
                        val change=event.changes.firstOrNull {it.id==down.id} ?: break
                        if(change.isConsumed)break
                        held=sourceMarkerAt(change.position.x,size.width.toFloat(),start,end,markers,10.dp.toPx());change.consume()
                        if(!change.pressed){normal=true;break}
                    }
                    if(normal&&alive.get())held?.let(latestPick)
                }finally{held=null}
            }
        }) {
        val mid=size.height/2
        val selectionLeft=((clip.sourceInMs-start).toDouble()/maxOf(1,end-start)*size.width).toFloat().coerceIn(0f,size.width)
        val selectionRight=((clip.sourceOutMs-start).toDouble()/maxOf(1,end-start)*size.width).toFloat().coerceIn(0f,size.width)
        if(selectionRight>selectionLeft)drawRect(colors.primary.copy(alpha=.08f),Offset(selectionLeft,0f),Size(selectionRight-selectionLeft,size.height))
        for((index,peak) in columns.withIndex())drawLine(colors.muted,Offset(size.width*index/192,mid-peak.second*mid*.86f),Offset(size.width*index/192,mid-peak.first*mid*.86f),maxOf(1f,size.width/192))
        fun x(source:Long)=size.width*(source-start).toFloat()/maxOf(1,end-start)
        for(marker in markers){val downbeat=marker in downbeats;drawLine(if(downbeat)colors.primary else colors.border,Offset(x(marker),0f),Offset(x(marker),if(downbeat)size.height else size.height*.3f),1.dp.toPx())}
        (held ?: selected)?.takeIf {it in start..end}?.let {drawLine(colors.primary,Offset(x(it),0f),Offset(x(it),size.height),2.dp.toPx());drawCircle(colors.primary,4.dp.toPx(),Offset(x(it),6.dp.toPx()))}
    }
    if(!canPick)Text("Load the current waveform to choose a point",style=SoundQ.typography.caption)
    Row(horizontalArrangement=Arrangement.spacedBy(SoundQ.spacing.small)) {
        SoundQButton("Earlier",{center=(center-span/2).coerceAtLeast(range.first)},enabled=canPick&&start>range.first,variant=SoundQButtonVariant.Quiet)
        SoundQButton(if(zoom==1)"Zoom in" else "Zoom ×$zoom",{zoom=if(zoom>=64)1 else zoom*2;center=(selected ?: center).coerceIn(range.first,range.last)},enabled=canPick,variant=SoundQButtonVariant.Quiet)
        SoundQButton("Later",{center=(center+span/2).coerceAtMost(range.last)},enabled=canPick&&end<range.last,variant=SoundQButtonVariant.Quiet)
    }
}

@Composable internal fun SourceTimingPicker(label:String,clip:TimelineClip,wave:TrackWaveform?,pick:SourceTimingPick?,enabled:Boolean,lifetime:Any?=clip,onChange:(SourceTimingPick)->Unit) {
    val current=wave?.let {w->pick?.takeIf {it.matches(clip,w)} ?: SourceTimingPick.forSource(clip,w)}
    var origin by remember(clip.occurrence,wave?.sourceKey){mutableStateOf(false)}
    Text(label,style=SoundQ.typography.title)
    SoundQTextField(current?.bpm.orEmpty(),{value->current?.let {onChange(it.copy(bpm=value,adopted=null))}},"Source BPM",enabled=enabled&&current!=null)
    SoundQButton("Use qualified timing",{if(wave!=null)current?.adopt(wave)?.let(onChange)},enabled=enabled&&wave?.phaseTiming!=null&&current!=null,variant=SoundQButtonVariant.Secondary)
    Row {
        SoundQButton(if(origin)"Beat anchor" else "Edit beat anchor",{origin=false},enabled=enabled,variant=SoundQButtonVariant.Quiet)
        SoundQButton(if(origin)"Edit group origin" else "Group origin",{origin=true},enabled=enabled,variant=SoundQButtonVariant.Quiet)
    }
    SourceMarkerPicker(if(origin)"Choose group origin" else "Choose beat anchor",clip,wave,if(origin)current?.groupOriginMs else current?.anchorMs,enabled,lifetime=lifetime) {value->
        current?.let {onChange(if(origin)it.copy(groupOriginMs=value) else it.copy(anchorMs=value,adopted=null))}
    }
    if(origin)SoundQButton("Leave group origin unknown",{current?.let {onChange(it.copy(groupOriginMs=null))}},enabled=enabled&&current!=null,variant=SoundQButtonVariant.Quiet)
}
