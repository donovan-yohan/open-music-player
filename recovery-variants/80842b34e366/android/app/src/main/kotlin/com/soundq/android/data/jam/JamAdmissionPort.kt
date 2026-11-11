package com.soundq.android.data.jam

import com.soundq.android.data.*
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/** A one-shot handoff to the existing Media3 owner. It holds no queue or playback state. */
class JamAdmissionPort(private val session:AccountSession) {
    class Ticket internal constructor(val id:String,val scope:AccountScope,val track:Track,val requestId:String,val incarnation:String,val valid:()->Boolean,internal val authoritySession:String?=null,internal val provenance:JamOccurrence?=null,internal val lookupOnly:Boolean=false) {
        internal val result=CompletableFuture<AdmissionReceipt>()
    }
    @Volatile var incarnation:String?=null
        private set
    private val pending=java.util.concurrent.ConcurrentHashMap<String,Ticket>()
    private data class Authority(val service:String?,val scope:AccountScope?)
    @Volatile private var authority=Authority(null,null)
    /** Bind the actual service lifetime, not a panel or constant fallback. */
    @Synchronized fun attachOwner(serviceId:String) {
        require(UUID.fromString(serviceId).toString()==serviceId&&serviceId!="00000000-0000-0000-0000-000000000000")
        authority=Authority(serviceId,null);replaceOwner()
    }
    /** Only the canonical service reports an admitted account. Never nest its
     * monitor around AccountSession's monitor; state collectors can run inline. */
    fun bindAccount(scope:AccountScope?) {
        val next=scope?.takeIf(session::current)
        synchronized(this) {
            val before=authority
            if(before.scope==null&&next==null)return
            if(before.scope!=null&&next!=null&&before.scope.owner===next.owner&&before.scope.epoch==next.epoch&&before.scope.accountId==next.accountId)return
            authority=before.copy(scope=next);replaceOwner()
        }
    }
    fun hostSession(scope:AccountScope):String? {
        val seen=authority;val owner=seen.scope ?: return null;val service=seen.service ?: return null
        if(owner.owner!==scope.owner||owner.epoch!=scope.epoch||owner.accountId!=scope.accountId||!session.remoteCurrent(owner)||authority!==seen)return null
        return "$service:${owner.epoch}"
    }
    @Synchronized fun replaceOwner():String=UUID.randomUUID().toString().also {incarnation=it;pending.values.forEach {t->t.result.completeExceptionally(SafeFailure(SafeFailure.Reason.Retired))};pending.clear()}
    @Synchronized fun detachOwner(){authority=Authority(null,null);incarnation=null;pending.values.forEach {t->t.result.completeExceptionally(SafeFailure(SafeFailure.Reason.Retired))};pending.clear()}
    fun request(scope:AccountScope,track:Track,requestId:String,expected:String,valid:()->Boolean,send:(String)->Unit):AdmissionReceipt {
        return sendTicket(scope,track,requestId,expected,null,valid,send)
    }
    fun requestApproved(scope:AccountScope,track:Track,requestId:String,expected:String,authoritySession:String,valid:()->Boolean,send:(String)->Unit):AdmissionReceipt {
        require(authoritySession.isNotBlank()&&authoritySession.toByteArray().size<=128)
        return sendTicket(scope,track,requestId,expected,authoritySession,valid,send)
    }
    fun requestApproved(scope:AccountScope,track:Track,requestId:String,expected:String,authoritySession:String,provenance:JamOccurrence,valid:()->Boolean,send:(String)->Unit):AdmissionReceipt {
        require(provenance.requestId==requestId&&provenance.sessionId==authoritySession)
        return sendTicket(scope,track,requestId,expected,authoritySession,valid,send,provenance,false)
    }
    /** Read-only reconciliation. An absent key never authorizes another insert. */
    fun lookupApproved(scope:AccountScope,track:Track,requestId:String,expected:String,authoritySession:String,provenance:JamOccurrence,valid:()->Boolean,send:(String)->Unit):AdmissionReceipt {
        require(provenance.requestId==requestId&&provenance.sessionId==authoritySession)
        return sendTicket(scope,track,requestId,expected,authoritySession,valid,send,provenance,true)
    }
    private fun sendTicket(scope:AccountScope,track:Track,requestId:String,expected:String,authoritySession:String?,valid:()->Boolean,send:(String)->Unit,provenance:JamOccurrence?=null,lookupOnly:Boolean=false):AdmissionReceipt {
        require(pending.isEmpty())
        if(!session.remoteCurrent(scope)||incarnation!=expected||(authoritySession!=null&&hostSession(scope)!=authoritySession)||!valid())throw SafeFailure(SafeFailure.Reason.Retired)
        val ticket=Ticket(UUID.randomUUID().toString(),scope,track,requestId,expected,valid,authoritySession,provenance,lookupOnly)
        pending[ticket.id]=ticket
        try {send(ticket.id);return ticket.result.get(20,TimeUnit.SECONDS)} finally {pending.remove(ticket.id)}
    }
    fun consume(id:String,insert:(Track)->String):Boolean {
        return consumeWithProvenance(id){track,provenance,lookupOnly->require(provenance==null&&!lookupOnly);insert(track)}
    }
    fun consumeWithProvenance(id:String,consume:(Track,JamOccurrence?,Boolean)->String):Boolean {
        val ticket=pending.remove(id) ?: return false
        return try {
            if(!session.remoteCurrent(ticket.scope)||incarnation!=ticket.incarnation||(ticket.authoritySession!=null&&hostSession(ticket.scope)!=ticket.authoritySession)||!ticket.valid())throw SafeFailure(SafeFailure.Reason.Retired)
            val occurrence=consume(ticket.track,ticket.provenance,ticket.lookupOnly)
            ticket.result.complete(AdmissionReceipt(ticket.requestId,ticket.authoritySession ?: ticket.incarnation,occurrence,incarnation));true
        }catch(e:Exception){ticket.result.completeExceptionally(e);false}
    }
    fun refused(id:String){pending.remove(id)?.result?.completeExceptionally(SafeFailure(SafeFailure.Reason.Refused))}
}
