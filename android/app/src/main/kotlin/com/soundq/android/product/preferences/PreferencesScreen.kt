package com.soundq.android.product.preferences

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.soundq.android.*
import com.soundq.android.data.*
import com.soundq.android.data.preferences.*
import com.soundq.android.product.ProductViewModel
import com.soundq.android.product.offline.readableStorageSize
import com.soundq.designsystem.*
import kotlinx.coroutines.*

/** Where Settings hands off to an existing owner outside its own route family. */
internal class SettingsExits(
    val onExit:()->Unit,
    val onDownloads:()->Unit,
    val onHistory:()->Unit,
    val onTool:(MusicTool)->Unit,
    val onSignedOut:()->Unit,
    val onGallery:(()->Unit)?,
)

/** Settings view state that outlives one host composition: exits to Downloads/History/tools and account changes. */
internal class SettingsMemory {
    /** Last observed temporary-audio status. Read only on Storage pages: status() validates every cached file. */
    var cache by mutableStateOf<com.soundq.android.data.cache.CacheStatus?>(null)
    /** Row to focus when the host next settles (the row that opened a popped page or an external destination). */
    var focus:String?=null
    fun reset(){cache=null;focus=null}
}

/**
 * Full-screen Settings. Device-local owners write under the current session version, so Settings works
 * signed in, signed out and offline; account writes keep the stricter captured account scope.
 * [pages] is owned by the caller so page state (scroll, auth fields) survives host recreation.
 * [onRoutes] applies an update to the stack as it is when the event runs, not as this composition last saw it.
 */
@Composable internal fun SettingsHost(model:ProductViewModel,auth:AuthState,routes:List<SettingsRoute>,onRoutes:((List<SettingsRoute>)->List<SettingsRoute>)->Unit,
    exits:SettingsExits,pages:androidx.compose.runtime.saveable.SaveableStateHolder,memory:SettingsMemory,authForm:@Composable (register:Boolean)->Unit) {
    val route=routes.lastOrNull() ?: return
    val graph=model.graph
    val work=rememberCoroutineScope()
    val version=remember {graph.session.version()}
    val scope=remember {graph.session.capture()}
    val alive=remember {java.util.concurrent.atomic.AtomicBoolean(true)}
    val valid={alive.get()&&graph.session.owns(version)}
    val accountValid={alive.get()&&scope?.let(graph.session::current)==true}
    val activity=androidx.activity.compose.LocalActivity.current as? MainActivity
    DisposableEffect(Unit){onDispose {alive.set(false);activity?.deviceUnlock?.cancel();graph.localUnlock.cancel()}}
    val cache=memory.cache
    fun refresh(){work.launch {val observed=withContext(Dispatchers.IO){graph.temporaryAudio.status()};if(valid())memory.cache=observed}}
    LaunchedEffect(route){if(route==SettingsRoute.Storage||route==SettingsRoute.StorageDetails)refresh()}
    val openers=remember {mutableMapOf<String,FocusRequester>()}
    fun opener(key:String)=openers.getOrPut(key){FocusRequester()}
    var settle by remember {mutableIntStateOf(0)}
    fun open(next:SettingsRoute)=onRoutes {it.push(next)}
    // Two Back presses can arrive before the first pop recomposes; each pops the then-current page.
    fun back()=onRoutes {current->
        val popped=current.lastOrNull() ?: return@onRoutes current
        pages.removeState(popped.name)
        memory.focus=popped.name;settle++
        current.pop()
    }
    fun leave(key:String,exit:()->Unit){memory.focus=key;exit()}
    androidx.activity.compose.BackHandler {back()}
    LaunchedEffect(route,settle) {
        val target=memory.focus ?: return@LaunchedEffect
        withFrameNanos {}
        runCatching {opener(target).requestFocus()}
        memory.focus=null
    }
    fun Modifier.opens(target:SettingsRoute)=focusRequester(opener(target.name))
    fun Modifier.opens(key:String)=focusRequester(opener(key))
    val leaving=SettingsExits(exits.onExit,{leave("Downloads",exits.onDownloads)},{leave("Listening history",exits.onHistory)},
        {tool->leave(tool.name,{exits.onTool(tool)})},exits.onSignedOut,exits.onGallery)
    pages.SaveableStateProvider(route.name) {
        SoundQSettingsScaffold(route.title,::back,scrollState=rememberScrollState()) {
            when(route) {
                SettingsRoute.Root->SettingsRoot(model,auth,cache,valid,::open,leaving) {Modifier.opens(it)}
                SettingsRoute.Account->AccountSettings(model,auth,accountValid,::open,exits) {Modifier.opens(it)}
                SettingsRoute.SignIn->authForm(false)
                SettingsRoute.CreateAccount->authForm(true)
                SettingsRoute.LocalAudio->LocalAudioDetail(graph,graph.session.version())
                SettingsRoute.Storage->StorageSettings(graph,cache,{refresh()},valid,{open(SettingsRoute.StorageDetails)},{leave("Manage downloads",exits.onDownloads)},
                    Modifier.opens(SettingsRoute.StorageDetails),Modifier.opens("Manage downloads"))
                SettingsRoute.StorageDetails->StorageDetails(cache)
                SettingsRoute.Theme->AppearanceChoices(graph.appearancePreferences)
                SettingsRoute.EndOfQueue->EndOfQueueChoices(graph.listeningPreferences,valid)
                SettingsRoute.SwipeToQueue->SwipeQueueChoices(graph.swipeQueuePreferences,valid)
                SettingsRoute.Crossfade->CrossfadeSetting(graph.crossfadePreferences,valid)
                SettingsRoute.KeyNotation->KeyNotationSetting(graph.keyNotationPreferences,valid)
                SettingsRoute.MusicTools->{
                    // The app bar already names this page; a section label would repeat it.
                    Spacer(Modifier.height(SoundQSettingsMetrics.firstSectionTop))
                    for(tool in MusicTool.entries)SoundQSettingsRow(tool.label,onClick={leaving.onTool(tool)},modifier=Modifier.opens(tool.name))
                }
                SettingsRoute.About->AboutSettings(valid,{open(SettingsRoute.Notices)},Modifier.opens(SettingsRoute.Notices))
                SettingsRoute.Notices->OpenSourceNotices()
            }
        }
    }
}

