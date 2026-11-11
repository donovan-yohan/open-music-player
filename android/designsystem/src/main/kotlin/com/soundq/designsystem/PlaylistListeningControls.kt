package com.soundq.designsystem

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/** Intent and callbacks only: playback authority remains with the supplied captures. */
@Composable fun PlaylistListeningControls(mixed:Boolean,canMix:Boolean,busy:Boolean,onPlain:()->Unit,onMixed:()->Unit,onGenerate:()->Unit,onPlay:()->Unit,onShuffle:()->Unit,canPlay:Boolean,canGenerate:Boolean=true) {
    val textMeasurer=rememberTextMeasurer()
    val density=LocalDensity.current
    val modeStyle=SoundQ.typography.body.copy(fontWeight=FontWeight.Medium)
    val labelWidth=with(density) {maxOf(textMeasurer.measure("Plain",modeStyle).size.width,textMeasurer.measure("Mixed",modeStyle).size.width).toDp()}
    val intentWidth=labelWidth+24.dp
    val playInteractions=remember {MutableInteractionSource()}
    val playFocused by playInteractions.collectIsFocusedAsState()
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val secondBand=maxWidth<SoundQ.sizes.target*3+intentWidth*2
        Box(Modifier.fillMaxWidth()) {
          Column(Modifier.fillMaxWidth().selectableGroup()) {
            Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).heightIn(min=56.dp),verticalAlignment=Alignment.CenterVertically) {
                Box(Modifier.width(SoundQ.sizes.target).fillMaxHeight().heightIn(min=56.dp).background(if(canPlay)SoundQ.colors.primary else SoundQ.colors.disabledSurface)
                    .semantics {contentDescription="Play playlist"}.clickable(interactionSource=playInteractions,indication=androidx.compose.foundation.LocalIndication.current,enabled=canPlay,role=Role.Button,onClick=onPlay)
                    .soundQCellFocus(playFocused,onPrimary=canPlay),contentAlignment=Alignment.Center) {
                    SoundQIcon(SoundQIcon.Play,null,tint=if(canPlay)SoundQ.colors.onPrimary else SoundQ.colors.disabled)
                }
                if(secondBand) Spacer(Modifier.weight(1f)) else {
                    ListeningIntent("Plain",!mixed,onPlain,Modifier.weight(1f).fillMaxHeight())
                    ListeningIntent("Mixed",mixed,if(canMix)onMixed else onGenerate,Modifier.weight(1f).fillMaxHeight(),enabled=canMix||canGenerate)
                }
                SoundQIconButton(SoundQIcon.Retry,"Generate Blend",onGenerate,Modifier.width(SoundQ.sizes.target).fillMaxHeight(),enabled=canGenerate&&!busy,outlined=false)
                SoundQIconButton(SoundQPlayerIcon.Shuffle,"Shuffle",onShuffle,Modifier.width(SoundQ.sizes.target).fillMaxHeight(),enabled=canPlay,outlined=false)
            }
            if(secondBand) Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min),verticalAlignment=Alignment.CenterVertically) {
                ListeningIntent("Plain",!mixed,onPlain,Modifier.weight(1f).fillMaxHeight())
                ListeningIntent("Mixed",mixed,if(canMix)onMixed else onGenerate,Modifier.weight(1f).fillMaxHeight(),enabled=canMix||canGenerate)
            }
          }
          SoundQDivider(Modifier.align(Alignment.BottomCenter))
        }
    }
}
@Composable private fun ListeningIntent(label:String,selected:Boolean,onClick:()->Unit,modifier:Modifier,enabled:Boolean=true) {
    val color by animateColorAsState(if(selected)SoundQ.colors.focus else SoundQ.colors.muted,tween(SoundQ.motion.selection.durationMillis,easing=SoundQ.motion.selection.easing),label="Listening intent")
    val interactions=remember {MutableInteractionSource()}
    val focused by interactions.collectIsFocusedAsState()
    Box(modifier.heightIn(min=56.dp).semantics {contentDescription="$label listening";this.selected=selected}
        .clickable(interactionSource=interactions,indication=androidx.compose.foundation.LocalIndication.current,enabled=enabled,role=Role.RadioButton,onClick=onClick)
        .soundQCellFocus(focused),contentAlignment=Alignment.Center) {
        Text(label,Modifier.padding(horizontal=12.dp,vertical=8.dp),color=if(!enabled)SoundQ.colors.disabled else if(selected)color else SoundQ.colors.text,style=SoundQ.typography.body.copy(fontWeight=if(selected)FontWeight.Medium else FontWeight.Normal))
        if(selected)Box(Modifier.align(Alignment.BottomCenter).padding(horizontal=12.dp).fillMaxWidth().offset(y=(-4).dp).height(2.dp).background(color))
    }
}
@Composable fun PlaylistBlendSeam(label:String,onClick:()->Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min=SoundQ.sizes.target).semantics {contentDescription=label}.clickable(role=Role.Button,onClick=onClick).padding(start=SoundQ.sizes.target),horizontalArrangement=Arrangement.spacedBy(SoundQ.spacing.medium),verticalAlignment=Alignment.CenterVertically) {
        SoundQIcon(SoundQIcon.Arrow,null,tint=SoundQ.colors.focus)
        Text(label,style=SoundQ.typography.caption,color=SoundQ.colors.muted)
    }
}
