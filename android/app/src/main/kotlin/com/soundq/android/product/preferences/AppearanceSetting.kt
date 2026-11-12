package com.soundq.android.product.preferences

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.*
import androidx.compose.ui.input.key.*
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.soundq.android.data.preferences.*
import com.soundq.designsystem.*
import kotlinx.coroutines.*
import java.util.concurrent.atomic.AtomicBoolean

/** Theme detail: one single-select list. Arrow/Home/End keys move and choose, as before. */
@Composable internal fun AppearanceChoices(owner:AppearancePreferences) {
    val state by owner.state.collectAsStateWithLifecycle()
    val work=rememberCoroutineScope()
    val alive=remember {AtomicBoolean(true)}
    var pending by remember {mutableStateOf(false)}
    var retry by remember {mutableStateOf<Appearance?>(null)}
    val requesters=remember {Appearance.entries.associateWith {FocusRequester()}}
    DisposableEffect(Unit){onDispose {alive.set(false)}}
    // Bind to the accepted revision rendered by this visit, not a later Reload.
    val capture=owner.capture()
    fun choose(choice:Appearance) {
        if(pending||!alive.get())return
        val captured=capture ?: return
        pending=true
        work.launch {
            try {
                val accepted=withContext(Dispatchers.IO){owner.setChoice(captured,choice,alive::get)}
                if(alive.get())retry=if(accepted)null else choice
            }finally {pending=false}
        }
    }
    fun reload() {
        if(pending)return
        pending=true
        work.launch {try {withContext(Dispatchers.IO){if(alive.get())owner.load()};if(alive.get())retry=null}finally {pending=false}}
    }
    LaunchedEffect(Unit){withFrameNanos {};runCatching {requesters.getValue(state.choice).requestFocus()}}
    Spacer(Modifier.height(SoundQSettingsMetrics.firstSectionTop))
    Column(Modifier.fillMaxWidth().selectableGroup()) {
        for(choice in Appearance.entries) {
            val enabled=state.ready&&capture!=null
            SoundQSettingsChoiceRow(appearanceLabel(choice),state.ready&&state.choice==choice,{choose(choice)},enabled=enabled,
                modifier=Modifier.focusRequester(requesters.getValue(choice)).onPreviewKeyEvent {event ->
                    val index=Appearance.entries.indexOf(choice)
                    val next=when(event.key){Key.DirectionDown,Key.DirectionRight->Appearance.entries[(index+1)%3];Key.DirectionUp,Key.DirectionLeft->Appearance.entries[(index+2)%3];Key.MoveHome->Appearance.System;Key.MoveEnd->Appearance.Dark;else->null}
                    if(next!=null&&enabled){if(event.type==KeyEventType.KeyDown){requesters.getValue(next).requestFocus();choose(next)};true}else false
                })
        }
    }
    if(!state.ready)SoundQSettingsBlock {SoundQFeedback("Loading…",FeedbackKind.Loading)}
    if(state.error==AppearanceError.Read)SoundQSettingsBlock {SoundQFeedback("Couldn't load theme",FeedbackKind.Error,action="Reload",onAction=::reload)}
    if(state.error==AppearanceError.Write)SoundQSettingsBlock {
        val failed=retry
        SoundQFeedback("Couldn't save theme",FeedbackKind.Error,action=if(failed!=null)"Try again" else "Reload",onAction={if(failed!=null)choose(failed)else reload()})
        if(failed!=null)SoundQButton("Reload",::reload,variant=SoundQButtonVariant.Quiet,enabled=!pending)
    }
}
