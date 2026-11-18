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
data class PlaylistSourceSyncState(val playlist:PlaylistId?=null,val observation:SourceSyncObservation?=null,val busy:Boolean=false,val uncertain:Boolean=false,val error:Boolean=false,val readbackFailed:Boolean=false)
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
class PlaylistSourceSyncRepository(private val api:SoundQApi,private val detail:PlaylistDetailRepository,private val receipts:IntakeReceipts=IntakeReceipts(),private val newOperation:()->String={UUID.randomUUID().toString()}) {
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
    @Synchronized fun refresh():(() -> Unit)? {
        val id=mutable.value.playlist ?: return null;val s=scope ?: return null
        if(mutable.value.busy||!current(visit,s,id))return null
        val v=visit;val t=++ticket;val pending=receipt
        mutable.value=mutable.value.copy(busy=true,error=false)
        val ran=java.util.concurrent.atomic.AtomicBoolean(false)
        return work@{
            if(!ran.compareAndSet(false,true))return@work
            fun valid()=synchronized(this){current(v,s,id)&&ticket==t}
            try {
                val observed=api.playlistSourceSync(s,id,pending?.job,::valid)
                val op=observed.operation
                if(pending?.job!=null&&op!=null)require(op.id==pending.job)
                synchronized(this){if(valid())mutable.value=mutable.value.copy(observation=observed,uncertain=pending!=null&&op==null)}
                val before=synchronized(this){if(valid())detail.managementDetail()else null}
                val after=if(op?.accepted==true&&before!=null)api.playlistManagementSnapshot(s,id,::valid) else null
                synchronized(this){if(valid()) {
                    val published=after!=null&&before!=null&&detail.publishManagement(before,if(after==before)before else after)
                    val reconciled=op?.accepted!=true||published
                    mutable.value=mutable.value.copy(observation=observed,uncertain=pending!=null&&op==null,readbackFailed=!reconciled)
                    if(op!=null&&pending!=null&&reconciled)receipts.finish(api.session.endpoint.identity,s.accountId,pending,"accepted",op.id)
                    if(op!=null&&!op.active&&reconciled)receipt=null
                }}
            }catch(_:Exception){synchronized(this){if(valid())mutable.value=mutable.value.copy(error=true,readbackFailed=mutable.value.observation?.operation?.accepted==true)}}
            finally{synchronized(this){if(visit==v&&ticket==t&&scope===s)mutable.value=mutable.value.copy(busy=false)}}
        }
    }
    @Synchronized fun start():(() -> Unit)? {
        val id=mutable.value.playlist ?: return null;val s=scope ?: return null;val observation=mutable.value.observation ?: return null
        val captured=detail.managementDetail() ?: return null
        if(!current(visit,s,id)||captured.playlist.id!=id||!captured.canManage||mutable.value.busy||!observation.eligible||observation.operation?.let {it.active&&!it.accepted}==true)return null
        val old=receipt
        val retry=mutable.value.uncertain&&old!=null
        val key=if(retry)old.job!! else newOperation()
        val binding=if(retry)old.candidateId!!.toLong() else observation.binding
        val v=visit;val t=++ticket
        // An older operation's completion is not acknowledgement of this new intent.
        mutable.value=mutable.value.copy(busy=true,error=false,readbackFailed=false,observation=observation.copy(operation=if(retry)observation.operation else null))
        val ran=java.util.concurrent.atomic.AtomicBoolean(false)
        return work@{
            if(!ran.compareAndSet(false,true))return@work
            fun valid()=synchronized(this){current(v,s,id)&&ticket==t}
            var durable=old
            try {
                if(!valid()||!detail.ownsManagement(captured))return@work
                if(!retry){durable=receipts.begin(api.session.endpoint.identity,s.accountId,"playlist-sync",job=key,playlistId=id.value,candidateId=binding.toString());synchronized(this){if(valid())receipt=durable}}
                val ack=api.startPlaylistSourceSync(s,id,key,binding,{valid()&&detail.ownsManagement(captured)},::valid)
                require(ack.id==key)
                receipts.finish(api.session.endpoint.identity,s.accountId,requireNotNull(durable),"accepted",key)
                synchronized(this){if(valid())mutable.value=mutable.value.copy(observation=observation.copy(operation=ack),uncertain=false)}
            }catch(error:Exception){
                val refused=(error as? SafeFailure)?.reason==SafeFailure.Reason.Refused
                durable?.let {runCatching {receipts.finish(api.session.endpoint.identity,s.accountId,it,if(refused)"refused"else "uncertain",key)}}
                synchronized(this){if(valid()){if(refused)receipt=null;mutable.value=mutable.value.copy(uncertain=!refused,error=true)}}
            }finally{synchronized(this){if(visit==v&&ticket==t&&scope===s)mutable.value=mutable.value.copy(busy=false)}}
        }
    }
}
