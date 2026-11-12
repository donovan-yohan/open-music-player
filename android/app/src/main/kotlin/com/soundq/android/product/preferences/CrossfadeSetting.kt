package com.soundq.android.product.preferences

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.soundq.android.data.preferences.CrossfadePreferences
import com.soundq.designsystem.*
import kotlinx.coroutines.*

/** Off and 1–12 seconds as one vertical single-select list. Engine timing semantics are the owner's. */
@Composable internal fun CrossfadeSetting(owner:CrossfadePreferences,valid:()->Boolean) {
    val state by owner.state.collectAsStateWithLifecycle()
    val work=rememberCoroutineScope()
    var pending by remember {mutableStateOf(false)}
    var failedWrite by remember {mutableStateOf(false)}
    val capture=owner.capture()
    fun choose(seconds:Int) {
        val captured=capture?:return
        if(pending||!valid())return
        pending=true
        work.launch {try {val saved=withContext(Dispatchers.IO){owner.setSeconds(captured,seconds,valid)};if(valid())failedWrite=!saved&&owner.state.value.error}finally {pending=false}}
    }
    Spacer(Modifier.height(SoundQSettingsMetrics.firstSectionTop))
    Column(Modifier.fillMaxWidth().selectableGroup()) {
        for(seconds in crossfadeChoices)SoundQSettingsChoiceRow(crossfadeLabel(seconds),state.ready&&state.seconds==seconds,{choose(seconds)},enabled=capture!=null&&!pending)
    }
    if(!state.ready)SoundQSettingsBlock {SoundQFeedback("Loading…",FeedbackKind.Loading)}
    if(state.error)SoundQSettingsBlock {SoundQFeedback(if(failedWrite)"Couldn’t save crossfade" else "Couldn’t load crossfade",FeedbackKind.Error,action="Reload",onAction={work.launch(Dispatchers.IO){if(valid())owner.load()}})}
}
