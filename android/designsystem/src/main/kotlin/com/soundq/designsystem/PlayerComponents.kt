package com.soundq.designsystem

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.input.key.*
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.window.DialogWindowProvider
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.SecureFlagPolicy

/** Authorized decoded pixels or a feature-owned decorative slot, never a URL or loader. */
@Composable fun SoundQArtworkSlot(
    modifier:Modifier=Modifier,
    size:Dp=72.dp,
    image:ImageBitmap?=null,
    artwork:(@Composable ()->Unit)?=null,
) {
    Box(modifier.size(size).clipToBounds().background(SoundQ.colors.raised),contentAlignment=Alignment.Center) {
        when {
            artwork!=null->artwork()
            image!=null->Image(image,null,Modifier.fillMaxSize(),contentScale=ContentScale.Crop)
            else->SoundQIcon(SoundQIcon.Note,null,tint=SoundQ.colors.muted)
        }
    }
}

/** Shared five-control target. Modes are display inputs; no service state lives here. */
@Composable internal fun PlayerControl(
    label:String,onClick:(()->Unit)?,enabled:Boolean,active:Boolean=false,primary:Boolean=false,
    icon:@Composable (Color)->Unit,
) {
    val colors=SoundQ.colors
    val ink=when { !enabled->colors.disabled;primary->colors.onPrimary;active->colors.focus;else->colors.text }
    Box(Modifier.size(if(primary)64.dp else 48.dp)
        .background(if(primary)if(enabled)colors.primary else colors.disabledSurface else Color.Transparent)
        .semantics {contentDescription=label;stateDescription=label;if(!primary)selected=active}
        .clickable(enabled=enabled,role=Role.Button,onClick={onClick?.invoke()}),contentAlignment=Alignment.Center) {icon(ink)}
}

/** One utility grid. Null permission/capture means the cell does not exist. */
@Composable fun SoundQPlayerUtilities(
    onQueue:()->Unit,
    onDevices:(()->Unit)?=null,
    onInfo:(()->Unit)?=null,
    modifier:Modifier=Modifier,
    compact:Boolean=false,
    speed:SoundQSpeedCell?=null,
) {
    val color=SoundQ.colors.border
    val rule=with(LocalDensity.current){SoundQ.sizes.border.toPx()}
    Row(modifier.fillMaxWidth().height(if(compact)48.dp else 56.dp).drawBehind {
        drawLine(color,Offset.Zero,Offset(size.width,0f),rule)
    }) {
        PlayerUtility("Open listening queue",onQueue,true) {SoundQIcon(SoundQIcon.List,null)}
        if(speed!=null)SpeedUtility(speed,false)
        if(onDevices!=null)PlayerUtility("Connected devices",onDevices,false) {SoundQIcon(SoundQPlayerIcon.Devices,null)}
        if(onInfo!=null)PlayerUtility("Song details",onInfo,false) {SoundQIcon(SoundQIcon.Info,null)}
    }
}

@Composable private fun RowScope.PlayerUtility(label:String,onClick:()->Unit,first:Boolean,icon:@Composable ()->Unit) {
    val color=SoundQ.colors.border
    val rule=with(LocalDensity.current){SoundQ.sizes.border.toPx()}
    Box(Modifier.weight(1f).fillMaxHeight().drawBehind {
        if(!first)drawLine(color,Offset.Zero,Offset(0f,size.height),rule)
    }.semantics {contentDescription=label}.clickable(role=Role.Button,onClick=onClick),contentAlignment=Alignment.Center) {icon()}
}

