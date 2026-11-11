package com.soundq.android.product.preferences

import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.*
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.soundq.android.*
import com.soundq.android.data.*
import com.soundq.android.data.preferences.*
import com.soundq.android.product.ProductViewModel
import com.soundq.android.product.offline.readableStorageSize
import com.soundq.designsystem.*
import kotlinx.coroutines.*

/** Only choice groups undo the sheet inset. Labels, feedback and consent keep it. */
@Composable internal fun SettingsChoices(content:@Composable ()->Unit) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        Column(Modifier.requiredWidth(maxWidth+SoundQ.spacing.gutter*2).align(androidx.compose.ui.Alignment.Center)) {
            Column(Modifier.fillMaxWidth().selectableGroup()) {content()}
        }
    }
}

@Composable fun PreferencesSheet(model:ProductViewModel,onDismiss:()->Unit,onDownloads:()->Unit,onHistory:()->Unit) {
    val graph=model.graph
    val settings by model.queueSettings.collectAsStateWithLifecycle()
    val storage by graph.storagePreferences.state.collectAsStateWithLifecycle()
    val listening by graph.listeningPreferences.state.collectAsStateWithLifecycle()
    val swipe by graph.swipeQueuePreferences.state.collectAsStateWithLifecycle()
    val unlock by graph.localUnlock.state.collectAsStateWithLifecycle()
    val work=rememberCoroutineScope()
    val scope=remember {graph.session.capture()}
    val alive=remember {java.util.concurrent.atomic.AtomicBoolean(true)}
    val valid={alive.get()&&scope?.let(graph.session::current)==true}
    val activity=androidx.activity.compose.LocalActivity.current as? MainActivity
    var cache by remember {mutableStateOf<com.soundq.android.data.cache.CacheStatus?>(null)}
    var cacheMessage by remember {mutableStateOf<String?>(null)}
    var confirmClear by remember {mutableStateOf<com.soundq.android.data.cache.CacheClearCapture?>(null)}
    var storageDetails by remember {mutableStateOf(false)}
    var confirmLogout by remember {mutableStateOf(false)}
    var clearOnLogout by remember {mutableStateOf(false)}
    var legal by remember {mutableStateOf(false)}
    var linkError by remember {mutableStateOf(false)}
    val context=LocalContext.current
    fun openLegal(path:String) {if(valid())try {context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW,android.net.Uri.parse("https://openmusicplayer.app/$path")))}catch(_:Exception){linkError=true}}
    fun refresh(){work.launch {val observed=withContext(Dispatchers.IO){graph.temporaryAudio.status()};if(valid())cache=observed}}
    LaunchedEffect(Unit){refresh()}
    DisposableEffect(Unit){onDispose {alive.set(false);activity?.deviceUnlock?.cancel();graph.localUnlock.cancel()}}
    fun enroll(enabled:Boolean) {
        val request=graph.localUnlock.requestEnrollment(enabled) ?: return
        activity?.deviceUnlock?.authenticate(if(enabled)"Protect this installed app session" else "Turn off local session protection") {accepted ->
            work.launch {withContext(Dispatchers.IO){graph.localUnlock.complete(request,accepted,valid)}}
        } ?: graph.localUnlock.cancel()
    }
    var appearanceOpen by remember {mutableStateOf(false)}
    var restoreAppearanceFocus by remember {mutableStateOf(false)}
    val appearanceOpener=remember {androidx.compose.ui.focus.FocusRequester()}
    val settingsScroll=androidx.compose.foundation.rememberScrollState()
    val appearanceScroll=androidx.compose.foundation.rememberScrollState()
    fun closeAppearance(){appearanceOpen=false;restoreAppearanceFocus=true}
    androidx.activity.compose.BackHandler(appearanceOpen){closeAppearance()}
    LaunchedEffect(restoreAppearanceFocus,appearanceOpen){if(restoreAppearanceFocus&&!appearanceOpen){withFrameNanos {};appearanceOpener.requestFocus();restoreAppearanceFocus=false}}
    SoundQSheet(if(appearanceOpen)"Appearance" else "Settings",{alive.set(false);onDismiss()},
        dismissAdmission={if(appearanceOpen){closeAppearance();false}else true},scrollState=if(appearanceOpen)appearanceScroll else settingsScroll) {
        if(appearanceOpen)AppearanceChoices(graph.appearancePreferences)
        else {
        Text("Account",style=SoundQ.typography.title)
        Text("Server: ${graph.endpoint.identity}",style=SoundQ.typography.mono)
        SettingsChoices {
        SoundQRow("Device unlock",if(activity?.deviceUnlock?.available()==true)"Use device authentication" else "Set a secure screen lock in Android Settings first",unlock.enrolled,
            {enroll(!unlock.enrolled)},enabled=unlock.ready&&!unlock.pending&&activity?.deviceUnlock?.available()==true,
            trailing={Switch(unlock.enrolled,null,enabled=unlock.ready&&!unlock.pending&&activity?.deviceUnlock?.available()==true)},role=Role.Switch)
        }
        unlock.error?.let {SoundQFeedback(it,FeedbackKind.Error)}
        if(unlock.enrolled)SoundQButton("Lock SoundQ",{if(valid()){graph.localUnlock.lock();onDismiss()}},variant=SoundQButtonVariant.Secondary)
        SoundQButton("Listening history",onHistory,variant=SoundQButtonVariant.Secondary)
        SoundQButton("Sign out",{confirmLogout=true},variant=SoundQButtonVariant.Secondary)
        Text("Playback",style=SoundQ.typography.title)
        val capture=graph.queueSettings.capture()
        SettingsChoices {
        SoundQRow("Keep queued songs","Keep manual queue when starting another list",settings.keepQueued,
            {capture?.let {model.keepQueued(it,!settings.keepQueued,valid)}},enabled=capture!=null,
            trailing={Switch(settings.keepQueued,null,enabled=capture!=null)},role=Role.Switch)
        }
        if(settings.loading)SoundQFeedback("Loading settings",FeedbackKind.Loading)
        if(settings.error)SoundQFeedback("Settings could not be saved or loaded",FeedbackKind.Error,"The saved choice has not been replaced.","Reload settings",{model.reloadQueueSettings(valid)})
        Text("End of queue",style=SoundQ.typography.title)
        val endCapture=graph.listeningPreferences.capture()
        SettingsChoices {
        for(mode in com.soundq.android.data.preferences.EndOfQueue.entries) {
            val label=if(mode==com.soundq.android.data.preferences.EndOfQueue.Off)"Off" else "Shuffle library"
            SoundQRow(label,if(mode==com.soundq.android.data.preferences.EndOfQueue.Off)"Stop after the last song" else "Continue with songs from your library",listening.mode==mode,
                {endCapture?.let {captured->work.launch(Dispatchers.IO){graph.listeningPreferences.setMode(captured,mode,valid)}}},enabled=endCapture!=null,
                trailing={RadioButton(listening.mode==mode,null,enabled=endCapture!=null)},role=Role.RadioButton)
        }
        }
        if(listening.error)SoundQFeedback("End-of-queue preference could not be saved or loaded",FeedbackKind.Error,"The accepted choice is unchanged.","Reload end-of-queue setting",{work.launch(Dispatchers.IO){if(valid())graph.listeningPreferences.load()}})
        Text("Swipe to queue",style=SoundQ.typography.title)
        val swipeCapture=graph.swipeQueuePreferences.capture()
        SettingsChoices {
        for(mode in com.soundq.android.data.preferences.SwipeQueue.entries) {
            val label=if(mode==com.soundq.android.data.preferences.SwipeQueue.PlayNext)"Play next" else "Add to queue"
            SoundQRow(label,"Left-swipe action",swipe.mode==mode,
                {swipeCapture?.let {captured->work.launch(Dispatchers.IO){graph.swipeQueuePreferences.setMode(captured,mode,valid)}}},enabled=swipeCapture!=null,
                trailing={RadioButton(swipe.mode==mode,null,enabled=swipeCapture!=null)},role=Role.RadioButton)
        }
        }
        if(swipe.error)SoundQFeedback("Swipe destination could not be saved or loaded",FeedbackKind.Error,"The accepted choice is unchanged.","Reload swipe destination",{work.launch(Dispatchers.IO){if(valid())graph.swipeQueuePreferences.load()}})
        DjModeSetting(graph.djModePreferences,valid)
        CrossfadeSetting(graph.crossfadePreferences,valid)
        Text("Storage",style=SoundQ.typography.title)
        val storageCapture=graph.storagePreferences.capture()
        SettingsChoices {
        SoundQRow("Temporary audio","Downloads are kept",storage.temporaryAudioEnabled,
            {storageCapture?.let {captured->work.launch(Dispatchers.IO){graph.storagePreferences.setTemporaryAudio(captured,!storage.temporaryAudioEnabled,valid)}}},enabled=storageCapture!=null,
            trailing={Switch(storage.temporaryAudioEnabled,null,enabled=storageCapture!=null)},role=Role.Switch)
        }
        if(storage.error)SoundQFeedback("Storage preference could not be saved",FeedbackKind.Error,"The accepted choice is unchanged.","Reload storage settings",{work.launch(Dispatchers.IO){if(valid())graph.storagePreferences.load()}})
        Text(cache?.bytes?.let {"Temporary audio: ${readableStorageSize(it)}"} ?: "Temporary audio size unavailable",style=SoundQ.typography.mono)
        cache?.takeIf {it.deferredFiles>0}?.let {Text("${it.deferredFiles} in-use files awaiting clear",color=SoundQ.colors.muted)}
        SoundQButton("Storage details",{storageDetails=!storageDetails},variant=SoundQButtonVariant.Quiet)
        if(storageDetails) {
            Text("Temporary audio reuses fully read audio. Downloads and artwork are separate.",color=SoundQ.colors.muted)
            cache?.let {Text("${it.bytes?.let {bytes->"$bytes bytes"} ?: "Size unavailable"} · ${it.files} tracked files · ${it.deferredFiles} in-use files awaiting clear · ${it.writingFiles} writes · ${it.failedFiles} validation failures",style=SoundQ.typography.mono)}
        }
        cacheMessage?.let {SoundQFeedback(it,FeedbackKind.Notice)}
        SoundQButton("Clear temporary audio",{if(valid())confirmClear=graph.temporaryAudio.captureClear()},variant=SoundQButtonVariant.Secondary)
        SoundQButton("Refresh",{refresh()},variant=SoundQButtonVariant.Quiet)
        SoundQButton("Manage downloads",onDownloads,variant=SoundQButtonVariant.Secondary)
        AppearanceSetting(graph.appearancePreferences,{appearanceOpen=true},appearanceOpener)
        KeyNotationSetting(graph.keyNotationPreferences,valid)
        Text("About",style=SoundQ.typography.title)
        Text("SoundQ ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",style=SoundQ.typography.mono)
        Text("${BuildConfig.OMP_SOURCE_REF} · ${BuildConfig.OMP_BUILD_ID}",style=SoundQ.typography.mono)
        SoundQButton("Open-source notices",{legal=true},variant=SoundQButtonVariant.Secondary)
        SoundQButton("Privacy policy",{openLegal("privacy")},variant=SoundQButtonVariant.Secondary)
        SoundQButton("Terms of service",{openLegal("terms")},variant=SoundQButtonVariant.Secondary)
        if(linkError)SoundQFeedback("Could not open the external link",FeedbackKind.Error)
        Text("Account deletion is not available in this build.",color=SoundQ.colors.muted)
        }
    }
    confirmClear?.let {captured ->AlertDialog(onDismissRequest={confirmClear=null},title={Text("Clear temporary audio?")},text={Text("Downloads and artwork stay on this device. In-use files are removed only after playback releases them.")},confirmButton={TextButton(onClick={confirmClear=null;work.launch {val result=withContext(Dispatchers.IO){if(valid())graph.temporaryAudio.clear(captured) else null};if(valid()&&result!=null){cacheMessage=when {result.failedFiles>0->"Some temporary audio could not be removed. Unknown files were preserved.";result.deferredFiles>0->"In-use audio will clear after playback releases it";else->"Temporary audio cleared"};refresh()}}}){Text("Clear")}},dismissButton={TextButton(onClick={confirmClear=null}){Text("Cancel")}})}
    if(confirmLogout)AlertDialog(onDismissRequest={confirmLogout=false},title={Text("Sign out?")},text={Column {Text("This retires the saved session and local unlock. Downloads stay on this device.");Row {Checkbox(clearOnLogout,{clearOnLogout=it});Text("Clear temporary playback audio")}}},confirmButton={TextButton(onClick={confirmLogout=false;if(valid())model.logout(clearOnLogout);onDismiss()}){Text("Sign out")}},dismissButton={TextButton(onClick={confirmLogout=false}){Text("Cancel")}})
    if(legal)SoundQSheet("Open-source notices",{legal=false}) {
        Text("Native dependencies include AndroidX, Compose, Media3, Kotlin, kotlinx.coroutines, kotlinx.serialization, OkHttp, Okio and Guava. A complete generated dependency license catalog is not bundled in this preview.")
        Text("Bundled Space Grotesk and IBM Plex Mono fonts use the SIL Open Font License. See the bundled font notices below.")
        val context=LocalContext.current
        var notices by remember {mutableStateOf("Loading bundled notices")}
        LaunchedEffect(Unit){notices=withContext(Dispatchers.IO){runCatching {context.assets.open("settings-notices.txt").bufferedReader().use {it.readText()}}.getOrDefault("Bundled notices unavailable")}}
        Text(notices,style=SoundQ.typography.caption)
    }
}

