package com.soundq.android.product.discovery

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.text.*
import androidx.compose.material3.Text
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.input.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.soundq.android.data.discovery.*
import com.soundq.android.product.ProductViewModel
import com.soundq.designsystem.*
import kotlinx.coroutines.delay

private fun LazyListScope.discoverHeader(content:@Composable ()->Unit) {
    item {Column(Modifier.fillMaxWidth().padding(horizontal=SoundQ.spacing.gutter,vertical=SoundQ.spacing.small)) {content()}}
}
private fun duration(ms:Long):String=if(ms<=0)"Duration unavailable" else "${ms/60000}:${(ms/1000%60).toString().padStart(2,'0')}"
@Composable fun DiscoverScreen(model:ProductViewModel,view:DiscoveryView?,intake:com.soundq.android.data.imports.ImportView?,onImports:()->Unit,onAccount:()->Unit,onAcquisition:()->Unit) {
    val repository=model.graph.discovery
    DisposableEffect(view,intake){onDispose {view?.let(repository::close);intake?.let(model.graph.imports::close)}}
    val state by repository.state.collectAsStateWithLifecycle()
    val imports by model.imports.collectAsStateWithLifecycle()
    var editor by remember(view) {mutableStateOf(TextFieldValue(state.draft.text))}
    // Only an authoritative navigation/refinement may replace the editor. Local edits publish synchronously.
    LaunchedEffect(state.draft){if(editor.text!=state.draft.text)editor=TextFieldValue(state.draft.text)}
    val focus=LocalFocusManager.current
    val queryFocus=remember {FocusRequester()}
    val context=LocalContext.current
    var options by remember(view) {mutableStateOf(false)}
    var queryFocused by remember(view) {mutableStateOf(false)}
    var entityDetails by remember(view) {mutableStateOf<DiscoveryEntity?>(null)}
    var catalogDetails by remember(view) {mutableStateOf<DiscoveryDetails?>(null)}
    // Keep the same accepted page and native list state while external Preview or Catalog is open.
    val scrolls=remember(view) {mutableMapOf<Pair<SourceResults?,DiscoveryResultType>,LazyListState>()}
    val scroll=remember(view,state.results,state.resultType) {scrolls.getOrPut(state.results to state.resultType){LazyListState()}}
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
    BackHandler(state.canBack&&state.inspected==null&&entityDetails==null) {view?.let(repository::back)}
    LazyColumn(Modifier.fillMaxSize(),state=scroll) {
        item {Row(Modifier.fillMaxWidth().height(64.dp),verticalAlignment=Alignment.CenterVertically) {
            if(state.canBack)SoundQIconButton(SoundQIcon.Back,"Back to previous search",{view?.let(repository::back)},Modifier.width(48.dp).fillMaxHeight(),outlined=false)
            Text("Discover",Modifier.weight(1f).padding(start=8.dp).semantics {heading()},style=SoundQ.typography.title.copy(fontSize=20.sp,fontWeight=FontWeight.SemiBold),maxLines=1,overflow=TextOverflow.Ellipsis)
            SoundQIconButton(SoundQIcon.Download,"Imports",onImports,Modifier.width(48.dp).fillMaxHeight(),outlined=false)
            Box {
                SoundQIconButton(SoundQIcon.More,"Discover options",{options=true},Modifier.width(48.dp).height(64.dp),outlined=false)
                DropdownMenu(options,{options=false}) {
                    DropdownMenuItem(text={Text("Server tools",style=SoundQ.typography.body)},leadingIcon={SoundQIcon(SoundQIcon.List,null)},onClick={options=false;onAcquisition()})
                    DropdownMenuItem(text={Text("Account and settings",style=SoundQ.typography.body)},leadingIcon={SoundQIcon(SoundQIcon.Settings,null)},onClick={options=false;onAccount()})
                }
            }
        };SoundQDivider()}
        discoverHeader {Row(verticalAlignment=Alignment.Bottom) {
            SoundQEntryField(editor,{next->val changed=next.text!=editor.text;editor=next;if(changed)view?.let {repository.edit(it,next.text)}},"Search sources",modifier=Modifier.weight(1f).focusRequester(queryFocus).onFocusChanged {queryFocused=it.hasFocus},
                keyboardOptions=KeyboardOptions(imeAction=ImeAction.Search),keyboardActions=KeyboardActions(onSearch={search()}))
            SoundQIconButton(SoundQIcon.Search,"Search",{search()},modifier=Modifier.height(56.dp),enabled=view!=null&&state.phase!=DiscoveryPhase.Loading,outlined=false)
            if(editor.text.isNotEmpty())SoundQIconButton(SoundQIcon.Close,"Clear search",{editor=TextFieldValue("");view?.let {repository.edit(it,"")};queryFocus.requestFocus()},modifier=Modifier.height(56.dp),outlined=false)
        }}
        if(state.invalidQuery)discoverHeader {SoundQFeedback("Enter a query up to 512 UTF-8 bytes.",FeedbackKind.Error)}
        if(queryFocused&&editor.text.isBlank()&&state.recent.isNotEmpty()) {
            discoverHeader {Row(verticalAlignment=Alignment.CenterVertically) {
                Text("Recent searches",Modifier.weight(1f),style=SoundQ.typography.title)
                SoundQIconButton(SoundQIcon.Close,"Clear search history",{view?.let(repository::clearRecent)},outlined=false)
            }}
            items(state.recent,key={"recent:$it"}) {query->SoundQRow(query,"",false,{
                view?.let {route->repository.recent(route,query)?.let {draft->editor=TextFieldValue(draft.text);model.searchSources(route,draft);focus.clearFocus()}}
            })}
        }
        item {SoundQTabs(DiscoveryResultType.entries.map {it.label},state.resultType.ordinal,{index->view?.let {repository.selectType(it,DiscoveryResultType.entries[index])}})}
        discoverHeader {SourceImportContinuation(imports,{receipt->intake?.let {model.recoverSourceImport(it,receipt)}},{receipt->intake?.let {model.retrySourceImport(it,receipt)}},{intake?.let(model.graph.imports::another)})}
        if(state.phase==DiscoveryPhase.Loading)discoverHeader {SoundQFeedback("Searching",FeedbackKind.Loading)}
        if(state.phase==DiscoveryPhase.Idle&&state.draft.text.isEmpty())discoverHeader {Text("Search music",style=SoundQ.typography.body)}
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
            if(imports.consumed)SourceImportContinuation(imports,{receipt->intake?.let {model.recoverSourceImport(it,receipt)}},{receipt->intake?.let {model.retrySourceImport(it,receipt)}},{intake?.let(model.graph.imports::another)})
            else if(choice.consumed)SoundQFeedback("Run a fresh search",FeedbackKind.Notice,"This selection has already been used.")
            else SoundQButton("Import source",{
                if(!choice.valid())view?.let {repository.reportExpired(it,choice)}
                else intake?.let {model.submitSourceImport(it,choice)}
            },enabled=row.downloadable&&!imports.pending)
            if(!row.downloadable)SoundQFeedback("Source unavailable for import",FeedbackKind.Notice)
        }
    }
}
