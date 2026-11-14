package com.soundq.android.product.home

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.Alignment
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.lazy.*
import androidx.compose.material3.Text
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics

import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.soundq.android.data.home.*
import com.soundq.android.product.ProductViewModel
import com.soundq.designsystem.*
import java.time.ZoneId
import java.time.format.DateTimeFormatter

@Composable fun HomeDestinationScreen(model: ProductViewModel, route: HomeRoute, onLibrary: () -> Unit, onAccount: () -> Unit, revealOwner:RowRevealOwner=remember {RowRevealOwner()}, onHistory:(()->Unit)?=null) {
    // Read collected snapshots before the deferred LazyListScope owner checks.
    // An initially absent (non-snapshot) repository owner must not short-circuit
    // observation of the State that will publish the accepted load.
    val recent = model.home.recent.collectAsStateWithLifecycle().value
    val top = model.home.top.collectAsStateWithLifecycle().value
    val history = model.home.history.collectAsStateWithLifecycle().value
    val listState = rememberLazyListState()
    LaunchedEffect(route) {
        if(route.destination == HomeDestination.History) model.loadHome(route,HomeSection.History)
        else {model.loadHome(route,HomeSection.Recent);model.loadHome(route,HomeSection.Top)}
    }
    val acceptedHistory=model.home.owns(route,HomeSection.History)
    val historyState=if(acceptedHistory)history else HistoryReadState(loading=true)
    Column(Modifier.fillMaxSize().closeRowRevealOutside(revealOwner)) {
        Row(Modifier.fillMaxWidth().heightIn(min=56.dp),verticalAlignment=Alignment.CenterVertically) {
            Text(if(route.destination==HomeDestination.History) "Listening history" else "Home",Modifier.weight(1f).padding(horizontal=SoundQ.spacing.gutter).semantics {heading()},style=SoundQ.typography.title)
            if(route.destination==HomeDestination.History)SoundQIconButton(SoundQIcon.Retry,"Refresh history",{model.loadHome(route,HomeSection.History,historyState)},enabled=acceptedHistory&&!historyState.loading,outlined=false)
            else onHistory?.let {SoundQIconButton(SoundQIcon.List,"Listening history",it,outlined=false)}
            SoundQIconButton(SoundQIcon.Settings,"Settings",onAccount,outlined=false)
        }
        SoundQDivider()
        if(route.destination==HomeDestination.History) {
            HistorySearch(route,historyState.query.text,enabled=acceptedHistory) {text->model.loadHome(route,HomeSection.History,historyState,query=historyState.query.copy(text=text))}
            SoundQTabs(listOf("All","Listened","Skipped"),historyState.query.kind.ordinal) {index->
                if(acceptedHistory)model.loadHome(route,HomeSection.History,historyState,query=historyState.query.copy(kind=HistoryKind.entries[index]))
            }
        }
        LazyColumn(Modifier.weight(1f).fillMaxWidth(),state=listState) {
        if(route.destination==HomeDestination.History) {
            val state=historyState
            if(state.loading)item {HomeStateCell {SoundQFeedback("Loading listening history",FeedbackKind.Loading)}}
            if(!state.loading&&state.error==null&&state.rows.isEmpty())item {HomeStateCell {SoundQFeedback(if(state.query==HistoryQuery())"No listening history yet" else "No matching history",FeedbackKind.Empty,action="Open Library",onAction=onLibrary)}}
            items(state.rows,key={it.id}) {event ->
                val metadata=listOfNotNull(
                    if(event.skipped) "Skipped" else "Listened",
                    event.playedAt.atZone(ZoneId.systemDefault()).format(DateTimeFormatter.ofPattern("MMM d, yyyy HH:mm")),
                    event.contextType,
                ).joinToString(" · ")
                HomeTrackRow(model,route,HomeSection.History,state.rows,event.entry,model.homePlay(route,HomeSection.History,state.rows,event.entry,event.id),model.homeQueue(route,HomeSection.History,state.rows,event.entry,event.id),revealOwner,metadata)
            }
            state.error?.let {error -> item {HomeStateCell {SoundQFeedback("Could not load listening history",FeedbackKind.Error,error.message,"Retry history",{model.loadHome(route,HomeSection.History,state,append=state.retryAppend)})}}}
            if(!state.loading&&state.error==null&&state.hasMore)item {HomeStateCell {SoundQButton("Load more history",{model.loadHome(route,HomeSection.History,state,append=true)},variant=SoundQButtonVariant.Secondary)}}
        } else {
            homeSection("Recently played",HomeSection.Recent,if(model.home.owns(route,HomeSection.Recent)) recent else HomeReadState(loading=true),model,route,onLibrary,revealOwner)
            homeSection("Your top tracks",HomeSection.Top,if(model.home.owns(route,HomeSection.Top)) top else HomeReadState(loading=true),model,route,onLibrary,revealOwner)
        }
        }
    }
}

@Composable private fun HomeStateCell(content:@Composable ()->Unit) {
    Box(Modifier.fillMaxWidth().padding(horizontal=SoundQ.spacing.gutter)){content()}
}

