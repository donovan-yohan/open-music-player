package com.soundq.android.data.imports

import com.soundq.android.data.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*

/** Facts about a bounded, session-local batch, never all server imports. */
@ConsistentCopyVisibility
data class ImportBatchProgress internal constructor(val identity:Long,val active:Int,val complete:Int,val failed:Int,val unknown:Int,val needsChecking:Boolean=false)

/** Observation only. Its sole owner is ImportRepository, not a route or player. */
internal class ImportProgressObservation(private val session:AccountSession,private val api:SoundQApi) {
    internal var clock:()->Long={System.nanoTime()/1_000_000}
    private val mutable=MutableStateFlow<ImportBatchProgress?>(null)
    val state:StateFlow<ImportBatchProgress?> = mutable
    internal class Lease(val scope:AccountScope,val floor:Long) {
        val handled=mutableSetOf<Long>()
        val seenJobs=mutableSetOf<java.util.UUID>()
    }
    private data class Fact(val id:ImportJobId,var status:ImportStatus?=null,var attempted:Boolean=false,var readAt:Long=0L)
    private var owner:AccountScope?=null
    private var lease:Lease?=null
    private val facts=linkedMapOf<java.util.UUID,Fact>()
    private val uncertain=mutableSetOf<Long>()
    private var checking=false
    private var identity=0L
    private var started:Long?=null
    private var terminal:Long?=null
    private var reads=0
    private val active=setOf(ImportStatus.Queued,ImportStatus.Downloading,ImportStatus.Processing,ImportStatus.Uploading)

    private var foreground=false
    @Synchronized fun visible(value:Boolean) {foreground=value;if(!value)pause()}
    /** Worker-only journal snapshot. Old receipts are a boundary, never lifetime totals. */
    fun open():Lease? {
        if(!synchronized(this){foreground})return null
        val scope=session.capture()?.takeIf(session::remoteCurrent) ?: return null
        val floor=try {api.intakeReceipts.entries(session.endpoint.identity,scope.accountId).lastOrNull()?.operation ?: 0L}
            catch(_:Exception){return null} // Existing Imports retains rejected-store recovery.
        return synchronized(this) {
            if(!foreground||!session.remoteCurrent(scope))return null
            if(owner?.let(session::remoteCurrent)!=true)clear()
            owner=scope
            Lease(scope,floor).also {next->
                next.seenJobs.addAll(facts.keys);lease=next
                // A new foreground lease revalidates active or previously unavailable facts once.
                facts.values.filter {it.status in active||it.status==null}.forEach {it.attempted=false;it.readAt=clock()-POLL_MS}
                publish(next)
            }
        }
    }
    @Synchronized fun current(candidate:Lease)=foreground&&lease===candidate&&session.remoteCurrent(candidate.scope)
    @Synchronized fun pause(candidate:Lease?=lease) {if(lease===candidate){lease=null;mutable.value=null}}
    @Synchronized fun retire() {lease=null;owner=null;clear()}
    private fun clear() {facts.clear();uncertain.clear();checking=false;started=null;terminal=null;reads=0;mutable.value=null}

    fun receipts(candidate:Lease) {
        if(!current(candidate))return
        val rows=try {api.intakeReceipts.entries(session.endpoint.identity,candidate.scope.accountId)}
            catch(_:Exception){synchronized(this){if(current(candidate)){checking=true;begin();publish(candidate)}};return}
        synchronized(this) {
            if(!current(candidate))return
            for(row in rows) {
                // Renewed leases exclude history, not settlement of uncertainty this owner already observed.
                if((row.operation<=candidate.floor&&row.operation !in uncertain)||row.operation in candidate.handled||row.kind !in setOf("download","source","queue"))continue
                if(candidate.handled.size>=MAX_RECEIPTS){checking=true;begin();break}
                if(row.phase=="uncertain") {begin();if(uncertain.size<MAX_JOBS)uncertain.add(row.operation)else checking=true}
                if(row.phase !in setOf("accepted","refused"))continue
                candidate.handled.add(row.operation);uncertain.remove(row.operation)
                // Receipt settlement is not a job observation; decision-only/refused rows add no counts.
                if(row.phase!="accepted"||row.job==null) {
                    // Retire an empty settled episode before a later row can begin another one.
                    if(facts.isEmpty()&&uncertain.isEmpty()&&!checking)clear()
                    continue
                }
                val id=ImportJobId(row.job)
                val key=java.util.UUID.fromString(id.value)
                if(key in candidate.seenJobs)continue
                begin()
                if(facts.size>=MAX_JOBS||candidate.seenJobs.size>=MAX_RECEIPTS){checking=true;continue}
                candidate.seenJobs.add(key);facts[key]=Fact(id);terminal=null
            }
            publish(candidate)
        }
    }
    private fun begin() {if(started==null){identity++;started=clock();reads=0;terminal=null}}

