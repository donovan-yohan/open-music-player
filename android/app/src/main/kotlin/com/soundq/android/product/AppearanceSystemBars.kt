package com.soundq.android.product

import androidx.activity.compose.LocalActivity
import androidx.compose.runtime.*
import androidx.core.view.WindowCompat

/** Same Activity/window. No secure-window, intent, route or playback mutation. */
@Composable internal fun AppearanceSystemBars(dark:Boolean) {
    val activity=LocalActivity.current ?: return
    SideEffect {
        WindowCompat.getInsetsController(activity.window,activity.window.decorView).apply {
            isAppearanceLightStatusBars=!dark
            isAppearanceLightNavigationBars=!dark
        }
    }
}
