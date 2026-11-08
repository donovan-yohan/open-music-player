package com.soundq.android.product.playlists

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import com.soundq.android.data.TrackId
import com.soundq.android.data.playlists.*
import com.soundq.android.playback.QueuePolicy
import com.soundq.designsystem.*

private fun LazyListScope.playlistHeader(key:Any?=null,content:@Composable ()->Unit) {
    item(key=key) {Column(Modifier.fillMaxWidth().padding(horizontal=SoundQ.spacing.gutter,vertical=SoundQ.spacing.small)) {content()}}
}
private fun mixTime(ms:Long):String {val seconds=ms/1000;return "${seconds/60}:${(seconds%60).toString().padStart(2,'0')}"}
private fun transitionLabel(t:kotlinx.serialization.json.JsonObject):String {
    val confidence=t.getValue("confidence") as kotlinx.serialization.json.JsonObject
    val label=when {
        confidence["simpleFade"].toString()=="true"->"simple fade"
        confidence["tempoShift"].toString()=="true"->"tempo shift"
        confidence["keyMatch"].toString()=="true"->"key match"
        confidence["tempoMatched"].toString()=="true"->"tempo matched"
        else->"simple fade"
    }
    val overlap=t.getValue("overlapMs").toString().toLong()/1000.0
    return "Fade · ${overlap}s · $label"
}
@Composable fun PlaylistDetailScreen(
    state: PlaylistDetailState,
    capture: PlaylistPlaybackCapture?,
    onBack: () -> Unit,
    onRetry: () -> Unit,
    onPlay: (PlaylistPlaybackCapture, TrackId) -> Unit,
    management: PlaylistManagementState = PlaylistManagementState(),
    actions: PlaylistManagementActions? = null,
    order: PlaylistOrderState = PlaylistOrderState(),
    orderActions: PlaylistOrderActions? = null,
    blend:PlaylistBlendState=PlaylistBlendState(),
    blendCapture:BlendCapture?=null,
    onGenerate:(BlendCapture)->Unit={},
    onRecover:(BlendCapture)->Unit={},
    onListening:(BlendCapture,Boolean)->Unit={_,_->},
    onShuffle:(PlaylistPlaybackCapture,TrackId)->Unit={_,_->},
    plan:com.soundq.android.data.mix.SavedMix?=null,
    canGenerate:Boolean=false,
    canRecover:Boolean=false,
    onPlayAt:(PlaylistPlaybackCapture,TrackId,Int)->Unit={p,id,_->onPlay(p,id)},
    onQueue:(PlaylistPlaybackCapture,Int,com.soundq.android.data.Track,()->Boolean)->Unit={_,_,_,_->},
    revealOwner:RowRevealOwner=remember {RowRevealOwner()},
    harmonic:@Composable (()->Boolean)->Unit={},
    artwork:@Composable (com.soundq.android.data.Track,()->Boolean)->Unit={_,_->},
    harmonicFeedback:@Composable ()->Unit={},
) {
    val lifetime=com.soundq.android.product.rememberTrackRowLifetime(state.detail)
    var seam by remember(state.id,state.detail) {mutableStateOf<Int?>(null)}
    seam?.let {index->state.detail?.let {detail->blend.transitions.getOrNull(index)?.let {transition->
        SoundQSheet("Transition ${index+1}",{seam=null}) {
            Text("${detail.tracks[index].title} → ${detail.tracks[index+1].title}",style=SoundQ.typography.title)
            Text("Occurrences ${index+1} → ${index+2}",style=SoundQ.typography.mono)
            Text(transitionLabel(transition))
            val bars=transition["bars"]?.toString()?.toLongOrNull() ?: 0
            if(bars>0)Text("$bars bars")
            Text("Volume fades · original speed",style=SoundQ.typography.caption)
        }
    }}}
    val target = actions?.capture()
    val orderTarget=orderActions?.capture()
    val gesture=remember {PlaylistOrderGesture()}
    androidx.activity.compose.BackHandler {if(!gesture.cancel())onBack()}
    var menu by remember(state.id) { mutableStateOf<PlaylistManagementTarget?>(null) }
    var rename by remember(state.id) { mutableStateOf<PlaylistManagementTarget?>(null) }
    var batch by remember(state.id,state.detail) { mutableStateOf<PlaylistManagementTarget?>(null) }
    var deletion by remember(state.id) { mutableStateOf<PlaylistDeleteConfirmation?>(null) }
    var member by remember(state.id,state.detail,lifetime) { mutableStateOf<Int?>(null) }
    var memberTarget by remember(state.id) { mutableStateOf<PlaylistManagementTarget?>(null) }
    LaunchedEffect(management.outcome,management.reconciled) {
        if(management.outcome==com.soundq.android.data.MutationOutcome.Confirmed || management.reconciled)rename=null
    }
    if(actions!=null) {
        menu?.let { captured -> PlaylistManagementMenu(captured,actions,{menu=null},{rename=captured;menu=null},{deletion=it;menu=null},{batch=captured;menu=null}) }
        rename?.let { captured -> PlaylistRenameSheet(captured,management,actions,{rename=null}) }
        batch?.let { captured -> PlaylistBatchSheet(captured,actions,{batch=null}) }
        deletion?.let { captured -> PlaylistDeleteSheet(captured,actions,{deletion=null}) }
    }
    member?.let {index->state.detail?.tracks?.getOrNull(index)?.let {track->
        SoundQSheet("Playlist track",{member=null;memberTarget=null}) {
            Text(track.title,style=SoundQ.typography.title)
            SoundQButton("Play",{if(lifetime.current())capture?.let {onPlayAt(it,track.id,index)};member=null},enabled=capture!=null)
            SoundQButton("Add to listening queue",{if(lifetime.current())capture?.let {onQueue(it,index,track,lifetime::current)};member=null},enabled=capture!=null,variant=SoundQButtonVariant.Secondary)
            if(actions!=null&&memberTarget!=null)SoundQButton("Remove from playlist",{if(lifetime.current())memberTarget?.let {actions.remove(it,track.id)};member=null;memberTarget=null},variant=SoundQButtonVariant.Secondary)
        }
    }}
    LazyColumn(Modifier.fillMaxSize()) {
        item { Box(Modifier.fillMaxWidth()) {
            Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).heightIn(min=64.dp),verticalAlignment=androidx.compose.ui.Alignment.CenterVertically) {
                SoundQIconButton(SoundQIcon.Back,"Back to playlists",onBack,Modifier.width(48.dp).fillMaxHeight(),outlined=false)
                Column(Modifier.weight(1f).padding(horizontal=8.dp,vertical=8.dp)) {
                    Text(state.detail?.playlist?.name ?: "Playlist",style=SoundQ.typography.title.copy(fontSize=20.sp,lineHeight=24.sp),modifier=Modifier.semantics {heading()},maxLines=1,overflow=TextOverflow.Ellipsis)
                    state.detail?.let {detail->Text("${detail.playlist.trackCount} tracks",style=SoundQ.typography.caption.copy(fontSize=12.sp,lineHeight=16.sp),color=SoundQ.colors.muted,maxLines=1,softWrap=false)}
                }
                harmonic {revealOwner.close();!gesture.cancel()}
                if(actions!=null) SoundQIconButton(SoundQIcon.More,"Playlist actions",{menu=target},Modifier.width(48.dp).fillMaxHeight(),enabled=target!=null,outlined=false)
            }
            SoundQDivider(Modifier.align(androidx.compose.ui.Alignment.BottomCenter))
        } }
        state.detail?.let {detail->if(detail.tracks.isNotEmpty()) item {
            PlaylistListeningControls(blend.enabled,blend.status in setOf(BlendStatus.Ready,BlendStatus.Unsupported),blend.loading,
                {blendCapture?.let {onListening(it,false)}},{blendCapture?.let {onListening(it,true)}},
                {blendCapture?.let(onGenerate)},{capture?.let {onPlayAt(it,detail.tracks.first().id,0)}},
                {capture?.let {onShuffle(it,detail.tracks.first().id)}},capture!=null,canGenerate)
        }}
        // Feedback slots own their conditional paint; an empty slot has no padded row.
        item {harmonicFeedback()}
        if(actions!=null && management.playlist!=null) playlistHeader { PlaylistManagementFeedback(management,actions) }
        if(orderActions!=null && order.outcome in setOf(com.soundq.android.data.MutationOutcome.Pending,com.soundq.android.data.MutationOutcome.Confirmed,com.soundq.android.data.MutationOutcome.Refused,com.soundq.android.data.MutationOutcome.Uncertain)) playlistHeader {PlaylistOrderFeedback(order,orderActions)}
        if (state.loading) playlistHeader { SoundQFeedback("Loading playlist", FeedbackKind.Loading) }
        state.error?.let { error -> playlistHeader { SoundQFeedback("Playlist unavailable", FeedbackKind.Error, error.message, "Retry playlist", onRetry) } }
        state.detail?.let { detail ->
            if (detail.tracks.isNotEmpty() && !QueuePolicy.acceptsContext(detail.tracks.size)) playlistHeader {
                SoundQFeedback("Playback unavailable", FeedbackKind.Error, QueuePolicy.CONTEXT_LIMIT_MESSAGE)
            }
            if (detail.tracks.isEmpty()) playlistHeader { SoundQFeedback("No tracks yet", FeedbackKind.Empty) }
            if (detail.playlist.draft.description.isNotBlank()) playlistHeader { Text(detail.playlist.draft.description) }
            if(blend.loading)playlistHeader {Box(Modifier.semantics {liveRegion=LiveRegionMode.Polite}) {SoundQFeedback("Preparing Blend",FeedbackKind.Loading)}}
            blend.notice?.let {notice->playlistHeader {Box(Modifier.semantics {liveRegion=LiveRegionMode.Polite}) {SoundQFeedback("Blend",FeedbackKind.Empty,notice)}}}
            if(canRecover)playlistHeader {SoundQButton("Read back saved Blend",{blendCapture?.let(onRecover)},enabled=blendCapture!=null&&!blend.loading,variant=SoundQButtonVariant.Secondary)}
            if(blend.enabled && blend.status==BlendStatus.Ready && plan!=null) {
                playlistHeader {Text("Mixed · saved",style=SoundQ.typography.title);Text("${blend.transitions.size} transitions · volume fades · original speed",style=SoundQ.typography.caption)}
                detail.tracks.forEachIndexed {index,track->
                    item(key="mixed-${plan.clips[index].occurrence}") {
                        val reveal=remember(track,index,state.detail,lifetime){RowRevealState(revealOwner)}
                        val queue={if(lifetime.current())capture?.let {onQueue(it,index,track,lifetime::current)};Unit}
                        SoundQSwipeQueue(track.title,reveal,capture!=null,queue) {front,admit->
                            val rowLifetime=com.soundq.android.product.rememberTrackRowLifetime(track)
                            val rowCurrent={lifetime.current()&&rowLifetime.current()}
                            SoundQMediaRow(track.title,track.artist,false,{if(admit())capture?.let {onPlayAt(it,track.id,index)}},
                                onMore={reveal.close();memberTarget=target;member=index},modifier=front,
                                metadata={com.soundq.android.product.LibraryMetadataContent(com.soundq.android.product.memberDurationMetadata(track.durationMs))},
                                artwork={key(lifetime,rowLifetime){artwork(track,rowCurrent)}},enabled=capture!=null||target!=null,supporting="${(index+1).toString().padStart(2,'0')} · Starts ${mixTime(plan.clips[index].start)}")
                        }
                    }
                    if(index<blend.transitions.size)playlistHeader(key="seam-$index") {PlaylistBlendSeam(transitionLabel(blend.transitions[index])){seam=index}}
                }
            } else if(orderActions!=null && !detail.playlist.draft.isPublic) item {
                val tracks=detail.tracks.associateBy {it.id.value.toString()}
                PlaylistMemberOrderList(detail.tracks.map {QueueRowVisual(it.id.value.toString(),it.title,it.artist,false,it.durationMs)},
                    onSelect={key->tracks[key]?.let {track->capture?.let {onPlay(it,track.id)}}},onMove={_,_->},
                    onRemove={key->tracks[key]?.let {track->target?.let {actions?.remove(it,track.id)}}},
                    onQueue={key->val index=detail.tracks.indexOfFirst {it.id.value.toString()==key};detail.tracks.getOrNull(index)?.let {track->if(lifetime.current())capture?.let {onQueue(it,index,track,lifetime::current)}}},
                    queueEnabled=capture!=null,revealOwner=revealOwner,
                    revision=detail,gestureState=gesture,onReorder={intent->
                        val moved=tracks[intent.occurrence]
                        moved!=null && orderTarget!=null && orderActions.move(orderTarget,moved.id,detail.tracks.map {it.id},intent.to)
                    },artwork={key->tracks[key]?.let {track->
                        val rowLifetime=com.soundq.android.product.rememberTrackRowLifetime(track)
                        key(lifetime,rowLifetime){artwork(track,{lifetime.current()&&rowLifetime.current()})}
                    }})
            } else itemsIndexed(detail.tracks, key = { index,track -> "${track.id.value}:$index" }) { index,track ->
                val reveal=remember(track,index,state.detail,lifetime){RowRevealState(revealOwner)}
                val queue={if(lifetime.current())capture?.let {onQueue(it,index,track,lifetime::current)};Unit}
                SoundQSwipeQueue(track.title,reveal,capture!=null,queue) {front,admit->
                    val rowLifetime=com.soundq.android.product.rememberTrackRowLifetime(track)
                    val rowCurrent={lifetime.current()&&rowLifetime.current()}
                    SoundQMediaRow(track.title,track.artist,false,{if(admit())capture?.let {onPlayAt(it,track.id,index)}},
                        onMore={reveal.close();memberTarget=target;member=index},modifier=front,
                                metadata={com.soundq.android.product.LibraryMetadataContent(com.soundq.android.product.memberDurationMetadata(track.durationMs))},
                        artwork={key(lifetime,rowLifetime){artwork(track,rowCurrent)}},enabled=capture!=null||target!=null)
                }
            }
        }
    }
}