@Composable private fun SettingsRoot(model:ProductViewModel,auth:AuthState,cache:com.soundq.android.data.cache.CacheStatus?,valid:()->Boolean,
    open:(SettingsRoute)->Unit,exits:SettingsExits,opener:(String)->Modifier) {
    val graph=model.graph
    val settings by model.queueSettings.collectAsStateWithLifecycle()
    val listening by graph.listeningPreferences.state.collectAsStateWithLifecycle()
    val swipe by graph.swipeQueuePreferences.state.collectAsStateWithLifecycle()
    val crossfade by graph.crossfadePreferences.state.collectAsStateWithLifecycle()
    val notation by graph.keyNotationPreferences.state.collectAsStateWithLifecycle()
    val appearance by graph.appearancePreferences.state.collectAsStateWithLifecycle()
    val phone by graph.phoneAudio.state.collectAsStateWithLifecycle()
    // Account is a single row; a section label above it would only repeat its title.
    Spacer(Modifier.height(SoundQSettingsMetrics.firstSectionTop))
    SoundQSettingsRow("Account",value=accountStatus(auth),onClick={open(SettingsRoute.Account)},modifier=opener("Account"))
    SoundQSettingsSectionLabel("Library")
    SoundQSettingsRow("Local audio",value=localAudioSummary(phone),onClick={open(SettingsRoute.LocalAudio)},modifier=opener("LocalAudio"))
    SoundQSettingsRow("Downloads",onClick=exits.onDownloads,modifier=opener("Downloads"))
    SoundQSettingsRow("Storage",value=cache?.bytes?.let(::readableStorageSize),onClick={open(SettingsRoute.Storage)},modifier=opener("Storage"))
    SoundQSettingsRow("Listening history",onClick=exits.onHistory,modifier=opener("Listening history"))
    SoundQSettingsSectionLabel("Playback")
    val capture=graph.queueSettings.capture()
    SoundQSettingsSwitchRow("Keep queued songs",settings.keepQueued,{capture?.let {captured->model.keepQueued(captured,it,valid)}},
        supporting=if(settings.loading)"Loading…" else "Keep your queue when starting another list",enabled=capture!=null)
    if(settings.error)SoundQSettingsBlock {SoundQFeedback(if(settings.writable)"Couldn’t save Keep queued songs" else "Couldn’t load Keep queued songs",FeedbackKind.Error,action="Reload",onAction={model.reloadQueueSettings(valid)})}
    SoundQSettingsRow("End of queue",value=summary(listening.ready,endOfQueueLabel(listening.mode)),onClick={open(SettingsRoute.EndOfQueue)},modifier=opener("EndOfQueue"))
    SoundQSettingsRow("Swipe to queue",value=summary(swipe.ready,swipeQueueLabel(swipe.mode)),onClick={open(SettingsRoute.SwipeToQueue)},modifier=opener("SwipeToQueue"))
    SoundQSettingsRow("Crossfade",value=summary(crossfade.ready,crossfadeLabel(crossfade.seconds)),onClick={open(SettingsRoute.Crossfade)},modifier=opener("Crossfade"))
    DjModeSetting(graph.djModePreferences,valid)
    SoundQSettingsRow("Key notation",value=summary(notation.ready,keyNotationLabel(notation.choice)),onClick={open(SettingsRoute.KeyNotation)},modifier=opener("KeyNotation"))
    SoundQSettingsSectionLabel("Appearance")
    SoundQSettingsRow("Theme",value=summary(appearance.ready,appearanceLabel(appearance.choice)),onClick={open(SettingsRoute.Theme)},modifier=opener("Theme"))
    SoundQSettingsSectionLabel("More")
    SoundQSettingsRow("Music tools",onClick={open(SettingsRoute.MusicTools)},modifier=opener("MusicTools"))
    SoundQSettingsRow("About",onClick={open(SettingsRoute.About)},modifier=opener("About"))
    exits.onGallery?.let {gallery->
        SoundQSettingsSectionLabel("Developer")
        SoundQSettingsRow("Component gallery",onClick=gallery)
    }
}

