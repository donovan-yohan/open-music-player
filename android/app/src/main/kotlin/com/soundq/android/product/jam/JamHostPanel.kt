package com.soundq.android.product.jam

import androidx.compose.runtime.*
import androidx.lifecycle.*
import androidx.lifecycle.compose.*
import androidx.compose.material3.*
import androidx.compose.foundation.layout.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import com.soundq.android.data.TrackId
import com.soundq.android.data.jam.JamConsent
import com.soundq.android.data.jam.guestOrigin
import com.soundq.android.product.ProductViewModel
import com.soundq.android.product.LibraryMetadataContent
import com.soundq.android.product.memberDurationMetadata
import com.soundq.android.product.artwork.TrackArtwork
import com.soundq.designsystem.*
import kotlinx.coroutines.*
import java.time.Instant
import androidx.compose.foundation.Canvas
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp

/** Undo only the sheet's horizontal inset for touching song cells. Headers stay padded. */
@Composable private fun JamSongRows(content:@Composable ()->Unit) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        Column(Modifier.requiredWidth(maxWidth+SoundQ.spacing.gutter*2).align(androidx.compose.ui.Alignment.Center)) {content()}
    }
}
private fun jamRequestStatus(status:String)=when(status) {
    "pending"->"Waiting approval";"approved"->"Approved";"importing"->"Importing";"ready"->"Ready · waiting turn"
    "queued"->"Added to host queue";"uncertain"->"Not confirmed";"withdrawn"->"Withdrawn";"failed"->"Import failed"
    "duplicate"->"Already requested";"declined"->"Declined";else->"Checking"
}
@Composable fun JamHostPanel(model:ProductViewModel,onDismiss:()->Unit) {
    val host=model.graph.jam
    val state by host.state.collectAsStateWithLifecycle()
    val library by model.library.collectAsStateWithLifecycle()
    val lifecycle=LocalLifecycleOwner.current
    var consent by remember {mutableStateOf<JamConsent?>(null)}
    val jobs=rememberCoroutineScope()
    var selected by remember {mutableStateOf(setOf<TrackId>())}
    var outside by remember {mutableStateOf(false)}
    var confirmEnd by remember {mutableStateOf(false)}
    var showInvitation by remember {mutableStateOf(false)}
    var origin by remember {mutableStateOf("")}
    var originError by remember {mutableStateOf(false)}
    val clipboard=LocalClipboardManager.current
    val observedScope=model.graph.session.capture()
    val artworkScope=remember(model.graph,observedScope?.epoch,observedScope?.accountId){observedScope}
    fun artworkCurrent()=consent?.let(host::current)==true&&artworkScope?.let(model.graph.session::current)==true
    LaunchedEffect(state.snapshot?.id) {if(state.snapshot==null){selected=emptySet();outside=false;confirmEnd=false;showInvitation=false}}
    DisposableEffect(host,lifecycle) {
        fun sync(){if(lifecycle.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)){if(consent==null)consent=host.open()}else{consent?.let(host::hide);consent=null}}
        val observer=LifecycleEventObserver {_,_->sync()};lifecycle.lifecycle.addObserver(observer);sync()
        onDispose {consent?.let(host::hide);consent=null;lifecycle.lifecycle.removeObserver(observer)}
    }
    fun action(work:(JamConsent)->Unit){val c=consent ?: return;jobs.launch(Dispatchers.IO){work(c)}}
    SoundQSheet("Jam",{consent?.let(host::hide);onDismiss()}) {
        Text("Approval on",style=SoundQ.typography.caption)
        state.message?.let {SoundQFeedback(it,if(state.uncertain)FeedbackKind.Error else FeedbackKind.Empty)}
        if(state.busy)SoundQFeedback("Updating Jam",FeedbackKind.Loading)
        val snapshot=state.snapshot
        if(snapshot==null) {
            if(state.uncertain)SoundQButton("Check same Jam",{action(host::refresh)},enabled=!state.busy,variant=SoundQButtonVariant.Secondary)
            Text("Choose 1–20 songs from your Library",style=SoundQ.typography.title)
            JamSongRows {
                library.rows.forEach {track ->key(track.id) {
                    var menu by remember {mutableStateOf(false)}
                    val chosen=track.id in selected
                    val toggle={selected=if(track.id in selected)selected-track.id else if(selected.size<20)selected+track.id else selected}
                    SoundQMediaRow(track.title,track.artist,false,toggle,onMore={menu=true},
                        modifier=Modifier.semantics {this.selected=chosen;stateDescription=if(chosen)"Selected for Jam" else "Not selected for Jam"},
                        artwork={TrackArtwork(model.graph,artworkScope,track,{artworkCurrent()&&model.library.value.rows.any {it===track}},sourceOwner="jam-picker" to consent)},
                        metadata={LibraryMetadataContent(memberDurationMetadata(track.durationMs))},
                        supporting=if(chosen)"Selected" else "Not selected",enabled=!state.busy)
                    if(menu)SoundQSheet("Jam song",{menu=false}) {
                        Text(track.title,style=SoundQ.typography.title)
                        SoundQButton(if(chosen)"Remove selection" else "Select song",{toggle();menu=false},enabled=!state.busy&&(chosen||selected.size<20))
                    }
                }}
            }
            if(library.total?.let {library.rows.size<it}==true)SoundQButton("Load more Library songs",model::loadMore,variant=SoundQButtonVariant.Secondary)
            Row {Checkbox(outside,{outside=it},enabled=!state.busy&&!state.uncertain);Text("Let guests find songs",Modifier.weight(1f))}
            SoundQButton("Create Jam",{val tracks=library.rows.filter {it.id in selected};action {host.create(it,tracks,outside)}},enabled=selected.isNotEmpty()&&!state.busy&&!state.uncertain)
        }else {
            Text("Jam ${snapshot.state}",style=SoundQ.typography.title)
            Text("${snapshot.catalog.size} songs offered · ${snapshot.requests.size} requests",style=SoundQ.typography.caption)
            SoundQButton("Invitation",{showInvitation=true},enabled=!state.busy,variant=SoundQButtonVariant.Secondary)
            if(showInvitation)SoundQSheet("Invitation",{showInvitation=false}) {
                SoundQTextField(origin,{origin=it;originError=false},"Guest website")
                if(originError)SoundQFeedback("Use an HTTPS origin. Local HTTP is loopback only.",FeedbackKind.Error)
                SoundQButton("New invitation",{if(runCatching {guestOrigin(origin)}.isSuccess){originError=false;action(host::invite)}else originError=true},enabled=!state.busy)
                state.invite?.takeIf {Instant.now().isBefore(it.expires)}?.let {invite ->
                    val link=remember(invite,origin){runCatching {invite.link(origin,snapshot.id)}.getOrNull()}
                    val matrix=remember(link){link?.let(::invitationQr)}
                    if(matrix!=null)Canvas(Modifier.size(256.dp).semantics {contentDescription="Jam invitation QR code"}) {
                        drawRect(Color.White)
                        val unit=size.width/matrix.width
                        for(y in 0 until matrix.height)for(x in 0 until matrix.width)if(matrix[x,y])drawRect(Color.Black,Offset(x*unit,y*unit),Size(unit,unit))
                    }
                    SoundQButton("Copy invitation",{try {val link=invite.link(origin,snapshot.id);clipboard.setText(AnnotatedString(link));originError=false}catch(_:Exception){originError=true}},enabled=!state.busy,variant=SoundQButtonVariant.Secondary)
                    Text("Invitation expires ${invite.expires}",style=SoundQ.typography.caption)
                }
            }
            SoundQButton("Refresh requests",{action(host::refresh)},enabled=!state.busy,variant=SoundQButtonVariant.Secondary)
            JamSongRows {
                snapshot.requests.forEach {request ->key(request.id) {
                    val song=snapshot.catalog.firstOrNull {it.id==request.catalogId}
                    val title=request.source?.title ?: song?.title ?: "Recording unavailable"
                    val owned=library.rows.singleOrNull {it.id==request.trackId}
                    var menu by remember(request){mutableStateOf(false)}
                    SoundQMediaRow(title,request.source?.artist ?: song?.artist.orEmpty(),false,{menu=true},onMore={menu=true},
                        artwork={TrackArtwork(model.graph,artworkScope,owned,{artworkCurrent()&&owned!=null&&model.library.value.rows.any {it===owned}&&host.state.value.snapshot?.requests?.any {it==request}==true},sourceOwner=Triple(snapshot.id,request.id,consent))},
                        metadata={LibraryMetadataContent(memberDurationMetadata(request.source?.durationMs ?: song?.durationMs ?: 0))},
                        supporting="${jamRequestStatus(request.status)} · ${request.source?.let {if(it.provider=="youtube")"YouTube · " else "SoundCloud · "}.orEmpty()}${request.name}",enabled=!state.busy&&(request.source!=null||song!=null))
                    if(menu)SoundQSheet("Song request",{menu=false}) {
                        Text(title,style=SoundQ.typography.title)
                        Text("${jamRequestStatus(request.status)} · ${request.name}")
                        request.source?.let {source ->
                            if(source.artist.isNotEmpty())Text(source.artist,style=SoundQ.typography.body)
                            Text("${if(source.provider=="youtube")"YouTube" else "SoundCloud"} · ${source.sourceId}",style=SoundQ.typography.caption)
                            if(source.durationMs>0)Text(formatSongTime(source.durationMs),style=SoundQ.typography.caption)
                            else Text("Duration unavailable",style=SoundQ.typography.caption)
                        }
                        if(request.status in setOf("pending","approved","importing","ready","uncertain")) {
                            if(request.status=="pending") {
                                SoundQButton(if(request.source!=null)"Import & queue" else "Approve & queue",{action {host.decide(it,request,true)};menu=false},enabled=!state.busy)
                            }
                            if(request.status!="uncertain")SoundQButton("Decline request",{action {host.decide(it,request,false)};menu=false},enabled=!state.busy,variant=SoundQButtonVariant.Secondary)
                            SoundQButton("Check request",{action {host.decide(it,request,true,true)};menu=false},enabled=!state.busy,variant=SoundQButtonVariant.Quiet)
                        }
                    }
                }}
            }
            SoundQButton("End Jam",{confirmEnd=true},enabled=!state.busy,variant=SoundQButtonVariant.Quiet)
            if(confirmEnd)SoundQSheet("End Jam?",{confirmEnd=false}) {
                Text("Guests lose access. Playback and added songs stay.",style=SoundQ.typography.body)
                SoundQButton("End Jam",{confirmEnd=false;action(host::end)},enabled=!state.busy)
                SoundQButton("Keep Jam",{confirmEnd=false},variant=SoundQButtonVariant.Quiet)
            }
        }
    }
}
