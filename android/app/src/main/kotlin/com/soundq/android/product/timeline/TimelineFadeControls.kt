package com.soundq.android.product.timeline

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.key.*
import androidx.compose.ui.unit.dp
import com.soundq.android.data.timeline.*
import com.soundq.android.product.ProductViewModel
import com.soundq.designsystem.*
import kotlinx.coroutines.*
import kotlin.math.*

/** A local, non-audible preview. Only the existing durable owner accepts edits. */
@Composable internal fun TimelineFadeControls(model:ProductViewModel,document:TimelineDocument,valid:()->Boolean,setBusy:(Boolean)->Unit,busy:Boolean) {
    var outgoing by remember {mutableStateOf<String?>(null)}
    var incoming by remember {mutableStateOf<String?>(null)}
    var preview by remember {mutableStateOf<TimelineFadeEdit?>(null)}
    var message by remember {mutableStateOf<String?>(null)}
    val repository=model.graph.timeline
    val state by repository.state.collectAsState()
    val jobs=rememberCoroutineScope()
    fun cancel(){preview=null;message=null}
    // Captured previews are not refreshed into a new document, account or pair.
    LaunchedEffect(document){if(preview!=null&&preview!!.revision!=document.revision){preview=null;message="Draft changed. Preview the selected occurrences again."}}
    BackHandler(preview!=null){cancel()}
    Column(Modifier.fillMaxWidth().onPreviewKeyEvent {if(it.key==Key.Escape&&preview!=null){cancel();true}else false},verticalArrangement=Arrangement.spacedBy(SoundQ.spacing.small)) {
        Text("Crossfade",style=SoundQ.typography.title)
        Text("Fade across the full overlap. Move the clips to change its length.",style=SoundQ.typography.caption)
        FadeOccurrencePicker("Outgoing occurrence",outgoing,document,busy){outgoing=it;cancel()}
        FadeOccurrencePicker("Incoming occurrence",incoming,document,busy){incoming=it;cancel()}
        val a=document.clips.firstOrNull {it.occurrence==outgoing}
        val b=document.clips.firstOrNull {it.occurrence==incoming}
        Text("Full existing overlap",style=SoundQ.typography.caption)
        Row(horizontalArrangement=Arrangement.spacedBy(SoundQ.spacing.small)) {
            SoundQIconButton(SoundQIcon.Eye,"Preview crossfade",{
                if(!busy&&valid()&&a!=null&&b!=null) {
                    val edit=fullOverlapFade(document.revision,a,b)
                    val decision=repository.preview(edit);preview=if(decision.accepted)edit else null;message=decision.reason
                }
            },enabled=!busy&&state.writable&&a!=null&&b!=null)
            SoundQIconButton(SoundQIcon.Check,"Accept crossfade",{
                val edit=preview
                if(!busy&&edit!=null&&valid()) {
                    setBusy(true);model.controller.pause()
                    jobs.launch {try {
                        val accepted=withContext(Dispatchers.IO){repository.commit(edit,valid)}
                        preview=null;message=if(accepted)"Crossfade saved in draft. Apply explicitly to audition." else "Crossfade was refused. Preview the current occurrences again."
                    } finally {setBusy(false)}}
                }
            },enabled=!busy&&preview!=null)
            SoundQIconButton(SoundQIcon.Close,"Cancel crossfade preview",{cancel()},enabled=!busy&&preview!=null)
            SoundQIconButton(SoundQIcon.Back,"Undo crossfade edit",{
                if(!busy&&valid()){setBusy(true);jobs.launch {try {withContext(Dispatchers.IO){repository.undo(valid)};cancel()}finally{setBusy(false)}}}
            },enabled=!busy&&state.canUndo)
        }
        preview?.let {edit ->
            Text("Preview · full overlap",style=SoundQ.typography.caption)
            val colors=SoundQ.colors
            Canvas(Modifier.fillMaxWidth().height(48.dp)) {
                // Independent complementary envelopes over the same admitted global interval.
                val steps=64
                for(i in 0 until steps) {
                    val u=i.toFloat()/steps;val v=(i+1).toFloat()/steps
                    fun point(t:Float,incoming:Boolean)=Offset(size.width*t,size.height*(1-(if(incoming)sin(t*PI/2)else cos(t*PI/2)).toFloat()))
                    drawLine(colors.text,point(u,false),point(v,false),2.dp.toPx())
                    drawLine(colors.primary,point(u,true),point(v,true),2.dp.toPx())
                }
            }
            Text("Outgoing fades out · Incoming fades in",style=SoundQ.typography.caption)
        }
        if(preview==null&&a!=null&&b!=null&&a.fadeOutMs>0&&b.fadeInMs>0)Text("Crossfade in draft",style=SoundQ.typography.caption)
        message?.let {Text(it,style=SoundQ.typography.caption)}
    }
}

@Composable private fun FadeOccurrencePicker(label:String,selected:String?,document:TimelineDocument,busy:Boolean,onSelect:(String)->Unit) {
    var expanded by remember {mutableStateOf(false)}
    val clip=document.clips.firstOrNull {it.occurrence==selected}
    Box {
        SoundQButton(label,{expanded=true},enabled=!busy&&document.clips.isNotEmpty(),variant=SoundQButtonVariant.Secondary)
        DropdownMenu(expanded&&!busy,{expanded=false}) {
            document.clips.forEachIndexed {index,c->
                DropdownMenuItem(text={Text("${index+1} · ${c.title}")},onClick={expanded=false;onSelect(c.occurrence)},modifier=Modifier.heightIn(min=48.dp))
            }
        }
    }
    Text(clip?.let {"$label · ${it.title}"} ?: "$label · not selected",style=SoundQ.typography.caption)
}
