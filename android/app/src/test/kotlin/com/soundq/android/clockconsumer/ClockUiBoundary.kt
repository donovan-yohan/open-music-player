package com.soundq.android.clockconsumer

import androidx.compose.runtime.*

// UI collaborator recorders, NOT Material, semantics/layout or Android-node implementations.
internal open class Modifier(val choice:(()->Unit)?=null) {companion object:Modifier()}
internal fun Modifier.selectableGroup()=this
internal fun Modifier.testTag(s:String)=this
internal fun Modifier.widthIn(min:Int)=this
internal fun Modifier.heightIn(min:Int)=this
internal fun Modifier.fillMaxWidth()=this
internal fun Modifier.then(m:Modifier)=this
internal fun Modifier.selectable(selected:Boolean,role:Role,onClick:()->Unit)=Modifier(onClick)
internal fun Modifier.semantics(block:Semantics.()->Unit)=this.also {Semantics().block()}
internal fun Modifier.clearAndSetSemantics(block:Semantics.()->Unit)=semantics(block)
internal class Semantics {var contentDescription="";var stateDescription="";var progressBarRangeInfo=ProgressBarRangeInfo.Indeterminate;var liveRegion=LiveRegionMode.Polite;fun disabled(){} }
internal object ProgressBarRangeInfo {val Indeterminate=this}
internal enum class Role {RadioButton}
internal enum class LiveRegionMode {Polite}
internal object Alignment {val CenterVertically=0;val Center=0}
internal val Int.dp:Int get()=this
internal object SoundQ {object colors {val focus=0;val muted=1;val error=2};object typography {val caption=0;val mono=1}}
internal class Recording {
    val texts=mutableListOf<String>()
    val choices=mutableListOf<()->Unit>()
    var change:(Float)->Unit={error("No slider")}
    var finish:()->Unit={error("No slider")}
    var enabled=false
}
internal val LocalRecording=staticCompositionLocalOf<Recording>{error("No recording")}
@Composable @NonRestartableComposable internal fun Row(modifier:Modifier,verticalAlignment:Int,content:@Composable ()->Unit)=content()
@Composable @NonRestartableComposable internal fun Box(modifier:Modifier,contentAlignment:Int,content:@Composable ()->Unit) {
    val r=LocalRecording.current
    modifier.choice?.let {click->SideEffect {r.choices+=click}}
    content()
}
@Composable @NonRestartableComposable internal fun Text(text:String,modifier:Modifier=Modifier,color:Int=0,style:Int=0,textAlign:androidx.compose.ui.text.style.TextAlign?=null) {
    val r=LocalRecording.current
    SideEffect {r.texts+=text}
}
@Composable @NonRestartableComposable internal fun Slider(value:Float,onValueChange:(Float)->Unit,modifier:Modifier,enabled:Boolean,onValueChangeFinished:()->Unit) {
    val r=LocalRecording.current
    SideEffect {r.change=onValueChange;r.finish=onValueChangeFinished;r.enabled=enabled}
}
