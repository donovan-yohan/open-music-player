package com.soundq.designsystem
import androidx.compose.animation.core.TweenSpec
import soundq.design.generated.SoundQComposeTokens as T
class SoundQMotion(val reduced: Boolean = false) {
    val queue: TweenSpec<Float> get() = TweenSpec(if (reduced) T.MOTION_DURATION_REDUCED else T.MOTION_DURATION_LIST, easing = T.MOTION_EASING_STANDARD)
    val selection: TweenSpec<Float> get() = TweenSpec(if (reduced) T.MOTION_DURATION_REDUCED else T.MOTION_DURATION_QUICK, easing = T.MOTION_EASING_STANDARD)
}
