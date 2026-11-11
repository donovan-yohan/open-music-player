package com.soundq.android.data.acquisition

import com.soundq.android.data.*
import com.soundq.android.data.discovery.SourceCandidate
import com.soundq.android.data.imports.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

class AcquisitionView internal constructor(internal val scope:AccountScope)
data class AcquisitionState(val busy:Boolean=false,val error:SafeFailure.Reason?=null,val queue:ServerImportQueue?=null,val playlist:PlaylistImportProgress?=null,val research:ResearchProgress?=null,val review:ResearchReview?=null,val receipts:List<IntakeReceipt> = emptyList(),val consent:Boolean=false,val uncertain:Boolean=false,val events:List<ResearchEvent> = emptyList(),val reviewedImport:ImportAcknowledgement?=null)
/** Acquisition operations have no player reference. Explicit claims happen before worker scheduling. */
class AcquisitionRepository(private val session:AccountSession,private val api:SoundQApi) {
    private val mutable=MutableStateFlow(AcquisitionState());val state:StateFlow<AcquisitionState> = mutable
    private var view:AcquisitionView?=null;private var owner:AccountScope?=null
    private class Flight(val scope:AccountScope,val write:Boolean) {var entered=false;var receipt:IntakeReceipt?=null;var work:(()->Unit)?=null}
    private var flight:Flight?=null
    private val usedReviews=mutableSetOf<String>()
    private var unresolved:IntakeReceipt?=null
    @Synchronized fun open():AcquisitionView? {
        val scope=session.capture()?.takeIf(session::remoteCurrent) ?: return null
        if(owner?.let(session::current)!=true)retire()
        owner=scope
        try {
            val saved=receipts(scope)
            unresolved=saved.lastOrNull {it.kind in setOf("queue","playlist","research","review")&&it.phase in setOf("pending","uncertain")}
            mutable.value=mutable.value.copy(receipts=saved,uncertain=unresolved!=null)
        }catch(_:Exception){mutable.value=mutable.value.copy(error=SafeFailure.Reason.StoreRejected,uncertain=true)}
        return AcquisitionView(scope).also {view=it}
    }
    /** Completion retires a cancelled, never-entered claim by identity, not a newer route's work. */
    fun schedule(scope:CoroutineScope,work:(() -> Unit)?,dispatcher:CoroutineDispatcher=Dispatchers.IO):Job? {
        if(work==null)return null
        val token=synchronized(this){flight?.takeIf {it.work===work}} ?: return null
        return scope.launch(dispatcher){work()}.also {job->job.invokeOnCompletion {synchronized(this){releaseUnentered(token)}}}
    }
    private fun releaseUnentered(token:Flight) {
        if(flight!==token||token.write&&token.entered)return
        // A worker may have prepared its receipt while still waiting for wire admission.
        token.receipt?.let {r->try {api.intakeReceipts.finish(session.endpoint.identity,token.scope.accountId,r,"refused",r.job)}catch(_:Exception){unresolved=r;mutable.value=mutable.value.copy(error=SafeFailure.Reason.StoreRejected,uncertain=true)}}
        flight=null;mutable.value=mutable.value.copy(busy=false)
    }
    @Synchronized fun closeCurrent(){view?.let(::close)}
    @Synchronized fun current(v:AcquisitionView)=view===v&&session.remoteCurrent(v.scope)
    @Synchronized fun close(v:AcquisitionView){if(view===v){view=null;flight?.let(::releaseUnentered)}}
    @Synchronized fun retire(){view=null;owner=null;flight=null;usedReviews.clear();unresolved=null;mutable.value=AcquisitionState()}
    @Synchronized fun consent(v:AcquisitionView,value:Boolean){if(current(v)&&!mutable.value.busy)mutable.value=mutable.value.copy(consent=value)}
    private fun receipts(scope:AccountScope)=api.intakeReceipts.entries(session.endpoint.identity,scope.accountId)
    @Synchronized fun refreshReceipts(v:AcquisitionView){if(current(v))try {mutable.value=mutable.value.copy(receipts=receipts(v.scope))}catch(_:Exception){mutable.value=mutable.value.copy(error=SafeFailure.Reason.StoreRejected)}}
    /** No closure can be invoked twice, or borrow a later mounted route. */
    private fun claim(v:AcquisitionView,kind:String?,job:String?=null,recovery:String?=null,sessionId:String?=null,candidateId:String?=null,work:(()->Boolean,()->Boolean)->((AcquisitionState)->AcquisitionState)): (() -> Unit)? = synchronized(this) {
        if(!current(v)||flight!=null||(kind!=null&&mutable.value.uncertain))return null
        val token=Flight(v.scope,kind!=null);flight=token;mutable.value=mutable.value.copy(busy=true,error=null)
        var dispatched=false
        val result:(()->Unit)={
            val allowed=synchronized(this){if(dispatched)false else {dispatched=true;flight===token&&current(v)}}
            if(allowed){
                var receipt:IntakeReceipt?=null
                fun valid()=synchronized(this){flight===token&&session.remoteCurrent(v.scope)&&(kind!=null&&token.entered||current(v))}
                fun admit()=synchronized(this){(flight===token&&current(v)).also {if(it)token.entered=true}}
                try {
                    synchronized(this){
                        if(flight!==token||!current(v))throw SafeFailure(SafeFailure.Reason.Retired)
                        if(kind!=null)receipt=api.intakeReceipts.begin(session.endpoint.identity,v.scope.accountId,kind,sessionId,candidateId,job=job).also {token.receipt=it}
                    }
                    val apply=work(::valid,::admit)
                    synchronized(this){if(valid()){
                        val next=apply(mutable.value)
                        receipt?.let {r->
                            api.intakeReceipts.finish(session.endpoint.identity,v.scope.accountId,r,"accepted",when(kind){"playlist"->next.playlist?.id?.value;"research"->next.research?.id?.value;"queue"->next.reviewedImport?.id?.value ?: job;else->job},decisionId=if(kind=="review")next.review?.decision else r.decisionId)
                            if(unresolved?.operation==r.operation)unresolved=null
                        }
                        unresolved?.takeIf {kind==null && it.kind==recovery && (it.kind=="queue" || it.job==job&&job!=null)}?.let {r->
                            api.intakeReceipts.finish(session.endpoint.identity,v.scope.accountId,r,"accepted",r.job);unresolved=null
                        }
                        mutable.value=next.copy(busy=false,error=null,uncertain=unresolved!=null,receipts=receipts(v.scope));flight=null
                    }}
                }catch(e:Exception){synchronized(this){if(flight===token&&session.current(v.scope)){
                    val reason=(e as? SafeFailure)?.reason ?: SafeFailure.Reason.Uncertain
                    val uncertain=kind!=null&&token.entered&&reason !in setOf(SafeFailure.Reason.Refused,SafeFailure.Reason.Capacity)
                    receipt?.let {r->runCatching {api.intakeReceipts.finish(session.endpoint.identity,v.scope.accountId,r,if(uncertain)"uncertain" else "refused",job)}}
                    if(uncertain)unresolved=receipt?.copy(phase="uncertain",job=job)
                    mutable.value=mutable.value.copy(busy=false,error=reason,uncertain=mutable.value.uncertain||uncertain);flight=null
                }}}
            }else synchronized(this){if(flight===token){flight=null;mutable.value=mutable.value.copy(busy=false)}}
        };token.work=result;result
    }
    fun loadQueue(v:AcquisitionView)=claim(v,null,recovery="queue"){valid,_->val q=api.serverImports(v.scope,valid);{s->s.copy(queue=q)}}
    fun manageQueue(v:AcquisitionView,snapshot:ServerImportQueue,operation:String,item:ServerImportItem?=null,position:Int?=null):(() -> Unit)? {
        synchronized(this){
            if(mutable.value.queue!==snapshot||operation !in setOf("retry","remove","reorder","clear"))return null
            if(operation!="clear"&&(item==null||snapshot.items.none {it===item}))return null
            if(operation=="retry"&&item?.retry!=true||operation=="remove"&&item?.remove!=true)return null
            if(operation=="reorder"&&position !in snapshot.items.indices)return null
        }
        return claim(v,"queue"){valid,admit->val q=api.manageServerImport(v.scope,operation,item?.id,position,valid,admit);{s->s.copy(queue=q)}}
    }
    fun startPlaylist(v:AcquisitionView,url:String,name:String,maxItems:Int,description:String=""):(() -> Unit)? {
        val source=ImportSource.parse(url)?.takeIf {it.provider=="youtube"} ?: return null
        val parsed=source.url.toHttpUrlOrNull() ?: return null
        if(parsed.queryParameter("list").isNullOrBlank()||maxItems !in 1..1000||name.length>200||description.length>5000)return null
        return claim(v,"playlist"){valid,admit->val progress=api.createPlaylistImport(v.scope,source,name,maxItems,valid,admit,description);{s->s.copy(playlist=progress)}}
    }
    fun loadPlaylist(v:AcquisitionView,id:ImportJobId)=claim(v,null,job=id.value,recovery="playlist"){valid,_->val p=api.playlistImport(v.scope,id,valid);{s->s.copy(playlist=p)}}
    /** Only an acknowledged current observation can navigate; never starts listening or a write. */
    @Synchronized fun openPlaylist(v:AcquisitionView,expected:PlaylistImportProgress,open:(Long)->Unit):Boolean {
        if(!current(v)||mutable.value.busy||mutable.value.playlist!==expected||expected.imported<=0)return false
        open(expected.playlistId)
        return true
    }
    fun startResearch(v:AcquisitionView,query:String):(() -> Unit)? {
        synchronized(this){if(!mutable.value.consent||query.isBlank()||query.toByteArray().size>512)return null}
        val key=java.util.UUID.randomUUID().toString()
        return claim(v,"research"){valid,admit->val r=api.startResearch(v.scope,query.trim(),key,valid,admit);{s->s.copy(research=r,review=null,consent=false,events=emptyList(),reviewedImport=null)}}
    }
    fun loadResearch(v:AcquisitionView,id:ImportJobId)=claim(v,null,job=id.value,recovery="research"){valid,_->
        val r=api.research(v.scope,id,valid)
        val previous=synchronized(this){mutable.value.research}
        if(previous?.id==r.id&&r.revision<previous.revision)throw SafeFailure(SafeFailure.Reason.InvalidResponse);
        {s:AcquisitionState->s.copy(research=r,review=if(s.research?.id==r.id&&s.research.revisionId==r.revisionId)s.review else null,events=if(s.research?.id==r.id)s.events else emptyList())}
    }
    fun loadEvents(v:AcquisitionView,expected:ResearchProgress):(() -> Unit)? {
        val after=synchronized(this){if(mutable.value.research!==expected)return null;mutable.value.events.lastOrNull()?.sequence ?: 0}
        return claim(v,null){valid,_->val events=api.researchEvents(v.scope,expected.id,after,valid);{s->s.copy(events=s.events+events.rows)}}
    }
    fun restoreReview(v:AcquisitionView,receipt:IntakeReceipt) {
        synchronized(this){
            if(!current(v)||mutable.value.busy||mutable.value.receipts.none {it===receipt}||receipt.kind!="review"||receipt.phase!="accepted")return
            mutable.value=mutable.value.copy(review=ResearchReview(receipt.decisionId ?: return,receipt.candidateId.orEmpty()),reviewedImport=null)
        }
    }
    fun importReviewed(v:AcquisitionView,expected:ResearchReview):(() -> Unit)? {
        synchronized(this){if(mutable.value.review!==expected||mutable.value.reviewedImport!=null)return null}
        return claim(v,"queue"){valid,admit->val ack=api.queueResearchReview(v.scope,expected.decision,valid,admit);{s->s.copy(reviewedImport=ack)}}
    }
    fun mutateResearch(v:AcquisitionView,expected:ResearchProgress,operation:String):(() -> Unit)? {
        synchronized(this){if(mutable.value.research!==expected||operation !in setOf("cancel","retry")||operation=="cancel"&&!expected.active||operation=="retry"&&(!expected.canRetry||!mutable.value.consent))return null}
        return claim(v,"research",expected.id.value){valid,admit->val r=api.mutateResearch(v.scope,expected.id,operation,valid,admit);{s->s.copy(research=r,consent=false)}}
    }
    fun review(v:AcquisitionView,expected:ResearchProgress,candidate:SourceCandidate,action:String,reason:String=""):(() -> Unit)? {
        val identity="${expected.id.value}:${expected.revisionId}:${candidate.id}"
        synchronized(this){if(mutable.value.research!==expected||expected.candidates.none {it===candidate}||action !in setOf("accepted","overridden")||identity in usedReviews)return null}
        if(reason.toByteArray().size>512||reason.contains("://")||action=="accepted"&&expected.recommended!=candidate.id||action=="overridden"&&reason.isBlank())return null
        if(runCatching {receipts(v.scope).any {it.kind=="review"&&it.sessionId==expected.revisionId&&it.candidateId==candidate.id&&it.phase!="refused"}}.getOrDefault(true))return null
        val key=java.util.UUID.randomUUID().toString()
        val work=claim(v,"review",expected.id.value,sessionId=expected.revisionId,candidateId=candidate.id){valid,admit->val r=api.reviewResearch(v.scope,expected.id,candidate,action,key,reason,valid,admit);{s->s.copy(review=r,reviewedImport=null)}} ?: return null
        synchronized(this){usedReviews.add(identity)};return work
    }
}
