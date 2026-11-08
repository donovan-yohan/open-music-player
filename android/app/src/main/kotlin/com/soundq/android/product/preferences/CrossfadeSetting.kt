package com.soundq.android.product.preferences

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.soundq.android.data.preferences.CrossfadePreferences
import com.soundq.designsystem.*
import kotlinx.coroutines.*

@Composable internal fun CrossfadeSetting(owner:CrossfadePreferences,valid:()->Boolean) {
    val state by owner.state.collectAsStateWithLifecycle()
    val work=rememberCoroutineScope()
    var pending by remember {mutableStateOf(false)}
    val capture=owner.capture()
    fun choose(seconds:Int) {
        val captured=capture?:return
        if(pending||!valid())return
        pending=true
        work.launch {try {withContext(Dispatchers.IO){owner.setSeconds(captured,seconds,valid)}}finally {pending=false}}
    }
    Text("Crossfade",style=SoundQ.typography.title)
    Text(if(state.seconds==0)"Off" else "${state.seconds} seconds",style=SoundQ.typography.mono)
    Text("Blend consecutive songs. Short songs use a shorter fade. Changes apply to the next prepared transition.",color=SoundQ.colors.muted)
    Row(horizontalArrangement=Arrangement.spacedBy(SoundQ.spacing.small)) {
        SoundQButton("Less crossfade",{choose(state.seconds-1)},variant=SoundQButtonVariant.Secondary,enabled=capture!=null&&!pending&&state.seconds>0)
        SoundQButton("More crossfade",{choose(state.seconds+1)},variant=SoundQButtonVariant.Secondary,enabled=capture!=null&&!pending&&state.seconds<12)
    }
    if(!state.ready)SoundQFeedback("Loading crossfade",FeedbackKind.Loading)
    if(state.error)SoundQFeedback("Crossfade preference could not be saved or loaded",FeedbackKind.Error,"The accepted choice is unchanged.","Reload crossfade",{work.launch(Dispatchers.IO){if(valid())owner.load()}})
}
