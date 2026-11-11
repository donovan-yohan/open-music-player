package com.soundq.android.product.playlists

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.*
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.input.*
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.soundq.android.data.harmonic.*
import com.soundq.android.data.playlists.*
import com.soundq.android.product.ProductViewModel
import com.soundq.designsystem.*

private class HarmonicSelection {
    private var selected by mutableStateOf<HarmonicResultCapture?>(null)
    private var epoch by mutableLongStateOf(0)
    fun replace(value:HarmonicResultCapture?) {epoch++;selected=value}
    fun capture(value:HarmonicResultCapture):()->Boolean {val version=epoch;return {selected===value&&epoch==version}}
    val value get()=selected
}

/** One modal host; lazy header entry never owns the modal or its capabilities. */
@Composable fun HarmonicPlaylist(model:ProductViewModel,actions:PlaylistManagementActions?,content:@Composable (@Composable (()->Boolean)->Unit,@Composable ()->Unit)->Unit) {
    val owner=model.graph.harmonic
    // Sheet content composes separately. Capture the same publication used to prepare focus holders.
    val state=owner.state.collectAsStateWithLifecycle().value
    val dj=model.graph.djModePreferences.state.collectAsStateWithLifecycle().value
    val detail=model.playlistDetail.collectAsStateWithLifecycle().value
    var route by remember {mutableStateOf<HarmonicRoute?>(null)}
    val selectionOwner=remember {HarmonicSelection()}
    val selected=selectionOwner.value
    var refusal by remember {mutableStateOf<String?>(null)}
    var queueNotice by remember {mutableStateOf<String?>(null)}
    val queryScroll=rememberScrollState()
    val actionScroll=rememberScrollState()
    val opener=remember {FocusRequester()}
    var restore by remember {mutableStateOf(false)}

    var fields by remember {mutableStateOf<HarmonicFields?>(null)}
    val resultFocus=remember(state.result){state.result?.tracks?.map {FocusRequester()}?:emptyList()}
    var returnFocus by remember {mutableStateOf<FocusRequester?>(null)}
    LaunchedEffect(selected) {if(selected==null){withFrameNanos {};returnFocus?.let {runCatching {it.requestFocus()}};returnFocus=null}}
    fun dismiss() {route?.let(owner::close);route=null;selectionOwner.replace(null);refusal=null;restore=true}
    DisposableEffect(owner) {onDispose {owner.retire()}}
    LaunchedEffect(dj.revision,detail.detail,detail.id) {route?.let {if(!owner.owns(it)){dismiss();owner.retire()}}}
    LaunchedEffect(restore,state.open) {if(restore&&!state.open&&model.graph.djModePreferences.enabled()){withFrameNanos {};runCatching {opener.requestFocus()};restore=false}}
    val entryDetail=detail.detail
    val entryVersion=model.graph.playlistDetail.managementVersion()
    val entryDj=dj.revision
    content({admitOpen->
        if(dj.ready&&model.graph.djModePreferences.enabled()&&detail.detail!=null&&!detail.loading&&detail.error==null) {
            SoundQIconButton(SoundQIcon.Search,"Find harmonic matches",{
                val entryCurrent=model.graph.playlistDetail.managementDetail()===entryDetail&&model.graph.playlistDetail.managementVersion()==entryVersion&&model.graph.djModePreferences.state.value.revision==entryDj
                val opened=if(entryCurrent&&admitOpen())owner.open()else null
                if(opened!=null){if(fields?.draft()!=owner.state.value.draft)fields=HarmonicFields(owner.state.value.draft);route=opened;selectionOwner.replace(null);refusal=null;queueNotice=null;model.harmonicWork(owner.initial(opened))}
            },Modifier.focusRequester(opener).width(SoundQ.sizes.target).fillMaxHeight(),outlined=false)
        }
    },{
        queueNotice?.let {notice->Column(Modifier.fillMaxWidth().padding(horizontal=SoundQ.spacing.gutter,vertical=SoundQ.spacing.small)) {SoundQFeedback(notice,FeedbackKind.Notice)}}
    })
    val current=route?:return
    if(!state.open)return
    val selection=selected
    val sheetAlive=remember(current){java.util.concurrent.atomic.AtomicBoolean(true)}
    DisposableEffect(sheetAlive){onDispose {sheetAlive.set(false)}}
    val panelAlive=remember(current,selection){java.util.concurrent.atomic.AtomicBoolean(true)}
    DisposableEffect(panelAlive){onDispose {panelAlive.set(false)}}
    val selectedAtBinding=selection?.let(selectionOwner::capture)
    fun back() {if(panelAlive.get()&&selectedAtBinding?.invoke()==true){selectionOwner.replace(null);refusal=null}}
    fun closeSheet(){if(sheetAlive.get()&&route===current)dismiss()}
    SoundQSheet(if(selection==null)"Harmonic matches" else selection.row.title,::closeSheet,
        scrollState=if(selection==null)queryScroll else actionScroll,onEscape={if(selection!=null)back()else closeSheet()}) {
        // Dialog-window Back takes precedence over the detail route's Back handler.
        androidx.activity.compose.BackHandler {if(selection!=null)back()else closeSheet()}
        if(selection==null) {
            fields?.let {HarmonicQueryPanel(state,it,{if(panelAlive.get())owner.edit(current,it)},{if(panelAlive.get())model.harmonicWork(owner.search(current))})}
            Text("Playlist: ${detail.detail?.playlist?.name?:"Playlist"}",style=SoundQ.typography.caption)
            state.result?.let {result->
                if(result.orderedByHistory)Text("Ordered by your listening history",style=SoundQ.typography.caption)
                Text("${result.tracks.size} matches",Modifier.semantics {liveRegion=LiveRegionMode.Polite},style=SoundQ.typography.caption)
                if(result.tracks.isEmpty())SoundQFeedback("No harmonic matches in your library yet.",FeedbackKind.Empty,"Try a wider tempo range, or analyze more tracks.")
                result.tracks.forEachIndexed {index,row->
                    val captured=owner.capture(current,index,row)
                    val focus=resultFocus[index]
                    fun select(){if(panelAlive.get()&&captured!=null&&owner.current(captured)){returnFocus=focus;selectionOwner.replace(captured);refusal=null}}
                    SoundQMediaRow(row.title,row.artist?:"Unknown artist",false,::select,::select,enabled=captured!=null,
                        modifier=Modifier.focusRequester(focus),supporting=listOfNotNull(row.bpm?.let {"$it BPM"},row.camelot).joinToString(" · "))
                }
            }
        } else {
            val selectionCurrent=selectionOwner.capture(selection)
            val selectedNow={selectionCurrent()&&owner.current(selection)}
            SoundQButton("Back",::back,variant=SoundQButtonVariant.Quiet)
            Text(selection.row.artist?:"Unknown artist",style=SoundQ.typography.caption)
            Text("Playlist: ${detail.detail?.playlist?.name?:"Playlist"}",style=SoundQ.typography.caption)
            refusal?.let {SoundQFeedback(it,FeedbackKind.Error)}
            val queueable=owner.queueTrack(selection)!=null
            SoundQRow("Add to queue","Manual queue insertion · playback stays unchanged",false,{
                if(!queueable)refusal="Could not add this track to queue: its length is unknown."
                else if(model.harmonicQueue(selection,selectedNow)){selectionOwner.replace(null);queueNotice="Queue request sent — check your listening queue.";restore=true}
                else refusal="Could not add this track to queue. Check the listening queue and try again."
            },leading={SoundQIcon(SoundQIcon.AddQueue,null)},enabled=owner.current(selection))
            if(!queueable)Text("Could not add this track to queue: its length is unknown.",style=SoundQ.typography.caption)
            val target=actions?.capture()
            SoundQRow("Add to this playlist",detail.detail?.playlist?.name?:"Playlist",false,{
                val work=target?.let {owner.membership(selection,it,model.graph.playlistManagement,selectedNow)}
                if(work!=null){selectionOwner.replace(null);restore=true;model.harmonicWork(work)}else refusal="This playlist change is not available. Check playlist state before trying again."
            },leading={SoundQIcon(SoundQIcon.Plus,null)},enabled=target!=null&&owner.current(selection))
            if(target==null)Text("Playlist changes are unavailable while another change needs checking, or this playlist is not privately owned.",style=SoundQ.typography.caption)
        }
    }
}

