package com.soundq.android.product.preferences

import androidx.compose.runtime.*
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.soundq.android.data.preferences.*
import com.soundq.designsystem.*
import kotlinx.coroutines.*

@Composable fun DjModeSetting(owner:DjModePreferences,accountValid:()->Boolean) {
    val state by owner.state.collectAsStateWithLifecycle()
    val work=rememberCoroutineScope()
    val alive=remember(owner){java.util.concurrent.atomic.AtomicBoolean(true)}
    DisposableEffect(alive){onDispose {alive.set(false)}}
    val valid={alive.get()&&accountValid()}
    var pending by remember(owner){mutableStateOf(false)}
    var retry by remember(owner){mutableStateOf<Boolean?>(null)}
    val capture=owner.capture()
    fun choose(value:Boolean) {
        if(pending||!valid())return
        val captured=capture?:return
        pending=true
        work.launch {try {val accepted=withContext(Dispatchers.IO){owner.setEnabled(captured,value,valid)};if(valid())retry=if(accepted)null else value}finally {pending=false}}
    }
    fun reload() {
        if(pending||!valid())return
        pending=true
        work.launch {try {withContext(Dispatchers.IO){if(valid())owner.load()};if(valid())retry=null}finally {pending=false}}
    }
    val enabled=state.ready&&capture!=null&&!pending
    SoundQSettingsSwitchRow("DJ mode",state.enabled,{choose(it)},supporting=if(state.ready)"Harmonic matching in playlists" else "Loading…",enabled=enabled)
    if(state.error==DjModeError.Read)SoundQSettingsBlock {SoundQFeedback("Couldn’t load DJ mode",FeedbackKind.Error,action="Reload DJ mode",onAction=::reload)}
    if(state.error==DjModeError.Write)SoundQSettingsBlock {
        val failed=retry
        SoundQFeedback("Couldn’t save DJ mode",FeedbackKind.Error,action=if(failed!=null)"Retry DJ mode" else "Reload DJ mode",onAction={if(failed!=null)choose(failed)else reload()})
        if(failed!=null)SoundQButton("Reload DJ mode",::reload,variant=SoundQButtonVariant.Quiet,enabled=!pending)
    }
}