@Composable private fun KeyNotationSetting(owner:KeyNotationPreferences,accountValid:()->Boolean) {
    val state by owner.state.collectAsStateWithLifecycle()
    val work=rememberCoroutineScope()
    val alive=remember(owner){java.util.concurrent.atomic.AtomicBoolean(true)}
    DisposableEffect(alive){onDispose {alive.set(false)}}
    val valid={alive.get()&&accountValid()}
    var pending by remember(owner){mutableStateOf(false)}
    var retry by remember(owner){mutableStateOf<KeyNotation?>(null)}
    // Capture during composition. A retained row cannot acquire new authority after Reload.
    val capture=owner.capture()
    fun choose(choice:KeyNotation) {
        if(pending||!valid())return
        val captured=capture?:return
        pending=true
        work.launch {
            try {
                val accepted=withContext(Dispatchers.IO){owner.setChoice(captured,choice,valid)}
                if(valid())retry=if(accepted)null else choice
            }finally {pending=false}
        }
    }
    fun reload() {
        if(pending||!valid())return
        pending=true
        work.launch {try {withContext(Dispatchers.IO){if(valid())owner.load()};if(valid())retry=null}finally {pending=false}}
    }
    Text("Key notation",style=SoundQ.typography.title)
    SettingsChoices {
        for(choice in KeyNotation.entries) {
            val selected=state.choice==choice
            val label=if(choice==KeyNotation.Camelot)"Camelot" else "Musical key"
            val enabled=state.ready&&capture!=null
            SoundQRow(label,if(choice==KeyNotation.Camelot)"8A, 11B" else "Am, F# major",selected,{choose(choice)},enabled=enabled,
                trailing={RadioButton(selected,null,enabled=enabled,colors=RadioButtonDefaults.colors(selectedColor=SoundQ.colors.primary,unselectedColor=SoundQ.colors.muted,disabledSelectedColor=SoundQ.colors.disabled,disabledUnselectedColor=SoundQ.colors.disabled))},role=Role.RadioButton)
        }
    }
    if(!state.ready)SoundQFeedback("Loading key notation",FeedbackKind.Loading)
    if(state.error==KeyNotationError.Read)SoundQFeedback("Couldn't load key notation",FeedbackKind.Error,"Your saved choice hasn't been replaced.","Reload key notation",::reload)
    if(state.error==KeyNotationError.Write) {
        val failed=retry
        SoundQFeedback("Couldn't save key notation",FeedbackKind.Error,"Your previous key notation is still selected.",
            if(failed!=null)"Retry key notation" else "Reload key notation",{if(failed!=null)choose(failed)else reload()})
        if(failed!=null)SoundQButton("Reload key notation",::reload,variant=SoundQButtonVariant.Quiet,enabled=!pending)
    }
}

