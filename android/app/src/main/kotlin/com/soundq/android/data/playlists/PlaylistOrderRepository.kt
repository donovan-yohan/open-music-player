package com.soundq.android.data.playlists

import com.soundq.android.data.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

class PlaylistOrderRoute internal constructor(internal val scope: AccountScope)
class PlaylistOrderTarget internal constructor(internal val route: PlaylistOrderRoute, internal val detail: PlaylistDetail, internal val intent: Long)
data class PlaylistOrderState(val outcome: MutationOutcome? = null, val playlist: PlaylistSummary? = null, val original: List<TrackId> = emptyList(), val proposed: List<TrackId> = emptyList(), val loading: Boolean = false, val reconciled: Boolean = false, val error: SafeFailure.Reason? = null)
/** Private member order only. No listening or session mutation dependency. */
class PlaylistOrderRepository(private val api: SoundQApi, private val detail: PlaylistDetailRepository) {
    private val mutable=MutableStateFlow(PlaylistOrderState())
    val state:StateFlow<PlaylistOrderState> = mutable
    private var route:PlaylistOrderRoute?=null
    private var intent=0L
    private var readVersion=0L
    private class Operation(val target:PlaylistOrderTarget) { var entered=false }
    private var operation:Operation?=null
    @Synchronized fun enter():PlaylistOrderRoute? {
        val scope=api.session.capture()?.takeIf(api.session::remoteCurrent) ?: return null
        if(operation?.target?.route?.scope?.let { !api.session.remoteCurrent(it) }==true)retire()
        route?.let(::leave)
        return PlaylistOrderRoute(scope).also {route=it}
    }
    @Synchronized fun leave(owner:PlaylistOrderRoute) {
        if(route!==owner)return
        route=null;readVersion++
        mutable.value=mutable.value.copy(loading=false,outcome=if(operation?.entered==false && mutable.value.outcome==MutationOutcome.Pending)MutationOutcome.Refused else mutable.value.outcome)
    }
    @Synchronized fun retire() {route=null;operation=null;intent++;readVersion++;mutable.value=PlaylistOrderState()}
    @Synchronized private fun owns(owner:PlaylistOrderRoute)=route===owner && api.session.remoteCurrent(owner.scope)
    @Synchronized private fun available()= !mutable.value.loading && mutable.value.outcome!=MutationOutcome.Pending && (mutable.value.outcome!=MutationOutcome.Uncertain || mutable.value.reconciled)
    @Synchronized fun capture(owner:PlaylistOrderRoute):PlaylistOrderTarget? {
        val value=detail.managementDetail() ?: return null
        if(!owns(owner)||value.playlist.draft.isPublic||!available())return null
        return PlaylistOrderTarget(owner,value,intent)
    }
    @Synchronized fun move(target:PlaylistOrderTarget,track:TrackId,original:List<TrackId>,to:Int):(() -> Unit)? {
        if(!owns(target.route)||target.intent!=intent||!detail.ownsManagement(target.detail)||!available()||target.detail.playlist.draft.isPublic)return null
        val order=target.detail.tracks.map {it.id}
        val from=order.indexOf(track)
        if(original!=order||from<0||to !in order.indices||to==from)return null
        val proposed=order.toMutableList().apply {add(to,removeAt(from))}.toList()
        intent++;readVersion++
        val op=Operation(target);operation=op
        mutable.value=PlaylistOrderState(MutationOutcome.Pending,target.detail.playlist,order,proposed)
        return work@{
            synchronized(this) {
                if(operation!==op||op.entered||mutable.value.outcome!=MutationOutcome.Pending)return@work
                if(!owns(target.route)||!detail.ownsManagement(target.detail)) {mutable.value=mutable.value.copy(outcome=MutationOutcome.Refused);return@work}
                op.entered=true
            }
            fun current()=synchronized(this) {operation===op&&owns(target.route)&&detail.ownsManagement(target.detail)}
            try {
                val observed=api.restorePlaylistPosition(target.route.scope,target.detail.playlist.id,track,to,::current)
                if(observed.playlist.draft.isPublic||observed.tracks.map {it.id}!=proposed)throw SafeFailure(SafeFailure.Reason.InvalidResponse)
                synchronized(this) {if(current()) {detail.publishManagement(target.detail,observed);mutable.value=mutable.value.copy(outcome=MutationOutcome.Confirmed)}}
            } catch(error:Exception) {
                synchronized(this) {
                    if(operation===op&&api.session.remoteCurrent(target.route.scope)) {
                        val reason=(error as? SafeFailure)?.reason ?: SafeFailure.Reason.InvalidResponse
                        mutable.value=mutable.value.copy(outcome=if(reason==SafeFailure.Reason.Refused)MutationOutcome.Refused else MutationOutcome.Uncertain,error=reason)
                    }
                }
            }
        }
    }
    @Synchronized fun recoveryAction(owner:PlaylistOrderRoute,enqueue: (() -> Unit) -> Unit):(() -> Unit)? {
        val op=operation ?: return null
        val revision=intent;val destination=detail.managementDetail();val version=detail.managementVersion()
        if(!owns(owner)||mutable.value.outcome!=MutationOutcome.Uncertain||mutable.value.loading||mutable.value.reconciled)return null
        return action@{synchronized(this) {
            if(operation!==op||!owns(owner)||intent!=revision||detail.managementVersion()!=version||detail.managementDetail()!==destination||mutable.value.loading)return@action
            val ticket=++readVersion
            mutable.value=mutable.value.copy(loading=true,error=null)
            enqueue {
                fun presentation()=synchronized(this) {operation===op&&owns(owner)&&readVersion==ticket}
                fun current()=presentation()&&detail.managementVersion()==version&&detail.managementDetail()===destination
                try {
                    val observed=api.playlistManagementSnapshot(owner.scope,op.target.detail.playlist.id,::current)
                    if(observed?.playlist?.draft?.isPublic==true)throw SafeFailure(SafeFailure.Reason.InvalidResponse)
                    synchronized(this) {if(current()) {destination?.takeIf {it.playlist.id==op.target.detail.playlist.id}?.let {detail.publishManagement(it,observed)};intent++;mutable.value=mutable.value.copy(reconciled=true)}}
                } catch(error:Exception) {synchronized(this) {if(presentation())mutable.value=mutable.value.copy(error=(error as? SafeFailure)?.reason ?: SafeFailure.Reason.Network)}}
                finally {synchronized(this) {if(presentation())mutable.value=mutable.value.copy(loading=false)}}
            }
        }}
    }
}
class PlaylistOrderActions(private val repository:PlaylistOrderRepository,private val enqueue: (() -> Unit) -> Unit) {
    private val route=repository.enter()
    fun capture()=route?.let(repository::capture)
    fun move(target:PlaylistOrderTarget,track:TrackId,original:List<TrackId>,to:Int):Boolean {
        val work=repository.move(target,track,original,to) ?: return false
        enqueue(work);return true
    }
    fun recoveryAction()=route?.let {repository.recoveryAction(it,enqueue)}
    fun recover() {recoveryAction()?.invoke()}
    fun close() {route?.let(repository::leave)}
}
