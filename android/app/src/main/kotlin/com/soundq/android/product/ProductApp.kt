package com.soundq.android.product

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.text.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.*
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.platform.*
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.input.*
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.lifecycle.*
import androidx.lifecycle.compose.*
import androidx.lifecycle.viewmodel.compose.viewModel
import com.soundq.android.R
import com.soundq.android.BuildConfig
import com.soundq.android.*
import com.soundq.android.data.*
import com.soundq.android.data.playlists.*
import com.soundq.designsystem.*
import com.soundq.android.data.home.*
import com.soundq.android.product.home.*
import com.soundq.android.data.imports.ImportView
import com.soundq.android.product.imports.ImportsScreen
import com.soundq.android.product.preferences.*

@Composable fun ProductApp(model:ProductViewModel=viewModel()) {
    PlayerFailureToasts(model)
    val auth by model.auth.collectAsStateWithLifecycle()
    val onlineRestore by model.onlineRestore.collectAsStateWithLifecycle()
    val library by model.library.collectAsStateWithLifecycle()
    val phone by model.graph.phoneAudio.state.collectAsStateWithLifecycle()
    var librarySource by rememberSaveable {mutableStateOf(LibrarySource.All)}
    var recentOrder by rememberSaveable {mutableStateOf(false)}
    var localQuery by remember {mutableStateOf(LibraryQuery())}
    var selectedPhone by remember {mutableStateOf<com.soundq.android.data.deviceaudio.DeviceAudio?>(null)}
    val imports by model.imports.collectAsStateWithLifecycle()
    val downloads by model.downloads.collectAsStateWithLifecycle()
    val incomingShare by model.graph.incomingShares.state.collectAsStateWithLifecycle()
    val catalog by model.graph.catalog.state.collectAsStateWithLifecycle()
    var importView by remember {mutableStateOf<ImportView?>(null)}
    val libraryScroll=rememberLazyListState()
    var revealImported by remember {mutableStateOf<TrackId?>(null)}
    DisposableEffect(Unit) {onDispose {importView?.let(model.graph.imports::close)}}
    LaunchedEffect(revealImported,library.rows,library.loading,library.error) {
        revealImported?.let {id ->
            val index=library.rows.indexOfFirst {it.id==id}
            if(index>=0){libraryScroll.scrollToItem(libraryRowScrollIndex(index,library.loading,library.error!=null,localAudioNotice(phone,library.query,librarySource,rowsEmpty=false)!=null));revealImported=null}
        }
    }
    val accountVersion=model.graph.session.version()
    val compactEntry=remember(accountVersion){java.util.concurrent.atomic.AtomicBoolean(true)}
    DisposableEffect(compactEntry){onDispose {compactEntry.set(false)}}
    val shell=remember(accountVersion,auth is AuthState.SignedIn) {
        val scope=model.graph.session.capture()
        HomeShell {scope!=null&&model.graph.session.current(scope)}
    }
    DisposableEffect(shell) {onDispose {shell.close()}}
    val route by shell.route.collectAsStateWithLifecycle()
    val playback by model.playback.collectAsStateWithLifecycle()
    val queueSettings by model.queueSettings.collectAsStateWithLifecycle()
    val playlists by model.playlists.collectAsStateWithLifecycle()
    val playlistDetail by model.playlistDetail.collectAsStateWithLifecycle()
    val playlistBlend by model.playlistBlend.collectAsStateWithLifecycle()
    LaunchedEffect(playlistDetail.detail) {model.graph.playlistBlend.sourceChanged()}
    val blendLifecycle=androidx.lifecycle.compose.LocalLifecycleOwner.current
    var blendForeground by remember {mutableStateOf(false)}
    var playlistArtworkVisit by remember {mutableLongStateOf(0L)}
    val playlistManagement by model.playlistManagement.collectAsStateWithLifecycle()
    val playlistOrder by model.playlistOrder.collectAsStateWithLifecycle()
    val queuePlaylist by model.queuePlaylist.collectAsStateWithLifecycle()
    var destination by rememberSaveable {mutableStateOf("Library")}
    val acquisitionSavedState=androidx.compose.runtime.saveable.rememberSaveableStateHolder()
    val acquisitionOwner=(auth as? AuthState.SignedIn)?.let {
        com.soundq.android.product.acquisition.PlaylistSavedOwner(model.graph.endpoint.identity,it.accountId)
    }
    var acquisitionReturn by rememberSaveable {mutableStateOf(emptyList<String>())}
    val acquisitionPlaylistJob=acquisitionOwner?.restoreJob(acquisitionReturn)
    val blendVisible=destination=="Playlists" && importView==null && playlistDetail.id!=null && auth is AuthState.SignedIn
    DisposableEffect(model,blendLifecycle,blendVisible) {
        fun sync() {
            val foreground=blendVisible && blendLifecycle.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
            model.graph.playlistBlend.visible(foreground)
            if(blendForeground!=foreground)playlistArtworkVisit++
            blendForeground=foreground
        }
        val observer=LifecycleEventObserver {_,_->sync()}
        blendLifecycle.lifecycle.addObserver(observer);sync()
        onDispose {model.graph.playlistBlend.visible(false);blendLifecycle.lifecycle.removeObserver(observer)}
    }
    val catalogActions=if(destination=="Catalog" && importView==null && auth is AuthState.SignedIn) remember(model,accountVersion){model.catalogActions()} else null
    DisposableEffect(catalogActions){onDispose {catalogActions?.close()}}
    var discoveryVisit by remember {mutableStateOf(0L)}
    val discoveryView=if(destination=="Discover" && importView==null && auth is AuthState.SignedIn) remember(model,accountVersion,discoveryVisit){model.graph.discovery.open()} else null
    val discoveryIntake=if(discoveryView!=null) remember(model,accountVersion,discoveryVisit){model.graph.imports.open()} else null
    fun leaveDiscovery() {
        discoveryView?.let(model.graph.discovery::close)
        discoveryIntake?.let(model.graph.imports::close)
        discoveryVisit++
    }
    val playlistActions = if(destination=="Playlists" && auth is AuthState.SignedIn) remember(model,(auth as AuthState.SignedIn).accountId) { model.playlistActions() } else null
    val managementActions = if(playlistActions!=null) remember(model,accountVersion) { model.playlistManagementActions() } else null
    DisposableEffect(managementActions) {onDispose {managementActions?.close()}}
    val orderActions = if(playlistActions!=null && importView==null) remember(model,accountVersion,playlistDetail.id) {model.playlistOrderActions()} else null
    DisposableEffect(orderActions) {onDispose {orderActions?.close()}}
    LaunchedEffect(playlistManagement.outcome,playlistManagement.observed,playlistManagement.missing) {
        if(playlistManagement.outcome==MutationOutcome.Confirmed || playlistManagement.reconciled)playlistActions?.reload()
    }
    fun closePlaylistDestination() {
        orderActions?.close()
        if(acquisitionPlaylistJob!=null) {
            model.closePlaylistDetail();destination="Acquisition"
        } else if(playlistDetail.id!=null)model.closePlaylistDetail()
        else {playlistActions?.close();destination="Library"}
    }
    if(destination=="Playlists" && importView==null) androidx.activity.compose.BackHandler {closePlaylistDestination()}
    DisposableEffect(playlistActions) {onDispose {playlistActions?.close();if(playlistActions!=null)model.closePlaylistDetail()}}
    val membership by model.playlistMembership.collectAsStateWithLifecycle()
    val libraryActions = if(destination=="Library" && importView==null && auth is AuthState.SignedIn) remember(model,accountVersion) { model.libraryPlaylistActions() } else null
    var picker by remember {mutableStateOf<MembershipPickerActions?>(null)}
    var detailsRoute by remember {mutableStateOf<com.soundq.android.data.trackdetails.DetailsRoute?>(null)}
    val trackDetails by model.trackDetails.collectAsStateWithLifecycle()
    val keyNotation by model.graph.keyNotationPreferences.state.collectAsStateWithLifecycle()
    DisposableEffect(accountVersion) {onDispose {detailsRoute?.let(model.graph.trackDetails::close)}}
    DisposableEffect(detailsRoute) {val captured=detailsRoute;onDispose {captured?.let(model.graph.trackDetails::close)}}
    var trackCapture by remember {mutableStateOf<LibraryTrackCapture?>(null)}
    var trackPlaylistActions by remember {mutableStateOf<LibraryPlaylistActions?>(null)}
    DisposableEffect(libraryActions) {onDispose {libraryActions?.close()}}
    DisposableEffect(picker) {val captured=picker;onDispose {captured?.close()}}
    LaunchedEffect(picker) {picker?.let {if(membership.outcome==null)it.reload()}}
    var panel by remember {mutableStateOf<String?>(null)}
    // Settings is a full-screen route family, not a panel. Names are saveable; decode drops unknown entries.
    var settingsRoutes by rememberSaveable {mutableStateOf(emptyList<String>())}
    var settingsReturn by rememberSaveable {mutableStateOf<List<String>?>(null)}
    var settingsOrigin by rememberSaveable {mutableStateOf("Library")}
    var pendingTool by rememberSaveable {mutableStateOf<String?>(null)}
    // Page state (scroll, embedded auth fields) and return focus outlive one SettingsHost composition.
    val settingsPages=androidx.compose.runtime.saveable.rememberSaveableStateHolder()
    val settingsMemory=remember {SettingsMemory()}
    var transportReturn by remember(accountVersion) {mutableStateOf<String?>(null)}
    fun closeDetails(captured:com.soundq.android.data.trackdetails.DetailsRoute) {
        model.graph.trackDetails.close(captured)
        if(detailsRoute===captured){detailsRoute=null;panel=if(captured.fromPlayer&&model.graph.session.remoteCurrent(captured.scope))"Player" else null}
    }
    LaunchedEffect(playback,detailsRoute,accountVersion) {
        detailsRoute?.takeIf {!model.graph.trackDetails.current(it)}?.let(::closeDetails)
    }
    var queueSave by remember {mutableStateOf<QueuePlaylistActions?>(null)}
    fun closeQueueSave() {queueSave?.close();queueSave=null}
    DisposableEffect(queueSave) {val captured=queueSave;onDispose {captured?.close()}}
    DisposableEffect(panel,detailsRoute) {val captured=detailsRoute;val owns=panel=="Details";onDispose {if(owns)captured?.let(model.graph.trackDetails::close)}}
    var selected by remember {mutableStateOf<Track?>(null)}
    var gallery by remember {mutableStateOf(false)}
    val paginationScope=remember(accountVersion,auth is AuthState.SignedIn){model.graph.session.capture()}
    var paginationNavigation by remember {mutableLongStateOf(0L)}
    var rowVisit by remember {mutableLongStateOf(0L)}
    val collectionVisit=remember(accountVersion,destination,importView,gallery,paginationNavigation,rowVisit){LibraryPaginationGate()}
    DisposableEffect(collectionVisit){onDispose {collectionVisit.close()}}
    val paginationVisit=remember(accountVersion,destination,importView,panel,gallery,picker,paginationNavigation,rowVisit){LibraryPaginationGate()}
    DisposableEffect(paginationVisit){onDispose {paginationVisit.close()}}
    val currentCollectionVisit by rememberUpdatedState(collectionVisit)
    val currentPaginationVisit by rememberUpdatedState(paginationVisit)
    val revealOwner=remember {RowRevealOwner()}
    val rowLifecycle=androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    val rowLifetime=remember(accountVersion,destination,importView,panel,gallery,library.query,library.loading,library.error,paginationNavigation,rowVisit) {
        LibraryRowLifetime {destination=="Library"&&importView==null&&panel==null&&!gallery&&auth is AuthState.SignedIn&&rowLifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)}
    }
    DisposableEffect(rowLifetime) {onDispose {rowLifetime.close();revealOwner.close()}}
    val currentRowLifetime by rememberUpdatedState(rowLifetime)
    DisposableEffect(rowLifecycle) {
        val observer=LifecycleEventObserver {_,event->when(event) {
            Lifecycle.Event.ON_PAUSE,Lifecycle.Event.ON_STOP->{currentCollectionVisit.close();currentPaginationVisit.close();currentRowLifetime.close();revealOwner.close()}
            Lifecycle.Event.ON_RESUME->{rowVisit++}
            else->Unit
        }}
        rowLifecycle.addObserver(observer)
        onDispose {currentRowLifetime.close();revealOwner.close();rowLifecycle.removeObserver(observer)}
    }
    fun openSettings(routes:List<SettingsRoute> = listOf(SettingsRoute.Root)) {
        if(settingsRoutes.isEmpty()){settingsOrigin=destination;SettingsRoute.entries.forEach {settingsPages.removeState(it.name)};settingsMemory.reset()}
        settingsReturn=null;panel=null;settingsRoutes=routes.encode()
    }
    /** Closing Settings in place remounts the tab beneath it. Discover's screen closed its handles on disposal. */
    fun closeSettings() {settingsRoutes=emptyList();if(destination=="Discover")discoveryVisit++}
    /** Actions that need a session open Account (or its sign-in form) on top of whatever Settings already shows. */
    fun openAccount() {openSettings(SettingsRoute.decode(settingsRoutes)+accountEntry(auth))}
    fun navigate(next:String) {
        if(auth !is AuthState.SignedIn&&next !in setOf("Library","Downloads")){openAccount();return}
        settingsReturn=null
        acquisitionReturn=emptyList()
        collectionVisit.close();paginationVisit.close();paginationNavigation++
        rowLifetime.close();revealOwner.close()
        catalogActions?.close()
        if(next!=destination)orderActions?.close()
        closeQueueSave()
        model.graph.acquisition.closeCurrent()
        leaveDiscovery()
        detailsRoute?.let(model.graph.trackDetails::close);detailsRoute=null
        panel=null;picker?.close();picker=null;trackCapture=null
        importView?.let(model.graph.imports::close);importView=null
        if(next!="Playlists"){model.closePlaylistDetail();playlistActions?.close()}
        shell.navigate(when(next){"Home"->HomeDestination.Home;"History"->HomeDestination.History;else->HomeDestination.Library})
        destination=next
    }
    /** Leave Settings for an existing destination, keeping a token so Back returns to the opening row. */
    fun settingsDestination(next:String,after:()->Unit={}) {
        if(auth !is AuthState.SignedIn&&next !in setOf("Library","Downloads")){openAccount();return}
        val stack=settingsRoutes
        settingsRoutes=emptyList();navigate(next);after();settingsReturn=stack
    }
    fun returnToSettings():Boolean {
        val stack=settingsReturn ?: return false
        settingsReturn=null;navigate(settingsOrigin);settingsRoutes=stack
        return true
    }
    fun openImports() {catalogActions?.close();orderActions?.close();closeQueueSave();model.graph.acquisition.closeCurrent();detailsRoute?.let(model.graph.trackDetails::close);detailsRoute=null;leaveDiscovery();panel=null;importView=model.graph.imports.open()}
    /** Music tools keep their existing owners. Without a session, Account opens and the chosen tool is retained. */
    fun openTool(tool:MusicTool) {
        if(auth !is AuthState.SignedIn){pendingTool=tool.name;openAccount();return}
        when(tool) {
            MusicTool.Catalog->settingsDestination("Catalog")
            MusicTool.Mixes->settingsDestination("Mixes")
            MusicTool.ConnectedDevices->panel="Devices"
            MusicTool.Jam->panel="Jam"
            MusicTool.Imports->settingsDestination("Discover") {openImports()}
            MusicTool.ServerImports->settingsDestination("Acquisition")
        }
    }
    val deviceScope=remember(accountVersion,auth is AuthState.DeviceOnly) {if(auth is AuthState.DeviceOnly)model.graph.session.capture() else null}
    androidx.activity.compose.BackHandler(auth is AuthState.DeviceOnly || (auth is AuthState.Pending && onlineRestore!=null)) {
        deviceScope?.let(model::goOnline)
    }
    androidx.activity.compose.BackHandler(((auth is AuthState.SignedIn && destination in listOf("Home","History","Discover","Downloads","Acquisition","Mixes"))||settingsReturn!=null) && importView==null && panel==null && settingsRoutes.isEmpty()) {if(!returnToSettings())navigate("Library")}
    LaunchedEffect(auth) {if(auth !is AuthState.SignedIn){orderActions?.close();closeQueueSave();importView?.let(model.graph.imports::close);importView=null;revealImported=null;detailsRoute?.let(model.graph.trackDetails::close);detailsRoute=null;panel=null;selected=null;picker?.close();picker=null;trackCapture=null;gallery=false;if(auth !is AuthState.Restoring && auth !is AuthState.Pending){acquisitionReturn=emptyList();destination="Library"}}}
    LaunchedEffect(playlistActions) {playlistActions?.reload()}
    // Single owner for auth-driven Settings routes: once a session exists the sign-in form retires, and a tool
    // chosen while signed out opens. Doing both here avoids a second writer re-pushing a stale stack.
    LaunchedEffect(auth is AuthState.SignedIn||auth is AuthState.DeviceOnly) {
        if(settingsRoutes.isEmpty())return@LaunchedEffect
        val stack=SettingsRoute.decode(settingsRoutes)
        val settled=stack.settled(auth)
        val tool=pendingTool?.let {name->MusicTool.entries.firstOrNull {it.name==name}}
        if(auth is AuthState.SignedIn&&tool!=null) {
            pendingTool=null
            settingsRoutes=settled.dropLastWhile {it==SettingsRoute.Account}.ifEmpty {listOf(SettingsRoute.Root)}.encode()
            openTool(tool)
        } else if(settled!=stack)settingsRoutes=settled.encode()
    }
    val appearance by model.graph.appearancePreferences.state.collectAsStateWithLifecycle()
    SoundQTheme(appearance=when(appearance.choice) {
        com.soundq.android.data.preferences.Appearance.System->soundq.design.generated.SoundQAppearance.System
        com.soundq.android.data.preferences.Appearance.Light->soundq.design.generated.SoundQAppearance.Light
        com.soundq.android.data.preferences.Appearance.Dark->soundq.design.generated.SoundQAppearance.Dark
    }) {
        // Only identity/incarnation changes reset row motion; 500ms playback cursor ticks do not.
        CompositionLocalProvider(LocalMediaMarqueeIdentity provides listOf(playback.accountEpoch,playback.sessionIdentity,
            playback.source,playback.sourceQueueIncarnation,playback.selectionIncarnation,playback.selectedOccurrence,
            playback.queue.singleOrNull {it.occurrenceId==playback.selectedOccurrence}?.ref)) {
        AppearanceSystemBars(SoundQ.colors.roles==soundq.design.generated.SoundQAppearanceMapping.dark)
        Surface(Modifier.fillMaxSize().closeRowRevealOutside(revealOwner),color=SoundQ.colors.background) {
            Box(Modifier.safeDrawingPadding().imePadding(),contentAlignment=Alignment.TopCenter) {
                if(gallery && auth is AuthState.SignedIn) {androidx.activity.compose.BackHandler {gallery=false};SoundQApp()}
                else if(auth is AuthState.LocalLocked) com.soundq.android.product.preferences.LocalUnlockScreen(model)
                else if(auth is AuthState.Pending && onlineRestore?.deviceOnly==true) Column(Modifier.fillMaxSize().padding(SoundQ.spacing.gutter)) {
                    SoundQFeedback("Going online",FeedbackKind.Loading)
                }
                // A sign-in started from Settings stays in Settings through Pending/SaveRequired; other auth states use the standalone form.
                else if(auth !is AuthState.SignedIn&&auth !is AuthState.DeviceOnly&&auth !is AuthState.SignedOut&&
                    SettingsRoute.decode(settingsRoutes).lastOrNull() !in setOf(SettingsRoute.SignIn,SettingsRoute.CreateAccount)) Column(Modifier.fillMaxSize()) {
                    incomingShare?.takeIf {it.account==null}?.let {share->
                        Text("Shared music link retained. Sign in, then confirm the import.",Modifier.padding(SoundQ.spacing.gutter))
                        SoundQButton("Discard shared link",{model.graph.incomingShares.dismiss(share)},variant=SoundQButtonVariant.Secondary)
                    }
                    Box(Modifier.weight(1f)){AuthScreen(auth,model)}
                }
                else if(settingsRoutes.isNotEmpty()) key(accountVersion) {
                    // Full screen: replaces tab content, bottom navigation and the compact player. Playback is untouched.
                    SettingsHost(model,auth,SettingsRoute.decode(settingsRoutes),{update->
                            // Read the stack now: an earlier event in this frame may already have changed it.
                            val current=SettingsRoute.decode(settingsRoutes)
                            if(current.isNotEmpty()) {
                                val routes=update(current)
                                if(routes.isEmpty())closeSettings() else settingsRoutes=routes.encode()
                                if(SettingsRoute.Account !in routes)pendingTool=null
                            }
                        },
                        SettingsExits(onExit={closeSettings()},
                            // Downloads belong to an account or offline session; without one, Account opens instead of an empty page.
                            onDownloads={if(model.graph.session.capture()==null)openAccount() else settingsDestination("Downloads")},
                            onHistory={settingsDestination("History")},
                            onTool=::openTool,
                            onSignedOut={orderActions?.close();closeQueueSave();importView?.let(model.graph.imports::close);importView=null;panel=null;settingsRoutes=listOf(SettingsRoute.Root).encode()},
                            onGallery=if(BuildConfig.DEBUG&&auth is AuthState.SignedIn){{gallery=true}}else null),
                        settingsPages,settingsMemory,authForm={register->AuthScreen(auth,model,scrollable=false,embedded=true,initialRegister=register)})
                }
                else Column(Modifier.widthIn(max=SoundQ.sizes.appMax).fillMaxSize()) {
                    incomingShare?.takeIf {it.account==null||it.account==(auth as? AuthState.SignedIn)?.accountId}?.let {
                        Row(Modifier.fillMaxWidth().heightIn(min=48.dp).padding(start=SoundQ.spacing.gutter),verticalAlignment=Alignment.CenterVertically) {
                            Text(if(auth is AuthState.SignedIn)"Shared link ready" else "Shared music link retained. Sign in, then confirm the import.",Modifier.weight(1f),style=SoundQ.typography.caption)
                            LibraryIconCell(SoundQIcon.Info,"Review shared link",{if(auth is AuthState.SignedIn)panel="SharedLink" else openAccount()})
                        }
                        SoundQDivider()
                    }
                    val activeImport=importView
                    val importDraft=imports.draft
                    if(activeImport!=null) {
                        fun closeImports(){model.graph.imports.close(activeImport);importView=null}
                        androidx.activity.compose.BackHandler {closeImports();returnToSettings()}
                        Box(Modifier.weight(1f).fillMaxWidth()) {
                            ImportsScreen(imports,{model.graph.imports.edit(activeImport,it)},
                                {model.submitImport(activeImport,importDraft)},
                                {model.checkImport(activeImport)},{model.recentImports(activeImport)},
                                {model.graph.imports.select(activeImport,it)},
                                {model.graph.imports.another(activeImport)},
                                {model.openImportLibrary(activeImport){id -> if(importView===activeImport){revealImported=id;closeImports();navigate("Library")}}},
                                {closeImports();returnToSettings()},{openSettings()},
                                {receipt->model.recoverSourceImport(activeImport,receipt)},
                                {receipt->model.retrySourceImport(activeImport,receipt)},{receipt->model.recoverDurableImport(activeImport,receipt)},{receipt->model.retryDurablePublication(activeImport,receipt)},
                                onOpenPlaylist={confirmation->model.graph.imports.openPlaylistTarget(activeImport,confirmation){id->closeImports();navigate("Playlists");if(model.graph.playlistDetail.select(id)!=null)model.retryPlaylistDetail()}})
                        }
                    } else if(destination=="Acquisition") Box(Modifier.weight(1f).fillMaxWidth()) {
                        acquisitionOwner?.let {owner->key(owner.providerKey) {acquisitionSavedState.SaveableStateProvider(owner.providerKey) {
                            com.soundq.android.product.acquisition.AcquisitionScreen(model,{navigate("Discover")},{openImports()},{id->openImports();importView?.let {model.graph.imports.selectRetained(it,id)}},
                                {job,id->navigate("Playlists");acquisitionReturn=owner.saveJob(job.value);if(model.graph.playlistDetail.select(PlaylistId(id))!=null)model.retryPlaylistDetail()},acquisitionPlaylistJob?.let {com.soundq.android.data.imports.ImportJobId(it)})
                        }}}
                    } else if(destination=="Catalog") Box(Modifier.weight(1f).fillMaxWidth()) {
                        catalogActions?.let {com.soundq.android.product.catalog.CatalogScreen(catalog,it,{if(!returnToSettings())navigate("Library")})}
                    } else if(destination=="Mixes") Box(Modifier.weight(1f).fillMaxWidth()) {
                        key(accountVersion) {com.soundq.android.product.mix.MixScreen(model)}
                    } else if(destination=="Downloads") Box(Modifier.weight(1f).fillMaxWidth()) {
                        val scope=remember(accountVersion){model.graph.session.capture()}
                        scope?.let {com.soundq.android.product.offline.DownloadsScreen(model,downloads,it,{if(!returnToSettings())navigate("Library")})}
                    } else if(destination=="Discover") Box(Modifier.weight(1f).fillMaxWidth()) {
                        com.soundq.android.product.discovery.DiscoverScreen(model,discoveryView,discoveryIntake,{openImports()},{openSettings()},{navigate("Acquisition")})
                        com.soundq.android.product.imports.SourceImportOptions(model,discoveryIntake)
                    } else if(destination in listOf("Home","History")) Box(Modifier.weight(1f).fillMaxWidth()) {
                        HomeDestinationScreen(model,route,{navigate("Library")},{openSettings()},revealOwner,onHistory={navigate("History")})
                    } else if(destination=="Playlists") Box(Modifier.weight(1f).fillMaxWidth()) {
                        val artworkCapture=remember(playlistDetail.detail?.let(::RowIdentity),accountVersion,playlistArtworkVisit,blendForeground) {if(blendForeground)model.graph.playlistDetail.capturePlayback()else null}
                        if(playlistDetail.id!=null)com.soundq.android.product.playlists.HarmonicPlaylist(model,managementActions) {harmonicEntry,harmonicFeedback->com.soundq.android.product.playlists.PlaylistDetailScreen(
                            playlistDetail,model.graph.playlistDetail.capturePlayback(),{closePlaylistDestination()},model::retryPlaylistDetail,{p,id->model.playPlaylist(p,id)},playlistManagement,managementActions,playlistOrder,orderActions,
                            playlistBlend,if(blendForeground)model.graph.playlistBlend.capture()else null,model::generatePlaylistBlend,model::recoverPlaylistBlend,
                            {captured,mixed->model.graph.playlistBlend.choose(captured,mixed)},model::shufflePlaylist,
                            model.graph.playlistBlend.acceptedPlan(),model.graph.playlistBlend.capture()?.let(model.graph.playlistBlend::canGenerate)==true,
                            model.graph.playlistBlend.capture()?.let(model.graph.playlistBlend::canRecover)==true,model::playPlaylist,
                            {p,index,track,valid->model.quickQueuePlaylist(p,index,track,valid)},revealOwner,harmonicEntry,
                            playback=playback,harmonicFeedback=harmonicFeedback,artwork={track,rowCurrent->com.soundq.android.product.artwork.TrackArtwork(model.graph,artworkCapture?.scope,track.takeIf {it.artwork!=null} ?: model.graph.track(track.id) ?: track,
                                {rowCurrent()&&artworkCapture?.let {captured->model.graph.playlistDetail.ownsPlayback(captured)&&captured.detail.tracks.any {it===track}}==true},sourceOwner=artworkCapture)})}
                        else playlistActions?.let { actions -> com.soundq.android.product.playlists.PlaylistsScreen(playlists,actions.capture,actions::create,actions::reload,actions::startNew,model::openPlaylist,
                            {managementActions?.let {com.soundq.android.product.playlists.PlaylistManagementFeedback(playlistManagement,it)}},onRefine=actions::refine) }
                    } else Column(Modifier.weight(1f).fillMaxWidth()) {
                        val mixedQuery=if(auth is AuthState.SignedIn)library.query else localQuery
                        val account=(auth as? AuthState.SignedIn)?.accountId ?: (auth as? AuthState.DeviceOnly)?.accountId
                        val projectionOwner=model.graph.library.projectionScope(library)
                        val downloadTracks=downloads.rows.filter {row->paginationScope?.let {model.graph.downloads.ownsComplete(it,row)}==true}.map {it.track}
                        val mixedNeeded=phone.snapshot?.files?.isNotEmpty()==true||downloadTracks.isNotEmpty()||librarySource!=LibrarySource.All||recentOrder||auth !is AuthState.SignedIn
                        LaunchedEffect(accountVersion,library,mixedNeeded) {if(mixedNeeded&&auth is AuthState.SignedIn)kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO){model.graph.library.completeProjection(library)}}
                        val mixedRows=remember(library,phone.snapshot,downloads,account,projectionOwner,accountVersion,librarySource,recentOrder,mixedQuery) {unifiedLibraryRows(model.graph.endpoint.identity,account,if(auth is AuthState.SignedIn&&projectionOwner!=null)library.rows else emptyList(),downloadTracks,phone.snapshot,mixedQuery,librarySource,recentOrder)}
                        val localAudioVisit=remember {java.util.concurrent.atomic.AtomicBoolean(true)}
                        DisposableEffect(localAudioVisit){onDispose {localAudioVisit.set(false)}}
                        // Same access action as Settings > Local audio.
                        // Session versions are captured per callback: a retired scope need not recompose this route.
                        val allowFileAccess=com.soundq.android.product.preferences.rememberFileAccess(model.graph) {
                            // The scan belongs to the phone owner's session scope, not this visit: leaving
                            // Library must not cancel a first scan that is still proving files.
                            val version=model.graph.session.version()
                            if(localAudioVisit.get()&&model.graph.phoneAudio.current(version)&&localAudioAccessChanged(model.graph.phoneAudio.state.value,model.graph.phoneAudio.platform.storageAllowed()))
                                model.graph.phoneAudio.refresh {model.graph.phoneAudio.current(version)}
                        }
                        val localNotice=localAudioNotice(phone,mixedQuery,librarySource,mixedRows.isEmpty())
                        val refined=mixedQuery!=LibraryQuery()||librarySource!=LibrarySource.All||recentOrder
                        fun clearRefinement(){if(auth is AuthState.SignedIn)model.refine(LibraryQuery())else localQuery=LibraryQuery();librarySource=LibrarySource.All;recentOrder=false}
                        LibraryHeader({openSettings()},{navigate("Catalog")})
                        LibrarySearch(mixedQuery.text) {if(auth is AuthState.SignedIn)model.refine(library.query.copy(text=it))else localQuery=localQuery.copy(text=it)}
                        LibraryFilters(mixedQuery.liked,if(mixedNeeded)mixedRows.size else library.total,{if(auth is AuthState.SignedIn)model.refine(library.query.copy(liked=it))else localQuery=localQuery.copy(liked=it)},{panel="Refine"})

                        if(mixedNeeded&&auth is AuthState.SignedIn&&!library.completeProjection)Text(if(library.projectionError||library.error!=null)"Partial server coverage · ordering shown results only" else "Loading complete server coverage · ordering shown results only",Modifier.padding(horizontal=SoundQ.spacing.gutter),style=SoundQ.typography.caption,color=SoundQ.colors.muted)
                        phone.message?.takeIf {librarySource!=LibrarySource.Server&&phone.snapshot==null}?.let {Text(it,Modifier.padding(horizontal=SoundQ.spacing.gutter),style=SoundQ.typography.caption)}
                        val collectionCurrent={collectionVisit.current()&&panel==null&&picker==null&&destination=="Library"&&rowLifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)&&paginationScope?.let(model.graph.session::remoteCurrent)==true}
                        LibraryCollectionControls(library,{model.refine(library.query.copy(collection=null))},
                            {model.playLibraryCollection(library,current=collectionCurrent)},
                            {model.playLibraryCollection(library,shuffle=true,current=collectionCurrent)})
                        LibraryNearBottomPagination(libraryScroll,library,accountVersion to paginationNavigation,
                            enabled=destination=="Library"&&importView==null&&panel==null&&picker==null&&!gallery&&auth is AuthState.SignedIn,
                            current={paginationVisit.current()&&paginationScope?.let(model.graph.session::remoteCurrent)==true},
                            onLoadMore={expected,current->model.loadMore(expected,current)})
                        LazyColumn(Modifier.weight(1f).fillMaxWidth().semantics {contentDescription=library.total?.let {"Library, $it tracks"} ?: "Library tracks"},state=libraryScroll) {
                        if(library.loading) item {LibraryStateCell {SoundQFeedback(if(library.rows.isEmpty())"Loading library" else "Loading more tracks",FeedbackKind.Loading)}}
                        if(!library.loading&&library.error==null&&mixedRows.isEmpty()&&localNotice!=LocalAudioNotice.NoneFound&&(localNotice==null||mixedQuery!=LibraryQuery()))item {LibraryStateCell {SoundQFeedback(if(!refined)"No tracks yet" else "No matching tracks",FeedbackKind.Empty,action="Clear refinement",onAction=::clearRefinement)}}
                        localNotice?.let {notice->item(key="local-audio-notice") {LibraryStateCell {Column {
                            LocalAudioNoticeContent(notice,allowFileAccess)
                            if(mixedRows.isEmpty()&&refined&&(notice==LocalAudioNotice.NoneFound||mixedQuery==LibraryQuery()))SoundQButton("Clear refinement",::clearRefinement,variant=SoundQButtonVariant.Quiet)
                        }}}}
                        itemsIndexed(if(mixedNeeded)mixedRows else mixedRows.filter {it.server!=null},key={_,row -> row.stable}) {_,mixedRow ->
                            val phoneRow=mixedRow.phone
                            if(phoneRow!=null) {
                                val phoneVisit=remember(accountVersion,paginationNavigation,rowVisit,panel){java.util.concurrent.atomic.AtomicBoolean(true)}
                                DisposableEffect(phoneVisit){onDispose {phoneVisit.set(false)}}
                                PhoneLibraryRow(model,phoneRow,playback.queue.singleOrNull {it.occurrenceId==playback.selectedOccurrence}?.ref==mixedRow.ref,revealOwner,
                                    {phoneVisit.get()&&destination=="Library"&&panel==null&&rowLifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)},
                                    {if(phoneVisit.get()){selectedPhone=phoneRow;panel="PhoneTrack"}})
                            } else {
                            val track=requireNotNull(mixedRow.server)
                            val index=library.rows.indexOfFirst {it===track}
                            if(index<0) {
                                val scope=model.graph.session.capture()
                                val row=downloads.rows.singleOrNull {it.track.id==track.id&&it.status==com.soundq.android.data.offline.DownloadStatus.Complete}
                                val current=playback.source==com.soundq.android.playback.PlaybackSource.Queue&&playback.queue.any {it.occurrenceId==playback.selectedOccurrence&&it.trackId==track.id.value}
                                SoundQMediaRow(track.title,track.artist,current,{if(scope!=null&&row!=null)model.playDownload(scope,row){model.graph.session.current(scope)}},{navigate("Downloads")},supporting="Downloaded · SoundQ",metadata={LibraryMetadataContent(memberDurationMetadata(track.durationMs))})
                            } else {
                            val mutation=library.mutations[track.id]
                            val capturedRow=remember(RowIdentity(track),rowLifetime,library.query,library.loading,library.error){model.graph.library.captureTrack(track)}
                            val capturedRoute=libraryActions
                            val reveal=remember(RowIdentity(track),rowLifetime){RowRevealState(revealOwner)}
                            val mounted=remember(reveal){java.util.concurrent.atomic.AtomicBoolean(true)}
                            DisposableEffect(reveal){onDispose {mounted.set(false);reveal.dispose()}}
                            val valid={mounted.get()&&rowLifetime.current()&&capturedRow?.let(model.graph.library::owns)==true}
                            SoundQRevealMediaRow(track.title,track.artist,playback.queue.firstOrNull {it.occurrenceId==playback.selectedOccurrence}?.trackId==track.id.value,
                                reveal,valid(),track.liked,capturedRow?.let {model.graph.library.offerLike(it.scope,track.id)}!=null,
                                {capturedRow?.let {model.likeLibrary(it,valid)}},{capturedRow?.let {model.enqueueLibrary(it,valid)}},
                                {if(valid()){if(library.query.liked||library.query.collection!=null)model.playLibraryCollection(library,selected=track.id,current=collectionCurrent)else model.play(index,library.rows)}},{if(valid()){revealOwner.close();trackCapture=capturedRow;trackPlaylistActions=capturedRoute;selected=track;panel="Track"}},
                                artwork={com.soundq.android.product.artwork.LibraryRowArtwork(model.graph.libraryArtwork,capturedRow,valid)},
                                metadata={LibraryMetadataContent(libraryRowMetadata(track.durationMs,library.analysis[track.id],keyNotation))},
                                onQuickQueue={capturedRow?.let {model.quickQueueLibrary(it,valid)}},
                                supporting=when(mutation){MutationOutcome.Pending->"Saving Like";MutationOutcome.Uncertain->"Like not confirmed — reload";MutationOutcome.ReadbackFailed->"Like saved — reload failed";MutationOutcome.Refused->"Like refused";else->if(track.liked==true)"Liked" else null})
                        }}
                        }
                        library.error?.let {error -> item {LibraryStateCell {SoundQFeedback("Could not load library",FeedbackKind.Error,error.message,"Retry library",{
                            if(library.failedAppend)model.retryLibraryPage(library) {paginationVisit.current()&&rowLifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)&&paginationScope?.let(model.graph.session::remoteCurrent)==true}
                            else if(paginationVisit.current()&&rowLifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)&&paginationScope?.let(model.graph.session::remoteCurrent)==true)model.refine(library.query)
                        })}}}
                        }
                    }
                    SoundQCompactPlayer(playback.title ?: "Nothing playing",playback.artist,playback.isPlaying,playback.canPlay,playback.preparing,{transportReturn=null;panel="Player"},model.controller::toggle,{transportReturn=null;panel="Queue"},
                        timing=compactSongTiming(playback),artwork={com.soundq.android.product.artwork.PlayerArtwork(model.graph,playback,72.dp,{compactEntry.get()})})
                    SoundQBottomNavigation(when(destination){"History"->"Home";"Catalog","Downloads","Acquisition"->"Library";else->destination},{settingsReturn=null;navigate(it)})
                }
                if(auth is AuthState.SignedIn || auth is AuthState.DeviceOnly || auth is AuthState.SignedOut)when(panel) {
                    "SharedLink"->incomingShare?.takeIf {auth is AuthState.SignedIn&&(it.account==null||it.account==(auth as? AuthState.SignedIn)?.accountId)}?.let {share->SoundQSheet("Shared link",{panel=null}) {
                        SoundQButton("Review shared link",{
                            openImports()
                            importView?.let {v->model.graph.imports.another(v);if(!model.imports.value.consumed){model.graph.imports.edit(v,share.source.url);model.graph.incomingShares.dismiss(share)}}
                        },enabled=!imports.pending)
                        SoundQButton("Discard shared link",{model.graph.incomingShares.dismiss(share);panel=null},variant=SoundQButtonVariant.Quiet)
                    }}
                    "Refine"->RefineSheet(if(auth is AuthState.SignedIn)library.query else localQuery,{panel=null},source=librarySource,recent=recentOrder) {query,source,recent->
                        librarySource=source;recentOrder=recent
                        if(auth is AuthState.SignedIn)model.refine(query)else localQuery=query
                        panel=null
                    }
                    "PhoneTrack"->selectedPhone?.let {row->PhoneTrackSheet(model,row,{panel=null},{openSettings(listOf(SettingsRoute.LocalAudio))})}
                    "Devices"->com.soundq.android.product.connect.ConnectedDevicesPanel(model,{panel=null},{panel="Jam"})
                    "Jam"->com.soundq.android.product.jam.JamHostPanel(model,{panel=null})
                    "Track"->selected?.let {track -> SoundQSheet(track.title,{panel=null}) {
                        val captured=trackCapture
                        val capturedActions=trackPlaylistActions
                        var songSpeed by remember(captured){mutableStateOf(false)}
                        var songSpeedValue by remember(captured){mutableStateOf<String?>(null)}
                        val downloadActive=remember(captured){java.util.concurrent.atomic.AtomicBoolean(true)}
                        DisposableEffect(downloadActive){onDispose {downloadActive.set(false)}}
                        val speedRef=captured?.let {com.soundq.android.playback.PlaybackRef.Server(model.graph.endpoint.identity,it.scope.accountId,track.id.value)}
                        val songValid={downloadActive.get()&&captured?.let(model.graph.library::owns)==true}
                        LaunchedEffect(speedRef,songSpeed) {
                            if(!songSpeed&&speedRef!=null)model.controller.songSpeed(speedRef,model.graph.session.version(),null,songValid) {value->if(songValid())songSpeedValue=value?.let {SoundQSpeedScale.label(it.speed)}}
                        }
                        if(songSpeed&&speedRef!=null)SongSpeedEditor(model,speedRef,songValid){songSpeed=false}
                        else Column {
                        Text(track.artist);if(track.album.isNotBlank())Text(track.album)
                        val downloadRow=downloads.rows.firstOrNull {it.track.id==track.id}
                        SongActionRow("Play",{if(downloadActive.get()&&captured?.let(model.graph.library::owns)==true){
                            if(library.query.liked||library.query.collection!=null)model.playLibraryCollection(library,selected=track.id) {collectionVisit.current()&&(panel==null||panel=="Track")&&destination=="Library"&&rowLifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)}
                            else model.play(library.rows.indexOfFirst {it===track},library.rows)
                            panel=null
                        }},SoundQIcon.Play,enabled=songValid())
                        SongActionRow("Play next",{captured?.let {model.enqueueLibrary(it,songValid,true)};panel=null},SoundQIcon.Next,enabled=songValid())
                        SongActionRow("Add to listening queue",{captured?.let {model.enqueueLibrary(it,songValid)};panel=null},SoundQIcon.AddQueue,enabled=songValid())
                        SoundQDivider()
                        SongActionRow("Playback speed",{songSpeed=true},value=songSpeedValue,opensDestination=true,enabled=songValid())
                        SongActionRow("Add to playlist",{
                            captured?.let {source->capturedActions?.open(source)?.let {picker=it;panel="Membership"}}
                        },SoundQIcon.Plus,opensDestination=true,enabled=captured!=null && model.graph.library.owns(captured))
                        SongActionRow(if(track.liked==true)"Unlike" else "Like",{captured?.let {model.likeLibrary(it,songValid)}},SoundQIcon.Heart,enabled=captured?.let {model.graph.library.offerLike(it.scope,track.id)}!=null)
                        SoundQDivider()
                        SongActionRow(if(downloadRow?.status==com.soundq.android.data.offline.DownloadStatus.Complete)"Downloaded to device" else if(downloadRow?.status==com.soundq.android.data.offline.DownloadStatus.Downloading)"Downloading to device" else "Download to device",{
                            captured?.let {source->model.downloadLibrary(source){downloadActive.get()&&model.graph.library.owns(source)}}
                        },SoundQIcon.Download,enabled=captured!=null&&model.graph.library.owns(captured)&&downloadRow?.status !in listOf(com.soundq.android.data.offline.DownloadStatus.Complete,com.soundq.android.data.offline.DownloadStatus.Downloading))
                        SongActionRow("Open Downloads",{navigate("Downloads")},SoundQIcon.Download,opensDestination=true)
                        SongActionRow("Song details",{
                            captured?.let {source->model.graph.trackDetails.open(source)?.let {detailsRoute=it;model.loadTrackDetails(it);panel="Details"}}
                        },SoundQIcon.Info,opensDestination=true,enabled=captured!=null&&model.graph.library.owns(captured))
                        if(track.artist.isNotEmpty())SongActionRow("Open artist in Library",{
                            if(captured?.let(model.graph.library::owns)==true){model.refine(LibraryQuery(sort=library.query.sort,ascending=library.query.ascending,collection=LibraryCollection(artist=track.artist)));panel=null}
                        },SoundQIcon.Library,opensDestination=true,enabled=songValid())
                        if(track.album.isNotEmpty())SongActionRow("Open album in Library",{
                            if(captured?.let(model.graph.library::owns)==true){model.refine(LibraryQuery(sort=library.query.sort,ascending=library.query.ascending,collection=LibraryCollection(artist=track.artist,album=track.album)));panel=null}
                        },SoundQIcon.Library,opensDestination=true,enabled=songValid())
                        }
                    }}
                    "Details"->detailsRoute?.let {captured->key(captured) {
                        com.soundq.android.product.trackdetails.TrackDetailsSheet(trackDetails,
                            {observed,action->model.changeTrackDetails(captured,observed,action)},
                            {model.loadTrackDetails(captured)},
                            {closeDetails(captured)},keyNotation=keyNotation.choice)
                    }}
                    "Membership"->picker?.let {actions->com.soundq.android.product.playlists.PlaylistMembershipSheet(membership,actions,{actions.close();picker=null;panel=null})}
                    "Player"->{
                        val playerEntry=remember {java.util.concurrent.atomic.AtomicBoolean(true)}
                        DisposableEffect(playerEntry){onDispose {playerEntry.set(false)}}
                        val infoCapture=model.graph.session.capture()?.let {scope->model.graph.trackDetails.capturePlayer(scope,playback){model.playback.value}}
                        val selectedDevice=(playback.queue.singleOrNull {it.occurrenceId==playback.selectedOccurrence}?.ref as? com.soundq.android.playback.PlaybackRef.Device)?.let {model.graph.phoneAudio.observed(it)}
                        val openInfo:(()->Unit)?=if(selectedDevice!=null){{selectedPhone=selectedDevice;panel="PhoneTrack"}}else if(infoCapture==null)null else {{
                            if(playerEntry.get()&&panel=="Player")model.graph.trackDetails.open(infoCapture)?.let {detailsRoute=it;model.loadTrackDetails(it);panel="Details"}
                        }}
                        val speed=rememberFullPlayerSpeed(playback,model.controller::setListeningSpeed)
                        SoundQFullPlayer(playback.title ?: "No track selected",playback.artist,playback.isPlaying,
                            playback.canPlay,playback.preparing,playback.positionMs,playback.durationMs,playback.selectedOccurrence,
                            onClose={panel=transportReturn;transportReturn=null},onPrimary=model.controller::toggle,onSeek=model.controller::seek,onQueue={transportReturn="Player";panel="Queue"},
                            onPrevious=model.controller::previous,onNext=model.controller::next,canPrevious=playback.canPrevious,canNext=playback.canNext,
                            shuffle=playback.shuffle,repeat=playback.repeat,onShuffle=model.controller::shuffle,onRepeat=model.controller::repeat,
                            onDevices=if(auth is AuthState.SignedIn){{panel="Devices"}}else null,onInfo=openInfo,error=playback.error,
                            clockContent=if(playback.source==com.soundq.android.playback.PlaybackSource.Queue&&playback.clockAuthority!=null){{FullPlayerClock(playback,model.controller::seekClock)}}else null,
                            speedCell=speed.cell,speedContent=speed.content,
                            artwork={BoxWithConstraints(Modifier.fillMaxSize()) {
                                com.soundq.android.product.artwork.PlayerArtwork(model.graph,playback,maxWidth,{playerEntry.get()&&panel=="Player"})
                            }})
                    }
                    "Queue"->QueuePanel(model,playback,model.graph.session.version(),{panel=transportReturn;transportReturn=null},{transportReturn="Queue";panel="Player"},onSave={
                        closeQueueSave()
                        val actions=model.queuePlaylistActions();queueSave=actions
                        actions.capture();actions.reload();panel="QueueSave"
                    })
                    "QueueSave"->queueSave?.let {actions->com.soundq.android.product.playlists.QueuePlaylistSheet(queuePlaylist,actions,{closeQueueSave();panel="Queue"})}
                }
            }
        }
        }
    }
}
// Header/search/filter are fixed chrome. Loading and the local-audio notice precede rows; recovery follows them.
internal fun libraryRowScrollIndex(index:Int,loading:Boolean,@Suppress("UNUSED_PARAMETER") error:Boolean,notice:Boolean=false):Int = index+(if(loading)1 else 0)+(if(notice)1 else 0)