/** Actual owner state only. An unknown or failed scan is not reported as zero songs. */
internal fun localAudioSummary(state:com.soundq.android.data.device.PhoneAudioState):String? = when(localAudioStatus(state)) {
    null->if(state.ready)null else "Loading…"
    LocalAudioStatus.Off->"Access off"
    LocalAudioStatus.Scanning->"Scanning…"
    LocalAudioStatus.Empty->"No audio found"
    LocalAudioStatus.Found->songCount(localAudioSongs(state))
    LocalAudioStatus.Failed->localAudioSongs(state).takeIf {it>0}?.let(::songCount)
}

@Composable private fun AccountSettings(model:ProductViewModel,auth:AuthState,accountValid:()->Boolean,open:(SettingsRoute)->Unit,exits:SettingsExits,opener:(SettingsRoute)->Modifier) {
    val graph=model.graph
    val unlock by graph.localUnlock.state.collectAsStateWithLifecycle()
    val activity=androidx.activity.compose.LocalActivity.current as? MainActivity
    val work=rememberCoroutineScope()
    var confirmLogout by remember {mutableStateOf(false)}
    var clearOnLogout by remember {mutableStateOf(false)}
    fun enroll(enabled:Boolean) {
        val request=graph.localUnlock.requestEnrollment(enabled) ?: return
        activity?.deviceUnlock?.authenticate(if(enabled)"Protect this installed app session" else "Turn off local session protection") {accepted ->
            work.launch {withContext(Dispatchers.IO){graph.localUnlock.complete(request,accepted,accountValid)}}
        } ?: graph.localUnlock.cancel()
    }
    Spacer(Modifier.height(SoundQSettingsMetrics.firstSectionTop))
    SoundQSettingsRow("Status",value=accountStatus(auth))
    SoundQSettingsRow("Server",value=graph.endpoint.identity,technical=true)
    val session=auth is AuthState.SignedIn||auth is AuthState.DeviceOnly
    if(session) {
        val available=activity?.deviceUnlock?.available()==true
        val enabled=unlock.ready&&!unlock.pending&&available
        SoundQSettingsSectionLabel("Security")
        SoundQSettingsSwitchRow("Device unlock",unlock.enrolled,{enroll(it)},
            supporting=if(!available)"Set up a screen lock" else if(unlock.pending)"Waiting for Android" else null,enabled=enabled)
        unlock.error?.let {SoundQSettingsBlock {SoundQFeedback(it,FeedbackKind.Error)}}
        if(unlock.enrolled)SoundQSettingsRow("Lock SoundQ",onClick={if(accountValid()){graph.localUnlock.lock();exits.onExit()}},trailing={})
    }
    SoundQSettingsSectionLabel("Session")
    when(auth) {
        is AuthState.SignedIn->SoundQSettingsRow("Sign out",onClick={confirmLogout=true},trailing={})
        is AuthState.DeviceOnly->{
            val deviceScope=remember {graph.session.capture()}
            SoundQSettingsRow("Go online",onClick={deviceScope?.let(model::goOnline)},enabled=deviceScope!=null,trailing={})
        }
        else->{
            SoundQSettingsRow("Sign in",onClick={open(SettingsRoute.SignIn)},modifier=opener(SettingsRoute.SignIn))
            SoundQSettingsRow("Create account",onClick={open(SettingsRoute.CreateAccount)},modifier=opener(SettingsRoute.CreateAccount))
        }
    }
    if(confirmLogout)AlertDialog(onDismissRequest={confirmLogout=false},title={Text("Sign out?")},
        text={Column {Text("Downloads stay on this device.")
            Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {Checkbox(clearOnLogout,{clearOnLogout=it});Text("Clear temporary playback audio")}}},
        confirmButton={TextButton(onClick={confirmLogout=false;if(accountValid()){model.logout(clearOnLogout);exits.onSignedOut()}}){Text("Sign out")}},
        dismissButton={TextButton(onClick={confirmLogout=false}){Text("Cancel")}})
}