/** Full-window host. Dismissal never issues transport commands. Parent retains route/capture ownership. */
@Composable fun SoundQFullPlayer(
    title:String,artist:String,playing:Boolean,available:Boolean,preparing:Boolean,
    position:Long,duration:Long,selectedOccurrence:String?,
    onClose:()->Unit,onPrimary:()->Unit,onSeek:(Long)->Unit,onQueue:()->Unit,
    onPrevious:(()->Unit)?=null,onNext:(()->Unit)?=null,canPrevious:Boolean=false,canNext:Boolean=false,
    shuffle:Boolean=false,repeat:Int=0,onShuffle:(()->Unit)?=null,onRepeat:(()->Unit)?=null,
    onDevices:(()->Unit)?=null,onInfo:(()->Unit)?=null,artwork:(@Composable ()->Unit)?=null,error:String?=null,
    returnFocus:FocusRequester?=null,
    clockContent:(@Composable ()->Unit)?=null,
    speedCell:SoundQSpeedCell?=null,
    speedContent:(@Composable ()->Unit)?=null,
) {
    val latestReturnFocus by rememberUpdatedState(returnFocus)
    DisposableEffect(Unit) {onDispose {latestReturnFocus?.let {runCatching {it.requestFocus()}}}}
    Dialog(onDismissRequest=onClose,properties=DialogProperties(
        dismissOnBackPress=true,dismissOnClickOutside=false,securePolicy=SecureFlagPolicy.Inherit,
        usePlatformDefaultWidth=false,decorFitsSystemWindows=false,
    )) {
        FullPlayerSystemBars()
        Surface(Modifier.fillMaxSize().testTag("player-window"),shape=RectangleShape,color=SoundQ.colors.sheet) {
            // This host alone consumes bars. Content can also be mounted without platform insets in a gallery.
            SoundQFullPlayerContent(title,artist,playing,available,preparing,position,duration,selectedOccurrence,
                onClose,onPrimary,onSeek,onQueue,onPrevious,onNext,canPrevious,canNext,shuffle,repeat,onShuffle,onRepeat,
                onDevices,onInfo,artwork,error,Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing),clockContent,speedCell,speedContent)
        }
    }
}

/** Only this Dialog's icon appearance changes; Activity, secure policy and insets stay owned above. */
@Suppress("DEPRECATION")
@Composable private fun FullPlayerSystemBars() {
    val window=(LocalView.current.parent as? DialogWindowProvider)?.window ?: return
    // Consume the already resolved SoundQ palette, including live System/Light/Dark changes.
    val light=SoundQ.colors.sheet.luminance()>0.5f
    SideEffect {
        if(android.os.Build.VERSION.SDK_INT>=30) {
            val mask=android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
            window.insetsController?.setSystemBarsAppearance(if(light)mask else 0,mask)
        } else {
            val mask=android.view.View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or android.view.View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
            window.decorView.systemUiVisibility=if(light)window.decorView.systemUiVisibility or mask
                else window.decorView.systemUiVisibility and mask.inv()
        }
    }
}