@Composable private fun LibraryIconCell(icon:SoundQIcon,label:String,onClick:()->Unit,modifier:Modifier=Modifier,enabled:Boolean=true) {
    Box(modifier.sizeIn(minWidth=SoundQ.sizes.target,minHeight=SoundQ.sizes.target)
        .semantics {contentDescription=label}
        .clickable(enabled=enabled,role=Role.Button,onClick=onClick),contentAlignment=Alignment.Center) {
        SoundQIcon(icon,null,tint=if(enabled)SoundQ.colors.text else SoundQ.colors.disabled)
    }
}

@Composable private fun LibraryHeader(onSettings:()->Unit,onCatalog:()->Unit) {
    var more by remember {mutableStateOf(false)}
    Column(Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth().heightIn(min=56.dp),verticalAlignment=Alignment.CenterVertically) {
            Row(Modifier.weight(1f).padding(horizontal=SoundQ.spacing.gutter),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(SoundQ.spacing.medium)) {
                Image(painterResource(R.drawable.soundq_logo),null,Modifier.size(24.dp))
                Text("Library",style=SoundQ.typography.title,modifier=Modifier.semantics {heading()})
            }
            Box {
                LibraryIconCell(SoundQIcon.More,"Library options",{more=true},Modifier.heightIn(min=56.dp))
                DropdownMenu(more,{more=false}) {DropdownMenuItem(text={Text("Catalog")},onClick={more=false;onCatalog()})}
            }
            LibraryIconCell(SoundQIcon.Settings,"Settings",onSettings,Modifier.heightIn(min=56.dp))
        }
        SoundQDivider()
    }
}

