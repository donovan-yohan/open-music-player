package com.soundq.android.data.playlists

import com.soundq.android.data.*
import com.soundq.android.data.acquisition.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.json.*
import java.util.UUID

data class SourceSyncOperation(val id:String,val playlist:PlaylistId,val status:String,val accepted:Boolean,val generation:Long,val added:Int,val removed:Int,val reordered:Boolean,val pending:Int,val failed:Int,val error:String?) {
    val active get()=status in setOf("resolving","importing")
}
data class SourceSyncObservation(val eligible:Boolean,val binding:Long,val reason:String?,val operation:SourceSyncOperation?)
data class PlaylistSourceSyncState(val playlist:PlaylistId?=null,val observation:SourceSyncObservation?=null,val busy:Boolean=false,val uncertain:Boolean=false,val error:Boolean=false,val readbackFailed:Boolean=false,val saveFailed:Boolean=false)
internal object SourceSyncJson {
    private fun p(o:JsonObject,k:String)=o.getValue(k).jsonPrimitive.also {require(it!=JsonNull)}
    private fun str(o:JsonObject,k:String)=p(o,k).also {require(it.isString)}.content
    private fun num(o:JsonObject,k:String)=p(o,k).also {require(!it.isString)}.long.also {require(it>=0)}
    private fun bool(o:JsonObject,k:String)=p(o,k).also {require(!it.isString)}.boolean
    fun operation(o:JsonObject,id:PlaylistId):SourceSyncOperation=checked {
        val key=str(o,"id");require(UUID.fromString(key).toString()==key)
        require(num(o,"playlistId")==id.value)
        val status=str(o,"status").also {require(it in setOf("resolving","importing","complete","partial_failure","failed","superseded"))}
        val accepted=bool(o,"accepted");require(status!="complete"||accepted)
        val added=num(o,"added");val removed=num(o,"removed");val pending=num(o,"pending");val failed=num(o,"failed");require(listOf(added,pending,failed).all {it<=1000}&&removed<=4000) // bounded historical mappings may exceed one current snapshot
        val error=o["errorCode"]?.let {str(o,"errorCode").also {v->require(v in setOf("source_incomplete","source_changed"))}}
        SourceSyncOperation(key,id,status,accepted,num(o,"generation"),added.toInt(),removed.toInt(),bool(o,"reordered"),pending.toInt(),failed.toInt(),error)
    }
    fun observation(o:JsonObject,id:PlaylistId):SourceSyncObservation=checked {
        val eligible=bool(o,"eligible");val binding=num(o,"bindingId")
        val reason=o["reason"]?.let {str(o,"reason").also {v->require(v=="relink_required")}}
        val op=o["operation"]?.takeUnless {it==JsonNull}?.jsonObject?.let {operation(it,id)}
        SourceSyncObservation(eligible,binding,reason,op)
    }
    private fun <T> checked(f:()->T):T=try {f()}catch(_:Exception){throw SafeFailure(SafeFailure.Reason.InvalidResponse)}
}

/** Browse publication owns no player, queue, media grants or listening journal.
 * Durable request receipts use the existing no-backup intake journal. Recovery
 * reads the exact operation, or explicitly retries that same idempotent intent. */
