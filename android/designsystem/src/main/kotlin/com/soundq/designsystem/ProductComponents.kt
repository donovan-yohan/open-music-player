package com.soundq.designsystem

import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.ui.input.pointer.*
import kotlinx.coroutines.launch
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.input.key.*
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.input.*
import kotlin.math.roundToInt

/** Selection/composition are native values, never reset by incoming feature state. */
@Composable fun SoundQEntryField(value:TextFieldValue,onValueChange:(TextFieldValue)->Unit,label:String,modifier:Modifier=Modifier,enabled:Boolean=true,
    secure:Boolean=false,revealed:Boolean=false,onReveal:(()->Unit)?=null,error:String?=null,keyboardOptions:KeyboardOptions=KeyboardOptions.Default,keyboardActions:KeyboardActions=KeyboardActions.Default,contentType:ContentType?=null) {
    Column(modifier.fillMaxWidth(),verticalArrangement=Arrangement.spacedBy(SoundQ.spacing.small)) {
        Text(label,style=SoundQ.typography.caption)
        OutlinedTextField(value,onValueChange,Modifier.fillMaxWidth().semantics {contentDescription=label;contentType?.let {this.contentType=it}},enabled=enabled,singleLine=true,
            textStyle=SoundQ.typography.body,shape=RectangleShape,isError=error!=null,
            visualTransformation=if(secure&&!revealed)PasswordVisualTransformation() else VisualTransformation.None,
            keyboardOptions=keyboardOptions,keyboardActions=keyboardActions,
            trailingIcon=if(secure&&onReveal!=null) {{SoundQIconButton(if(revealed)SoundQIcon.EyeOff else SoundQIcon.Eye,if(revealed)"Hide $label" else "Show $label",onReveal,enabled=enabled)}} else null,
            supportingText=if(error!=null) {{Text(error)}} else null,
            colors=OutlinedTextFieldDefaults.colors(focusedBorderColor=SoundQ.colors.focus,unfocusedBorderColor=SoundQ.colors.inputBorder,cursorColor=SoundQ.colors.focus,errorBorderColor=SoundQ.colors.error))
    }
}
enum class FeedbackKind {Loading,Empty,Error,Notice}
@Composable fun SoundQFeedback(title:String,kind:FeedbackKind,detail:String?=null,action:String?=null,onAction:(()->Unit)?=null) {
    Column(Modifier.fillMaxWidth().padding(vertical=SoundQ.spacing.large),verticalArrangement=Arrangement.spacedBy(SoundQ.spacing.medium)) {
        Text(title,style=SoundQ.typography.title,color=if(kind==FeedbackKind.Error)SoundQ.colors.error else SoundQ.colors.text,
            modifier=Modifier.semantics {liveRegion=LiveRegionMode.Polite})
        detail?.let {Text(it,color=SoundQ.colors.muted)}
        if(action!=null&&onAction!=null)SoundQButton(action,onAction,variant=SoundQButtonVariant.Secondary)
    }
}
@Composable fun SoundQTabs(labels:List<String>,selected:Int,onSelect:(Int)->Unit) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).selectableGroup()) {
        labels.forEachIndexed {index,label ->
            val active=index==selected
            Column(Modifier.width(IntrinsicSize.Max).widthIn(min=96.dp).selectable(active,role=Role.Tab,onClick={onSelect(index)})) {
                Box(Modifier.heightIn(min=48.dp).padding(horizontal=16.dp,vertical=12.dp),contentAlignment=Alignment.Center) {
                    Text(label,style=SoundQ.typography.body,color=if(active)SoundQ.colors.primary else SoundQ.colors.muted,maxLines=1,softWrap=false)
                }
                Box(Modifier.fillMaxWidth().height(1.dp).background(if(active)SoundQ.colors.primary else SoundQ.colors.border))
            }
        }
    }
}
private val LocalMediaRowBottomRule=staticCompositionLocalOf {true}

