package com.soundq.designsystem

import androidx.compose.foundation.MarqueeAnimationMode
import androidx.compose.foundation.basicMarquee
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.MotionDurationScale
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/** Presentation reset token supplied by the existing playback projection, never a selection owner.
 * It excludes cursor/position updates and reaches rows inside sheets as well as ordinary lists. */
val LocalMediaMarqueeIdentity=staticCompositionLocalOf<Any?> {null}

/** One native Text/semantics node; foundation draws the loop, not duplicate composables.
 * Removing the modifier when motion is disabled cancels an in-flight pass and restores ellipsis.
 * Foundation intentionally ignores MotionDurationScale internally (1.12.1), so gate it here. */
@Composable internal fun SoundQMediaIdentityText(
    text:String,
    selected:Boolean,
    identity:Any?,
    style:TextStyle,
    color:Color=Color.Unspecified,
    modifier:Modifier=Modifier,
) {
    val scale=rememberCoroutineScope().coroutineContext[MotionDurationScale]?.scaleFactor ?: 1f
    val view=LocalView.current
    var visible by remember(identity,text) {mutableStateOf(false)}
    val motionAllowed=!SoundQ.motion.reduced&&scale>0f&&LocalWindowInfo.current.isWindowFocused&&visible
    // A content change of the same measured width must reset too. Width changes are handled by
    // basicMarquee; density/font-scale changes recreate it even if the pixel width stays equal.
    key(identity,text,selected,motionAllowed,LocalDensity.current,style) {
        Text(text,modifier.clipToBounds().onGloballyPositioned {coordinates->
            val bounds=coordinates.boundsInWindow()
            visible=bounds.width>0f&&bounds.height>0f&&bounds.right>0f&&bounds.bottom>0f&&
                bounds.left<view.width&&bounds.top<view.height
        }.then(if(selected&&motionAllowed)Modifier.basicMarquee(
            iterations=Int.MAX_VALUE,
            animationMode=MarqueeAnimationMode.Immediately,
            initialDelayMillis=2000,
            repeatDelayMillis=2000,
            velocity=24.dp,
        ) else Modifier),style=style,color=color,maxLines=1,softWrap=false,overflow=TextOverflow.Ellipsis)
    }
}
