package com.soundq.android.data.playlists

import com.soundq.android.data.*
import com.soundq.android.playback.PlaybackProjection
import com.soundq.android.playback.QueueOccurrence
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

class QueuePlaylistRoute internal constructor(internal val scope:AccountScope)
data class QueuePlaylistSnapshot(val occurrences:List<QueueOccurrence>,val tracks:List<TrackId>,val duplicateOccurrences:Int,val omittedOccurrences:Int=0)
class QueuePlaylistTarget internal constructor(internal val route:QueuePlaylistRoute,internal val snapshot:QueuePlaylistSnapshot,internal val revision:Long,val playlist:PlaylistSummary?=null,val draft:PlaylistDraft?=null)
data class QueuePlaylistState(val snapshot:QueuePlaylistSnapshot?=null,val rows:List<PlaylistSummary> = emptyList(),val total:Int?=null,val loading:Boolean=false,val outcome:MutationOutcome?=null,val ack:PlaylistAddAck?=null,val created:PlaylistSummary?=null,val target:PlaylistId?=null,val draft:PlaylistDraft?=null,val observed:PlaylistDetail?=null,val reconciled:Boolean=false,val error:SafeFailure.Reason?=null)
class QueuePlaylistRepository(private val api:SoundQApi) {
    private val mutable=MutableStateFlow(QueuePlaylistState())
    val state:StateFlow<QueuePlaylistState> = mutable
    private var route:QueuePlaylistRoute?=null
    private var revision=0L
    private var readVersion=0L
    private class Operation(val target:QueuePlaylistTarget) {var entered=false;var dispatched=false;var created:PlaylistSummary?=null}
    private var operation:Operation?=null
    @Synchronized private fun owns(owner:QueuePlaylistRoute)=route===owner&&api.session.remoteCurrent(owner.scope)
    @Synchronized private fun available()=mutable.value.outcome==null || mutable.value.outcome==MutationOutcome.Refused
    @Synchronized fun enter():QueuePlaylistRoute? {
        val scope=api.session.capture()?.takeIf(api.session::remoteCurrent) ?: return null
        if(operation?.target?.route?.scope?.let {!api.session.remoteCurrent(it)}==true)retire()
        route?.let(::close)
        return QueuePlaylistRoute(scope).also {route=it}
    }
    @Synchronized fun capture(owner:QueuePlaylistRoute,visible:PlaybackProjection):Boolean {
        if(!owns(owner)||!available()||mutable.value.loading)return false
        if(visible.connection!=PlaybackProjection.Connection.Connected||visible.queue.isEmpty()||visible.queue.map {it.occurrenceId}.distinct().size!=visible.queue.size) {
            mutable.value=mutable.value.copy(error=SafeFailure.Reason.Refused);return false
        }
        val ids=visible.queue.filter {it.trackId>0}.map {TrackId(it.trackId)}
        if(ids.isEmpty()){mutable.value=mutable.value.copy(error=SafeFailure.Reason.Refused);return false}
        revision++;readVersion++
        mutable.value=QueuePlaylistState(snapshot=QueuePlaylistSnapshot(visible.queue.toList(),ids,ids.size-ids.distinct().size,visible.queue.size-ids.size))
        return true
    }
    @Synchronized fun reload(owner:QueuePlaylistRoute,more:Boolean=false):(() -> Unit)? {
        val s=mutable.value
        if(!owns(owner)||s.loading||s.snapshot==null||!available()||more&&(s.total==null||s.rows.size>=s.total))return null
        val ticket=++readVersion;val offset=if(more)s.rows.size else 0
        mutable.value=s.copy(loading=true,error=null)
        return {
            fun current()=synchronized(this) {owns(owner)&&readVersion==ticket}
            try {
                val page=api.playlists(owner.scope,offset,::current)
                synchronized(this) {if(current()) {
                    val rows=(if(more)s.rows else emptyList())+page.rows
                    require(rows.map {it.id}.distinct().size==rows.size)
                    mutable.value=mutable.value.copy(rows=rows,total=page.total)
                }}
            } catch(error:Exception) {synchronized(this) {if(current())mutable.value=mutable.value.copy(error=(error as? SafeFailure)?.reason ?: SafeFailure.Reason.InvalidResponse)}}
            finally {synchronized(this) {if(current())mutable.value=mutable.value.copy(loading=false)}}
        }
    }
    @Synchronized fun select(owner:QueuePlaylistRoute,row:PlaylistSummary):QueuePlaylistTarget? {
        val s=mutable.value;val snapshot=s.snapshot ?: return null
        if(!owns(owner)||!available()||s.loading||s.error!=null||row.draft.isPublic||s.rows.none {it===row})return null
        return QueuePlaylistTarget(owner,snapshot,revision,playlist=row)
    }
    @Synchronized fun newTarget(owner:QueuePlaylistRoute,draft:PlaylistDraft):QueuePlaylistTarget? {
        val s=mutable.value;val snapshot=s.snapshot ?: return null
        if(!owns(owner)||!available()||s.loading||draft.isPublic)return null
        return QueuePlaylistTarget(owner,snapshot,revision,draft=draft)
    }
    @Synchronized fun save(target:QueuePlaylistTarget):(() -> Unit)? {
        if(!owns(target.route)||target.revision!=revision||target.snapshot!==mutable.value.snapshot||!available()||mutable.value.loading)return null
        revision++;readVersion++
        val op=Operation(target);operation=op
        mutable.value=mutable.value.copy(outcome=MutationOutcome.Pending,ack=null,created=null,target=target.playlist?.id,draft=target.draft,error=null,reconciled=false,observed=null)
        return work@{
            synchronized(this) {
                if(operation!==op||op.entered||mutable.value.outcome!=MutationOutcome.Pending)return@work
                if(!owns(target.route)) {mutable.value=mutable.value.copy(outcome=MutationOutcome.Refused);return@work}
                op.entered=true
            }
            fun account()=synchronized(this) {operation===op&&api.session.remoteCurrent(target.route.scope)}
            fun admit()=synchronized(this) {(account()&&owns(target.route)).also {if(it)op.dispatched=true}}
            try {
                val destination=target.playlist ?: api.createQueuePlaylist(target.route.scope,target.draft!!,::account,::admit).also {created->
                    synchronized(this) {if(account()) {op.created=created;mutable.value=mutable.value.copy(created=created,target=created.id)}}
                }
                if(!account()||!owns(target.route))throw SafeFailure(SafeFailure.Reason.Retired)
                val ack=api.addQueuePlaylistTracks(target.route.scope,destination.id,target.snapshot.tracks,::account,::admit)
                synchronized(this) {if(account())mutable.value=mutable.value.copy(outcome=MutationOutcome.Confirmed,ack=ack,error=null)}
            } catch(error:Exception) {
                synchronized(this) {if(account()) {
                    val reason=(error as? SafeFailure)?.reason ?: SafeFailure.Reason.InvalidResponse
                    val outcome=if(op.created!=null)MutationOutcome.ReadbackFailed else if(!op.dispatched||reason==SafeFailure.Reason.Refused)MutationOutcome.Refused else MutationOutcome.Uncertain
                    mutable.value=mutable.value.copy(outcome=outcome,error=reason)
                }}
            }
        }
    }
    @Synchronized fun close(owner:QueuePlaylistRoute) {
        if(route!==owner)return
        route=null;readVersion++
        mutable.value=mutable.value.copy(loading=false,outcome=if(operation?.entered==false&&mutable.value.outcome==MutationOutcome.Pending)MutationOutcome.Refused else mutable.value.outcome)
    }
    @Synchronized fun recoveryAction(owner:QueuePlaylistRoute,enqueue:(() -> Unit)->Unit):(() -> Unit)? {
        val op=operation ?: return null
        val s=mutable.value;val capturedRevision=revision
        if(!owns(owner)||s.loading||s.reconciled||s.outcome !in listOf(MutationOutcome.Uncertain,MutationOutcome.ReadbackFailed))return null
        val id=s.target
        return action@{synchronized(this) {
            if(!owns(owner)||operation!==op||revision!=capturedRevision||mutable.value.loading||mutable.value.reconciled)return@action
            val ticket=++readVersion;mutable.value=mutable.value.copy(loading=true,error=null)
            enqueue {
                fun current()=synchronized(this) {owns(owner)&&operation===op&&readVersion==ticket&&revision==capturedRevision}
                try {
                    // Missing create ACK has no trustworthy ID. Browse only; never identify a
                    // possibly-created playlist by a nonunique name or repeat either POST.
                    val observed=if(id!=null)api.playlistManagementSnapshot(owner.scope,id,::current) else null
                    if(observed?.playlist?.draft?.isPublic==true)throw SafeFailure(SafeFailure.Reason.InvalidResponse)
                    val page=if(id==null)api.playlists(owner.scope,0,::current) else null
                    synchronized(this) {if(current()) {revision++;mutable.value=mutable.value.copy(observed=observed,rows=page?.rows ?: mutable.value.rows,total=page?.total ?: mutable.value.total,reconciled=true)}}
                } catch(error:Exception) {synchronized(this) {if(current())mutable.value=mutable.value.copy(error=(error as? SafeFailure)?.reason ?: SafeFailure.Reason.Network)}}
                finally {synchronized(this) {if(owns(owner)&&operation===op&&readVersion==ticket)mutable.value=mutable.value.copy(loading=false)}}
            }
        }}
    }
    @Synchronized fun startNew(owner:QueuePlaylistRoute):Boolean {
        val s=mutable.value
        if(!owns(owner)||s.loading||s.outcome==MutationOutcome.Pending||s.outcome in listOf(MutationOutcome.Uncertain,MutationOutcome.ReadbackFailed)&&!s.reconciled)return false
        operation=null;revision++;readVersion++;mutable.value=QueuePlaylistState();return true
    }
    @Synchronized fun retire() {route=null;operation=null;revision++;readVersion++;mutable.value=QueuePlaylistState()}
}
class QueuePlaylistActions(private val repository:QueuePlaylistRepository,private val enqueue:(() -> Unit) -> Unit,private val visible:()->PlaybackProjection) {
    private val route=repository.enter()
    fun capture():Boolean=route?.let {repository.capture(it,visible())} ?: false
    fun reload() {route?.let {repository.reload(it)}?.let(enqueue)}
    fun select(row:PlaylistSummary)=route?.let {repository.select(it,row)}
    fun save(target:QueuePlaylistTarget) {repository.save(target)?.let(enqueue)}
    fun more() {route?.let {repository.reload(it,true)}?.let(enqueue)}
    fun newTarget(draft:PlaylistDraft)=route?.let {repository.newTarget(it,draft)}
    fun recoveryAction(): (() -> Unit)? = route?.let {repository.recoveryAction(it,enqueue)}
    fun recover() {recoveryAction()?.invoke()}
    fun startNew():Boolean = route?.let(repository::startNew) ?: false
    fun close() {route?.let(repository::close)}
}