/** Paint slot boundaries above all translated children, without changing list geometry. */
@Composable fun SoundQMediaListRules(listState:LazyListState,content:@Composable (Modifier)->Unit) {
    val color=SoundQ.colors.border
    val width=SoundQ.sizes.border
    CompositionLocalProvider(LocalMediaRowBottomRule provides false) {
        content(Modifier.drawWithContent {
            drawContent()
            val info=listState.layoutInfo
            val thickness=width.toPx().roundToInt().coerceAtLeast(1).toFloat()
            clipRect(left=0f,top=0f,right=size.width,bottom=size.height) {
                info.visibleItemsInfo.forEach {item ->
                    val bottom=(item.offset+item.size-info.viewportStartOffset).toFloat()
                    drawRect(color,topLeft=Offset(0f,bottom-thickness),size=androidx.compose.ui.geometry.Size(size.width,thickness))
                }
            }
        })
    }
}

/** Paint on the complete row host unless its list owns the stationary boundaries. */
@Composable fun Modifier.mediaRowBottomRule():Modifier {
    if(!LocalMediaRowBottomRule.current)return this
    val color=SoundQ.colors.border
    val width=SoundQ.sizes.border
    return drawWithContent {
        drawContent()
        val thickness=width.toPx().roundToInt().coerceAtLeast(1).toFloat()
        drawRect(color,topLeft=Offset(0f,size.height-thickness),size=androidx.compose.ui.geometry.Size(size.width,thickness))
    }
}
@Composable fun mediaRowBackground(current:Boolean):Color = if(current)SoundQ.colors.surface else SoundQ.colors.background

val LocalMediaRowCompactMetadata=staticCompositionLocalOf {false}