private class HarmonicFields(initial:HarmonicDraft) {
    var bpm by mutableStateOf(TextFieldValue(initial.bpm))
    var camelot by mutableStateOf(TextFieldValue(initial.camelot))
    var tolerance by mutableStateOf(TextFieldValue(initial.tolerance))
    var history by mutableStateOf(initial.history)
    fun draft()=HarmonicDraft(bpm.text,camelot.text,tolerance.text,history)
}
@Composable private fun HarmonicQueryPanel(state:HarmonicState,fields:HarmonicFields,onEdit:(HarmonicDraft)->Unit,onSearch:()->Unit) {
    var bpm by fields::bpm
    var camelot by fields::camelot
    var tolerance by fields::tolerance
    val focus=LocalFocusManager.current
    val valid=state.draft.query()!=null
    fun submit(){if(valid&&!state.loading)onSearch()}
    Text("Tracks in your library that mix well from this tempo and key.",style=SoundQ.typography.caption)
    SoundQEntryField(bpm,{bpm=it;onEdit(fields.draft())},"BPM",enabled=!state.loading,
        error=if(bpm.text.isNotBlank()&&bpm.text.trim().toDoubleOrNull()?.let {it.isFinite()&&it>0&&it<=300}!=true)"Enter a BPM greater than 0 and no more than 300" else null,
        keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Decimal,imeAction=ImeAction.Next),keyboardActions=KeyboardActions(onNext={focus.moveFocus(FocusDirection.Next)}))
    SoundQEntryField(camelot,{camelot=it;onEdit(fields.draft())},"Camelot key",enabled=!state.loading,
        error=if(camelot.text.isNotBlank()&&normalizeHarmonicKey(camelot.text)==null)"Use a Camelot key such as 8A (1–12, A or B)"else null,
        keyboardOptions=KeyboardOptions(capitalization=KeyboardCapitalization.Characters,imeAction=ImeAction.Next),keyboardActions=KeyboardActions(onNext={focus.moveFocus(FocusDirection.Next)}))
    SoundQEntryField(tolerance,{tolerance=it;onEdit(fields.draft())},"Tempo range (± BPM)",enabled=!state.loading,
        error=if(tolerance.text.isNotBlank()&&tolerance.text.trim().toDoubleOrNull()?.let {it.isFinite()&&it in 0.0..50.0}!=true)"Enter a range from 0 to 50 BPM."else null,
        keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Decimal,imeAction=ImeAction.Done),keyboardActions=KeyboardActions(onDone={submit()}))
    SoundQRow("Order by my listening history","Use your server's listening-history order",state.draft.history,{fields.history=!state.draft.history;onEdit(fields.draft())},enabled=!state.loading,role=Role.Switch,
        trailing={Switch(state.draft.history,{fields.history=it;onEdit(fields.draft())},enabled=!state.loading,modifier=Modifier.semantics {contentDescription="Order by my listening history"})})
    if(!valid)Text("Enter a tempo in BPM and a Camelot key like 8A.",style=SoundQ.typography.caption)
    SoundQButton("Find matches",::submit,enabled=valid&&!state.loading)
    if(state.inputsChanged)Text("Inputs changed — find matches to update results",style=SoundQ.typography.caption)
    if(state.loading)SoundQFeedback("Finding harmonic matches…",FeedbackKind.Loading)
    if(state.disabled||state.failed) {
        SoundQFeedback(if(state.disabled)"Harmonic matching is turned off on this server."else "Could not load harmonic matches. Try again.",FeedbackKind.Error)
        SoundQButton("Retry",::submit,enabled=valid&&!state.loading,variant=SoundQButtonVariant.Secondary)
    }
}
