package com.soundq.android.product.connect

import androidx.compose.runtime.*
import androidx.lifecycle.*
import androidx.lifecycle.compose.*
import androidx.compose.material3.Text
import androidx.compose.foundation.layout.*
import androidx.compose.ui.Modifier
import com.soundq.android.product.ProductViewModel
import com.soundq.designsystem.*
import kotlinx.coroutines.*

@Composable fun ConnectedDevicesPanel(model:ProductViewModel,onDismiss:()->Unit,onJam:()->Unit) {
    val presence=model.graph.presence
    val state by presence.state.collectAsStateWithLifecycle()
    val lifecycle=LocalLifecycleOwner.current
    val jobs=rememberCoroutineScope()
    DisposableEffect(presence,lifecycle) {
        fun sync(){presence.visible(lifecycle.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))}
        val observer=LifecycleEventObserver {_,_->sync()};lifecycle.lifecycle.addObserver(observer);sync()
        onDispose {presence.visible(false);lifecycle.lifecycle.removeObserver(observer)}
    }
    SoundQSheet("Connected devices",onDismiss) {
        Text("This device: ${state.status.name}",style=SoundQ.typography.title)
        Text("Private listening activity on this account. Presence does not transfer or synchronize audio.",style=SoundQ.typography.caption)
        if(state.listFailed)SoundQFeedback("Devices unavailable",FeedbackKind.Error,"The server may be temporarily unavailable. A slow retry is scheduled.")
        if(state.devices.isEmpty())SoundQFeedback("No device reports",FeedbackKind.Empty)
        state.devices.forEach {device ->
            Column(Modifier.fillMaxWidth().padding(vertical=SoundQ.spacing.small)) {
                Text(device.label,style=SoundQ.typography.title)
                Text(device.title?.let {"$it · ${device.artist.orEmpty()}"} ?: "Not listening")
                Text("${device.platform} · ${if(device.playing)"Playing" else "Paused or idle"}",style=SoundQ.typography.caption)
            }
        }
        SoundQButton("Refresh devices",{presence.visible(true) },variant=SoundQButtonVariant.Secondary)
        SoundQButton("Host a Jam",onJam)
        if(state.status==com.soundq.android.data.connect.PresenceStatus.Detached)SoundQButton("Connect this device",{presence.reconnect()},variant=SoundQButtonVariant.Secondary)
        else SoundQButton("Disconnect this device",{jobs.launch(Dispatchers.IO){presence.disconnect()}},variant=SoundQButtonVariant.Quiet)
    }
}