/** compactSupporting retains dense facts; supportingMaxLines > 1 opts into natural-height event facts. */
@Composable fun SoundQMediaRow(title:String,subtitle:String,current:Boolean,onActivate:()->Unit,onMore:()->Unit,modifier:Modifier=Modifier,artwork:(@Composable ()->Unit)?=null,supporting:String?=null,metadata:(@Composable ()->Unit)?=null,enabled:Boolean=true,compactSupporting:String?=supporting,supportingMaxLines:Int=1) {
    require(supportingMaxLines>0)
    val colors=SoundQ.colors
    val multiline=supportingMaxLines>1
    val enlarged=LocalDensity.current.fontScale>=1.3f
    // Normal geometry stays fixed; enlarged text reserves title, artist/duration, then analysis.
    val rowHeight=if(enlarged&&metadata!=null)106.dp else SoundQ.sizes.mediaRow
    val compactFact=compactSupporting?.takeIf {it.isNotBlank()} ?: supporting
    val density=LocalDensity.current
    val titleStyle=if(enlarged&&!multiline)SoundQ.typography.title.copy(lineHeight=with(density){38.dp.toSp()}) else SoundQ.typography.title
    val artistStyle=if(enlarged&&!multiline)SoundQ.typography.caption.copy(lineHeight=with(density){34.dp.toSp()}) else SoundQ.typography.caption
    val identity=listOf(LocalMediaMarqueeIdentity.current,title,subtitle)
    Box(modifier.fillMaxWidth().then(if(multiline)Modifier.heightIn(min=SoundQ.sizes.mediaRow)else Modifier.height(rowHeight))
        .background(mediaRowBackground(current))
        .mediaRowBottomRule()
        .semantics(mergeDescendants=true) {
            selected=current;if(current)stateDescription="Current track"
            // A metadata content description must not eclipse the song's accessible identity.
            contentDescription=listOfNotNull(title,subtitle,supporting ?: compactFact).joinToString(", ")
        }
        .clickable(enabled=enabled,role=Role.Button,onClick=onActivate)) {
        Row(if(multiline)Modifier.fillMaxWidth().height(IntrinsicSize.Min).heightIn(min=SoundQ.sizes.mediaRow)else Modifier.fillMaxSize(),verticalAlignment=Alignment.CenterVertically) {
            SoundQArtworkSlot(Modifier.testTag("media-artwork"),size=if(multiline)SoundQ.sizes.mediaRow else rowHeight,artwork=artwork)
            Column(Modifier.weight(1f).then(if(multiline)Modifier else Modifier.fillMaxHeight()).padding(horizontal=if(enlarged&&metadata!=null&&!multiline)4.dp else 8.dp),verticalArrangement=Arrangement.Center) {
                SoundQMediaIdentityText(title,current,identity,modifier=(if(multiline)Modifier.fillMaxWidth() else if(enlarged)Modifier.height(38.dp) else Modifier).testTag("media-title"),
                    style=titleStyle,color=if(current)colors.primary else colors.text)
                if(multiline) {
                    // History facts own the full lane below identity and optional real metadata.
                    SoundQMediaIdentityText(subtitle,current,identity,modifier=Modifier.fillMaxWidth().testTag("media-artist"),style=artistStyle,color=colors.muted)
                    metadata?.invoke()
                    supporting?.let {
                        Text(it,Modifier.fillMaxWidth(),color=colors.muted,style=SoundQ.typography.caption,
                            maxLines=supportingMaxLines,softWrap=true,overflow=TextOverflow.Ellipsis)
                    }
                } else if(enlarged)Box(Modifier.height(if(metadata!=null)68.dp else 34.dp).fillMaxWidth()) {
                    // The metadata slot paints duration at the right of this first line and analysis below.
                    Row(Modifier.height(34.dp).fillMaxWidth(if(metadata!=null)0.4f else 1f),verticalAlignment=Alignment.CenterVertically) {
                        SoundQMediaIdentityText(subtitle,current,identity,modifier=Modifier.weight(1f).testTag("media-artist"),style=artistStyle,color=colors.muted)
                        compactFact?.let {fact ->
                            Text(fact,Modifier.weight(1f,fill=false).padding(start=4.dp)
                                .clearAndSetSemantics {text=androidx.compose.ui.text.AnnotatedString(supporting ?: fact)},
                                style=artistStyle,color=colors.muted,maxLines=1,softWrap=false,overflow=TextOverflow.Ellipsis)
                        }
                    }
                    if(metadata!=null)CompositionLocalProvider(LocalMediaRowCompactMetadata provides true) {
                        Box(Modifier.fillMaxWidth()) {metadata()}
                    }
                } else {
                    SoundQMediaIdentityText(subtitle,current,identity,modifier=Modifier.testTag("media-artist"),style=artistStyle,color=colors.muted)
                    if(metadata!=null||supporting!=null)Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {
                        if(metadata!=null)Box(Modifier.width(IntrinsicSize.Max)) {metadata()}
                        supporting?.let {
                            Text(it,modifier=Modifier.weight(1f).padding(start=if(metadata!=null)4.dp else 0.dp),
                                color=colors.muted,style=SoundQ.typography.caption,maxLines=1,softWrap=false,overflow=TextOverflow.Ellipsis)
                        }
                    }
                }
            }
            CellIcon(SoundQIcon.More,"More for $title",onMore,Modifier.width(48.dp).fillMaxHeight())
        }
    }
}
/** Shared in compact and full surfaces; no media/service types in visual module. */
@Composable fun SoundQTransport(playing:Boolean,available:Boolean,preparing:Boolean,onPrimary:()->Unit,onPrevious:(()->Unit)?=null,onNext:(()->Unit)?=null,canPrevious:Boolean=false,canNext:Boolean=false,
    shuffle:Boolean=false,repeat:Int=0,onShuffle:(()->Unit)?=null,onRepeat:(()->Unit)?=null,modifier:Modifier=Modifier) {
    BoxWithConstraints(modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(if(maxWidth<350.dp)0.dp else 8.dp,Alignment.CenterHorizontally),verticalAlignment=Alignment.CenterVertically) {
            PlayerControl("Shuffle ${if(shuffle)"on" else "off"}",onShuffle,available&&onShuffle!=null,active=shuffle) {
                SoundQIcon(SoundQPlayerIcon.Shuffle,null,tint=it)
            }
            PlayerControl("Previous track",onPrevious,available&&canPrevious&&onPrevious!=null) {SoundQIcon(SoundQIcon.Previous,null,tint=it)}
            PlayerControl(if(playing||preparing)"Pause" else "Play",onPrimary,available,primary=true) {
                SoundQIcon(if(playing||preparing)SoundQIcon.Pause else SoundQIcon.Play,null,tint=it)
            }
            PlayerControl("Next track",onNext,available&&canNext&&onNext!=null) {SoundQIcon(SoundQIcon.Next,null,tint=it)}
            val repeatLabel="Repeat ${when(repeat){1->"one";2->"all";else->"off"}}"
            PlayerControl(repeatLabel,onRepeat,available&&onRepeat!=null,active=repeat==1||repeat==2) {
                Box(contentAlignment=Alignment.Center) {
                    SoundQIcon(SoundQPlayerIcon.Repeat,null,tint=it)
                    if(repeat==1)Text("1",modifier=Modifier.clearAndSetSemantics {},style=SoundQ.typography.mono,color=it)
                }
            }
        }
    }
}
@Composable fun SoundQCompactPlayer(title:String,artist:String,playing:Boolean,available:Boolean,preparing:Boolean,onExpand:()->Unit,onPrimary:()->Unit,onQueue:()->Unit,artwork:(@Composable ()->Unit)?=null,timing:CompactSongTiming=CompactSongTiming()) {
    val density=LocalDensity.current
    val measurer=androidx.compose.ui.text.rememberTextMeasurer()
    val titleHeight=with(density){measurer.measure("Ag",SoundQ.typography.title,maxLines=1).size.height.toDp()}
    val artistHeight=with(density){measurer.measure("Ag",SoundQ.typography.caption,maxLines=1).size.height.toDp()}
    val clockWidth=with(density){measurer.measure(timing.clockText,SoundQ.typography.mono,maxLines=1).size.width.toDp()}
    val hasClock=timing.selected
    val displayTitle=title
    val identity=listOf(timing.identity ?: LocalMediaMarqueeIdentity.current,displayTitle,artist)
    val colors=SoundQ.colors
    BoxWithConstraints(Modifier.fillMaxWidth().background(colors.player)) {
        val footer=hasClock&&(density.fontScale>=1.3f||clockWidth>maxWidth-72.dp-96.dp-16.dp)
        val rowHeight=if(footer)(titleHeight+artistHeight+8.dp).coerceAtLeast(72.dp) else 72.dp
        val stackClock=clockWidth>maxWidth-16.dp
        val clock:@Composable ()->Unit={
            Text(if(footer&&stackClock)timing.clockText.replace(" / ","\n/ ") else timing.clockText,
                Modifier.fillMaxWidth().semantics {contentDescription=timing.clockDescription},
                style=SoundQ.typography.mono,color=colors.muted,softWrap=false)
        }
        Column(Modifier.fillMaxWidth()) {
            Row(Modifier.fillMaxWidth().height(rowHeight),verticalAlignment=Alignment.CenterVertically) {
                Row(Modifier.weight(1f).fillMaxHeight()
                    .semantics(mergeDescendants=true) {
                        contentDescription="$displayTitle, $artist"
                        stateDescription=when {timing.state==CompactPlaybackState.Ended->"Playback ended";playing->"Playing";timing.state==CompactPlaybackState.None->"Nothing playing";else->"Paused"}
                    }
                    .clickable(role=Role.Button,onClickLabel="Open now playing",onClick=onExpand),verticalAlignment=Alignment.CenterVertically) {
                    SoundQArtworkSlot(Modifier.testTag("compact-artwork"),size=rowHeight,artwork=artwork)
                    Column(Modifier.weight(1f).padding(horizontal=8.dp),verticalArrangement=Arrangement.Center) {
                        SoundQMediaIdentityText(displayTitle,selected=timing.selected,identity=identity,modifier=Modifier.testTag("compact-title"),style=SoundQ.typography.title)
                        if(artist.isNotEmpty())SoundQMediaIdentityText(artist,selected=timing.selected,identity=identity,modifier=Modifier.testTag("compact-artist"),style=SoundQ.typography.caption,color=colors.muted)
                        if(hasClock&&!footer)clock()
                    }
                }
                CellIcon(if(playing||preparing)SoundQIcon.Pause else SoundQIcon.Play,
                    if(playing||preparing)"Pause" else "Play",onPrimary,
                    modifier=Modifier.width(48.dp).fillMaxHeight().cellRule(start=true),enabled=available)
                CellIcon(SoundQIcon.List,"Open listening queue",onQueue,Modifier.width(48.dp).fillMaxHeight().cellRule(start=true))
            }
            if(footer)Box(Modifier.fillMaxWidth().clickable(role=Role.Button,onClickLabel="Open now playing",onClick=onExpand).padding(horizontal=8.dp,vertical=4.dp)) {clock()}
        }
        val fraction=timing.fraction
        Box(Modifier.fillMaxWidth().height(2.dp).background(colors.border)
            .then(if(fraction!=null)Modifier.semantics {progressBarRangeInfo=ProgressBarRangeInfo(fraction,0f..1f)} else Modifier)
            .drawBehind {if(fraction!=null)drawRect(colors.primary,size=androidx.compose.ui.geometry.Size(size.width*fraction,size.height))})
    }
}
/** A single shared edge; never stacks a second border around touching cells. */
@Composable private fun Modifier.cellRule(start:Boolean=false):Modifier {
    val color=SoundQ.colors.border
    val width=with(LocalDensity.current){SoundQ.sizes.border.toPx()}
    return drawBehind {
        if(start)drawLine(color,Offset(0f,0f),Offset(0f,size.height),width)
    }
}

