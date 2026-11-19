package com.soundq.android.product.discovery

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.clickable
import androidx.compose.foundation.lazy.*

import androidx.compose.material3.Text
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalDensity

import androidx.compose.ui.text.input.*
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.semantics.*
import com.soundq.android.data.discovery.*
import com.soundq.android.product.ProductViewModel
import com.soundq.android.product.MainPageHeader
import com.soundq.designsystem.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private fun LazyListScope.discoverHeader(content:@Composable ()->Unit) {
    item {Column(Modifier.fillMaxWidth().padding(horizontal=SoundQ.spacing.gutter,vertical=SoundQ.spacing.small)) {content()}}
}
private fun duration(ms:Long):String=if(ms<=0)"Duration unavailable" else formatSongTime(ms)
@Composable internal fun DiscoverScreen(model:ProductViewModel,view:DiscoveryView?,intake:com.soundq.android.data.imports.ImportView?,onImports:()->Unit,onAccount:()->Unit,onAcquisition:()->Unit,radarArtworkRoot:RadarArtworkRoute,radarVisible:()->Boolean) {
    val repository=model.graph.discovery
    DisposableEffect(view,intake){onDispose {view?.let(repository::close);intake?.let(model.graph.imports::close)}}
    val state by repository.state.collectAsStateWithLifecycle()
    val radar by repository.radar.collectAsStateWithLifecycle()
    val visibleRadarPage=radar.page?.takeIf {view?.let(repository::current)==true}
    val imports by model.imports.collectAsStateWithLifecycle()
    var editor by remember(view) {mutableStateOf(TextFieldValue(state.draft.text))}
    // Only an authoritative navigation/refinement may replace the editor. Local edits publish synchronously.
    LaunchedEffect(state.draft){if(editor.text!=state.draft.text)editor=TextFieldValue(state.draft.text)}
    val focus=LocalFocusManager.current
    val queryFocus=remember {FocusRequester()}
    var options by remember(view) {mutableStateOf(false)}
    var queryFocused by remember(view) {mutableStateOf(false)}
    var radarCollection by rememberSaveable(view) {mutableStateOf(false)}
    var keyboardWasVisible by remember(view) {mutableStateOf(false)}
    val keyboardVisible=WindowInsets.ime.getBottom(LocalDensity.current)>0
    LaunchedEffect(view,keyboardVisible,queryFocused) {
        if(queryFocused&&keyboardWasVisible&&!keyboardVisible)focus.clearFocus()
        keyboardWasVisible=keyboardVisible
    }
    val showRadarCollection=radarCollection&&state.draft.text.isBlank()
    var entityDetails by remember(view) {mutableStateOf<DiscoveryEntity?>(null)}
    var catalogDetails by remember(view) {mutableStateOf<DiscoveryDetails?>(null)}
    // Keep the same accepted page and native list state while Catalog is open.
    val scrolls=remember(view) {mutableMapOf<Pair<Any?,DiscoveryResultType>,LazyListState>()}
    val pageIdentity=state.results?.identity
    val searchScroll=remember(view,pageIdentity,state.resultType) {scrolls.getOrPut(pageIdentity to state.resultType){LazyListState()}}
    val radarScroll=remember(view,radar.page) {LazyListState()}
    val fullRadarScroll=remember(view,radar.page) {radarFullListState()}
    val scroll=if(showRadarCollection)fullRadarScroll else if(state.draft.text.isBlank())radarScroll else searchScroll
    // A normal route visit, not query edits or playback ticks, asks the server's daily policy.
    // The observer retires synchronously through STOP/RESUME even without recomposition.
    val radarLifecycle=LocalLifecycleOwner.current
    val radarShown=radarVisible()
    val rows=rememberDiscoveryRowActions(model,view,radarArtworkRoot,radarShown&&catalogDetails==null)
    val rowSurface=rows.surface
    var radarActive by remember(view,radarLifecycle) {mutableStateOf(false)}
    var radarSurfaceVisit by remember(view,radarLifecycle) {mutableStateOf<RadarArtworkRoute?>(null)}
    fun renewRadarArtwork() {
        // Retire before layout/coverage changes, not when the retained lazy slots are disposed.
        radarSurfaceVisit?.let {old->old.retire();radarSurfaceVisit=RadarArtworkRoute()}
    }
    fun changeRadarCollection(full:Boolean) {
        if(radarCollection==full)return
        rows.renew()
        renewRadarArtwork()
        radarCollection=full
    }
    LaunchedEffect(view,state.draft.text) {if(state.draft.text.isNotBlank())changeRadarCollection(false)}
    val radarInvalidation by repository.radarInvalidation.collectAsStateWithLifecycle()
    DisposableEffect(view,radarLifecycle,catalogDetails,radarShown) {
        var landing:RadarLanding?=null
        var active=false
        fun sync() {
            active=radarShown&&catalogDetails==null&&radarLifecycle.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
            if(active&&landing==null) {
                landing=view?.let {repository.showRadar(it){active&&radarVisible()&&radarLifecycle.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)}}
                radarSurfaceVisit=if(landing!=null)RadarArtworkRoute()else null
                if(landing!=null)view?.let {model.loadReleaseRadar(it,automatic=true)}
            } else if(!active) {
                radarSurfaceVisit?.retire();radarSurfaceVisit=null
                landing?.let(repository::hideRadar);landing=null
            }
            radarActive=active
        }
        val observer=LifecycleEventObserver {_,_->sync()}
        radarLifecycle.lifecycle.addObserver(observer);sync()
        onDispose {radarSurfaceVisit?.retire();radarSurfaceVisit=null;active=false;landing?.let(repository::hideRadar);radarActive=false;radarLifecycle.lifecycle.removeObserver(observer)}
    }
    // Retry invalidated reads only at eligible transitions, never on playback ticks.
    // The revision also witnesses repeated invalidations if Loading is conflated away.
    LaunchedEffect(view,radarInvalidation,radar.stale,radar.phase,state.draft.text.isBlank(),radarActive,radarShown,catalogDetails) {
        if(radarActive&&radarShown&&catalogDetails==null&&state.draft.text.isBlank()) {
            if(radar.stale&&radar.phase==RadarPhase.Ready)view?.let {model.loadReleaseRadar(it)}
            // Cancellation can retire the first GET without replacing this live landing.
            if(radar.page==null&&radar.phase==RadarPhase.Idle)view?.let {model.loadReleaseRadar(it,automatic=true)}
        }
    }
    fun search() {
        val route=view ?: return
        rows.renew()
        // Capture and claim before IME/focus can deliver a composition-ending callback.
        val submitted=editor.text
        if(repository.state.value.draft.text!=submitted)repository.edit(route,submitted)
        val draft=repository.state.value.draft
        model.searchSources(route,draft)
        editor=editor.copy(composition=null)
        focus.clearFocus()
    }
    // IMEs can retain a composing word indefinitely. Debounce text, not composition;
    // composition-only updates neither restart the timer nor issue another read.
    LaunchedEffect(view,state.draft) {
        val route=view ?: return@LaunchedEffect
        val draft=state.draft
        if(draft.text.isNotBlank()&&state.phase==DiscoveryPhase.Idle) {
            delay(350)
            val latest=repository.state.value
            if(latest.draft===draft&&latest.phase==DiscoveryPhase.Idle)model.searchSources(route,draft)
        }
    }
    val openedCatalog=catalogDetails
    if(openedCatalog!=null) {
        val actions=remember(view,openedCatalog) {model.catalogActions().also {it.discover(openedCatalog)}}
        DisposableEffect(actions) {onDispose {actions.close()}}
        val catalog by model.graph.catalog.state.collectAsStateWithLifecycle()
        com.soundq.android.product.catalog.CatalogScreen(catalog,actions,{catalogDetails=null})
        return
    }
    // The slot binds the exact root and layout captures, not a predicate that looks up their successors.
    val radarSurfaceOwner=if(radarActive&&radarShown&&state.draft.text.isBlank()) {
        radarSurfaceVisit?.let {visit->
            remember(view,visibleRadarPage,state.draft,showRadarCollection,visit,radarArtworkRoot) {
                RadarArtworkRoute(visit,radarArtworkRoot)
            }
        }
    } else null
    fun back() {rows.renew();view?.let(repository::back)}
    BackHandler(state.canBack&&entityDetails==null) {back()}
    BackHandler(showRadarCollection) {changeRadarCollection(false)}
    BackHandler(queryFocused&&entityDetails==null) {focus.clearFocus()}
    Column(Modifier.fillMaxSize()) {
        MainPageHeader(if(showRadarCollection)"New releases" else "Discover",navigation=if(showRadarCollection) ({
            SoundQIconButton(SoundQIcon.Back,"Back to Discover",{changeRadarCollection(false)},Modifier.heightIn(min=56.dp),outlined=false)
        }) else if(state.canBack) ({
            SoundQIconButton(SoundQIcon.Back,"Back to previous search",{back()},Modifier.heightIn(min=56.dp),outlined=false)
        }) else null) {
            SoundQIconButton(SoundQIcon.Download,"Imports",onImports,Modifier.heightIn(min=56.dp),outlined=false)
            Box {
                SoundQIconButton(SoundQIcon.More,"Discover options",{options=true},Modifier.heightIn(min=56.dp),outlined=false)
                DropdownMenu(options,{options=false}) {
                    DropdownMenuItem(text={Text("Server tools",style=SoundQ.typography.body)},leadingIcon={SoundQIcon(SoundQIcon.List,null)},onClick={options=false;onAcquisition()})
                    DropdownMenuItem(text={Text("Settings",style=SoundQ.typography.body)},leadingIcon={SoundQIcon(SoundQIcon.Settings,null)},onClick={options=false;onAccount()})
                }
            }
        }
        if(!showRadarCollection) {
        SoundQSearchStrip(editor,{next->val changed=next.text!=editor.text;editor=next;if(changed){rows.renew();view?.let {repository.edit(it,next.text)}}},
            "Search music","Music search query","Search music","Clear search",onSubmit=null,
            onClear={rows.renew();editor=TextFieldValue("");view?.let {repository.edit(it,"")};queryFocus.requestFocus()},
            editorModifier=Modifier.focusRequester(queryFocus).onFocusChanged {queryFocused=it.hasFocus},
            clearEnabled=view!=null&&editor.text.isNotEmpty())
        SoundQTabs(DiscoveryResultType.entries.map {it.label},state.resultType.ordinal,Modifier.fillMaxWidth(),SoundQTabsTreatment.MainPageCells) {index->
            val type=DiscoveryResultType.entries[index]
            view?.let {if(repository.state.value.resultType!=type){rows.renew();model.selectDiscoveryType(it,type)}}
        }
        val sourceBatches=state.results?.batches.orEmpty().filter {it.rows.isNotEmpty()}
        if(state.resultType==DiscoveryResultType.Song&&sourceBatches.size==2) {
            val scope=rememberCoroutineScope()
            val late=sourceBatches.last().rows.first()
            SoundQListActionRow("View ${late.provider.label} results",{
                val latest=repository.state.value
                if(latest.results?.identity===pageIdentity&&latest.resultType==DiscoveryResultType.Song) {
                    focus.clearFocus()
                    scope.launch {searchScroll.animateScrollToItem(sourceBatches.first().rows.size)}
                }
            })
        }
        }
        if(state.expired)SoundQFeedback("Source choice expired",FeedbackKind.Notice,"Search again to import.","Search again",{search()})
        LazyColumn(Modifier.fillMaxWidth().weight(1f),state=scroll) {
        if(state.invalidQuery)discoverHeader {SoundQFeedback("Enter a query up to 512 UTF-8 bytes.",FeedbackKind.Error)}
        if(!showRadarCollection&&queryFocused&&editor.text.isBlank()&&state.recent.isNotEmpty()) {
            discoverHeader {Row(verticalAlignment=Alignment.CenterVertically) {
                Text("Recent searches",Modifier.weight(1f),style=SoundQ.typography.title)
                SoundQIconButton(SoundQIcon.Close,"Clear search history",{view?.let(repository::clearRecent)},outlined=false)
            }}
            items(state.recent,key={"recent:$it"}) {query->SoundQRow(query,"",false,{
                view?.let {route->repository.recent(route,query)?.let {draft->rows.renew();editor=TextFieldValue(draft.text);model.searchSources(route,draft);focus.clearFocus()}}
            })}
        }

        if(state.phase==DiscoveryPhase.Loading)items(6,key={"search-skeleton:$it"}) {index->
            val status=if(index==0)Modifier.semantics {
                contentDescription="Loading search results"
                liveRegion=LiveRegionMode.Polite
                progressBarRangeInfo=ProgressBarRangeInfo.Indeterminate
            } else Modifier
            SoundQMediaRowSkeleton(status,showSupporting=state.resultType==DiscoveryResultType.Song)
        }
        if(state.draft.text.isBlank()) {
            if(!showRadarCollection)discoverHeader {Text("New releases",style=SoundQ.typography.title,modifier=Modifier
                .fillMaxWidth().heightIn(min=48.dp).clickable(enabled=visibleRadarPage!=null&&!radar.stale&&radar.phase==RadarPhase.Ready) {
                    changeRadarCollection(true);focus.clearFocus()
                }.semantics {heading()})}
            when(radar.phase) {
                RadarPhase.Held->discoverHeader {Text("Search music",style=SoundQ.typography.body)}
                RadarPhase.Loading->discoverHeader {SoundQFeedback("Finding new releases",FeedbackKind.Loading)}
                RadarPhase.Failed->discoverHeader {SoundQFeedback("New releases unavailable",FeedbackKind.Error,action="Try again",onAction={view?.let {model.loadReleaseRadar(it,true)}})}
                else->Unit
            }
            if(radar.stale)discoverHeader {SoundQFeedback("Releases need refreshing",FeedbackKind.Notice,action="Refresh",onAction={view?.let {model.loadReleaseRadar(it,true)}})}
            visibleRadarPage?.let {page->
                val draft=state.draft
                if(page.coverage.providerStatus in setOf("unavailable","timeout"))discoverHeader {SoundQFeedback("Could not update new releases",FeedbackKind.Error)}
                if(page.songs.isEmpty()&&radar.phase==RadarPhase.Ready)discoverHeader {SoundQFeedback(radarEmptyMessage(page.coverage),FeedbackKind.Empty)}
                items(page.songs.take(if(showRadarCollection)20 else 5),key={"radar:${it.recording.value}"}) {song->
                    val current={view!=null&&rowSurface?.current()==true&&radarSurfaceOwner?.current()==true&&repository.radarCurrent(view,page,song,draft)}
                    val enabled=view!=null&&rowSurface!=null&&!radar.stale&&radar.phase==RadarPhase.Ready
                    SoundQMediaRow(song.title,song.artist,false,onActivate={
                        if(view!=null)rows.preview(view,song,song.title,song.artist,{rowSurface?.current()==true&&radarSurfaceOwner?.current()==true&&
                            repository.radarCurrent(view,page,song,draft,preview=true)}) {valid->model.graph.api.recordingPreviewSource(view.scope,song.recording,valid)}
                    },onMore=null,
                        artwork={if(view!=null&&radarSurfaceOwner!=null)RadarArtwork(model.graph.mediaClient,repository,view,page,song,draft,radarSurfaceOwner,fullList=fullRadarScroll.takeIf {showRadarCollection})},
                        supporting="First released · ${song.firstRelease.raw}",enabled=enabled,
                        preview=SoundQMediaPreviewActions(rows.pending(song),enabled&&intake!=null&&!imports.pending&&!rows.adding) {
                            if(view!=null&&intake!=null)rows.addRecording(view,intake,song,current)
                        })
                }
                if(!showRadarCollection&&page.songs.isNotEmpty())item {
                    SoundQListActionRow("View all",{changeRadarCollection(true);focus.clearFocus()},enabled=view!=null&&!radar.stale&&radar.phase==RadarPhase.Ready,description="View all New releases")
                }
            }
        }
        state.error?.let {discoverHeader {SoundQFeedback("Search unavailable",FeedbackKind.Error,it.message,"Search again",{search()})}}
        state.results?.let {results->
            val entities=results.entities.filter {it.type==state.resultType}
            if(state.resultType==DiscoveryResultType.Song) {
                if(state.phase==DiscoveryPhase.Ready&&results.rows.isEmpty())discoverHeader {SoundQFeedback("No song sources",FeedbackKind.Empty)}
                val selectable=results.batches.mapNotNull {it.selection}
                val exhausted=selectable.isNotEmpty()&&selectable.all(model.graph.imports::sourceSessionConsumed)
                if(exhausted&&!imports.pending&&!state.expired&&results.providers.all {it.status=="ok"})discoverHeader {
                    SoundQButton("Search again",{search()},variant=SoundQButtonVariant.Secondary)
                }
                items(results.rows,key={"source:${it.provider.wire}:${it.id}"}) {row->
                    val batch=results.batches.first {it.rows.any {candidate->candidate===row}}
                    val exact=view?.let {repository.sourceRowGuard(it,batch,row)}
                    val previewExact=view?.let {repository.sourceRowGuard(it,batch,row,preview=true)}
                    val current={rowSurface?.current()==true&&exact?.invoke()==true}
                    val consumed=batch.selection?.let(model.graph.imports::sourceSessionConsumed)==true
                    SoundQMediaRow(title=row.title,subtitle=row.artist.ifBlank {row.uploader},current=false,
                        onActivate={if(view!=null)rows.preview(view,row,row.title,row.artist.ifBlank {row.uploader},
                            {rowSurface?.current()==true&&previewExact?.invoke()==true}) {row.previewSource}},onMore=null,
                        artwork={Box(Modifier.fillMaxSize()) {
                            DiscoveryArtwork(model.graph.mediaClient,row.thumbnailUrl,results.identity to view) {view?.let(repository::current)==true&&repository.state.value.results?.identity===results.identity}
                            DiscoveryProviderMark(row.provider,Modifier.align(Alignment.BottomEnd).padding(3.dp))
                        }},
                        supporting=duration(row.durationMs)+(if(row.downloadable)"" else " · Import unavailable"),enabled=rowSurface!=null,
                        preview=SoundQMediaPreviewActions(rows.pending(row),rowSurface!=null&&intake!=null&&batch.selection!=null&&row.downloadable&&!imports.pending&&!consumed) {
                            if(view!=null&&intake!=null)rows.addSource(view,intake,batch,row,current)
                        })
                }
            } else {
                if(entities.isEmpty()&&results.providers.any {it.provider==DiscoveryProvider.MusicBrainz&&it.status=="ok"})discoverHeader {SoundQFeedback("No ${state.resultType.label.lowercase()} matches",FeedbackKind.Empty)}
                items(entities) {entity->
                    val refine:()->Unit={view?.let {route->repository.refine(route,entity)?.let {draft->model.searchSources(route,draft)}}}
                    SoundQMediaRow(entity.title,entity.subtitle,false,refine,{entityDetails=entity},supporting=entity.type.label,enabled=view!=null)
                }
            }
            if(!state.pendingProviders)results.providers.filter {it.status!="ok"}.forEach {provider->discoverHeader {
                val status=when(provider.status){"timeout"->"Taking too long";"disabled","unsupported"->"Unavailable";else->"Could not search"}
                Text("${provider.provider.label}: $status",style=SoundQ.typography.caption)
            }}
            if(!state.pendingProviders&&state.phase==DiscoveryPhase.Ready&&results.providers.any {it.status!="ok"})discoverHeader {
                SoundQButton("Search again",{search()},variant=SoundQButtonVariant.Secondary)
            }
        }
        }
    }

    entityDetails?.let {entity->SoundQSheet("${entity.type.label} details",{entityDetails=null}) {
        Text(entity.title,style=SoundQ.typography.title)
        if(entity.subtitle.isNotBlank())Text(entity.subtitle)
        if(entity.id.isNotBlank())Text("${if(entity.type==DiscoveryResultType.Album)"Release-group" else "Artist"} MusicBrainz ID: ${entity.id}",style=SoundQ.typography.mono)
        if(entity.catalogTarget!=null)SoundQButton("Details",{view?.let {route->repository.details(route,entity)?.let {catalogDetails=it;entityDetails=null}}},variant=SoundQButtonVariant.Secondary)
        SoundQButton("Refine search",{view?.let {route->repository.refine(route,entity)?.let {draft->entityDetails=null;model.searchSources(route,draft)}}},variant=SoundQButtonVariant.Secondary)
    }}
}