    /** One initial exact read per admitted job; paced subsequent reads only for observed active jobs. */
    fun refresh(candidate:Lease) {
        val due=synchronized(this) {
            advance(candidate)
            if(!current(candidate))return
            facts.values.filter {!it.attempted||it.status in active&&clock()-it.readAt>=POLL_MS}.toList()
        }
        for(fact in due) {
            val admitted=synchronized(this) {
                if(!current(candidate)||facts.values.none {it===fact}||expired())false
                else if(reads>=MAX_READS){checking=true;facts.values.filter {it.status in active||!it.attempted}.forEach {it.status=null;it.attempted=true};publish(candidate);false}
                else {reads++;fact.attempted=true;fact.readAt=clock();true}
            }
            if(!admitted)continue
            fun valid()=synchronized(this){current(candidate)&&!expired()&&facts.values.any {it===fact}}
            val result=runCatching {if(!valid())throw SafeFailure(SafeFailure.Reason.Retired);api.importJob(candidate.scope,fact.id,::valid)}
            synchronized(this) {
                if(valid()) {
                    fact.status=result.getOrNull()?.takeIf {it.id==fact.id}?.status
                    publish(candidate)
                }
            }
        }
        synchronized(this){advance(candidate)}
    }
    private fun expired()=started?.let {clock()-it>=EXPIRY_MS}==true
    @Synchronized fun advance(candidate:Lease) {
        if(!current(candidate))return
        if(expired()&&facts.values.any {it.status in active||!it.attempted}) {
            facts.values.filter {it.status in active||!it.attempted}.forEach {it.status=null;it.attempted=true}
            checking=true
        }
        if(terminal?.let {clock()-it>=DWELL_MS}==true)clear()
        publish(candidate)
    }
    private fun publish(candidate:Lease) {
        if(!current(candidate))return
        val completed=facts.values.count {it.status==ImportStatus.Complete}
        if(facts.isEmpty()&&uncertain.isEmpty()&&!checking){mutable.value=null;return}
        if(facts.isNotEmpty()&&completed==facts.size&&uncertain.isEmpty()&&!checking) {
            if(terminal==null)terminal=clock()
        } else terminal=null
        mutable.value=ImportBatchProgress(identity,facts.values.count {it.status in active},completed,
            facts.values.count {it.status==ImportStatus.Failed},facts.values.count {it.status==null},checking||uncertain.isNotEmpty())
    }
    @Synchronized fun nextDelay(candidate:Lease):Long? {
        if(!current(candidate))return null
        terminal?.let {return (DWELL_MS-(clock()-it)).coerceAtLeast(1)}
        val due=facts.values.filter {!it.attempted||it.status in active}.minOfOrNull {
            if(!it.attempted)0L else (POLL_MS-(clock()-it.readAt)).coerceAtLeast(0)
        } ?: return null
        val expiry=started?.let {EXPIRY_MS-(clock()-it)} ?: EXPIRY_MS
        return minOf(due,expiry).coerceAtLeast(1)
    }
    @Synchronized fun owns(expected:ImportBatchProgress)=mutable.value===expected&&lease?.let(::current)==true
    @Synchronized fun dismiss(expected:ImportBatchProgress) {if(owns(expected))clear()}

    /** No idle timer. Events wake journal reconciliation; only active facts/dwell own a deadline. */
    suspend fun observe(events:Flow<Unit>)=coroutineScope {
        val captured=open() ?: return@coroutineScope
        val wake=Channel<Unit>(Channel.CONFLATED)
        val signals=launch {events.collect {wake.trySend(Unit)}}
        try {
            while(isActive&&current(captured)) {
                receipts(captured);refresh(captured)
                val wait=nextDelay(captured)
                if(wait==null)wake.receive() else withTimeoutOrNull(wait){wake.receive()}
            }
        } finally {signals.cancel();wake.close();pause(captured)}
    }
    companion object {
        const val MAX_JOBS=32
        const val MAX_RECEIPTS=256
        const val MAX_READS=120
        const val POLL_MS=3_000L
        const val DWELL_MS=2_500L
        const val EXPIRY_MS=10*60_000L
    }
}