/** Border-free target for cells whose container owns the shared boundaries. */
@Composable private fun CellIcon(icon:SoundQIcon,label:String,onClick:()->Unit,modifier:Modifier=Modifier,enabled:Boolean=true) {
    Box(modifier.sizeIn(minWidth=SoundQ.sizes.target,minHeight=SoundQ.sizes.target)
        .semantics {contentDescription=label}
        .clickable(enabled=enabled,role=Role.Button,onClick=onClick),contentAlignment=Alignment.Center) {
        SoundQIcon(icon,null,tint=if(enabled)SoundQ.colors.text else SoundQ.colors.disabled)
    }
}

/** The four root destinations are a fixed row, not wrapping legacy tabs. */
@Composable fun SoundQBottomNavigation(selected:String,onSelect:(String)->Unit) {
    val labels=listOf("Home","Discover","Library","Playlists")
    val icons=listOf(SoundQIcon.Home,SoundQIcon.Search,SoundQIcon.Library,SoundQIcon.List)
    val expandedText=LocalDensity.current.fontScale>1f
    Column(Modifier.fillMaxWidth()) {
        SoundQDivider()
        Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).selectableGroup()) {
            labels.forEachIndexed {index,label->
                val active=label==selected
                Column(Modifier.weight(1f).fillMaxHeight().heightIn(min=64.dp)
                    .background(if(active)SoundQ.colors.surface else SoundQ.colors.background)
                    .cellRule(start=index>0)
                    .selectable(selected=active,role=Role.Tab,onClick={onSelect(label)})
                    .padding(vertical=SoundQ.spacing.small),horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.Center) {
                    SoundQIcon(icons[index],null,tint=if(active)SoundQ.colors.primary else SoundQ.colors.muted)
                    Text(label,style=SoundQ.typography.caption,color=if(active)SoundQ.colors.text else SoundQ.colors.muted,maxLines=if(expandedText)Int.MAX_VALUE else 1,softWrap=expandedText)
                }
            }
        }
    }
}