@Composable private fun HistorySearch(route:HomeRoute,committed:String,enabled:Boolean,onSearch:(String)->Unit) {
    var draft by remember(route){mutableStateOf(TextFieldValue(committed))}
    val colors=SoundQ.colors
    Row(Modifier.fillMaxWidth().heightIn(min=64.dp),verticalAlignment=Alignment.CenterVertically) {
        SoundQIconButton(SoundQIcon.Search,"Search history",{val text=draft.text;onSearch(text)},enabled=enabled,outlined=false)
        BasicTextField(draft,{draft=it},Modifier.weight(1f).heightIn(min=64.dp).semantics {contentDescription="History title or artist"},
            singleLine=true,textStyle=SoundQ.typography.body.copy(color=colors.text),cursorBrush=androidx.compose.ui.graphics.SolidColor(colors.focus),
            keyboardOptions=KeyboardOptions(imeAction=ImeAction.Search),keyboardActions=KeyboardActions(onSearch={if(enabled){val text=draft.text;onSearch(text)}}),
            decorationBox={editor->Column(Modifier.fillMaxWidth().padding(horizontal=SoundQ.spacing.small,vertical=SoundQ.spacing.small),verticalArrangement=Arrangement.Center) {
                Text("Title or artist",style=SoundQ.typography.caption,color=colors.muted)
                editor()
            }})
        SoundQIconButton(SoundQIcon.Close,"Clear history search",{draft=TextFieldValue("");onSearch("")},enabled=enabled&&draft.text.isNotEmpty(),outlined=false)
    }
    SoundQDivider()
}

private fun LazyListScope.homeSection(title:String,section:HomeSection,state:HomeReadState,model:ProductViewModel,route:HomeRoute,onLibrary:()->Unit,revealOwner:RowRevealOwner) {
    item {Row(Modifier.fillMaxWidth().heightIn(min=48.dp),verticalAlignment=Alignment.CenterVertically) {
        Text(title,style=SoundQ.typography.title,modifier=Modifier.weight(1f).padding(horizontal=SoundQ.spacing.gutter,vertical=SoundQ.spacing.medium).semantics {heading()})
        SoundQIconButton(SoundQIcon.Retry,if(section==HomeSection.Recent)"Refresh recent" else "Refresh top tracks",{model.loadHome(route,section,state)},enabled=!state.loading,outlined=false)
    }}
    if(state.loading)item {HomeStateCell {SoundQFeedback("Loading $title",FeedbackKind.Loading)}}
    state.error?.let {error -> item {HomeStateCell {SoundQFeedback("Could not load $title",FeedbackKind.Error,error.message,"Retry $title",{model.loadHome(route,section,state)})}}}
    if(!state.loading&&state.error==null&&state.rows.isEmpty())item {HomeStateCell {SoundQFeedback(if(section==HomeSection.Recent)"No recent plays yet" else "No top tracks yet",FeedbackKind.Empty,action="Open Library",onAction=onLibrary)}}
    itemsIndexed(state.rows,key={index,row -> "${section.name}:${row.track.id.value}:$index"}) {_,row -> HomeTrackRow(model,route,section,state.rows,row,model.homePlay(route,section,state.rows,row),model.homeQueue(route,section,state.rows,row),revealOwner)}
}

@Composable private fun HomeTrackRow(model:ProductViewModel,route:HomeRoute,section:HomeSection,acceptedRows:Any,row:HomeEntry,onPlay:()->Unit,onQueue:()->Unit,revealOwner:RowRevealOwner,metadata:String?=null) {
    val lifetime=com.soundq.android.product.rememberTrackRowLifetime(Triple(route,com.soundq.android.product.RowIdentity(acceptedRows),com.soundq.android.product.RowIdentity(row)))
    val scope=remember(route,com.soundq.android.product.RowIdentity(acceptedRows),com.soundq.android.product.RowIdentity(row),lifetime) {if(model.home.owns(route,section))model.graph.session.capture()else null}
    val valid={lifetime.current()&&route.current()&&model.home.owns(route,section)&&scope?.let(model.graph.session::remoteCurrent)==true&&when(section) {
        HomeSection.Recent->model.home.recent.value.rows===acceptedRows
        HomeSection.Top->model.home.top.value.rows===acceptedRows
        HomeSection.History->model.home.history.value.rows===acceptedRows
    }}
    val state=remember(row,lifetime){RowRevealState(revealOwner)}
    var menu by remember(row,lifetime){mutableStateOf(false)}
    val queue={if(valid()&&row.eligible)onQueue();Unit}
    val playback=model.playback.collectAsStateWithLifecycle().value
    val current=playback.queue.firstOrNull {it.occurrenceId==playback.selectedOccurrence}?.trackId==row.track.id.value
    val notation=model.graph.keyNotationPreferences.state.collectAsStateWithLifecycle().value
    val fields=com.soundq.android.product.libraryRowMetadata(row.track.durationMs,null,notation)
    val rowMetadata:(@Composable ()->Unit)?=if(section==HomeSection.History&&fields.isEmpty())null
        else {{com.soundq.android.product.LibraryMetadataContent(fields)}}
    SoundQSwipeQueue(row.track.title,state,row.eligible&&valid(),queue,current=current) {front,admit->
        Box {
            SoundQMediaRow(row.track.title,row.track.artist,current,
                {if(valid()&&admit())onPlay()},{state.close();menu=true},modifier=front,enabled=row.eligible&&valid(),
                artwork={com.soundq.android.product.artwork.TrackArtwork(model.graph,scope,row.track,valid,sourceOwner=lifetime)},
                supporting=listOfNotNull(metadata,if(!row.eligible)"Not in your library"else null).joinToString(" · ").takeIf {it.isNotEmpty()},
                supportingMaxLines=if(section==HomeSection.History)6 else 1,metadata=rowMetadata)
            DropdownMenu(menu,{menu=false}) {
                DropdownMenuItem(text={Text("Play")},onClick={menu=false;if(valid())onPlay()},enabled=row.eligible&&valid())
                DropdownMenuItem(text={Text("Add to listening queue")},onClick={menu=false;queue()},enabled=row.eligible&&valid())
            }
        }
    }
}