class PlaylistSourceSyncRepository(private val api:SoundQApi,private val detail:PlaylistDetailRepository,private val receipts:IntakeReceipts=IntakeReceipts(),private val newOperation:()->String={UUID.randomUUID().toString()},private val playlists:PlaylistRepository?=null) {
    private val mutable=MutableStateFlow(PlaylistSourceSyncState())
    val state:StateFlow<PlaylistSourceSyncState> = mutable
    private var visit=0L
    private var ticket=0L
    private var scope:AccountScope?=null
    private var receipt:IntakeReceipt?=null
    @Synchronized fun lifetime():Long=visit
    @Synchronized fun leave(owner:Long){if(visit==owner)retire()}
    @Synchronized fun retire(){visit++;ticket++;scope=null;receipt=null;mutable.value=PlaylistSourceSyncState()}
    @Synchronized fun enter(id:PlaylistId):(() -> Unit)? {
        retire();val s=api.session.capture() ?: return null;scope=s
        mutable.value=PlaylistSourceSyncState(playlist=id)
        // Claim the visit synchronously before IO enqueue. Receipt disk reads stay
        // inside the one-shot work, fenced by that same visit across pause/ABA.
        val v=visit;val ran=java.util.concurrent.atomic.AtomicBoolean(false)
        return enterWork@{
            if(!ran.compareAndSet(false,true)||!current(v,s,id))return@enterWork
            try {
                val restored=receipts.entries(api.session.endpoint.identity,s.accountId).lastOrNull {it.kind=="playlist-sync"&&it.playlistId==id.value&&it.phase in setOf("pending","uncertain")}
                val work=synchronized(this){if(!current(v,s,id))null else {receipt=restored;refresh()}}
                work?.invoke()
            }catch(_:Exception){synchronized(this){if(current(v,s,id))mutable.value=mutable.value.copy(error=true)}}
        }
    }
    @Synchronized private fun current(v:Long,s:AccountScope,id:PlaylistId)=visit==v&&scope===s&&api.session.current(s)&&mutable.value.playlist==id&&detail.state.value.id==id
    @Synchronized fun refresh(owner:Long=visit):(() -> Unit)? {
        val id=mutable.value.playlist ?: return null;val s=scope ?: return null
        if(owner!=visit||mutable.value.busy||!current(visit,s,id))return null
        val v=visit;val t=++ticket;val pending=receipt
        mutable.value=mutable.value.copy(busy=true,error=false)
        val ran=java.util.concurrent.atomic.AtomicBoolean(false)
        return work@{
            if(!ran.compareAndSet(false,true))return@work
            fun valid()=synchronized(this){current(v,s,id)&&ticket==t}
            try {
                reconcile(s,id,synchronized(this){mutable.value.observation},pending,true,::valid)
            }catch(_:Exception){synchronized(this){if(valid())mutable.value=mutable.value.copy(error=true,readbackFailed=mutable.value.observation?.operation?.accepted==true)}}
            finally{synchronized(this){if(visit==v&&ticket==t&&scope===s)mutable.value=mutable.value.copy(busy=false)}}
        }
    }
    private fun reconcile(s:AccountScope,id:PlaylistId,known:SourceSyncObservation?,pending:IntakeReceipt?,readStatus:Boolean,valid:()->Boolean) {
        // Acceptance is a fact, not the outcome of either fallible read below.
        val before=synchronized(this){if(!valid())return else {
            if(known?.operation?.accepted==true)mutable.value=mutable.value.copy(observation=known,readbackFailed=true)
            detail.managementDetail()
        }}
        val list=synchronized(this){if(valid())playlists?.captureList()else null}
        var observed=known
        var statusComplete=!readStatus
        if(readStatus)try {
            val latest=api.playlistSourceSync(s,id,pending?.job,valid)
            if(pending?.job!=null&&latest.operation!=null)require(latest.operation.id==pending.job)
            if(known?.operation?.accepted==true)require(latest.operation?.accepted==true)
            observed=latest;statusComplete=true
        }catch(_:Exception){/* Retain known acceptance; membership is independent. */}
        val op=observed?.operation
        synchronized(this){if(valid())mutable.value=mutable.value.copy(observation=observed,readbackFailed=op?.accepted==true)}
        var snapshotRead=false
        var after:PlaylistDetail?=null
        if(op?.accepted==true&&before!=null&&valid())try {
            after=api.playlistManagementSnapshot(s,id,valid);snapshotRead=true
        }catch(_:Exception){/* Keep the original durable intent for GET recovery. */}
        synchronized(this){if(valid()) {
            val published=snapshotRead&&before!=null&&detail.publishManagement(before,if(after==before)before else after)
            if(published&&after==null&&list!=null)playlists?.confirmedMissing(list,id)
            val reconciled=statusComplete&&(op?.accepted!=true||published)
            mutable.value=mutable.value.copy(observation=observed,uncertain=pending!=null&&(op==null||!reconciled),readbackFailed=op?.accepted==true&&!reconciled,error=!reconciled)
            if(op!=null&&pending!=null&&reconciled)receipts.finish(api.session.endpoint.identity,s.accountId,pending,"accepted",op.id)
            if(op!=null&&!op.active&&reconciled)receipt=null
        }}
    }
    @Synchronized fun canStart():Boolean {
        val id=mutable.value.playlist ?: return false;val s=scope ?: return false
        val observation=mutable.value.observation ?: return false;val captured=detail.managementDetail() ?: return false
        return current(visit,s,id)&&captured.playlist.id==id&&captured.canManage&&!mutable.value.busy&&!mutable.value.readbackFailed&&observation.eligible&&observation.operation?.let {it.active&&!it.accepted}!=true
    }
    @Synchronized fun start():(() -> Unit)? {
        if(!canStart())return null
        val id=mutable.value.playlist ?: return null;val s=scope ?: return null;val observation=mutable.value.observation ?: return null
        val captured=detail.managementDetail() ?: return null
        val old=receipt
        val retry=mutable.value.uncertain&&old!=null
        val key=if(retry)old.job!! else newOperation()
        val binding=if(retry)old.candidateId!!.toLong() else observation.binding
        val v=visit;val t=++ticket
        // An older operation's completion is not acknowledgement of this new intent.
        mutable.value=mutable.value.copy(busy=true,error=false,readbackFailed=false,saveFailed=false,observation=observation.copy(operation=if(retry)observation.operation else null))
        val ran=java.util.concurrent.atomic.AtomicBoolean(false)
        return work@{
            if(!ran.compareAndSet(false,true))return@work
            fun valid()=synchronized(this){current(v,s,id)&&ticket==t}
            var durable=if(retry)old else null
            var membershipReadback=false
            try {
                if(!valid()||!detail.ownsManagement(captured))return@work
                if(!retry){durable=receipts.begin(api.session.endpoint.identity,s.accountId,"playlist-sync",job=key,playlistId=id.value,candidateId=binding.toString());synchronized(this){if(valid())receipt=durable}}
                val ack=api.startPlaylistSourceSync(s,id,key,binding,{valid()&&detail.ownsManagement(captured)},::valid)
                require(ack.id==key)
                membershipReadback=ack.accepted
                if(membershipReadback) {
                    reconcile(s,id,observation.copy(operation=ack),requireNotNull(durable),binding==0L,::valid)
                }
                else {
                    receipts.finish(api.session.endpoint.identity,s.accountId,requireNotNull(durable),"accepted",key)
                    synchronized(this){if(valid())mutable.value=mutable.value.copy(observation=observation.copy(operation=ack),uncertain=false)}
                }
            }catch(error:Exception){
                val refused=(error as? SafeFailure)?.reason==SafeFailure.Reason.Refused
                val retired=(error as? SafeFailure)?.reason==SafeFailure.Reason.Retired
                val settleRefusal=refused&&!retry
                if(!retired&&!membershipReadback)durable?.let {runCatching {receipts.failSourceSync(api.session.endpoint.identity,s.accountId,it,settleRefusal)}}
                synchronized(this){if(valid()){
                    if(settleRefusal&&!membershipReadback)receipt=null
                    mutable.value=mutable.value.copy(uncertain=durable!=null&&(!settleRefusal||membershipReadback),error=true,readbackFailed=membershipReadback,saveFailed=durable==null,observation=if(durable==null)observation else mutable.value.observation)
                }}
            }finally{synchronized(this){if(visit==v&&ticket==t&&scope===s)mutable.value=mutable.value.copy(busy=false)}}
        }
    }
}
