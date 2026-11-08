package com.soundq.android.product.preferences

import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.*
import androidx.compose.ui.input.key.*
import androidx.compose.ui.semantics.*
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.soundq.android.data.preferences.*
import com.soundq.designsystem.*
import kotlinx.coroutines.*
import java.util.concurrent.atomic.AtomicBoolean

/** Device-local subpage inside the existing Settings modal, not a second window. */
@Composable internal fun AppearanceSetting(owner:AppearancePreferences,onOpen:()->Unit,opener:FocusRequester) {
    val state by owner.state.collectAsStateWithLifecycle()
    val systemDark=isSystemInDarkTheme()
    val summary=if(state.choice==Appearance.System)"System · ${if(systemDark)"Dark" else "Light"}" else state.choice.name
    SoundQRow("Appearance",summary,false,onOpen,leading={SoundQIcon(SoundQIcon.Settings,null)},
        trailing={SoundQIcon(SoundQIcon.Next,null)},rowModifier=Modifier.focusRequester(opener).semantics {contentDescription="Choose appearance"})
}

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
    LaunchedEffect(Unit){withFrameNanos {};requesters.getValue(state.choice).requestFocus()}
    Column {
        SettingsChoices {
            for(choice in Appearance.entries) {
                var focused by remember(choice){mutableStateOf(false)}
                val selected=state.choice==choice
                val enabled=state.ready&&capture!=null
                SoundQRow(choice.name,when(choice){Appearance.System->"Follow this device's appearance";Appearance.Light->"Use the light palette";Appearance.Dark->"Use the dark palette"},selected,{choose(choice)},enabled=enabled,
                    leading={RadioButton(selected,null,enabled=enabled,colors=RadioButtonDefaults.colors(selectedColor=SoundQ.colors.primary,unselectedColor=SoundQ.colors.muted,disabledSelectedColor=SoundQ.colors.disabled,disabledUnselectedColor=SoundQ.colors.disabled))},trailing={if(selected)SoundQIcon(SoundQIcon.Check,"Selected")},role=Role.RadioButton,
                    rowModifier=Modifier.focusRequester(requesters.getValue(choice)).onFocusChanged {focused=it.isFocused}
                        .then(if(focused)Modifier.border(SoundQ.sizes.focus,SoundQ.colors.focus)else Modifier)
                        .onPreviewKeyEvent {event ->
                            val index=Appearance.entries.indexOf(choice)
                            val next=when(event.key){Key.DirectionDown,Key.DirectionRight->Appearance.entries[(index+1)%3];Key.DirectionUp,Key.DirectionLeft->Appearance.entries[(index+2)%3];Key.MoveHome->Appearance.System;Key.MoveEnd->Appearance.Dark;else->null}
                            if(next!=null&&enabled){if(event.type==KeyEventType.KeyDown){requesters.getValue(next).requestFocus();choose(next)};true}else false
                        })
            }
        }
        if(!state.ready)SoundQFeedback("Loading appearance",FeedbackKind.Loading)
        if(state.error==AppearanceError.Read)SoundQFeedback("Couldn't load appearance",FeedbackKind.Error,"Your saved choice hasn't been replaced.","Reload appearance",::reload)
        if(state.error==AppearanceError.Write) {
            val failed=retry
            SoundQFeedback("Couldn't save appearance",FeedbackKind.Error,"Your previous appearance is still selected.",
                if(failed!=null)"Retry ${failed.name}" else "Reload appearance",{if(failed!=null)choose(failed)else reload()})
            if(failed!=null)SoundQButton("Reload appearance",::reload,variant=SoundQButtonVariant.Quiet,enabled=!pending)
        }
    }
}
