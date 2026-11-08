package com.soundq.android.product.catalog

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.input.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import com.soundq.android.data.catalog.*
import com.soundq.designsystem.*

private fun LazyListScope.catalogHeader(content:@Composable ()->Unit) {
    item {Column(Modifier.fillMaxWidth().padding(SoundQ.spacing.gutter),verticalArrangement=Arrangement.spacedBy(SoundQ.spacing.small)) {content()}}
}

/** Catalog owns metadata and target-bound membership, never playback or acquisition. */
@Composable fun CatalogScreen(state:CatalogState,actions:CatalogActions,onExit:()->Unit) {
    var albums by remember {mutableStateOf(false)}
    var draft by remember {mutableStateOf(TextFieldValue(state.draft))}
    LaunchedEffect(state.draft) {if(draft.text!=state.draft)draft=TextFieldValue(state.draft)}
    LaunchedEffect(state.operation) {if(state.operation is CatalogRead.Releases)albums=true}
    val focus=LocalFocusManager.current
    val scrolls=remember {mutableMapOf<String,LazyListState>()}
    val key=state.group?.id?.value ?: state.album?.id?.value ?: state.artist?.row?.id?.value ?: state.operation.toString()
    val scroll=remember(key) {scrolls.getOrPut(key){LazyListState()}}
    fun back() {if(!actions.back())onExit()}
    BackHandler {back()}
    LazyColumn(Modifier.fillMaxSize(),state=scroll) {
        item {
            Row(Modifier.fillMaxWidth().height(64.dp),verticalAlignment=Alignment.CenterVertically) {
                SoundQIconButton(SoundQIcon.Back,"Back",{back()},Modifier.width(48.dp).fillMaxHeight(),outlined=false)
                Text("Catalog",Modifier.weight(1f).padding(start=8.dp).semantics {heading()},style=SoundQ.typography.title.copy(fontSize=20.sp,fontWeight=FontWeight.SemiBold),maxLines=1,overflow=TextOverflow.Ellipsis)
            };SoundQDivider()
        }
        val root=state.artist==null && state.group==null && state.album==null && state.operation !is CatalogRead.Artist && state.operation !is CatalogRead.Album
        state.membershipNotice?.takeIf {it!=state.inspection?.membership}?.let {notice->catalogHeader {Text(notice,style=SoundQ.typography.body)}}
        items(state.recoveries.filter {it.intent.recording!=state.inspection?.selection?.row?.id?.value},key={"membership:"+it.intent.operation}) {recovery ->
            Column(Modifier.padding(SoundQ.spacing.gutter)) {
                Text(recovery.intent.title,style=SoundQ.typography.title)
                Text(recovery.status,style=SoundQ.typography.body)
                SoundQButton("Check Library",{actions.checkMembership(recovery)},enabled=!recovery.busy,variant=SoundQButtonVariant.Secondary)
                if(recovery.retryEligible)SoundQButton("Retry Add",{actions.retryMembership(recovery)},enabled=!recovery.busy)
            }
        }
        if(root) {
            item {SoundQTabs(listOf("Artists","Albums on server"),if(albums)1 else 0,{albums=it==1;actions.edit(draft.text)})}
            catalogHeader {
                fun submit() {val submitted=draft.text;actions.submit(submitted,albums);draft=draft.copy(composition=null);focus.clearFocus()}
                Row(verticalAlignment=Alignment.Bottom) {
                    SoundQEntryField(draft,{val changed=it.text!=draft.text;draft=it;if(changed)actions.edit(it.text)},"Search catalog",modifier=Modifier.weight(1f),keyboardOptions=KeyboardOptions(imeAction=ImeAction.Search),keyboardActions=KeyboardActions(onSearch={submit()}))
                    SoundQIconButton(SoundQIcon.Search,"Submit catalog search",{submit()},modifier=Modifier.height(56.dp),enabled=!state.loading,outlined=false)
                    if(draft.text.isNotEmpty())SoundQIconButton(SoundQIcon.Close,"Clear catalog search",{draft=TextFieldValue("");actions.edit("")},modifier=Modifier.height(56.dp),outlined=false)
                }
                state.inputError?.let {SoundQFeedback(it,FeedbackKind.Error)}
            }
        }
        if(state.loading)catalogHeader {SoundQFeedback("Loading catalog",FeedbackKind.Loading)}
        else if(state.missing)catalogHeader {SoundQFeedback("Catalog item not found",FeedbackKind.Empty,action="Retry catalog",onAction={actions.retry(state)})}
        else if(state.error!=null)catalogHeader {SoundQFeedback("Could not load catalog",FeedbackKind.Error,state.error.message,"Retry catalog",{actions.retry(state)})}
        else if(state.group!=null)catalogHeader {
            Text(state.group.title,style=SoundQ.typography.title)
            SoundQFeedback("Edition unavailable",FeedbackKind.Notice,action="Search albums",onAction={actions.groupEditions(state)})
            Text("Release-group MusicBrainz ID: ${state.group.id.value}",style=SoundQ.typography.mono)
        }
        else if(state.album!=null) {
            val album=state.album
            item {Column(Modifier.padding(SoundQ.spacing.gutter)) {
                Text(album.title,style=SoundQ.typography.heading,modifier=Modifier.semantics {heading()})
                album.artist?.let {Text(it,style=SoundQ.typography.title)}
                album.date?.let {Text(it,style=SoundQ.typography.caption)}
                Text(album.trackCount?.let {"$it tracks reported"} ?: "Track total unavailable",style=SoundQ.typography.mono)
                if(album.tracks.isEmpty())SoundQFeedback("No tracks listed",FeedbackKind.Empty,"The server returned no track listing for this edition.")
            }}
            itemsIndexed(album.tracks,key={index,row->"${row.id.value}:$index"}) {index,row ->
                SoundQMediaRow(title=row.title,subtitle=row.artist ?: album.artist.orEmpty(),current=false,
                    onActivate={actions.recording(state,row,index)},onMore={actions.recording(state,row,index)},
                    supporting=listOfNotNull(row.position?.let {"Track $it"},duration(row.durationMs)).joinToString(" · "))
            }
        }
        else if(state.artist!=null) {
            val artist=state.artist
            catalogHeader {
                Text(artist.row.name,style=SoundQ.typography.heading,modifier=Modifier.semantics {heading()})
                Text(artist.row.description,style=SoundQ.typography.caption)
                Text("Release groups",style=SoundQ.typography.title)
                if(artist.releases.isEmpty())SoundQFeedback("No release groups listed",FeedbackKind.Empty)
            }
            items(artist.releases,key={it.id.value}) {row ->SoundQMediaRow(row.title,artist.row.name,false,{actions.group(state,row)},{actions.group(state,row)},supporting=listOfNotNull(row.date,"Release group").joinToString(" · "))}
        }
        else if(state.albums!=null) {
            val page=state.albums
            catalogHeader {Text("${page.total} albums on server",style=SoundQ.typography.mono);if(page.rows.isEmpty())SoundQFeedback("No matching albums",FeedbackKind.Empty)}
            items(page.rows,key={it.localId}) {row ->SoundQMediaRow(row.title,row.artist.orEmpty(),false,{actions.album(state,row)},{actions.album(state,row)},supporting=if(row.id==null)"No linked catalog edition" else "Catalog edition · ${row.trackCount} server tracks",enabled=row.id!=null)}
            if(page.offset+page.rows.size<page.total && page.rows.isNotEmpty())catalogHeader {SoundQButton("Next albums",{actions.search(true,page.offset+page.rows.size)})}
        }
        else if(state.search!=null) {
            val page=state.search
            catalogHeader {Text("${page.total} catalog artists",style=SoundQ.typography.mono);if(page.rows.isEmpty())SoundQFeedback("No matching artists",FeedbackKind.Empty)}
            items(page.rows,key={it.id.value}) {row ->SoundQMediaRow(row.name,row.description,false,{actions.artist(state,row)},{actions.artist(state,row)},supporting="MusicBrainz")}
            if(page.offset+page.rows.size<page.total && page.rows.isNotEmpty())catalogHeader {SoundQButton("Next artists",{actions.search(false,page.offset+page.rows.size)})}
        }
    }
    state.inspection?.let {inspection ->SoundQSheet("Recording details",{actions.dismissRecording(inspection)}) {
        val row=inspection.selection.row
        Text(row.title,style=SoundQ.typography.title)
        (row.artist ?: inspection.selection.album.artist)?.let {Text(it)}
        row.position?.let {Text("Track $it")}
        Text(duration(row.durationMs))
        when {
            inspection.membership!=null->Text(inspection.membership,style=SoundQ.typography.body)
            inspection.loading->SoundQFeedback("Checking Library",FeedbackKind.Loading)
            inspection.unavailable->SoundQFeedback("Library lookup unavailable",FeedbackKind.Notice,null,"Retry lookup",{actions.retryRecording(inspection)})
            inspection.error!=null->SoundQFeedback("Could not check Library",FeedbackKind.Error,null,"Retry lookup",{actions.retryRecording(inspection)})
            else->inspection.result?.let {result ->
                val status=when(result.status) {
                    "owned"->"In your Library"
                    "stored_unowned"->"Stored on server · Not in your Library"
                    "missing"->"No stored match"
                    "needs_review"->"Recording match needs review"
                    else->if(result.truncated)"Multiple matches · Results incomplete" else "Multiple recording matches"
                }
                Text(status,style=SoundQ.typography.body)
            }
        }
        if(inspection.membership=="Adding")SoundQButton("Add to Library",{},enabled=false)
        val result=inspection.result
        if(result?.status=="stored_unowned"&&!result.truncated&&result.candidates.singleOrNull()?.let {it.mbVerified&&!it.inLibrary&&it.trackId>0}==true&&inspection.membership==null&&state.recoveries.none {it.intent.recording==row.id.value}&&state.membershipNotice!="Recovery unavailable")
            SoundQButton("Add to Library",{actions.addRecording(inspection)},enabled=!inspection.loading)
        state.recoveries.singleOrNull {it.intent.recording==row.id.value}?.let {recovery ->
            SoundQButton("Check Library",{actions.checkMembership(recovery)},enabled=!recovery.busy,variant=SoundQButtonVariant.Secondary)
            if(recovery.retryEligible)SoundQButton("Retry Add",{actions.retryMembership(recovery)},enabled=!recovery.busy)
        }
        Text("Recording MusicBrainz ID: ${row.id.value}",style=SoundQ.typography.mono)
    }}
}
private fun duration(ms:Long?):String = if(ms==null || ms==0L)"Duration unavailable" else "${ms/60000}:${((ms/1000)%60).toString().padStart(2,'0')}"
