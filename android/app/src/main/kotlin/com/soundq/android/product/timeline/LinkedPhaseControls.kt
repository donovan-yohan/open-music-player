package com.soundq.android.product.timeline

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.*
import androidx.compose.ui.unit.dp
import com.soundq.android.data.timeline.*
import com.soundq.designsystem.*
import kotlinx.coroutines.*

/** UI owns only unaccepted input. Every durable action returns to the existing timeline owner. */
@Composable internal fun LinkedPhaseControls(
    document:TimelineDocument,waves:Map<Long,TrackWaveform>,busy:Boolean,canUndo:Boolean,valid:()->Boolean,
    preview:(PhaseEdit)->EditDecision,commit:suspend (PhaseEdit)->Boolean,
    move:suspend (TimelineEdit)->Boolean,unlock:suspend (Long)->Boolean,undo:suspend ()->Boolean,
    movement:TimelineEdit?=null,onMovementConsumed:()->Unit={},onPreview:(TimelineDocument?)->Unit={},setBusy:(Boolean)->Unit={},
) {
    var master by remember {mutableStateOf<String?>(null)}
    var incoming by remember {mutableStateOf<String?>(null)}
    var increment by remember {mutableIntStateOf(1)}
    var pickA by remember {mutableStateOf<SourceTimingPick?>(null)};var pickB by remember {mutableStateOf<SourceTimingPick?>(null)}
    var proposed by remember {mutableStateOf<Long?>(null)}
    var pairStart by remember {mutableStateOf<Long?>(null)}
    var showTiming by remember {mutableStateOf(false)}
    var held by remember {mutableStateOf<PhaseEdit?>(null)}
    var heldMove by remember {mutableStateOf<TimelineEdit?>(null)}
    var heldAdmission by remember {mutableStateOf<(() -> Boolean)?>(null)}
    var message by remember {mutableStateOf<String?>(null)}
    val jobs=rememberCoroutineScope()
    fun cancel(){held=null;heldMove=null;heldAdmission=null;onPreview(null);onMovementConsumed()}
    LaunchedEffect(document.revision){held=null;heldMove=null;heldAdmission=null;onPreview(null);onMovementConsumed()}
    LaunchedEffect(movement){movement?.let {held=null;heldMove=it;heldAdmission=valid;onPreview(runCatching {document.edited(it)}.getOrNull())}}
    BackHandler(held!=null||heldMove!=null){cancel()}
    LaunchedEffect(document.phaseLink,waves) {
        document.phaseLink?.let {link ->
            master=link.reference;incoming=link.incoming;increment=link.increment
            fun captured(id:String,grid:PhaseGrid):SourceTimingPick? {
                val clip=document.clips.singleOrNull {it.occurrence==id} ?: return null
                val wave=waves[clip.track] ?: return null
                return SourceTimingPick.forSource(clip,wave)?.takeIf {it.sourceKey==grid.sourceKey}?.copy(anchorMs=grid.anchorMs,groupOriginMs=grid.groupOriginMs,adopted=grid)
            }
            pickA=captured(link.reference,link.referenceGrid);pickB=captured(link.incoming,link.incomingGrid)
        }
    }
    val a=document.clips.firstOrNull {it.occurrence==master}
    val b=document.clips.firstOrNull {it.occurrence==incoming}
    LaunchedEffect(a,b,waves[a?.track],waves[b?.track]) {
        if(a!=null&&pickA!=null&&waves[a.track]?.let {pickA!!.matches(a,it)}!=true)pickA=null
        if(b!=null&&pickB!=null&&waves[b.track]?.let {pickB!!.matches(b,it)}!=true)pickB=null
        cancel();proposed=null;pairStart=null
    }
    fun grid(c:TimelineClip,pick:SourceTimingPick?):PhaseGrid {
        val wave=waves[c.track] ?: error("Load the current source")
        return requireNotNull(pick?.phaseGrid(c,wave)) {"Choose a beat anchor and compatible source BPM"}
    }
    fun action(block:suspend ()->Boolean) {
        if(busy||!valid())return
        setBusy(true)
        jobs.launch {try {val ok=withContext(Dispatchers.IO){block()};cancel();message=if(ok)"Saved draft relation. Apply explicitly to audition the exact revision." else "Edit refused. Qualify the current sources and preview again."}finally{setBusy(false)}}
    }
    Column(Modifier.fillMaxWidth().onPreviewKeyEvent {if(it.key==Key.Escape&&(held!=null||heldMove!=null)){cancel();true}else false},verticalArrangement=Arrangement.spacedBy(SoundQ.spacing.small)) {
        Text("Reference-linked placement",style=SoundQ.typography.title)
        Text("Choose each source beat, then preview their alignment.",style=SoundQ.typography.caption)
        PhaseOccurrencePicker("Reference",master,document,busy){master=it;pickA=null;cancel()}
        PhaseOccurrencePicker("Incoming",incoming,document,busy){incoming=it;pickB=null;proposed=null;cancel()}
        SoundQButton("Increment $increment beats",{increment=when(increment){1->4;4->16;16->32;else->1};cancel()},enabled=!busy,variant=SoundQButtonVariant.Secondary)
        SoundQButton(if(showTiming)"Hide source timing" else "Choose source timing",{showTiming=!showTiming},enabled=!busy,variant=SoundQButtonVariant.Quiet)
        if(showTiming) {
            a?.let {SourceTimingPicker("Reference",it,waves[it.track],pickA,!busy,lifetime=document.revision){value->pickA=value;cancel()}}
            b?.let {SourceTimingPicker("Incoming",it,waves[it.track],pickB,!busy,lifetime=document.revision){value->pickB=value;cancel()}}
        }
        Text("Incoming placement",style=SoundQ.typography.caption)
        Row {
            listOf(-1,1).forEach {direction->SoundQButton(if(direction<0)"−$increment beats" else "+$increment beats",{
                if(b!=null)runCatching {grid(b,pickB)}.getOrNull()?.let {g->proposed=(proposed ?: b.globalStartMs)+direction*g.periodMs*increment;cancel()}
            },enabled=!busy&&b!=null&&runCatching {grid(b,pickB)}.isSuccess,variant=SoundQButtonVariant.Secondary)}
            SoundQButton("Current",{proposed=null;cancel()},enabled=!busy,variant=SoundQButtonVariant.Quiet)
        }
        Row(horizontalArrangement=Arrangement.spacedBy(SoundQ.spacing.small)) {
            SoundQIconButton(SoundQIcon.Eye,"Preview linked placement",{
                cancel()
                if(valid()&&a!=null&&b!=null)try {
                    val edit=PhaseEdit(document.revision,a,b,grid(a,pickA),grid(b,pickB),increment,proposed ?: b.globalStartMs)
                    val decision=preview(edit)
                    if(decision.accepted){val solution=solvePhase(document,edit);held=edit;heldAdmission=valid;onPreview(document.copy(clips=solution.clips,phaseLink=solution.link));message="Dashed preview only. No draft or player change."}else message=decision.reason
                }catch(_:Exception){message="Choose both beat anchors and equal supported source BPM. Grouped steps also need both group origins."}
            },enabled=!busy&&a!=null&&b!=null)
            SoundQIconButton(SoundQIcon.Check,"Accept linked preview",{val e=held;val m=heldMove;val admission=heldAdmission;if(admission?.invoke()!=true){cancel();message="Preview lifetime ended. Preview again."}else if(e!=null)action {admission()&&commit(e)} else if(m!=null)action {admission()&&move(m)}},enabled=!busy&&(held!=null||heldMove!=null))
            SoundQIconButton(SoundQIcon.Close,"Cancel linked preview",{cancel()},enabled=!busy&&(held!=null||heldMove!=null))
            SoundQIconButton(SoundQIcon.Back,"Undo linked edit",{action {undo()}},enabled=!busy&&canUndo)
        }
        document.phaseLink?.let {link ->
            Text("Linked · ${link.increment} beats",style=SoundQ.typography.caption)
            val reference=document.clips.single {it.occurrence==link.reference}
            Text("Move pair",style=SoundQ.typography.caption)
            Row {
                listOf(-1,1).forEach {direction->SoundQButton(if(direction<0)"−${link.increment} beats" else "+${link.increment} beats",{
                    pairStart=(pairStart ?: reference.globalStartMs)+direction*link.referenceGrid.periodMs*link.increment;cancel()
                },enabled=!busy,variant=SoundQButtonVariant.Secondary)}
            }
            SoundQButton("Preview pair move",{
                val edit=TimelineEdit(document.revision,reference,EditKind.Placement,pairStart ?: reference.globalStartMs)
                val next=runCatching {document.edited(edit)}.getOrNull()
                if(next!=null&&validateTimeline(next.clips)==null&&validatePhase(next)==null){cancel();heldMove=edit;heldAdmission=valid;onPreview(next)}else message="Pair move is outside bounds or exceeds four voices."
            },enabled=!busy,variant=SoundQButtonVariant.Quiet)
            SoundQButton("Unlock relation",{action {unlock(document.revision)}},enabled=!busy,variant=SoundQButtonVariant.Secondary)
            Text("Unlock keeps positions, speeds and fades.",style=SoundQ.typography.caption)
        }
        message?.let {Text(it,style=SoundQ.typography.caption)}
    }
}

@Composable private fun PhaseOccurrencePicker(label:String,selected:String?,document:TimelineDocument,busy:Boolean,onSelect:(String)->Unit) {
    var open by remember {mutableStateOf(false)}
    val index=document.clips.indexOfFirst {it.occurrence==selected}
    Box {
        SoundQButton(if(index<0)"$label · choose" else "$label · ${index+1} · ${document.clips[index].title}",{open=true},enabled=!busy,variant=SoundQButtonVariant.Secondary)
        DropdownMenu(open&&!busy,{open=false}) {
            document.clips.forEachIndexed {i,c ->DropdownMenuItem(text={Text("${i+1} · ${c.title}")},onClick={open=false;onSelect(c.occurrence)},modifier=Modifier.heightIn(min=48.dp))}
        }
    }
}
