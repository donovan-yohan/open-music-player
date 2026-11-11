package com.soundq.android.product.mix

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.input.TextFieldValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.soundq.android.data.*
import com.soundq.android.data.mix.*
import com.soundq.android.product.ProductViewModel
import com.soundq.designsystem.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*

/** Route reads publish on main only while the captured route AND selection still own the result. */
@Composable fun MixScreen(model:ProductViewModel) {
    val library by model.library.collectAsStateWithLifecycle()
    val playback by model.playback.collectAsStateWithLifecycle()
    val scope=remember {model.graph.session.capture()}
    val route=remember {scope?.let(model.mixExchange::open)} ?: return
    val exchange by route.owner.state.collectAsStateWithLifecycle()
    val jobs=rememberCoroutineScope()
    val scroll=rememberLazyListState()
    var rows by remember {mutableStateOf<List<SavedMix>>(emptyList())}
    var selected by remember {mutableStateOf<SavedMix?>(null)}
    var title by remember {mutableStateOf("")}
    var busy by remember {mutableStateOf(false)}
    var message by remember {mutableStateOf<String?>(null)}
    var blockedWrite by remember {mutableStateOf(false)}
    var total by remember {mutableIntStateOf(0)}
    var exchangeWorking by remember {mutableStateOf(false)}
    var bindingRevision by remember {mutableIntStateOf(0)}
    val capture=remember(bindingRevision){route.capture()}
    val valid={route.current(capture)&&scope?.let(model.graph.session::remoteCurrent)==true}
    DisposableEffect(route){onDispose {route.close()}}
    fun writesAllowed()=!busy&&!blockedWrite&&!exchangeWorking&&!route.owner.snapshot().blocksOtherWrites&&!route.owner.snapshot().pending
    fun select(saved:SavedMix) {
        if(!route.select(capture,saved))return
        selected=saved;title=saved.name;bindingRevision++
    }
    fun upsert(saved:SavedMix) {rows=if(rows.any {it.id==saved.id})rows.map {if(it.id==saved.id)saved else it}else rows+saved}
    fun run(work:suspend ()->Unit) {
        if(!valid()||busy||exchangeWorking||route.owner.snapshot().pending)return
        busy=true;message=null
        jobs.launch {
            try {work()}
            catch(error:CancellationException){throw error}
            catch(_:Exception){if(valid())message="Could not confirm this request. Reload saved mixes before trying another save."}
            finally {if(valid())busy=false}
        }
    }
    fun load(append:Boolean=false) {run {
        val page=withContext(Dispatchers.IO){model.graph.api.mixPlans(scope!!,if(append)rows.size else 0,valid)}
        if(valid()){rows=(if(append)rows+page.rows else page.rows).distinctBy {it.id};total=page.total}
    }}
    LaunchedEffect(route){load()}

    val context=LocalContext.current
    val keyboard=LocalSoftwareKeyboardController.current
    val opener=remember {FocusRequester()}
    val selectionFocus=remember {FocusRequester()}
    val recoveryFocus=remember {FocusRequester()}
    val fieldFocus=remember {FocusRequester()}
    var focusTarget by remember {mutableStateOf<String?>(null)}
    var reloadAfterClose by remember {mutableStateOf(false)}
    var sheet by remember {mutableStateOf(false)}
    var sheetGeneration by remember {mutableLongStateOf(0)}
    var page by remember {mutableStateOf(MixExchangePage.Choose)}
    var draft by remember {mutableStateOf(TextFieldValue(route.owner.snapshot().input))}
    var fieldError by remember {mutableStateOf<String?>(null)}
    var copyMessage by remember {mutableStateOf<String?>(null)}
    var dismissTo by remember {mutableStateOf<MixExchangePage?>(null)}
    var confirmDismiss by remember {mutableStateOf(false)}
    var duplicateConfirmation by remember {mutableStateOf(false)}
    var restoreField by remember {mutableIntStateOf(0)}
    val uncertain=exchange.phase in setOf(ExchangePhase.UnknownCreate,ExchangePhase.ReadbackFailed)
    fun renewBinding() {copyMessage=null;if(route.select(capture,selected))bindingRevision++}
    fun closeSheet(target:String="opener") {
        sheet=false;sheetGeneration++;confirmDismiss=false;duplicateConfirmation=false
        renewBinding();focusTarget=target
    }
    fun openSheet(target:MixExchangePage=MixExchangePage.Choose) {
        if(!valid()||busy||exchangeWorking)return
        sheetGeneration++;page=target;sheet=true;copyMessage=null;fieldError=null
    }
    fun finishDismiss() {
        if(dismissTo==null)closeSheet() else {page=dismissTo!!;renewBinding();confirmDismiss=false}
    }
    fun requestDismiss(destination:MixExchangePage?):Boolean {
        if(!valid()||!sheet)return false
        if(exchangeWorking||route.owner.snapshot().pending)return false
        if(confirmDismiss||duplicateConfirmation)return false
        dismissTo=destination
        if(page==MixExchangePage.Import&&draft.text.isNotEmpty()) {confirmDismiss=true;return false}
        if(destination!=null){page=destination;renewBinding();return false}
        return true
    }
    fun exchangeRequest(recover:Boolean=false,export:Boolean=false) {
        if(!valid()||busy||exchangeWorking)return
        val state=capture.binding.snapshot()
        if(state.pending)return
        if(!recover&&!export) {
            if(!writesAllowed()||state.phase !in setOf(ExchangePhase.Editing,ExchangePhase.Refused))return
            if(draft.composition!=null) {fieldError="Finish composing before importing.";restoreField++;return}
            try {validateExchangeInput(draft.text)} catch(_:IllegalArgumentException) {
                fieldError=when {draft.text.isBlank()->"Enter mix JSON.";else->"Use valid Unicode metadata of 256 KiB or less."};restoreField++;return
            }
            if(!capture.binding.edit(draft.text))return
        }
        if(export&&state.blocksOtherWrites)return
        exchangeWorking=true;fieldError=null;copyMessage=null
        keyboard?.hide()
        val origin=capture;val sheetOrigin=sheetGeneration
        jobs.launch {
            try {
                val saved=withContext(Dispatchers.IO) {
                    if(export){origin.binding.loadExport();null}
                    else if(recover)origin.binding.recoverSaved() else origin.binding.importMix()
                }
                if(route.current(origin)&&sheet&&sheetGeneration==sheetOrigin&&saved!=null) {
                    exchangeWorking=false;upsert(saved);select(saved);route.capture().binding.edit("");blockedWrite=false;busy=false
                    sheet=false;sheetGeneration++;draft=TextFieldValue();message="Mix imported";focusTarget="selection"
                } else if(route.current(origin)&&!export&&origin.binding.snapshot().phase==ExchangePhase.Refused)restoreField++
            } finally {if(route.current(origin)||sheetGeneration==sheetOrigin)exchangeWorking=false}
        }
    }
    LaunchedEffect(restoreField) {
        if(restoreField>0&&sheet&&page==MixExchangePage.Import&&!confirmDismiss) {fieldFocus.requestFocus();keyboard?.show()}
    }
    LaunchedEffect(bindingRevision,reloadAfterClose) {if(reloadAfterClose){reloadAfterClose=false;load()}}
    LaunchedEffect(focusTarget,sheet) {
        val target=focusTarget
        if(target!=null&&!sheet) {
            val index=when(target){"selection"->rows.size+4+(if(rows.size<total)1 else 0);"recovery"->2;else->0}
            if(target!="opener")scroll.scrollToItem(index.coerceIn(0,(scroll.layoutInfo.totalItemsCount-1).coerceAtLeast(0)))
            withFrameNanos {}
            when(target){"selection"->selectionFocus.requestFocus();"recovery"->recoveryFocus.requestFocus();else->if(scroll.layoutInfo.visibleItemsInfo.any {it.index==0})opener.requestFocus()}
            focusTarget=null
        }
    }
    LazyColumn(Modifier.fillMaxSize(),state=scroll,contentPadding=PaddingValues(SoundQ.spacing.gutter),verticalArrangement=Arrangement.spacedBy(SoundQ.spacing.medium)) {
        item {Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically) {
            Text("Mixes",Modifier.weight(1f).semantics {heading()},style=SoundQ.typography.heading)
            SoundQIconButton(SoundQIcon.More,"Mix import and export",{openSheet()},Modifier.focusRequester(opener),enabled=!busy&&!exchangeWorking)
        }}
        item {
            if(busy)SoundQFeedback("Loading mix",FeedbackKind.Loading)
            message?.let {SoundQFeedback(it,if(it=="Mix imported")FeedbackKind.Notice else FeedbackKind.Error)}
        }
        item {
            if(uncertain||exchange.priorUnconfirmed) {
                Text("Import not confirmed",Modifier.focusRequester(recoveryFocus).focusable().semantics {heading()},style=SoundQ.typography.title)
                Text("The previous import may already exist.",style=SoundQ.typography.caption)
                SoundQButton("Return to import",{openSheet(MixExchangePage.Import)},enabled=!busy&&!exchangeWorking,variant=SoundQButtonVariant.Secondary)
            }
        }
        item {SoundQButton("Reload saved mixes",{load()},enabled=!busy&&!exchangeWorking&&!exchange.pending,variant=SoundQButtonVariant.Secondary)}
        if(rows.isEmpty()&&!busy)item {Text("No saved mixes",style=SoundQ.typography.title)}
        items(rows,key={it.id}) {row ->
            SoundQRow(row.name,"${row.clips.size} clips",selected?.id==row.id,{
                run {
                    val fresh=withContext(Dispatchers.IO){model.graph.api.mixPlan(scope!!,row.id,valid)}
                    if(valid()){select(fresh);blockedWrite=false;busy=false}
                }
            },enabled=!busy&&!exchangeWorking&&!exchange.pending)
        }
        if(rows.size<total)item {SoundQButton("Load more mixes",{load(true)},enabled=!busy&&!exchangeWorking&&!exchange.pending)}
        val plan=selected
        if(plan!=null) {
            item {Text("Saved mix",Modifier.focusRequester(selectionFocus).focusable().semantics {heading()},style=SoundQ.typography.title);SoundQTextField(title,{title=it},"Mix name",enabled=!busy&&!exchangeWorking&&!exchange.pending)}
            item {SoundQButton("Save mix",{
                if(selected===plan && valid() && writesAllowed()) {
                    blockedWrite=true
                    run {
                        val saved=withContext(Dispatchers.IO){model.graph.api.saveMix(scope!!,plan,title,plan.clips,valid)}
                        if(valid()){select(saved);upsert(saved);blockedWrite=false;busy=false}
                    }
                }
            },enabled=writesAllowed()&&title.isNotBlank())}
            item {SoundQButton("Play downloaded mix",{
                if(selected===plan && !busy && !exchangeWorking && valid()) {busy=true;model.controller.playMix(plan){accepted->if(valid()){busy=false;if(!accepted)message="Mix could not be started. Reload the saved version and check device downloads."}}}
            },enabled=!busy&&!exchangeWorking&&!exchange.pending&&plan.playable()&&playback.canPlayMix)
                if(!playback.canPlayMix)Text("Mix playback is not available in this build.",style=SoundQ.typography.caption)
                else if(!plan.playable())Text("This mix needs a playback capability not available here yet.",style=SoundQ.typography.caption)
                else Text("Uses downloaded stereo Opus sources and verified prepared stems.",style=SoundQ.typography.caption)}
            items(plan.clips,key={it.id}) {clip ->Text("Track ${clip.track} · ${clip.sourceStart}–${clip.sourceEnd} ms · starts ${clip.start} ms",style=SoundQ.typography.mono)}
        }
        item {SoundQButton("New mix from loaded library",{
            val tracks=library.rows
            if(valid()&&writesAllowed()&&model.library.value.rows===tracks&&tracks.isNotEmpty()&&tracks.all {it.durationMs>0}) {
                var at=0L
                val clips=tracks.map {track ->
                    val c=MixJson.clip(buildJsonObject {put("clipId",java.util.UUID.randomUUID().toString());put("queueItemId",java.util.UUID.randomUUID().toString());put("trackId",track.id.value);put("sourceStartMs",0);put("sourceEndMs",track.durationMs);put("timelineStartMs",at);put("gainDb",0);put("tempoPolicy","volumeOnly");put("pitchMode","preserve")})
                    at=Math.addExact(at,track.durationMs);c
                }
                blockedWrite=true
                run {
                    val saved=withContext(Dispatchers.IO){model.graph.api.saveMix(scope!!,null,"New mix",clips,valid)}
                    if(valid()){select(saved);upsert(saved);blockedWrite=false;busy=false}
                }
            }
        },enabled=writesAllowed()&&library.rows.isNotEmpty()&&library.rows.all {it.durationMs>0},variant=SoundQButtonVariant.Secondary)}
    }
    if(sheet) {
        val sheetTitle=when(page){MixExchangePage.Choose->"Mix import and export";MixExchangePage.Import->"Import mix";MixExchangePage.Export->"Export saved mix"}
        val callbackGeneration=sheetGeneration
        SoundQSheet(sheetTitle,onDismiss={closeSheet()},dismissAdmission={requestDismiss(null)}) {
            BackHandler {
                if(duplicateConfirmation)duplicateConfirmation=false
                else if(confirmDismiss){confirmDismiss=false;restoreField++}
                else if(requestDismiss(if(page==MixExchangePage.Choose)null else MixExchangePage.Choose))closeSheet()
            }
            if(confirmDismiss) {
                Text("Discard changes?",style=SoundQ.typography.title)
                SoundQButton("Keep editing",{confirmDismiss=false;restoreField++})
                SoundQButton("Discard",{
                    // Discarding text is not evidence of rollback. The owner preserves uncertainty.
                    if(!uncertain&&capture.binding.edit(""))draft=TextFieldValue()
                    finishDismiss()
                },variant=SoundQButtonVariant.Secondary)
            } else if(duplicateConfirmation) {
                Text("The previous import may already exist. Importing again can create another saved mix.")
                SoundQButton("Keep checking",{duplicateConfirmation=false},variant=SoundQButtonVariant.Secondary)
                SoundQButton("Import again",{if(valid()&&capture.binding.startAnotherImport(true)){duplicateConfirmation=false;restoreField++}})
            } else {
                MixExchangeContent(page,draft,{value ->
                    if(valid()&&sheetGeneration==callbackGeneration) {
                        // Native caret/composition publications do not edit the attempt or clear its feedback.
                        if(value.text==draft.text)draft=value
                        else if(!exchangeWorking&&capture.binding.edit(value.text)){draft=value;fieldError=null}
                    }
                },savedName=selected?.name,exportText=exchange.exportText,busy=exchangeWorking||exchange.pending,
                    canImport=writesAllowed()&&exchange.phase in setOf(ExchangePhase.Editing,ExchangePhase.Refused)&&draft.text.isNotBlank(),
                    fieldError=fieldError,fieldFocus=fieldFocus,canChooseImport=!busy&&!blockedWrite,
                    canChooseExport=!busy&&!exchange.blocksOtherWrites,importReadOnly=uncertain,
                    onChooseImport={if(valid()&&!busy&&!blockedWrite&&!exchangeWorking&&!route.owner.snapshot().pending){page=MixExchangePage.Import}},
                    onChooseExport={if(valid()&&selected!=null&&!busy&&!exchangeWorking&&!route.owner.snapshot().pending&&!route.owner.snapshot().blocksOtherWrites){page=MixExchangePage.Export;exchangeRequest(export=true)}},
                    onBack={requestDismiss(MixExchangePage.Choose)},onImport={exchangeRequest()},
                    onCopy={
                        if(valid()&&sheet&&sheetGeneration==callbackGeneration) {
                            val copied=capture.binding.copyExport {raw ->
                                val clipboard=context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                clipboard.setPrimaryClip(ClipData.newPlainText("Mix JSON",raw))
                            }
                            copyMessage=if(copied)"Mix JSON copied" else "Could not copy mix JSON"
                        }
                    },feedback={
                        MixExchangeFeedback(exchange)
                        copyMessage?.let {SoundQFeedback(it,FeedbackKind.Notice)}
                        if(exchange.phase==ExchangePhase.ExportFailed)SoundQButton("Reload export",{exchangeRequest(export=true)},enabled=!exchangeWorking)
                        if(uncertain) {
                            if(exchange.phase==ExchangePhase.ReadbackFailed)SoundQButton("Reload saved version",{exchangeRequest(recover=true)},enabled=!exchangeWorking)
                            SoundQButton("Reload saved mixes",{closeSheet("recovery");reloadAfterClose=true},enabled=!busy&&!exchangeWorking,variant=SoundQButtonVariant.Secondary)
                            SoundQButton("Start another import",{duplicateConfirmation=true},enabled=!busy&&!exchangeWorking,variant=SoundQButtonVariant.Secondary)
                        }
                    })
            }
        }
    }
}