@Composable private fun LibrarySearch(committed:String,onSearch:(String)->Unit) {
    var query by rememberSaveable(stateSaver=TextFieldValue.Saver) {mutableStateOf(TextFieldValue(committed))}
    var lastCommitted by remember {mutableStateOf(committed)}
    var submitted by remember {mutableStateOf<String?>(null)}
    // An acknowledgement must not replace edits made after our explicit submission.
    LaunchedEffect(committed) {
        if(committed!=lastCommitted&&committed!=query.text&&committed!=submitted)query=TextFieldValue(committed)
        if(committed==submitted)submitted=null
        lastCommitted=committed
    }
    val focus=LocalFocusManager.current
    fun submit() {
        // Explicit Search commits visible intent, even while the IME is composing.
        val text=query.text
        submitted=text
        focus.clearFocus()
        onSearch(text)
    }
    val colors=SoundQ.colors
    Column(Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth().heightIn(min=64.dp),verticalAlignment=Alignment.CenterVertically) {
            LibraryIconCell(SoundQIcon.Search,"Search library",::submit,Modifier.heightIn(min=64.dp))
            BasicTextField(query,{query=it},Modifier.weight(1f).heightIn(min=64.dp).semantics {contentDescription="Library search query"},
                singleLine=true,textStyle=SoundQ.typography.body.copy(color=colors.text),cursorBrush=androidx.compose.ui.graphics.SolidColor(colors.focus),
                keyboardOptions=KeyboardOptions(imeAction=ImeAction.Search),keyboardActions=KeyboardActions(onSearch={submit()}),
                decorationBox={editor->Column(Modifier.fillMaxWidth().padding(horizontal=SoundQ.spacing.gutter,vertical=SoundQ.spacing.small),verticalArrangement=Arrangement.Center) {
                    Text("Search library",style=SoundQ.typography.caption,color=colors.muted)
                    editor()
                }})
            LibraryIconCell(SoundQIcon.Close,"Clear library search",{query=TextFieldValue("");submitted="";onSearch("")},Modifier.heightIn(min=64.dp),enabled=query.text.isNotEmpty())
        }
        SoundQDivider()
    }
}