@Composable fun LocalUnlockScreen(model:ProductViewModel) {
    val graph=model.graph
    val state by graph.localUnlock.state.collectAsStateWithLifecycle()
    val activity=androidx.activity.compose.LocalActivity.current as? MainActivity
    val work=rememberCoroutineScope()
    val alive=remember {java.util.concurrent.atomic.AtomicBoolean(true)}
    DisposableEffect(Unit){onDispose {alive.set(false);activity?.deviceUnlock?.cancel();graph.localUnlock.cancel()}}
    fun unlock() {
        val request=graph.localUnlock.requestUnlock() ?: return
        activity?.deviceUnlock?.authenticate("Continue to your installed SoundQ session") {accepted->
            work.launch {val ok=withContext(Dispatchers.IO){graph.localUnlock.complete(request,accepted){alive.get()}};if(ok&&graph.session.state.value is AuthState.Restoring)model.restore()}
        } ?: graph.localUnlock.cancel()
    }
    Column(Modifier.fillMaxSize().padding(SoundQ.spacing.gutter),verticalArrangement=Arrangement.spacedBy(SoundQ.spacing.medium)) {
        Text("SoundQ is locked",style=SoundQ.typography.heading)
        Text("Use Android device authentication to continue. Playback stays paused.")
        state.error?.let {SoundQFeedback(it,FeedbackKind.Error)}
        SoundQButton(if(state.pending)"Waiting for Android" else "Unlock with device",{unlock()},enabled=!state.pending&&activity?.deviceUnlock?.available()==true)
        SoundQButton("Sign in with password instead",{activity?.deviceUnlock?.cancel();val version=graph.session.version();work.launch(Dispatchers.IO){graph.localUnlock.passwordFallback(version){alive.get()}}},variant=SoundQButtonVariant.Secondary)
    }
}
