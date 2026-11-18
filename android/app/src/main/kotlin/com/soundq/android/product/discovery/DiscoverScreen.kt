package com.soundq.android.product.discovery

import android.content.Intent
import android.net.Uri
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
import androidx.compose.ui.platform.LocalContext
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
    val context=LocalContext.current
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
    var radarDetails by remember(view) {mutableStateOf<Triple<RadarPage,RadarSong,DiscoveryDraft>?>(null)}
    // Keep the same accepted page and native list state while external Preview or Catalog is open.
    val scrolls=remember(view) {mutableMapOf<Pair<SourceResults?,DiscoveryResultType>,LazyListState>()}
    val searchScroll=remember(view,state.results,state.resultType) {scrolls.getOrPut(state.results to state.resultType){LazyListState()}}
    val radarScroll=remember(view,radar.page) {LazyListState()}
    val fullRadarScroll=remember(view,radar.page) {radarFullListState()}
    val scroll=if(showRadarCollection)fullRadarScroll else if(state.draft.text.isBlank())radarScroll else searchScroll
    // A normal route visit, not query edits or playback ticks, asks the server's daily policy.
    // The observer retires synchronously through STOP/RESUME even without recomposition.
    val radarLifecycle=LocalLifecycleOwner.current
    val radarShown=radarVisible()
    var radarActive by remember(view,radarLifecycle) {mutableStateOf(false)}
    var radarSurfaceVisit by remember(view,radarLifecycle) {mutableStateOf<RadarArtworkRoute?>(null)}
    fun renewRadarArtwork() {
        // Retire before layout/coverage changes, not when the retained lazy slots are disposed.
        radarSurfaceVisit?.let {old->old.retire();radarSurfaceVisit=RadarArtworkRoute()}
    }
    fun changeRadarDetails(next:Triple<RadarPage,RadarSong,DiscoveryDraft>?) {
        if(radarDetails===next)return
        // Only artwork loses admission. Find sources still needs the accepted Radar landing.
        renewRadarArtwork()
        radarDetails=next
    }
    fun changeRadarCollection(full:Boolean) {
        if(radarCollection==full)return
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
                landing?.let(repository::hideRadar);landing=null;changeRadarDetails(null)
            }
            radarActive=active
        }
        val observer=LifecycleEventObserver {_,_->sync()}
        radarLifecycle.lifecycle.addObserver(observer);sync()
        onDispose {radarSurfaceVisit?.retire();radarSurfaceVisit=null;active=false;landing?.let(repository::hideRadar);changeRadarDetails(null);radarActive=false;radarLifecycle.lifecycle.removeObserver(observer)}
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
    LaunchedEffect(view,state.draft,radar.page,radar.stale,radar.phase) {
        radarDetails?.let {(page,song,draft)->if(view==null||!repository.radarCurrent(view,page,song,draft))changeRadarDetails(null)}
    }
    fun search() {
        val route=view ?: return
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
    val radarSurfaceOwner=if(radarActive&&radarShown&&state.draft.text.isBlank()&&radarDetails==null) {
        radarSurfaceVisit?.let {visit->
            remember(view,visibleRadarPage,state.draft,showRadarCollection,visit,radarArtworkRoot) {
                RadarArtworkRoute(visit,radarArtworkRoot)
            }
        }
    } else null
    BackHandler(state.canBack&&state.inspected==null&&entityDetails==null&&radarDetails==null) {view?.let(repository::back)}
    BackHandler(showRadarCollection&&radarDetails==null) {changeRadarCollection(false)}
    BackHandler(queryFocused&&state.inspected==null&&entityDetails==null&&radarDetails==null) {focus.clearFocus()}
    Column(Modifier.fillMaxSize()) {
        MainPageHeader(if(showRadarCollection)"New releases" else "Discover",navigation=if(showRadarCollection) ({
            SoundQIconButton(SoundQIcon.Back,"Back to Discover",{changeRadarCollection(false)},Modifier.heightIn(min=56.dp),outlined=false)
        }) else if(state.canBack) ({
            SoundQIconButton(SoundQIcon.Back,"Back to previous search",{view?.let(repository::back)},Modifier.heightIn(min=56.dp),outlined=false)
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
        SoundQSearchStrip(editor,{next->val changed=next.text!=editor.text;editor=next;if(changed)view?.let {repository.edit(it,next.text)}},
            "Search music","Music search query","Search music","Clear search",onSubmit={search()},
            onClear={editor=TextFieldValue("");view?.let {repository.edit(it,"")};queryFocus.requestFocus()},
            editorModifier=Modifier.focusRequester(queryFocus).onFocusChanged {queryFocused=it.hasFocus},
            submitEnabled=view!=null&&state.phase!=DiscoveryPhase.Loading,clearEnabled=view!=null&&editor.text.isNotEmpty())
        SoundQTabs(DiscoveryResultType.entries.map {it.label},state.resultType.ordinal,Modifier.fillMaxWidth(),SoundQTabsTreatment.MainPageCells) {index->view?.let {repository.selectType(it,DiscoveryResultType.entries[index])}}
        }
        LazyColumn(Modifier.fillMaxWidth().weight(1f),state=scroll) {
        if(state.invalidQuery)discoverHeader {SoundQFeedback("Enter a query up to 512 UTF-8 bytes.",FeedbackKind.Error)}
        if(!showRadarCollection&&queryFocused&&editor.text.isBlank()&&state.recent.isNotEmpty()) {
            discoverHeader {Row(verticalAlignment=Alignment.CenterVertically) {
                Text("Recent searches",Modifier.weight(1f),style=SoundQ.typography.title)
                SoundQIconButton(SoundQIcon.Close,"Clear search history",{view?.let(repository::clearRecent)},outlined=false)
            }}
            items(state.recent,key={"recent:$it"}) {query->SoundQRow(query,"",false,{
                view?.let {route->repository.recent(route,query)?.let {draft->editor=TextFieldValue(draft.text);model.searchSources(route,draft);focus.clearFocus()}}
            })}
        }

        if(state.phase==DiscoveryPhase.Loading)discoverHeader {SoundQFeedback("Searching",FeedbackKind.Loading)}
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
                    val open:()->Unit={view?.let {route->if(radarDetails==null&&repository.radarCurrent(route,page,song,draft)&&radarSurfaceOwner?.current()==true)changeRadarDetails(Triple(page,song,draft))}}
                    SoundQMediaRow(song.title,song.artist,false,open,open,
                        artwork={if(view!=null&&radarSurfaceOwner!=null)RadarArtwork(model.graph.mediaClient,repository,view,page,song,draft,radarSurfaceOwner,fullList=fullRadarScroll.takeIf {showRadarCollection})},
                        supporting="First released · ${song.firstRelease.raw}",enabled=view!=null&&!radar.stale&&radar.phase==RadarPhase.Ready)
                }
                if(!showRadarCollection&&page.songs.isNotEmpty())item {
                    SoundQListActionRow("View all",{changeRadarCollection(true);focus.clearFocus()},enabled=view!=null&&!radar.stale&&radar.phase==RadarPhase.Ready,description="View all New releases")
                }
            }
        }
        state.error?.let {discoverHeader {SoundQFeedback("Search unavailable",FeedbackKind.Error,it.message,"Search again",{search()})}}
        if(state.expired)discoverHeader {SoundQFeedback("Source choice expired",FeedbackKind.Notice,"Search again to import.","Search again",{search()})}
        state.results?.let {results->
            val entities=results.entities.filter {it.type==state.resultType}
            results.providers.filter {it.status!="ok"}.forEach {provider->discoverHeader {
                Text("${provider.provider.label}: ${when(provider.status){"timeout"->"Taking too long";"disabled"->"Unavailable";"unsupported"->"Unavailable";else->"Could not search"}}",style=SoundQ.typography.caption)
            }}
            if(results.providers.none {it.status=="ok"})discoverHeader {SoundQFeedback("Sources unavailable",FeedbackKind.Error,action="Search again",onAction={search()})}
            if(state.resultType==DiscoveryResultType.Song) {
                if(results.rows.isEmpty())discoverHeader {SoundQFeedback("No song sources",FeedbackKind.Empty)}
                items(results.rows,key={it.id}) {row->
                    SoundQMediaRow(title=row.title,subtitle=row.artist.ifBlank {row.uploader},current=false,
                        onActivate={view?.let {repository.inspect(it,row)}},onMore={view?.let {repository.inspect(it,row)}},
                        artwork={DiscoveryArtwork(model.graph.mediaClient,row.thumbnailUrl,results to view) {view?.let(repository::current)==true&&repository.state.value.results===results}},
                        supporting="${row.provider.label} · ${duration(row.durationMs)}"+(if(row.downloadable)"" else " · Import unavailable"),enabled=view!=null)
                }
            } else {
                if(entities.isEmpty())discoverHeader {SoundQFeedback("No ${state.resultType.label.lowercase()} matches",FeedbackKind.Empty)}
                items(entities) {entity->
                    val refine:()->Unit={view?.let {route->repository.refine(route,entity)?.let {draft->model.searchSources(route,draft)}}}
                    SoundQMediaRow(entity.title,entity.subtitle,false,refine,{entityDetails=entity},supporting=entity.type.label,enabled=view!=null)
                }
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
    state.inspected?.let {choice->
        var previewError by remember(choice) {mutableStateOf(false)}
        SoundQSheet("Source details",{view?.let {repository.dismiss(it,choice)}}) {
            val row=choice.candidate
            Text(row.title,style=SoundQ.typography.title)
            if(row.artist.isNotBlank())Text(row.artist)
            if(row.uploader.isNotBlank()&&row.uploader!=row.artist)Text("Uploader · ${row.uploader}")
            if(row.album.isNotBlank())Text("Album · ${row.album}")
            Text("${row.provider.label} · ${duration(row.durationMs)}")
            if(row.sourceId.isNotBlank())Text("Source ID · ${row.sourceId}",style=SoundQ.typography.mono)
            row.explicit?.let {Text(if(it)"Explicit" else "Not explicit",style=SoundQ.typography.caption)}
            androidx.compose.foundation.text.selection.SelectionContainer {Text(row.source.url,style=SoundQ.typography.mono)}
            SoundQButton("Preview source",{
                previewError=view?.let {route->!repository.preview(route,choice) {url->context.startActivity(Intent(Intent.ACTION_VIEW,Uri.parse(url)))}} ?: true
            },variant=SoundQButtonVariant.Secondary)
            if(previewError)SoundQFeedback("Could not open source",FeedbackKind.Error)
            val terminalSource=imports.sourceReceipt?.phase in setOf(SourceImportPhase.Accepted,SourceImportPhase.DecisionRefused)
            if(imports.consumed&&!terminalSource)SoundQButton("Open imports",onImports,variant=SoundQButtonVariant.Secondary)
            else if(choice.consumed||model.graph.imports.sourceSessionConsumed(choice))SoundQButton("Search again",{
                view?.let {route->
                    intake?.let(model.graph.imports::another)
                    repository.dismiss(route,choice)
                    search()
                }
            },variant=SoundQButtonVariant.Secondary)
            else SoundQButton("Import source",{
                if(!choice.valid())view?.let {repository.reportExpired(it,choice)}
                else intake?.let {
                    if(terminalSource)model.graph.imports.another(it)
                    model.submitSourceImport(it,choice)
                }
            },enabled=row.downloadable&&!imports.pending)
            if(!row.downloadable)SoundQFeedback("Source unavailable for import",FeedbackKind.Notice)
        }
    }
    radarDetails?.takeIf {(page,song,draft)->view?.let {repository.radarCurrent(it,page,song,draft)}==true}?.let {evidence->
        val (page,song,draft)=evidence
        // An equal-song reopen must not reuse a modal's asynchronous hide coroutine.
        key(radarSurfaceVisit) {
            SoundQSheet("Song evidence",{if(radarDetails===evidence)changeRadarDetails(null)}) {
                Text(song.title,style=SoundQ.typography.title)
                Text(song.artist)
                Text("First released · ${song.firstRelease.raw} (${song.firstRelease.precision})")
                Text("Recording MusicBrainz ID: ${song.recording.value}",style=SoundQ.typography.mono)
                Text("Credited listened-to artist IDs: ${song.creditedSeeds.joinToString {it.value}}",style=SoundQ.typography.mono)
                Text("Source search is not proof of a recording match. Inspect the source before importing.",style=SoundQ.typography.caption)
                SoundQButton("Find sources",{if(radarDetails===evidence)view?.let {model.findReleaseSources(it,page,song,draft)}},enabled=!radar.finding&&view?.let {repository.radarCurrent(it,page,song,draft)}==true)
                if(radar.finding)SoundQFeedback("Checking library",FeedbackKind.Loading)
                radar.error?.let {SoundQFeedback("Could not check library",FeedbackKind.Error)}
            }
        }
    }
}
