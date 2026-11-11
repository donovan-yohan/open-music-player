package com.soundq.android.product.preferences

import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.*
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
    SettingsChoices {
        SoundQRow("DJ mode","Harmonic matching in playlists",state.enabled,{choose(!state.enabled)},enabled=enabled,role=Role.Switch,
            trailing={Switch(state.enabled,null,enabled=enabled)})
    }
    Text("Other DJ controls are unavailable.",color=SoundQ.colors.muted)
    if(!state.ready)SoundQFeedback("Loading DJ mode",FeedbackKind.Loading)
    if(pending)SoundQFeedback("Saving DJ mode…",FeedbackKind.Loading)
    if(state.error==DjModeError.Read)SoundQFeedback("Couldn't load DJ mode",FeedbackKind.Error,"Your saved choice hasn't been replaced.","Reload DJ mode",::reload)
    if(state.error==DjModeError.Write) {
        val failed=retry
        SoundQFeedback("Couldn't save DJ mode",FeedbackKind.Error,"Your previous choice is unchanged.",if(failed!=null)"Retry DJ mode" else "Reload DJ mode",{if(failed!=null)choose(failed)else reload()})
        if(failed!=null)SoundQButton("Reload DJ mode",::reload,variant=SoundQButtonVariant.Quiet,enabled=!pending)
    }
}