@Composable private fun StorageSettings(graph:AppGraph,cache:com.soundq.android.data.cache.CacheStatus?,refresh:()->Unit,valid:()->Boolean,
    onDetails:()->Unit,onDownloads:()->Unit,detailsModifier:Modifier,downloadsModifier:Modifier) {
    val storage by graph.storagePreferences.state.collectAsStateWithLifecycle()
    val work=rememberCoroutineScope()
    var confirmClear by remember {mutableStateOf<com.soundq.android.data.cache.CacheClearCapture?>(null)}
    var cacheMessage by remember {mutableStateOf<String?>(null)}
    var failedWrite by remember {mutableStateOf(false)}
    var pending by remember {mutableStateOf(false)}
    Spacer(Modifier.height(SoundQSettingsMetrics.firstSectionTop))
    val storageCapture=graph.storagePreferences.capture()
    SoundQSettingsSwitchRow("Temporary audio",storage.temporaryAudioEnabled,
        {enabled->if(!pending)storageCapture?.let {captured->pending=true;work.launch {try {val saved=withContext(Dispatchers.IO){graph.storagePreferences.setTemporaryAudio(captured,enabled,valid)};if(valid())failedWrite=!saved&&graph.storagePreferences.state.value.error}finally {pending=false}}}},enabled=storageCapture!=null&&!pending)
    if(storage.error)SoundQSettingsBlock {SoundQFeedback(if(failedWrite)"Couldn’t save temporary audio" else "Couldn’t load temporary audio",FeedbackKind.Error,action="Reload",onAction={work.launch(Dispatchers.IO){if(valid())graph.storagePreferences.load()}})}
    SoundQSettingsRow("Used",value=cache?.bytes?.let(::readableStorageSize) ?: "Unavailable")
    cache?.takeIf {it.deferredFiles>0}?.let {SoundQSettingsRow("Clearing after playback",value=if(it.deferredFiles==1)"1 file" else "${it.deferredFiles} files")}
    SoundQSettingsRow("Clear temporary audio",onClick={if(valid())confirmClear=graph.temporaryAudio.captureClear()},trailing={})
    SoundQSettingsRow("Storage details",onClick=onDetails,modifier=detailsModifier)
    SoundQSettingsRow("Refresh",onClick=refresh,trailing={})
    cacheMessage?.let {message->SoundQSettingsBlock {
        if(message==CLEAR_FAILED)SoundQFeedback(message,FeedbackKind.Error,action="Retry",onAction={if(valid())confirmClear=graph.temporaryAudio.captureClear()})
        else SoundQFeedback(message,FeedbackKind.Notice)
    }}
    SoundQSettingsSectionLabel("Downloads")
    SoundQSettingsRow("Manage downloads",onClick=onDownloads,modifier=downloadsModifier)
    confirmClear?.let {captured ->AlertDialog(onDismissRequest={confirmClear=null},title={Text("Clear temporary audio?")},text={Text("Downloads and artwork stay on this device.")},confirmButton={TextButton(onClick={confirmClear=null;work.launch {val result=withContext(Dispatchers.IO){if(valid())graph.temporaryAudio.clear(captured) else null};if(valid()&&result!=null){cacheMessage=when {result.failedFiles>0->CLEAR_FAILED;result.deferredFiles>0->"Clearing after playback";else->"Temporary audio cleared"};refresh()}}}){Text("Clear")}},dismissButton={TextButton(onClick={confirmClear=null}){Text("Cancel")}})}
}
private const val CLEAR_FAILED="Couldn’t clear some audio"