@Composable private fun LibraryFilters(liked:Boolean,total:Int?,onLiked:(Boolean)->Unit,onRefine:()->Unit) {
    val border=SoundQ.colors.border
    val borderWidth=with(LocalDensity.current){SoundQ.sizes.border.toPx()}
    Column(Modifier.fillMaxWidth()) {
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val showCount=maxWidth>=400.dp
            Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).selectableGroup(),verticalAlignment=Alignment.CenterVertically) {
                listOf("All tracks","Liked").forEachIndexed {index,label->
                    val selected=liked==(index==1)
                    Box(Modifier.weight(1f).fillMaxHeight().heightIn(min=48.dp)
                        .background(if(selected)SoundQ.colors.surface else SoundQ.colors.background)
                        .drawBehind {if(index>0)drawLine(border,Offset.Zero,Offset(0f,size.height),borderWidth)}
                        .selectable(selected=selected,role=Role.Tab,onClick={onLiked(index==1)})
                        .padding(horizontal=SoundQ.spacing.gutter),contentAlignment=Alignment.CenterStart) {
                        Text(label,style=SoundQ.typography.caption,color=if(selected)SoundQ.colors.text else SoundQ.colors.muted)
                    }
                }
                if(showCount)Text(total?.let {"$it tracks"} ?: "",Modifier.padding(horizontal=SoundQ.spacing.gutter),style=SoundQ.typography.mono)
                LibraryIconCell(SoundQIcon.Filter,"Refine library",onRefine,Modifier.fillMaxHeight().drawBehind {drawLine(border,Offset.Zero,Offset(0f,size.height),borderWidth)})
            }
        }
        SoundQDivider()
    }
}