/** Viewport host for Queue/editor. The caller owns exactly one weighted content region. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable fun SoundQWorkspaceSheet(title:String,onDismiss:()->Unit,queueGesture:QueueGestureState?=null,actions:@Composable RowScope.()->Unit={},content:@Composable ColumnScope.()->Unit) {
    val dismiss by rememberUpdatedState(onDismiss)
    val requestDismiss:()->Unit={if(queueGesture?.cancel()!=true)dismiss()}
    val state=rememberModalBottomSheetState(skipPartiallyExpanded=true,confirmValueChange={value->value!=SheetValue.Hidden||queueGesture?.cancel()!=true})
    val worker=rememberCoroutineScope()
    val handleDismiss:()->Unit={worker.launch {state.hide();if(!state.isVisible)dismiss()};Unit}
    ModalBottomSheet(onDismissRequest={if(!state.isVisible)dismiss()},sheetState=state,sheetGesturesEnabled=false,
        modifier=Modifier.fillMaxHeight().onPreviewKeyEvent {
            if(queueGesture?.onKey(it)==true)true
            else if(it.key==Key.Escape&&it.type==KeyEventType.KeyUp){requestDismiss();true}else false
        },dragHandle=null,shape=RectangleShape,containerColor=SoundQ.colors.sheet,
        scrimColor=SoundQ.colors.scrim.copy(alpha=soundq.design.generated.SoundQComposeTokens.MOTION_SCRIM_OPACITY)) {
        Column(Modifier.fillMaxWidth().fillMaxHeight().imePadding()) {
            SoundQSheetDragHandle(title,handleDismiss)
            Row(Modifier.fillMaxWidth().heightIn(min=56.dp),verticalAlignment=Alignment.CenterVertically) {
                Text(title,Modifier.weight(1f).padding(horizontal=SoundQ.spacing.gutter).semantics {heading()},style=SoundQ.typography.title)
                actions()
                CellIcon(SoundQIcon.Close,"Close $title",requestDismiss,Modifier.heightIn(min=56.dp))
            }
            SoundQDivider()
            Column(Modifier.weight(1f).fillMaxWidth(),content=content)
        }
    }
}

@Composable fun SoundQSeek(position:Long,duration:Long,identity:String?,onSeek:(Long)->Unit) {
    val known=duration>0
    // Losing duration retires a held draft as well as disabling future seek admission.
    var draft by remember(identity,known) {mutableStateOf<Float?>(null)}
    val value=if(known)draft ?: (position.toDouble()/duration).toFloat() else 0f
    val semantics=if(known)Modifier.semantics {contentDescription="Playback position"}
        else Modifier.clearAndSetSemantics {
            contentDescription="Playback position";stateDescription="Duration unavailable";disabled()
            progressBarRangeInfo=ProgressBarRangeInfo.Indeterminate
        }
    Slider(value.coerceIn(0f,1f),{if(known)draft=it},Modifier.fillMaxWidth().heightIn(min=SoundQ.sizes.target).then(semantics),
        enabled=known,onValueChangeFinished={if(known)draft?.let {onSeek((it*duration).toLong())};draft=null})
    val elapsed=formatTime(if(known)draft?.let {it*duration}?.toLong() ?: position else position)
    Text("$elapsed / ${if(known)formatTime(duration) else "—"}",
        modifier=Modifier.fillMaxWidth().then(if(known)Modifier else Modifier.semantics {contentDescription="Elapsed $elapsed, Duration unavailable"}),
        style=SoundQ.typography.mono,textAlign=androidx.compose.ui.text.style.TextAlign.Center)
}
private fun formatTime(ms:Long):String = formatSongTime(ms)

/** Only downs in this full-size target may request drag dismissal. Body/nested scroll never may. */
@Composable private fun SoundQSheetDragHandle(title:String,onDismiss:()->Unit) {
    val dismiss by rememberUpdatedState(onDismiss)
    val threshold=with(LocalDensity.current){96.dp.toPx()}
    Box(Modifier.fillMaxWidth().height(48.dp)
        .semantics {
            contentDescription="Drag to close $title"
            onClick(label="Close $title"){dismiss();true}
            dismiss {dismiss();true}
        }
        .onKeyEvent {
            if(it.type==KeyEventType.KeyUp&&(it.key==Key.Enter||it.key==Key.Spacebar)){dismiss();true}else false
        }.focusable()
        .pointerInput(title,threshold) {
            awaitEachGesture {
                val down=awaitFirstDown(pass=PointerEventPass.Initial)
                down.consume()
                var refused=false
                while(true) {
                    val event=awaitPointerEvent(PointerEventPass.Initial)
                    val change=event.changes.firstOrNull {it.id==down.id}
                    if(change==null||event.changes.any {it.isConsumed}||event.changes.count {it.pressed}>1)refused=true
                    val travel=change?.let {it.position-down.position} ?: Offset.Zero
                    if(kotlin.math.abs(travel.x)>viewConfiguration.touchSlop&&kotlin.math.abs(travel.x)>kotlin.math.abs(travel.y))refused=true
                    val released=change!=null&&!change.pressed
                    event.changes.forEach {it.consume()}
                    if(released) {
                        if(!refused&&travel.y>=threshold&&travel.y>kotlin.math.abs(travel.x)*1.5f)dismiss()
                        break
                    }
                    if(event.changes.none {it.pressed})break
                }
            }
        },contentAlignment=Alignment.Center) {
        Box(Modifier.width(40.dp).height(4.dp).background(SoundQ.colors.muted))
    }
}
@OptIn(ExperimentalMaterial3Api::class)
@Composable fun SoundQSheet(title:String,onDismiss:()->Unit,queueGesture:QueueGestureState?=null,dismissAdmission:()->Boolean={true},scrollState:ScrollState=rememberScrollState(),onEscape:(()->Unit)?=null,content:@Composable ColumnScope.()->Unit) {
    val admit by rememberUpdatedState(dismissAdmission)
    val dismiss by rememberUpdatedState(onDismiss)
    val requestDismiss:()->Unit={if(queueGesture?.cancel()!=true&&admit())dismiss()}
    val sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true,confirmValueChange={value -> value!=SheetValue.Hidden||(queueGesture?.cancel()!=true&&admit())})
    val worker=rememberCoroutineScope()
    val handleDismiss:()->Unit={worker.launch {sheetState.hide();if(!sheetState.isVisible)dismiss()};Unit}
    // Material3 Back completes even when hide was vetoed. Completion is not a new dismissal intent.
    ModalBottomSheet(onDismissRequest={if(!sheetState.isVisible)dismiss()},modifier=Modifier.onPreviewKeyEvent {
            if(queueGesture?.onKey(it)==true)true
            else if(it.key==Key.Escape&&it.type==KeyEventType.KeyUp){(onEscape?:requestDismiss)();true}
            else false
        },shape=RectangleShape,containerColor=SoundQ.colors.sheet,scrimColor=SoundQ.colors.scrim.copy(alpha=soundq.design.generated.SoundQComposeTokens.MOTION_SCRIM_OPACITY),
        sheetState=sheetState,sheetGesturesEnabled=false,dragHandle=null) {
        SoundQSheetDragHandle(title,handleDismiss)
        Column(Modifier.fillMaxWidth().imePadding().verticalScroll(scrollState).padding(SoundQ.spacing.gutter),verticalArrangement=Arrangement.spacedBy(SoundQ.spacing.medium)) {
            Row(verticalAlignment=Alignment.CenterVertically) {Text(title,Modifier.weight(1f).semantics {heading()},style=SoundQ.typography.heading);SoundQIconButton(SoundQIcon.Close,"Close $title",requestDismiss)}
            content()
        }
    }
}