@Composable private fun StorageDetails(cache:com.soundq.android.data.cache.CacheStatus?) {
    SoundQSettingsSectionLabel("Temporary audio",first=true)
    if(cache==null){SoundQSettingsBlock {SoundQFeedback("Loading storage",FeedbackKind.Loading)};return}
    SoundQSettingsRow("Size",value=cache.bytes?.let {"$it bytes"} ?: "Unavailable")
    SoundQSettingsRow("Tracked files",value="${cache.files}")
    SoundQSettingsRow("Awaiting clear",value="${cache.deferredFiles}")
    SoundQSettingsRow("Active writes",value="${cache.writingFiles}")
    SoundQSettingsRow("Validation failures",value="${cache.failedFiles}")
}

@Composable private fun EndOfQueueChoices(owner:EndOfQueuePreferences,valid:()->Boolean) {
    val state by owner.state.collectAsStateWithLifecycle()
    val work=rememberCoroutineScope()
    val capture=owner.capture()
    var failedWrite by remember {mutableStateOf(false)}
    // One write per captured revision: a second tap before the first settles would be refused as stale.
    var pending by remember {mutableStateOf(false)}
    Spacer(Modifier.height(SoundQSettingsMetrics.firstSectionTop))
    Column(Modifier.fillMaxWidth().selectableGroup()) {
        for(mode in EndOfQueue.entries)SoundQSettingsChoiceRow(endOfQueueLabel(mode),state.ready&&state.mode==mode,
            {if(!pending)capture?.let {captured->pending=true;work.launch {try {val saved=withContext(Dispatchers.IO){owner.setMode(captured,mode,valid)};if(valid())failedWrite=!saved&&owner.state.value.error}finally {pending=false}}}},enabled=capture!=null&&!pending)
    }
    if(!state.ready)SoundQSettingsBlock {SoundQFeedback("Loading…",FeedbackKind.Loading)}
    if(state.error)SoundQSettingsBlock {SoundQFeedback(if(failedWrite)"Couldn’t save End of queue" else "Couldn’t load End of queue",FeedbackKind.Error,action="Reload",onAction={work.launch(Dispatchers.IO){if(valid())owner.load()}})}
}

@Composable private fun SwipeQueueChoices(owner:SwipeQueuePreferences,valid:()->Boolean) {
    val state by owner.state.collectAsStateWithLifecycle()
    val work=rememberCoroutineScope()
    val capture=owner.capture()
    var failedWrite by remember {mutableStateOf(false)}
    // One write per captured revision: a second tap before the first settles would be refused as stale.
    var pending by remember {mutableStateOf(false)}
    Spacer(Modifier.height(SoundQSettingsMetrics.firstSectionTop))
    Column(Modifier.fillMaxWidth().selectableGroup()) {
        for(mode in listOf(SwipeQueue.AddToQueue,SwipeQueue.PlayNext))SoundQSettingsChoiceRow(swipeQueueLabel(mode),state.ready&&state.mode==mode,
            {if(!pending)capture?.let {captured->pending=true;work.launch {try {val saved=withContext(Dispatchers.IO){owner.setMode(captured,mode,valid)};if(valid())failedWrite=!saved&&owner.state.value.error}finally {pending=false}}}},enabled=capture!=null&&!pending)
    }
    if(!state.ready)SoundQSettingsBlock {SoundQFeedback("Loading…",FeedbackKind.Loading)}
    if(state.error)SoundQSettingsBlock {SoundQFeedback(if(failedWrite)"Couldn’t save Swipe to queue" else "Couldn’t load Swipe to queue",FeedbackKind.Error,action="Reload",onAction={work.launch(Dispatchers.IO){if(valid())owner.load()}})}
}

