package com.soundq.android.product

import androidx.compose.runtime.*
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner

/** Pause, unmount and source replacement permanently revoke a captured row visit. */
@Composable internal fun rememberTrackRowLifetime(source:Any?):LibraryRowLifetime {
    val lifecycle=LocalLifecycleOwner.current.lifecycle
    var visit by remember {mutableLongStateOf(0L)}
    val lifetime=remember(source,visit){LibraryRowLifetime {lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)}}
    DisposableEffect(lifetime){onDispose {lifetime.close()}}
    val current by rememberUpdatedState(lifetime)
    DisposableEffect(lifecycle) {
        val observer=LifecycleEventObserver {_,event->when(event) {
            Lifecycle.Event.ON_PAUSE,Lifecycle.Event.ON_STOP->current.close()
            Lifecycle.Event.ON_RESUME->visit++
            else->Unit
        }}
        lifecycle.addObserver(observer)
        onDispose {current.close();lifecycle.removeObserver(observer)}
    }
    return lifetime
}
