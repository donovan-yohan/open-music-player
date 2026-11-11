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
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import com.soundq.android.data.timeline.*
import com.soundq.designsystem.*

/** Placement viewport only: it does not constrain or rewrite authored source bounds. */
@Composable internal fun TimelinePlacementPicker(clip:TimelineClip,wave:TrackWaveform?,value:Long,enabled:Boolean,lifetime:Any?=clip,onPlace:(Long)->Unit) {
    val length=clip.globalEndMs-clip.globalStartMs
    var start by remember(clip){mutableLongStateOf(maxOf(0,clip.globalStartMs-length))}
    var span by remember(clip){mutableLongStateOf(maxOf(10000,length*3))}
    val end=minOf(302400000000L,start+span)
    val tier=wave?.takeIf {it.track.value==clip.track&&it.durationMs==clip.sourceDurationMs}?.tiers?.maxByOrNull {it.minima.size}
    val canPlace=enabled&&tier!=null&&tier.minima.isNotEmpty()&&tier.maxima.isNotEmpty()
    val colors=SoundQ.colors
    val latestPlace by rememberUpdatedState(onPlace)
    var held by remember(clip,start,end){mutableStateOf<Long?>(null)}
    val alive=remember(clip,wave?.sourceKey,lifetime){java.util.concurrent.atomic.AtomicBoolean(true)}
    DisposableEffect(alive){onDispose{alive.set(false)}}
    Text("Drag the waveform to place the clip",style=SoundQ.typography.caption)
    Canvas(Modifier.fillMaxWidth().height(96.dp).background(colors.surface)
        .semantics {contentDescription="Clip placement waveform"}
        .pointerInput(clip,start,end,canPlace,wave?.sourceKey,lifetime){
            if(canPlace)awaitEachGesture {
                val down=awaitFirstDown();down.consume()
                val initial=sourceMarkerAt(down.position.x,size.width.toFloat(),start,end,emptyList(),0f)
                // Grabbing the body preserves the contact offset; touching empty space places the start.
                val offset=if(initial in value..(value+length))initial-value else 0L
                held=(initial-offset).coerceAtLeast(0)
                var normal=false
                try {
                    while(true){
                        val event=awaitPointerEvent();if(event.changes.count {it.pressed}>1)break
                        val change=event.changes.firstOrNull {it.id==down.id} ?: break
                        if(change.isConsumed)break
                        held=(sourceMarkerAt(change.position.x,size.width.toFloat(),start,end,emptyList(),0f)-offset).coerceAtLeast(0);change.consume()
                        if(!change.pressed){normal=true;break}
                    }
                    if(normal&&alive.get())held?.let(latestPlace)
                }finally{held=null}
            }
        }) {
        val shown=held ?: value
        fun x(t:Long)=size.width*(t-start).toFloat()/(end-start)
        val left=x(shown);val right=x(shown+length)
        if(tier!=null) {
            val n=minOf(tier.minima.size,tier.maxima.size)
            val first=(clip.sourceInMs.toDouble()/wave.durationMs*n).toInt().coerceIn(0,n)
            val last=(clip.sourceOutMs.toDouble()/wave.durationMs*n).toInt().coerceIn(first,n)
            val step=maxOf(1,(last-first)/192)
            for(i in first until last step step) {
                val global=shown+(clip.globalAt((i.toDouble()/n*wave.durationMs).toLong())-clip.globalStartMs)
                val px=x(global)
                if(px in 0f..size.width)drawLine(colors.muted,Offset(px,size.height/2-tier.maxima[i]*size.height*.42f),Offset(px,size.height/2-tier.minima[i]*size.height*.42f),maxOf(1f,(right-left)/192))
            }
        }
        drawLine(colors.primary,Offset(left,0f),Offset(left,size.height),2.dp.toPx())
        drawLine(colors.primary,Offset(right,0f),Offset(right,size.height),2.dp.toPx())
        drawLine(colors.border,Offset(0f,size.height-1f),Offset(size.width,size.height-1f),1f)
    }
    if(!canPlace)Text("Load the current waveform to place the clip",style=SoundQ.typography.caption)
    Row {
        SoundQButton("Earlier",{start=maxOf(0,start-span/2)},enabled=enabled&&start>0,variant=SoundQButtonVariant.Quiet)
        SoundQButton("Zoom",{span=if(span<=2000)maxOf(10000,length*3) else maxOf(2000,span/2);start=maxOf(0,value-span/3)},enabled=enabled,variant=SoundQButtonVariant.Quiet)
        SoundQButton("Later",{start=minOf(302400000000L-span,start+span/2)},enabled=enabled&&end<302400000000L,variant=SoundQButtonVariant.Quiet)
    }
}