/** Responsive body shared by the real dialog and a parent-consumable gallery. No navigation dependencies. */
@Composable fun SoundQFullPlayerContent(
    title:String,artist:String,playing:Boolean,available:Boolean,preparing:Boolean,
    position:Long,duration:Long,selectedOccurrence:String?,
    onClose:()->Unit,onPrimary:()->Unit,onSeek:(Long)->Unit,onQueue:()->Unit,
    onPrevious:(()->Unit)?=null,onNext:(()->Unit)?=null,canPrevious:Boolean=false,canNext:Boolean=false,
    shuffle:Boolean=false,repeat:Int=0,onShuffle:(()->Unit)?=null,onRepeat:(()->Unit)?=null,
    onDevices:(()->Unit)?=null,onInfo:(()->Unit)?=null,artwork:(@Composable ()->Unit)?=null,error:String?=null,
    modifier:Modifier=Modifier,
    clockContent:(@Composable ()->Unit)?=null,
    speedCell:SoundQSpeedCell?=null,
    speedContent:(@Composable ()->Unit)?=null,
) {
    Column(modifier.background(SoundQ.colors.sheet).onPreviewKeyEvent {
        if(it.key==Key.Escape&&it.type==KeyEventType.KeyUp){onClose();true}else false
    }) {
        Box(Modifier.fillMaxWidth().height(56.dp)) {
            Text("Now playing",Modifier.align(Alignment.Center).semantics {heading()},style=SoundQ.typography.title,color=SoundQ.colors.text)
            Box(Modifier.align(Alignment.CenterEnd).width(48.dp).fillMaxHeight()
                .semantics {contentDescription="Close Now playing"}.clickable(role=Role.Button,onClick=onClose),contentAlignment=Alignment.Center) {
                SoundQIcon(SoundQIcon.Close,null)
            }
            SoundQDivider(Modifier.align(Alignment.BottomCenter))
        }
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth().testTag("player-body")) {
            val viewportHeight=maxHeight
            val landscape=maxWidth>=560.dp&&maxWidth>maxHeight
            val short=maxHeight<=664.dp
            val gap=if(short)8.dp else 16.dp
            // Reserve fixed controls first; text growth is handled by scrolling, not smaller targets.
            val portraitArt=minOf(maxWidth-32.dp,if(short)(maxHeight-300.dp).coerceIn(120.dp,260.dp) else 320.dp).coerceAtLeast(72.dp)
            val splitArt=minOf(280.dp,maxWidth*0.38f-32.dp,(maxHeight-96.dp).coerceAtLeast(72.dp))
            val scroll=rememberScrollState()
            val controls:@Composable ()->Unit = {
                Column(Modifier.fillMaxWidth(),horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(gap)) {
                    Column(Modifier.fillMaxWidth().padding(horizontal=8.dp),horizontalAlignment=Alignment.CenterHorizontally) {
                        Text(title,Modifier.fillMaxWidth(),style=SoundQ.typography.heading,color=SoundQ.colors.text,
                            textAlign=TextAlign.Center,maxLines=2,overflow=TextOverflow.Ellipsis)
                        Text(artist,Modifier.fillMaxWidth(),style=SoundQ.typography.body,color=SoundQ.colors.muted,
                            textAlign=TextAlign.Center,maxLines=1,softWrap=false,overflow=TextOverflow.Ellipsis)
                    }
                    if(error!=null)Text(error,Modifier.fillMaxWidth().padding(horizontal=8.dp).semantics {liveRegion=LiveRegionMode.Polite},
                        color=SoundQ.colors.error,style=SoundQ.typography.caption,textAlign=TextAlign.Center)
                    if(preparing)Text("Preparing audio",color=SoundQ.colors.muted,style=SoundQ.typography.caption)
                    Column(Modifier.fillMaxWidth().padding(horizontal=8.dp),horizontalAlignment=Alignment.CenterHorizontally) {
                        if(clockContent!=null)clockContent() else SoundQSeek(position,duration,selectedOccurrence,onSeek)
                    }
                    SoundQTransport(playing,available,preparing,onPrimary,onPrevious,onNext,canPrevious,canNext,
                        shuffle,repeat,onShuffle,onRepeat)
                    // The speed panel mounts directly under the utilities (no gap), like clockContent.
                    Column(Modifier.fillMaxWidth()) {
                        SoundQPlayerUtilities(onQueue,onDevices,onInfo,compact=landscape,speed=speedCell)
                        if(speedCell?.expanded==true&&speedContent!=null) {
                            val reveal=remember {androidx.compose.foundation.relocation.BringIntoViewRequester()}
                            Box(Modifier.fillMaxWidth().bringIntoViewRequester(reveal)) {speedContent()}
                            LaunchedEffect(reveal) {reveal.bringIntoView()}
                        }
                    }
                }
            }
            // The minimum viewport centers a fitting composition; overflow scrolls below the fixed toolbar.
            Column(Modifier.fillMaxSize().verticalScroll(scroll),horizontalAlignment=Alignment.CenterHorizontally) {
                if(landscape)Row(Modifier.fillMaxWidth().heightIn(min=viewportHeight).padding(16.dp),verticalAlignment=Alignment.CenterVertically,
                    horizontalArrangement=Arrangement.spacedBy(16.dp,Alignment.CenterHorizontally)) {
                    Box(Modifier.weight(0.42f),contentAlignment=Alignment.Center) {
                        SoundQArtworkSlot(Modifier.testTag("player-artwork"),splitArt,artwork=artwork)
                    }
                    Box(Modifier.weight(0.58f).widthIn(max=460.dp),contentAlignment=Alignment.Center) {controls()}
                } else Column(Modifier.widthIn(max=460.dp).fillMaxWidth().heightIn(min=viewportHeight).padding(top=16.dp,bottom=16.dp),
                    horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(gap,Alignment.CenterVertically)) {
                    SoundQArtworkSlot(Modifier.testTag("player-artwork"),portraitArt,artwork=artwork)
                    controls()
                }
            }
        }
    }
}
