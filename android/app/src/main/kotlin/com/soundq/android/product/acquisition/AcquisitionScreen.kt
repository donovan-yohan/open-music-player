package com.soundq.android.product.acquisition

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.soundq.android.data.acquisition.*
import com.soundq.android.data.imports.ImportJobId
import com.soundq.android.product.ProductViewModel
import com.soundq.designsystem.*

/** Independently mounted server acquisition surface, never the listening queue. */
@Composable fun AcquisitionScreen(model:ProductViewModel,onClose:()->Unit,onImports:()->Unit,onInspectImport:(ImportJobId)->Unit,onOpenPlaylist:(ImportJobId,Long)->Unit={_,_->},resumePlaylist:ImportJobId?=null) {
    val repo=model.graph.acquisition
    val scope=model.graph.session.version()
    val view=remember(model,scope){repo.open()}
    DisposableEffect(view){onDispose {view?.let(repo::close)}}
    val state by repo.state.collectAsStateWithLifecycle()
    LaunchedEffect(view,resumePlaylist){view?.let {repo.refreshReceipts(it);model.acquire(if(resumePlaylist!=null)repo.loadPlaylist(it,resumePlaylist)else repo.loadQueue(it))}}
    LaunchedEffect(view,state.playlist?.id,state.playlist?.status) {
        val mounted=view ?: return@LaunchedEffect
        val id=state.playlist?.id ?: return@LaunchedEffect
        if(state.playlist?.status !in setOf("resolving","importing"))return@LaunchedEffect
        while(repo.current(mounted)) {
            kotlinx.coroutines.delay(3000)
            val work=repo.loadPlaylist(mounted,id) ?: continue
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO){work()}
        }
    }
    LaunchedEffect(view,state.research?.id,state.research?.status) {
        val mounted=view ?: return@LaunchedEffect
        val id=state.research?.id ?: return@LaunchedEffect
        if(state.research?.active!=true)return@LaunchedEffect
        while(repo.current(mounted)) {
            kotlinx.coroutines.delay(3000)
            val work=repo.loadResearch(mounted,id) ?: continue
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO){work()}
        }
    }
    var tab by rememberSaveable {mutableStateOf(if(resumePlaylist!=null)1 else 0)}
    var url by rememberSaveable {mutableStateOf("")};var name by rememberSaveable {mutableStateOf("")};var limit by rememberSaveable {mutableStateOf("500")}
    var description by rememberSaveable {mutableStateOf("")}
    var query by remember {mutableStateOf("")};var overrideReason by remember {mutableStateOf("")}
    var clear by remember(view) {mutableStateOf<ServerImportQueue?>(null)}
    var jobActions by remember(view) {mutableStateOf<Pair<ServerImportQueue,ServerImportItem>?>(null)}
    var receiptDetails by remember(view) {mutableStateOf<IntakeReceipt?>(null)}
    var invalid by remember {mutableStateOf(false)}
    LazyColumn(Modifier.fillMaxSize().testTag("acquisition-list"),contentPadding=PaddingValues(0.dp)) {
        acquisitionBand {Row {Text("Server imports",Modifier.weight(1f),style=SoundQ.typography.heading);SoundQIconButton(SoundQIcon.Close,"Close server imports",onClose,outlined=false)}}
        acquisitionBand {SoundQButton("Import from link",onImports,variant=SoundQButtonVariant.Secondary)}
        item {SoundQTabs(listOf("Jobs","YouTube playlist","Research"),tab,{tab=it})}
        if(state.busy)acquisitionBand {SoundQFeedback("Checking import",FeedbackKind.Loading)}
        state.error?.let {acquisitionBand {SoundQFeedback(if(state.uncertain)"Import not confirmed" else "Import unavailable",FeedbackKind.Error,it.message)}}
        if(state.uncertain)acquisitionBand {Text("Check the original import before trying again.")}
        if(tab==0) {
            acquisitionBand {Row {Text("Import jobs",Modifier.weight(1f),style=SoundQ.typography.title);SoundQIconButton(SoundQIcon.Retry,"Refresh server queue",{view?.let {model.acquire(repo.loadQueue(it))}},enabled=!state.busy,outlined=false)}}
            state.queue?.let {snapshot->
                if(snapshot.items.isEmpty())acquisitionBand {SoundQFeedback("No imports queued",FeedbackKind.Empty)}
                items(snapshot.items,key={it.id}) {row->
                    SoundQRow(row.title,"${row.status.replace('_',' ')} · ${row.progress}%",false,{jobActions=snapshot to row},trailing={SoundQIconButton(SoundQIcon.More,"Import actions for ${row.title}",{jobActions=snapshot to row},outlined=false)})
                }
                if(snapshot.items.isNotEmpty())acquisitionBand {SoundQButton("Clear server queue",{clear=snapshot},enabled=!state.busy&&!state.uncertain,variant=SoundQButtonVariant.Secondary)}
            }
            acquisitionBand {Row {Text("Recent imports",Modifier.weight(1f),style=SoundQ.typography.title);SoundQIconButton(SoundQIcon.Retry,"Reload receipts",{view?.let(repo::refreshReceipts)},enabled=!state.busy,outlined=false)}}
            items(state.receipts.asReversed(),key={it.operation}) {receipt->
                SoundQRow(if(receipt.phase in setOf("pending","uncertain"))"Import not confirmed" else if(receipt.phase=="refused")"Import refused" else "Saved import",when(receipt.kind){"playlist"->"Playlist import";"research","review"->"Research";else->"Source import"},false,{receiptDetails=receipt})
            }
        }
        if(tab==1) {
            item {PlaylistImportBand {Text("Import a YouTube playlist",style=SoundQ.typography.title);Text("Creates a server playlist and imports its available entries. Unavailable and duplicate entries remain visible in progress.")}}
            item {PlaylistImportBand {SoundQTextField(url,{url=it;invalid=false},"YouTube playlist URL",enabled=!state.busy)}}
            item {PlaylistImportBand {SoundQTextField(name,{name=it;invalid=false},"New playlist name (optional)",enabled=!state.busy)}}
            item {PlaylistImportBand {SoundQTextField(description,{description=it;invalid=false},"Playlist description (optional)",enabled=!state.busy)}}
            item {PlaylistImportBand {SoundQTextField(limit,{limit=it;invalid=false},"Maximum items (1–1000)",enabled=!state.busy)}}
            item {PlaylistImportBand {SoundQButton("Import playlist",{val action=view?.let {repo.startPlaylist(it,url,name,limit.toIntOrNull() ?: 0,description)};invalid=action==null;model.acquire(action)},enabled=!state.busy&&!state.uncertain)}}
            if(invalid)item {PlaylistImportBand {SoundQFeedback("Check playlist input",FeedbackKind.Error,"Use a YouTube HTTPS playlist link with a list ID, a name up to 200 characters, a description up to 5000 characters and a limit from 1 to 1000.")}}
            state.playlist?.let {progress->
                item {PlaylistImportBand {
                    Text(progress.sourceTitle?.takeIf {it.isNotBlank()} ?: "Playlist import",style=SoundQ.typography.title)
                    Text(when(progress.status){"resolving"->"Reading playlist";"importing"->"Importing entries";"complete"->"Import complete";"partial_failure"->"Import finished with some failures";"cancelled"->"Import cancelled";else->"Import failed"},Modifier.testTag("playlist-import-state"))
                    Text("${progress.imported} imported · ${progress.queued} queued · ${progress.failed} failed · ${progress.skipped} duplicates skipped · ${progress.total} total")

                    progress.error?.let {Text(it)}
                    FlowRow(horizontalArrangement=Arrangement.spacedBy(SoundQ.spacing.small)) {
                        SoundQIconButton(SoundQIcon.Retry,"Check playlist progress",{view?.let {model.acquire(repo.loadPlaylist(it,progress.id))}},enabled=!state.busy,outlined=false)
                        if(progress.imported>0)SoundQButton("Open playlist",{view?.let {repo.openPlaylist(it,progress){id->onOpenPlaylist(progress.id,id)}}},enabled=!state.busy,variant=SoundQButtonVariant.Secondary)
                    }
                }}
                items(progress.items,key={it.id}) {row->PlaylistImportBand {Text("${row.title} · ${row.status}");row.error?.let {Text(it,style=SoundQ.typography.caption)}}}
                item {PlaylistImportBand {SoundQButton("View individual imports",onImports,variant=SoundQButtonVariant.Secondary)}}
            }
        }
        if(tab==2) {
            acquisitionBand {Text("Opt-in research",style=SoundQ.typography.title);Text("Sends your query and source candidates to the server's configured model and may use its research budget. Review saves a decision, not an import.")}
            acquisitionBand {SoundQTextField(query,{query=it},"Research query",enabled=!state.busy)}
            acquisitionBand {Row {Checkbox(state.consent,{value->view?.let {repo.consent(it,value)}},enabled=!state.busy);Text("I consent to model-assisted research for this request.",Modifier.weight(1f))}}
            acquisitionBand {SoundQButton("Start research",{view?.let {model.acquire(repo.startResearch(it,query))}},enabled=state.consent&&query.isNotBlank()&&query.toByteArray().size<=512&&!state.busy&&!state.uncertain)}
            state.research?.let {progress->
                acquisitionBand {
                    Text("${progress.status} · revision ${progress.revision} · ${progress.stage}",style=SoundQ.typography.title)
                    progress.degradation?.let {Text(when(it){"model_disabled"->"Research model is disabled. Baseline results are still available.";"budget_exhausted"->"Research budget exhausted. No automatic retry.";"safety_rejected"->"The server refused this research for safety.";else->"Research degraded: ${it.replace('_',' ')}"})}
                    SoundQButton("Load research events",{view?.let {model.acquire(repo.loadEvents(it,progress))}},enabled=!state.busy,variant=SoundQButtonVariant.Secondary)
                    SoundQButton("Refresh research",{view?.let {model.acquire(repo.loadResearch(it,progress.id))}},enabled=!state.busy)
                    if(progress.active&&progress.status!="cancel_requested")SoundQButton("Cancel research",{view?.let {model.acquire(repo.mutateResearch(it,progress,"cancel"))}},enabled=!state.busy&&!state.uncertain,variant=SoundQButtonVariant.Secondary)
                    if(progress.canRetry)SoundQButton("Retry research with consent",{view?.let {model.acquire(repo.mutateResearch(it,progress,"retry"))}},enabled=state.consent&&!state.busy&&!state.uncertain,variant=SoundQButtonVariant.Secondary)
                }
                items(state.events,key={"event:${it.sequence}"}) {event->PlaylistImportBand {Text("${event.sequence} · ${event.kind.replace('_',' ')}",style=SoundQ.typography.caption)}}
                acquisitionBand {SoundQTextField(overrideReason,{overrideReason=it},"Reason for overriding recommendation",enabled=!state.busy)}
                items(progress.candidates,key={it.id}) {row->
                    PlaylistImportBand {
                    Text(row.title,style=SoundQ.typography.title);Text(row.provider.label)
                    androidx.compose.foundation.text.selection.SelectionContainer {Text(row.source.url,style=SoundQ.typography.mono)}
                    FlowRow(horizontalArrangement=Arrangement.spacedBy(SoundQ.spacing.small)) {
                        SoundQButton("Accept source review",{view?.let {model.acquire(repo.review(it,progress,row,"accepted"))}},enabled=row.id==progress.recommended&&!state.busy&&!state.uncertain)
                        SoundQButton("Override recommendation",{view?.let {model.acquire(repo.review(it,progress,row,"overridden",overrideReason))}},enabled=overrideReason.isNotBlank()&&overrideReason.toByteArray().size<=512&&!state.busy&&!state.uncertain,variant=SoundQButtonVariant.Secondary)
                    }
                    }
                }
            }
            state.review?.let {review->acquisitionBand {
                    SoundQFeedback("Review saved",FeedbackKind.Notice,"No import or playback was started.")
                    SoundQButton("Import reviewed source",{view?.let {model.acquire(repo.importReviewed(it,review))}},enabled=state.reviewedImport==null&&!state.busy&&!state.uncertain)
                    state.reviewedImport?.let {Text("Import job ${it.id.value}");SoundQButton("Check in Imports",{onInspectImport(it.id)},variant=SoundQButtonVariant.Secondary)}
                }}
        }
    }
    jobActions?.let {(snapshot,row)->SoundQSheet("Import actions",{jobActions=null}) {
        Text(row.title,style=SoundQ.typography.title);Text("${row.status.replace('_',' ')} · ${row.progress}%")
        Row {
            fun action(operation:String,position:Int?=null){jobActions=null;view?.let {model.acquire(repo.manageQueue(it,snapshot,operation,row,position))}}
            if(row.retry)SoundQIconButton(SoundQIcon.Retry,"Retry import",{action("retry")},enabled=!state.busy&&!state.uncertain,outlined=false)
            if(row.remove)SoundQIconButton(SoundQIcon.Trash,"Remove from server queue",{action("remove")},enabled=!state.busy&&!state.uncertain,outlined=false)
            if(row.position>0)SoundQIconButton(SoundQIcon.Up,"Move earlier",{action("reorder",row.position-1)},enabled=!state.busy&&!state.uncertain,outlined=false)
            if(row.position<snapshot.items.lastIndex)SoundQIconButton(SoundQIcon.Down,"Move later",{action("reorder",row.position+1)},enabled=!state.busy&&!state.uncertain,outlined=false)
        }
    }}
    receiptDetails?.let {receipt->SoundQSheet("Import details",{receiptDetails=null}) {
        androidx.compose.foundation.text.selection.SelectionContainer {Text("Request ${receipt.operation}\n${receipt.kind} · ${receipt.phase}\n${receipt.job.orEmpty()}\n${receipt.decisionId.orEmpty()}",style=SoundQ.typography.mono)}
        if(receipt.kind=="review"&&receipt.phase=="accepted"&&receipt.decisionId!=null)SoundQButton("Restore saved research review",{receiptDetails=null;tab=2;view?.let {repo.restoreReview(it,receipt)}},enabled=!state.busy)
        receipt.job?.let {job->
            if(receipt.kind in setOf("download","source","queue"))SoundQButton("Check import",{receiptDetails=null;onInspectImport(ImportJobId(job))},enabled=!state.busy)
            if(receipt.kind=="playlist")SoundQButton("Check playlist import",{receiptDetails=null;tab=1;view?.let {model.acquire(repo.loadPlaylist(it,ImportJobId(job)))}},enabled=!state.busy)
            if(receipt.kind=="research")SoundQButton("Check research",{receiptDetails=null;tab=2;view?.let {model.acquire(repo.loadResearch(it,ImportJobId(job)))}},enabled=!state.busy)
        }
        if(receipt.job==null&&receipt.kind in setOf("download","source"))SoundQButton("Check import",{receiptDetails=null;onImports()},enabled=!state.busy)
    }}
    clear?.let {snapshot->SoundQSheet("Clear server queue?",{clear=null}) {
        Text("Removes these server queue entries. It does not cancel already running downloads, delete Library tracks or change your listening queue.")
        SoundQButton("Clear server queue",{clear=null;view?.let {model.acquire(repo.manageQueue(it,snapshot,"clear"))}},enabled=!state.busy)
        SoundQButton("Keep imports",{clear=null},variant=SoundQButtonVariant.Secondary)
    }}
}

private fun LazyListScope.acquisitionBand(content:@Composable ColumnScope.()->Unit)=item {PlaylistImportBand(content)}

@Composable private fun PlaylistImportBand(content:@Composable ColumnScope.()->Unit) {
    Column(Modifier.fillMaxWidth().padding(SoundQ.spacing.gutter),verticalArrangement=Arrangement.spacedBy(SoundQ.spacing.small),content=content)
    SoundQDivider()
}