@Composable private fun AboutSettings(valid:()->Boolean,onNotices:()->Unit,noticesModifier:Modifier) {
    val context=LocalContext.current
    var failedLink by remember {mutableStateOf<String?>(null)}
    fun openLegal(path:String) {
        if(!valid())return
        failedLink=try {context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW,android.net.Uri.parse("https://openmusicplayer.app/$path")));null}catch(_:Exception){path}
    }
    SoundQSettingsSectionLabel("SoundQ",first=true)
    SoundQSettingsRow("Version",value="${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",technical=true)
    SoundQSettingsRow("Build",value="${BuildConfig.OMP_SOURCE_REF} · ${BuildConfig.OMP_BUILD_ID}",technical=true)
    SoundQSettingsSectionLabel("Legal")
    SoundQSettingsRow("Open-source notices",onClick=onNotices,modifier=noticesModifier)
    SoundQSettingsRow("Privacy policy",onClick={openLegal("privacy")})
    SoundQSettingsRow("Terms of service",onClick={openLegal("terms")})
    failedLink?.let {path->SoundQSettingsBlock {SoundQFeedback("Couldn’t open link",FeedbackKind.Error,action="Try again",onAction={openLegal(path)})}}
}

@Composable private fun OpenSourceNotices() {
    val context=LocalContext.current
    var attempt by remember {mutableIntStateOf(0)}
    var notices by remember {mutableStateOf<String?>(null)}
    var failed by remember {mutableStateOf(false)}
    LaunchedEffect(attempt) {
        failed=false
        val read=withContext(Dispatchers.IO){runCatching {context.assets.open("settings-notices.txt").bufferedReader().use {it.readText()}}.getOrNull()}
        notices=read;failed=read==null
    }
    SoundQSettingsBlock(Modifier.padding(vertical=SoundQ.spacing.large)) {
        Text("Native dependencies include AndroidX, Compose, Media3, Kotlin, kotlinx.coroutines, kotlinx.serialization, OkHttp, Okio and Guava. A complete generated dependency license catalog is not bundled.",style=SoundQ.typography.body)
        Text("Bundled Space Grotesk and IBM Plex Mono fonts use the SIL Open Font License.",style=SoundQ.typography.body)
        when {
            failed->SoundQFeedback("Couldn’t load notices",FeedbackKind.Error,action="Try again",onAction={attempt++})
            notices==null->SoundQFeedback("Loading notices",FeedbackKind.Loading)
            else->Text(notices.orEmpty(),style=SoundQ.typography.caption)
        }
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
    Spacer(Modifier.height(SoundQSettingsMetrics.firstSectionTop))
    Column(Modifier.fillMaxWidth().selectableGroup()) {
        for(choice in KeyNotation.entries) {
            val selected=state.ready&&state.choice==choice
            val enabled=state.ready&&capture!=null
            SoundQSettingsChoiceRow(keyNotationLabel(choice),selected,{choose(choice)},supporting=if(choice==KeyNotation.Camelot)"8A, 11B" else "Am, F# major",enabled=enabled)
        }
    }
    if(!state.ready)SoundQSettingsBlock {SoundQFeedback("Loading…",FeedbackKind.Loading)}
    if(state.error==KeyNotationError.Read)SoundQSettingsBlock {SoundQFeedback("Couldn’t load key notation",FeedbackKind.Error,action="Reload key notation",onAction=::reload)}
    if(state.error==KeyNotationError.Write)SoundQSettingsBlock {
        val failed=retry
        SoundQFeedback("Couldn’t save key notation",FeedbackKind.Error,action=if(failed!=null)"Retry key notation" else "Reload key notation",onAction={if(failed!=null)choose(failed)else reload()})
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