/** Never disclose server bodies, source hashes, parser text or arbitrary exception messages. */
@Composable private fun MixExchangeFeedback(state:ExchangeState) {
    when(state.phase) {
        ExchangePhase.ImportPending->SoundQFeedback("Importing mix…",FeedbackKind.Loading)
        ExchangePhase.Checking->SoundQFeedback("Checking saved mix…",FeedbackKind.Loading)
        ExchangePhase.ExportLoading->SoundQFeedback("Loading saved mix metadata…",FeedbackKind.Loading)
        ExchangePhase.UnknownCreate->SoundQFeedback("Import not confirmed",FeedbackKind.Error,"It may have been saved. Reload saved mixes before starting another import.")
        ExchangePhase.ReadbackFailed->SoundQFeedback("Saved mix could not be verified",FeedbackKind.Error,"The import may be saved, but its readback was not confirmed.")
        ExchangePhase.Refused->when(state.refusal) {
            ExchangeRefusal.Code.MISSING_SOURCES->SoundQFeedback("Matching audio is missing",FeedbackKind.Error,"Add the matching audio to your library before importing.")
            ExchangeRefusal.Code.AMBIGUOUS_SOURCE->SoundQFeedback("More than one library track matches a required source.",FeedbackKind.Error)
            ExchangeRefusal.Code.SOURCE_MISMATCH->SoundQFeedback("A matching source does not fit the mix’s authored audio window.",FeedbackKind.Error)
            else->SoundQFeedback("Mix metadata was not accepted.",FeedbackKind.Error)
        }
        ExchangePhase.ExportFailed->SoundQFeedback(if(state.refusal==ExchangeRefusal.Code.UNSUPPORTED_METADATA)"This saved mix cannot be exported without losing metadata." else "Could not load saved mix metadata",FeedbackKind.Error)
        ExchangePhase.ExportReady->SoundQFeedback("Mix JSON ready",FeedbackKind.Notice)
        ExchangePhase.Retired->SoundQFeedback("This exchange is no longer available",FeedbackKind.Notice)
        ExchangePhase.Confirmed,ExchangePhase.Editing->Unit
    }
    if(state.priorUnconfirmed)SoundQFeedback("Previous import not confirmed",FeedbackKind.Notice,"The previous import may already exist.")
}