@Composable private fun LibraryStateCell(content:@Composable ()->Unit) {
    Box(Modifier.fillMaxWidth().padding(horizontal=SoundQ.spacing.gutter),contentAlignment=Alignment.CenterStart) {content()}
}

/** Embedded in Settings, the app bar names the form: no brand block, heading or mode switch. */
@Composable private fun AuthScreen(state:AuthState,model:ProductViewModel,scrollable:Boolean=true,embedded:Boolean=false,initialRegister:Boolean=false) {
    var register by rememberSaveable {mutableStateOf(initialRegister)}
    var email by rememberSaveable(stateSaver=TextFieldValue.Saver) {mutableStateOf(TextFieldValue(""))}
    var username by rememberSaveable(stateSaver=TextFieldValue.Saver) {mutableStateOf(TextFieldValue(""))}
    var password by remember {mutableStateOf(TextFieldValue(""))}
    var confirm by remember {mutableStateOf(TextFieldValue(""))}
    var reveal by remember {mutableStateOf(false)}
    var revealConfirm by remember {mutableStateOf(false)}
    var error by remember {mutableStateOf<String?>(null)}
    var optionsOpen by remember {mutableStateOf(false)}
    val focus=LocalFocusManager.current
    val lifecycle=androidx.lifecycle.compose.LocalLifecycleOwner.current
    DisposableEffect(lifecycle) {
        val observer=LifecycleEventObserver {_,event -> if(event==Lifecycle.Event.ON_STOP){password=TextFieldValue("");confirm=TextFieldValue("");reveal=false;revealConfirm=false}}
        lifecycle.lifecycle.addObserver(observer)
        onDispose {lifecycle.lifecycle.removeObserver(observer);password=TextFieldValue("");confirm=TextFieldValue("");reveal=false;revealConfirm=false}
    }
    val pending=state is AuthState.Pending || state is AuthState.Restoring
    val recovery by model.onlineRestore.collectAsStateWithLifecycle()
    val recovering=recovery!=null
    val canListenOffline=model.graph.session.canListenOffline()
    val canReconnect=model.graph.session.canReconnectSaved()
    fun switchMode(){register=!register;password=TextFieldValue("");confirm=TextFieldValue("");error=null;reveal=false;revealConfirm=false}
    fun submit() {
        if(pending||password.composition!=null||confirm.composition!=null)return
        error=when { !Regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$").matches(email.text.trim())->"Enter a valid email."
            password.text.isEmpty()->"Enter your password."
            register&&username.text.toByteArray().size !in 3..50->"Username must be 3–50 bytes."
            register&&password.text.toByteArray().size<8->"Password must contain at least 8 bytes."
            register&&password.text!=confirm.text->"Passwords do not match."
            else->null }
        if(error==null){focus.clearFocus();model.submit(email.text,password.text,username.text.takeIf {register})}
    }
    // The standalone route owns a viewport. Settings already owns scrolling,
    // so embedded auth fields are ordinary content with the single 20dp gutter.
    val scroll=rememberScrollState()
    val bodyModifier=if(scrollable)Modifier.widthIn(max=SoundQ.sizes.appMax).fillMaxSize().verticalScroll(scroll)
        else Modifier.widthIn(max=SoundQ.sizes.appMax).fillMaxWidth()
    Column(bodyModifier.padding(SoundQ.spacing.gutter),verticalArrangement=Arrangement.spacedBy(SoundQ.spacing.medium)) {
        if(!embedded) {
            Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(SoundQ.spacing.medium)) {
                Image(painterResource(R.drawable.soundq_logo),null,Modifier.size(SoundQ.sizes.target))
                Text("SoundQ",style=SoundQ.typography.title)
            }
            Text(if(register)"Create account" else "Sign in",style=SoundQ.typography.heading,modifier=Modifier.semantics {heading()})
        }
        if(state is AuthState.SaveRequired) {
            SoundQFeedback("Account accepted, secure save failed",FeedbackKind.Error,state.reason.message,"Retry secure save",model::retrySave)
            SoundQButton("Cancel accepted session",model::cancelAuth,variant=SoundQButtonVariant.Secondary)
        } else {
            if(register)SoundQEntryField(username,{username=it},"Username",enabled=!pending,contentType=ContentType.NewUsername,keyboardOptions=KeyboardOptions(imeAction=ImeAction.Next),keyboardActions=KeyboardActions(onNext={focus.moveFocus(androidx.compose.ui.focus.FocusDirection.Down)}))
            SoundQEntryField(email,{email=it},"Email",enabled=!pending,contentType=ContentType.EmailAddress,keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Email,imeAction=ImeAction.Next),keyboardActions=KeyboardActions(onNext={focus.moveFocus(androidx.compose.ui.focus.FocusDirection.Down)}))
            SoundQEntryField(password,{password=it},"Password",enabled=!pending,contentType=if(register)ContentType.NewPassword else ContentType.Password,secure=true,revealed=reveal,onReveal={reveal=!reveal},keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Password,imeAction=if(register)ImeAction.Next else ImeAction.Done),keyboardActions=KeyboardActions(onDone={submit()},onNext={focus.moveFocus(androidx.compose.ui.focus.FocusDirection.Down)}))
            if(register)SoundQEntryField(confirm,{confirm=it},"Confirm password",enabled=!pending,contentType=ContentType.NewPassword,secure=true,revealed=revealConfirm,onReveal={revealConfirm=!revealConfirm},keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Password,imeAction=ImeAction.Done),keyboardActions=KeyboardActions(onDone={submit()}))
            error?.let {SoundQFeedback(it,FeedbackKind.Error)}
            if(state is AuthState.SignedOut&&state.error!=null) {
                val title=when {
                    state.error==SafeFailure.Reason.Network->"Can’t reach SoundQ"
                    state.error==SafeFailure.Reason.Refused->"Sign in unavailable"
                    state.uncertain->"Connection interrupted"
                    else->"Sign in unavailable"
                }
                val detail=when {
                    state.error==SafeFailure.Reason.Network->"Check your connection to the SoundQ server, then try again."
                    state.uncertain&&state.error!=SafeFailure.Reason.Refused->if(canReconnect)"We couldn’t confirm the response. Reconnect before trying again." else "We couldn’t confirm the response. Check your connection before trying again."
                    else->state.error.message
                }
                SoundQFeedback(title,FeedbackKind.Error,detail,if(canReconnect)"Reconnect" else null,if(canReconnect)model::reconnectSaved else null)
                if(state.error==SafeFailure.Reason.StoreRejected)SoundQButton("Discard rejected saved session",model::discardStore,variant=SoundQButtonVariant.Secondary)
            }
            if(pending)SoundQFeedback(if(state is AuthState.Restoring||recovering)"Connecting…" else if(register)"Creating account…" else "Signing in…",FeedbackKind.Loading)
            // Natural wrapping is only a narrow-width / enlarged-text fallback; ordinary phones retain one inline row.
            FlowRow(horizontalArrangement=Arrangement.spacedBy(SoundQ.spacing.medium),verticalArrangement=Arrangement.spacedBy(SoundQ.spacing.small)) {
                SoundQButton(if(register)"Create account" else "Sign in",{submit()},enabled=!pending&&!(state is AuthState.SignedOut&&state.error==SafeFailure.Reason.StoreRejected))
                if(!embedded)SoundQButton(if(register)"Sign in" else "Create account",::switchMode,enabled=!pending,variant=SoundQButtonVariant.Secondary)
            }
            if(state is AuthState.Pending&&!recovering)SoundQButton("Cancel sign-in view",model::cancelAuth,variant=SoundQButtonVariant.Quiet)
        }
        SoundQButton("More options",{optionsOpen=true},enabled=!pending||canListenOffline,variant=SoundQButtonVariant.Quiet)
    }
    if(optionsOpen)SoundQSheet("More options",{optionsOpen=false}) {
        if(canListenOffline)SoundQButton("Listen offline",{optionsOpen=false;model.useDeviceDownloads()},variant=SoundQButtonVariant.Quiet)
        Text(model.graph.endpoint.identity,style=SoundQ.typography.caption,color=SoundQ.colors.muted)
    }
}
@Composable private fun RefineSheet(query:LibraryQuery,onDismiss:()->Unit,source:LibrarySource=LibrarySource.All,recent:Boolean=false,onApply:(LibraryQuery,LibrarySource,Boolean)->Unit) {
    var draft by remember {mutableStateOf(query)}
    var draftRecent by remember {mutableStateOf(recent)}
    var draftSource by remember {mutableStateOf(source)}
    SoundQSheet("Refine library",onDismiss) {
        Text("Source",style=SoundQ.typography.title)
        SoundQTabs(LibrarySource.entries.map {it.name},LibrarySource.entries.indexOf(draftSource),{draftSource=LibrarySource.entries[it]})
        Text("Sort",style=SoundQ.typography.title)
        SoundQTabs(LibrarySort.entries.map {it.name},LibrarySort.entries.indexOf(draft.sort),{draftRecent=false;draft=draft.copy(sort=LibrarySort.entries[it])})
        Row(Modifier.fillMaxWidth().heightIn(min=48.dp).selectable(selected=draftRecent,role=Role.RadioButton,onClick={draftRecent=true}),verticalAlignment=Alignment.CenterVertically) {
            RadioButton(draftRecent,{draftRecent=true});Text("Recently played",style=SoundQ.typography.body)
        }
        SoundQTabs(listOf("Descending","Ascending"),if(draft.ascending)1 else 0,{draft=draft.copy(ascending=it==1)})
        SoundQTabs(listOf("All verification","Verified","Unverified"),when(draft.verified){true->1;false->2;null->0},{draft=draft.copy(verified=when(it){1->true;2->false;else->null})})
        SoundQTextField(draft.genre,{draft=draft.copy(genre=it)},"Genre (exact match)")
        SoundQTextField(draft.collection?.artist.orEmpty(),{value->
            val artist=value.takeUnless {it.isEmpty()};val album=draft.collection?.album
            draft=draft.copy(collection=if(artist==null&&album==null)null else LibraryCollection(artist,album))
        },"Artist (exact match)")
        SoundQTextField(draft.collection?.album.orEmpty(),{value->
            val album=value.takeUnless {it.isEmpty()};val artist=draft.collection?.artist
            draft=draft.copy(collection=if(artist==null&&album==null)null else LibraryCollection(artist,album))
        },"Album (exact match)")
        SoundQButton("Apply refinement",{onApply(draft,draftSource,draftRecent)})
        SoundQButton("Reset refinement",{draft=LibraryQuery();draftRecent=false;draftSource=LibrarySource.All},variant=SoundQButtonVariant.Secondary)
        SoundQButton("Cancel",onDismiss,variant=SoundQButtonVariant.Quiet)
    }
}
