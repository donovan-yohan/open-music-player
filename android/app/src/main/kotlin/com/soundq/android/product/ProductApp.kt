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

@Composable fun ProductApp(model:ProductViewModel=viewModel()) {
    val auth by model.auth.collectAsStateWithLifecycle()
    val onlineRestore by model.onlineRestore.collectAsStateWithLifecycle()
    val library by model.library.collectAsStateWithLifecycle()
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
            if(index>=0){libraryScroll.scrollToItem(libraryRowScrollIndex(index,library.loading,library.error!=null));revealImported=null}
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
    fun navigate(next:String) {
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
    fun openImports() {catalogActions?.close();orderActions?.close();closeQueueSave();model.graph.acquisition.closeCurrent();detailsRoute?.let(model.graph.trackDetails::close);detailsRoute=null;leaveDiscovery();panel=null;importView=model.graph.imports.open()}
    val deviceScope=remember(accountVersion,auth is AuthState.DeviceOnly) {if(auth is AuthState.DeviceOnly)model.graph.session.capture() else null}
    androidx.activity.compose.BackHandler(auth is AuthState.DeviceOnly || (auth is AuthState.Pending && onlineRestore!=null)) {
        deviceScope?.let(model::goOnline)
    }
    androidx.activity.compose.BackHandler(auth is AuthState.SignedIn && destination in listOf("Home","History","Discover","Downloads","Acquisition","Mixes") && importView==null && panel==null) {navigate("Library")}
    LaunchedEffect(auth) {if(auth !is AuthState.SignedIn){orderActions?.close();closeQueueSave();importView?.let(model.graph.imports::close);importView=null;revealImported=null;detailsRoute?.let(model.graph.trackDetails::close);detailsRoute=null;panel=null;selected=null;picker?.close();picker=null;trackCapture=null;gallery=false;if(auth !is AuthState.Restoring && auth !is AuthState.Pending){acquisitionReturn=emptyList();destination="Library"}}}
    LaunchedEffect(playlistActions) {playlistActions?.reload()}
    val appearance by model.graph.appearancePreferences.state.collectAsStateWithLifecycle()
    SoundQTheme(appearance=when(appearance.choice) {
        com.soundq.android.data.preferences.Appearance.System->soundq.design.generated.SoundQAppearance.System
        com.soundq.android.data.preferences.Appearance.Light->soundq.design.generated.SoundQAppearance.Light
        com.soundq.android.data.preferences.Appearance.Dark->soundq.design.generated.SoundQAppearance.Dark
    }) {
        AppearanceSystemBars(SoundQ.colors.roles==soundq.design.generated.SoundQAppearanceMapping.dark)
        Surface(Modifier.fillMaxSize().closeRowRevealOutside(revealOwner),color=SoundQ.colors.background) {
            Box(Modifier.safeDrawingPadding().imePadding(),contentAlignment=Alignment.TopCenter) {
                if(gallery && auth is AuthState.SignedIn) {androidx.activity.compose.BackHandler {gallery=false};SoundQApp()}
                else if(auth is AuthState.DeviceOnly) Column(Modifier.widthIn(max=SoundQ.sizes.appMax).fillMaxSize()) {
                    Box(Modifier.weight(1f).fillMaxWidth()) {
                        deviceScope?.let {scope ->com.soundq.android.product.offline.DownloadsScreen(model,downloads,scope,{model.goOnline(scope)})}
                    }
                    if(playback.title!=null)SoundQCompactPlayer(playback.title!!,playback.artist,playback.isPlaying,playback.canPlay,playback.preparing,{transportReturn=null;panel="Player"},model.controller::toggle,{transportReturn=null;panel="Queue"},
                        timing=compactSongTiming(playback),artwork={com.soundq.android.product.artwork.PlayerArtwork(model.graph,playback,72.dp,{compactEntry.get()})})
                }
                else if(auth is AuthState.LocalLocked) com.soundq.android.product.preferences.LocalUnlockScreen(model)
                else if(auth is AuthState.Pending && onlineRestore?.deviceOnly==true) Column(Modifier.fillMaxSize().padding(SoundQ.spacing.gutter)) {
                    SoundQFeedback("Going online",FeedbackKind.Loading)
                }
                else if(auth !is AuthState.SignedIn) Column(Modifier.fillMaxSize()) {
                    incomingShare?.takeIf {it.account==null}?.let {share->
                        Text("Shared music link retained. Sign in, then confirm the import.",Modifier.padding(SoundQ.spacing.gutter))
                        SoundQButton("Discard shared link",{model.graph.incomingShares.dismiss(share)},variant=SoundQButtonVariant.Secondary)
                    }
                    Box(Modifier.weight(1f)){AuthScreen(auth,model)}
                }
                else Column(Modifier.widthIn(max=SoundQ.sizes.appMax).fillMaxSize()) {
                    incomingShare?.takeIf {it.account==null||it.account==(auth as AuthState.SignedIn).accountId}?.let {
                        Row(Modifier.fillMaxWidth().heightIn(min=48.dp).padding(start=SoundQ.spacing.gutter),verticalAlignment=Alignment.CenterVertically) {
                            Text("Shared link ready",Modifier.weight(1f),style=SoundQ.typography.caption)
                            LibraryIconCell(SoundQIcon.Info,"Review shared link",{panel="SharedLink"})
                        }
                        SoundQDivider()
                    }
                    val activeImport=importView
                    val importDraft=imports.draft
                    if(activeImport!=null) {
                        fun closeImports(){model.graph.imports.close(activeImport);importView=null}
                        androidx.activity.compose.BackHandler {closeImports()}
                        Box(Modifier.weight(1f).fillMaxWidth()) {
                            ImportsScreen(imports,{model.graph.imports.edit(activeImport,it)},
                                {model.submitImport(activeImport,importDraft)},
                                {model.checkImport(activeImport)},{model.recentImports(activeImport)},
                                {model.graph.imports.select(activeImport,it)},
                                {model.graph.imports.another(activeImport)},
                                {model.openImportLibrary(activeImport){id -> if(importView===activeImport){revealImported=id;closeImports();navigate("Library")}}},
                                {closeImports()},{panel="Account"},
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
                        catalogActions?.let {com.soundq.android.product.catalog.CatalogScreen(catalog,it,{navigate("Library")})}
                    } else if(destination=="Mixes") Box(Modifier.weight(1f).fillMaxWidth()) {
                        key(accountVersion) {com.soundq.android.product.mix.MixScreen(model)}
                    } else if(destination=="Downloads") Box(Modifier.weight(1f).fillMaxWidth()) {
                        val scope=remember(accountVersion){model.graph.session.capture()}
                        scope?.let {com.soundq.android.product.offline.DownloadsScreen(model,downloads,it,{navigate("Library")})}
                    } else if(destination=="Discover") Box(Modifier.weight(1f).fillMaxWidth()) {
                        com.soundq.android.product.discovery.DiscoverScreen(model,discoveryView,discoveryIntake,{openImports()},{panel="Account"},{navigate("Acquisition")})
                        com.soundq.android.product.imports.SourceImportOptions(model,discoveryIntake)
                    } else if(destination in listOf("Home","History")) Box(Modifier.weight(1f).fillMaxWidth()) {
                        HomeDestinationScreen(model,route,{navigate("Library")},{panel="Account"},revealOwner,onHistory={navigate("History")})
                    } else if(destination=="Playlists") Box(Modifier.weight(1f).fillMaxWidth()) {
                        val artworkCapture=remember(playlistDetail.detail?.let(::RowIdentity),accountVersion,playlistArtworkVisit,blendForeground) {if(blendForeground)model.graph.playlistDetail.capturePlayback()else null}
                        if(playlistDetail.id!=null)com.soundq.android.product.playlists.HarmonicPlaylist(model,managementActions) {harmonicEntry,harmonicFeedback->com.soundq.android.product.playlists.PlaylistDetailScreen(
                            playlistDetail,model.graph.playlistDetail.capturePlayback(),{closePlaylistDestination()},model::retryPlaylistDetail,{p,id->model.playPlaylist(p,id)},playlistManagement,managementActions,playlistOrder,orderActions,
                            playlistBlend,if(blendForeground)model.graph.playlistBlend.capture()else null,model::generatePlaylistBlend,model::recoverPlaylistBlend,
                            {captured,mixed->model.graph.playlistBlend.choose(captured,mixed)},model::shufflePlaylist,
                            model.graph.playlistBlend.acceptedPlan(),model.graph.playlistBlend.capture()?.let(model.graph.playlistBlend::canGenerate)==true,
                            model.graph.playlistBlend.capture()?.let(model.graph.playlistBlend::canRecover)==true,model::playPlaylist,
                            {p,index,track,valid->model.quickQueuePlaylist(p,index,track,valid)},revealOwner,harmonicEntry,
                            harmonicFeedback=harmonicFeedback,artwork={track,rowCurrent->com.soundq.android.product.artwork.TrackArtwork(model.graph,artworkCapture?.scope,track.takeIf {it.artwork!=null} ?: model.graph.track(track.id) ?: track,
                                {rowCurrent()&&artworkCapture?.let {captured->model.graph.playlistDetail.ownsPlayback(captured)&&captured.detail.tracks.any {it===track}}==true},sourceOwner=artworkCapture)})}
                        else playlistActions?.let { actions -> com.soundq.android.product.playlists.PlaylistsScreen(playlists,actions.capture,actions::create,actions::reload,actions::startNew,model::openPlaylist,
                            {managementActions?.let {com.soundq.android.product.playlists.PlaylistManagementFeedback(playlistManagement,it)}},onRefine=actions::refine) }
                    } else Column(Modifier.weight(1f).fillMaxWidth()) {
                        LibraryHeader({panel="Account"},{navigate("Catalog")})
                        LibrarySearch(library.query.text) {model.refine(library.query.copy(text=it))}
                        LibraryFilters(library.query.liked,library.total,{model.refine(library.query.copy(liked=it))},{panel="Refine"})
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
                        if(!library.loading&&library.error==null&&library.rows.isEmpty())item {LibraryStateCell {SoundQFeedback(if(library.query==LibraryQuery())"No tracks yet" else "No matching tracks",FeedbackKind.Empty,action="Clear refinement",onAction={model.refine(LibraryQuery())})}}
                        itemsIndexed(library.rows,key={index,track -> "${track.id.value}:$index"}) {index,track ->
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
                        }
                        library.error?.let {error -> item {LibraryStateCell {SoundQFeedback("Could not load library",FeedbackKind.Error,error.message,"Retry library",{
                            if(library.failedAppend)model.retryLibraryPage(library) {paginationVisit.current()&&rowLifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)&&paginationScope?.let(model.graph.session::remoteCurrent)==true}
                            else if(paginationVisit.current()&&rowLifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)&&paginationScope?.let(model.graph.session::remoteCurrent)==true)model.refine(library.query)
                        })}}}
                        }
                    }
                    SoundQCompactPlayer(playback.title ?: "Nothing playing",playback.artist,playback.isPlaying,playback.canPlay,playback.preparing,{transportReturn=null;panel="Player"},model.controller::toggle,{transportReturn=null;panel="Queue"},
                        timing=compactSongTiming(playback),artwork={com.soundq.android.product.artwork.PlayerArtwork(model.graph,playback,72.dp,{compactEntry.get()})})
                    SoundQBottomNavigation(when(destination){"History"->"Home";"Catalog","Downloads","Acquisition"->"Library";else->destination},::navigate)
                }
                if(auth is AuthState.SignedIn || auth is AuthState.DeviceOnly)when(panel) {
                    "SharedLink"->incomingShare?.takeIf {auth is AuthState.SignedIn&&(it.account==null||it.account==(auth as AuthState.SignedIn).accountId)}?.let {share->SoundQSheet("Shared link",{panel=null}) {
                        SoundQButton("Review shared link",{
                            openImports()
                            importView?.let {v->model.graph.imports.another(v);if(!model.imports.value.consumed){model.graph.imports.edit(v,share.source.url);model.graph.incomingShares.dismiss(share)}}
                        },enabled=!imports.pending)
                        SoundQButton("Discard shared link",{model.graph.incomingShares.dismiss(share);panel=null},variant=SoundQButtonVariant.Quiet)
                    }}
                    "Account"->SoundQSheet("Account",{panel=null}) {
                        Text("Server: ${model.graph.endpoint.identity}",style=SoundQ.typography.mono)
                        SoundQButton("Catalog",{navigate("Catalog")})
                        SoundQButton("Mixes",{navigate("Mixes")})
                        SoundQButton("Downloads",{navigate("Downloads")})
                        SoundQButton("Connected devices",{panel="Devices"},variant=SoundQButtonVariant.Secondary)
                        SoundQButton("Jam",{panel="Jam"},variant=SoundQButtonVariant.Secondary)
                        SoundQButton("Imports",{navigate("Discover");openImports()})
                        SoundQButton("Server import jobs and research",{navigate("Acquisition")})
                        SoundQButton("History",{navigate("History")},variant=SoundQButtonVariant.Secondary)
                        SoundQButton("Sign out",{orderActions?.close();closeQueueSave();importView?.let(model.graph.imports::close);importView=null;panel=null;model.logout()})
                        SoundQButton("Settings",{panel="Settings"},variant=SoundQButtonVariant.Secondary)
                        if(BuildConfig.DEBUG)SoundQButton("Developer component gallery",{panel=null;gallery=true},variant=SoundQButtonVariant.Secondary)
                    }
                    "Settings"->com.soundq.android.product.preferences.PreferencesSheet(model,{panel=null},{navigate("Downloads")},{navigate("History")})
                    "Refine"->RefineSheet(library.query,{panel=null}) {model.refine(it);panel=null}
                    "Devices"->com.soundq.android.product.connect.ConnectedDevicesPanel(model,{panel=null},{panel="Jam"})
                    "Jam"->com.soundq.android.product.jam.JamHostPanel(model,{panel=null})
                    "Track"->selected?.let {track -> SoundQSheet(track.title,{panel=null}) {
                        Text(track.artist);if(track.album.isNotBlank())Text(track.album)
                        val captured=trackCapture
                        val capturedActions=trackPlaylistActions
                        val downloadActive=remember(captured){java.util.concurrent.atomic.AtomicBoolean(true)}
                        DisposableEffect(downloadActive){onDispose {downloadActive.set(false)}}
                        val downloadRow=downloads.rows.firstOrNull {it.track.id==track.id}
                        SoundQButton(if(downloadRow?.status==com.soundq.android.data.offline.DownloadStatus.Complete)"Downloaded to device" else if(downloadRow?.status==com.soundq.android.data.offline.DownloadStatus.Downloading)"Downloading to device" else "Download to device",{
                            captured?.let {source->model.downloadLibrary(source){downloadActive.get()&&model.graph.library.owns(source)}}
                        },enabled=captured!=null&&model.graph.library.owns(captured)&&downloadRow?.status !in listOf(com.soundq.android.data.offline.DownloadStatus.Complete,com.soundq.android.data.offline.DownloadStatus.Downloading),variant=SoundQButtonVariant.Secondary)
                        SoundQButton("Song details",{
                            captured?.let {source->model.graph.trackDetails.open(source)?.let {detailsRoute=it;model.loadTrackDetails(it);panel="Details"}}
                        },enabled=captured!=null&&model.graph.library.owns(captured),variant=SoundQButtonVariant.Secondary)
                        SoundQButton("Open Downloads",{navigate("Downloads")},variant=SoundQButtonVariant.Secondary)
                        SoundQButton("Add to playlist",{
                            captured?.let {source->capturedActions?.open(source)?.let {picker=it;panel="Membership"}}
                        },enabled=captured!=null && model.graph.library.owns(captured),variant=SoundQButtonVariant.Secondary)
                        SoundQButton("Play",{if(downloadActive.get()&&captured?.let(model.graph.library::owns)==true){
                            if(library.query.liked||library.query.collection!=null)model.playLibraryCollection(library,selected=track.id) {collectionVisit.current()&&(panel==null||panel=="Track")&&destination=="Library"&&rowLifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)}
                            else model.play(library.rows.indexOfFirst {it===track},library.rows)
                            panel=null
                        }},enabled=captured?.let(model.graph.library::owns)==true)
                        if(track.artist.isNotEmpty())SoundQButton("Open artist in Library",{
                            if(captured?.let(model.graph.library::owns)==true){model.refine(LibraryQuery(sort=library.query.sort,ascending=library.query.ascending,collection=LibraryCollection(artist=track.artist)));panel=null}
                        },enabled=captured?.let(model.graph.library::owns)==true,variant=SoundQButtonVariant.Secondary)
                        if(track.album.isNotEmpty())SoundQButton("Open album in Library",{
                            if(captured?.let(model.graph.library::owns)==true){model.refine(LibraryQuery(sort=library.query.sort,ascending=library.query.ascending,collection=LibraryCollection(artist=track.artist,album=track.album)));panel=null}
                        },enabled=captured?.let(model.graph.library::owns)==true,variant=SoundQButtonVariant.Secondary)
                        val mutation=library.mutations[track.id]
                        val sheetValid={downloadActive.get()&&captured?.let(model.graph.library::owns)==true}
                        SoundQButton(if(track.liked==true)"Unlike" else "Like",{captured?.let {model.likeLibrary(it,sheetValid)}},enabled=captured?.let {model.graph.library.offerLike(it.scope,track.id)}!=null,variant=SoundQButtonVariant.Secondary)
                        SoundQButton("Play next",{captured?.let {model.enqueueLibrary(it,sheetValid,true)};panel=null},enabled=sheetValid(),variant=SoundQButtonVariant.Secondary)
                        SoundQButton("Add to listening queue",{captured?.let {model.enqueueLibrary(it,sheetValid)};panel=null},enabled=sheetValid(),variant=SoundQButtonVariant.Secondary)
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
                        val openInfo:(()->Unit)?=if(infoCapture==null)null else {{
                            if(playerEntry.get()&&panel=="Player")model.graph.trackDetails.open(infoCapture)?.let {detailsRoute=it;model.loadTrackDetails(it);panel="Details"}
                        }}
                        SoundQFullPlayer(playback.title ?: "No track selected",playback.artist,playback.isPlaying,
                            playback.canPlay,playback.preparing,playback.positionMs,playback.durationMs,playback.selectedOccurrence,
                            onClose={panel=transportReturn;transportReturn=null},onPrimary=model.controller::toggle,onSeek=model.controller::seek,onQueue={transportReturn="Player";panel="Queue"},
                            onPrevious=model.controller::previous,onNext=model.controller::next,canPrevious=playback.canPrevious,canNext=playback.canNext,
                            shuffle=playback.shuffle,repeat=playback.repeat,onShuffle=model.controller::shuffle,onRepeat=model.controller::repeat,
                            onDevices=if(auth is AuthState.SignedIn){{panel="Devices"}}else null,onInfo=openInfo,error=playback.error,
                            clockContent=if(playback.source==com.soundq.android.playback.PlaybackSource.Queue&&playback.clockAuthority!=null){{FullPlayerClock(playback,model.controller::seekClock)}}else null,
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
// Header/search/filter are fixed chrome. Loading precedes rows; recovery follows them.
internal fun libraryRowScrollIndex(index:Int,loading:Boolean,@Suppress("UNUSED_PARAMETER") error:Boolean):Int = index+(if(loading)1 else 0)

@Composable private fun LibraryIconCell(icon:SoundQIcon,label:String,onClick:()->Unit,modifier:Modifier=Modifier,enabled:Boolean=true) {
    Box(modifier.sizeIn(minWidth=SoundQ.sizes.target,minHeight=SoundQ.sizes.target)
        .semantics {contentDescription=label}
        .clickable(enabled=enabled,role=Role.Button,onClick=onClick),contentAlignment=Alignment.Center) {
        SoundQIcon(icon,null,tint=if(enabled)SoundQ.colors.text else SoundQ.colors.disabled)
    }
}

@Composable private fun LibraryHeader(onAccount:()->Unit,onCatalog:()->Unit) {
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
            LibraryIconCell(SoundQIcon.Settings,"Account and settings",onAccount,Modifier.heightIn(min=56.dp))
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

@Composable private fun AuthScreen(state:AuthState,model:ProductViewModel) {
    var register by rememberSaveable {mutableStateOf(false)}
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
    Column(Modifier.widthIn(max=SoundQ.sizes.appMax).fillMaxSize().verticalScroll(rememberScrollState()).padding(SoundQ.spacing.gutter),verticalArrangement=Arrangement.spacedBy(SoundQ.spacing.medium)) {
        Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(SoundQ.spacing.medium)) {
            Image(painterResource(R.drawable.soundq_logo),null,Modifier.size(SoundQ.sizes.target))
            Text("SoundQ",style=SoundQ.typography.title)
        }
        Text(if(register)"Create account" else "Sign in",style=SoundQ.typography.heading,modifier=Modifier.semantics {heading()})
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
                SoundQButton(if(register)"Sign in" else "Create account",::switchMode,enabled=!pending,variant=SoundQButtonVariant.Secondary)
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
@Composable private fun RefineSheet(query:LibraryQuery,onDismiss:()->Unit,onApply:(LibraryQuery)->Unit) {
    var draft by remember {mutableStateOf(query)}
    SoundQSheet("Refine library",onDismiss) {
        Text("Sort",style=SoundQ.typography.title)
        SoundQTabs(LibrarySort.entries.map {it.name},LibrarySort.entries.indexOf(draft.sort),{draft=draft.copy(sort=LibrarySort.entries[it])})
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
        SoundQButton("Apply refinement",{onApply(draft)})
        SoundQButton("Reset refinement",{draft=LibraryQuery()},variant=SoundQButtonVariant.Secondary)
    }
}
