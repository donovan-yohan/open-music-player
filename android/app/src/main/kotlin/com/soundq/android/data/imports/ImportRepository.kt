package com.soundq.android.data.imports

import com.soundq.android.data.*
import com.soundq.android.data.discovery.*
import com.soundq.android.data.playlists.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

class ImportDraft internal constructor(val text:String) { override fun toString()="ImportDraft([redacted])" }
class ImportView internal constructor(internal val scope:AccountScope)
class ImportSubmission internal constructor(internal val scope:AccountScope,internal val source:ImportSource,internal val choice:SourceChoice?=null,internal val playlist:PlaylistId?=null) { internal var dispatched=false;internal var wireEntered=false;internal var canceled=false }
class ImportSourcePlan internal constructor(internal val view:ImportView,val choice:SourceChoice)
enum class ImportPlaylistPhase { AwaitingImport, AwaitingLibrary, AwaitingMembership, Confirmed }
data class ImportPlaylistConfirmation(val playlist:PlaylistId,val job:ImportJobId,val track:TrackId?,val phase:ImportPlaylistPhase)
data class ImportsState(val draft:ImportDraft=ImportDraft(""),val pending:Boolean=false,val consumed:Boolean=false,val acknowledgement:ImportAcknowledgement?=null,val selected:ImportJob?=null,val recent:List<ImportJob> = emptyList(),val loading:Boolean=false,val error:SafeFailure.Reason?=null,val invalidLink:Boolean=false,val sourceReceipt:SourceImportReceipt?=null,val durableReceipt:com.soundq.android.data.acquisition.IntakeReceipt?=null,val sourcePlan:ImportSourcePlan?=null,val playlistChoices:List<PlaylistSummary> = emptyList(),val playlistTotal:Int?=null,val chosenPlaylist:PlaylistSummary?=null,val playlistConfirmation:ImportPlaylistConfirmation?=null)
/** Account-owned evidence, separate from route/draft/read lifetimes. Never owns playback. */
class ImportRepository(private val session:AccountSession,private val api:SoundQApi,private val library:LibraryRepository) {
    private val mutable=MutableStateFlow(ImportsState())
    val state:StateFlow<ImportsState> = mutable
    private var owner:AccountScope?=null
    private var hydrated=false
    private var view:ImportView?=null
    private var submission:ImportSubmission?=null
    private var read:Any?=null
    private var identityVersion=0L
    private val consumedSourceSessions=mutableSetOf<String>()
    // Observation-only seam for deterministic capture/admission scheduling tests.
    internal var beforeIdentityReadAdmission:(()->Unit)?=null
    @Synchronized fun open():ImportView? {
        val scope=session.capture() ?: run {retire();return null}
        if(owner?.let(session::current)!=true)retire()
        owner=scope;read=null;mutable.value=mutable.value.copy(loading=false)
        if(!hydrated)try {
            hydrated=true
            val receipt=api.intakeReceipts.entries(session.endpoint.identity,scope.accountId).lastOrNull {it.kind in setOf("download","source")}
            if(receipt!=null)mutable.value=mutable.value.copy(consumed=true,durableReceipt=receipt,acknowledgement=receipt.job?.let {ImportAcknowledgement(ImportJobId(it),ImportStatus.Queued)},error=if(receipt.phase in setOf("pending","uncertain"))SafeFailure.Reason.Uncertain else null)
        }catch(_:Exception){mutable.value=mutable.value.copy(consumed=true,error=SafeFailure.Reason.StoreRejected)}
        return ImportView(scope).also {view=it}
    }
    @Synchronized fun current(candidate:ImportView)=view===candidate && session.current(candidate.scope)
    @Synchronized fun close(candidate:ImportView) {if(view===candidate){
        val post=submission
        if(post!=null&&!post.wireEntered&&mutable.value.pending) {
            post.canceled=true;post.dispatched=true
            mutable.value=mutable.value.copy(pending=false,sourceReceipt=mutable.value.sourceReceipt?.copy(phase=SourceImportPhase.DecisionRefused),error=SafeFailure.Reason.Retired)
        }
        view=null;read=null;mutable.value=mutable.value.copy(loading=false,sourcePlan=null,playlistChoices=emptyList(),playlistTotal=null,chosenPlaylist=null)
    }}
    @Synchronized fun edit(candidate:ImportView,text:String) {
        if(!current(candidate)||mutable.value.consumed)return
        mutable.value=mutable.value.copy(draft=ImportDraft(text),invalidLink=false,error=null)
    }
    @Synchronized fun claim(candidate:ImportView,expected:ImportDraft=mutable.value.draft):ImportSubmission? {
        if(!current(candidate)||mutable.value.draft!==expected||mutable.value.consumed||mutable.value.pending)return null
        val source=ImportSource.parse(mutable.value.draft.text)
        if(source==null){mutable.value=mutable.value.copy(invalidLink=true);return null}
        identityVersion++;read=null
        mutable.value=mutable.value.copy(pending=true,consumed=true,loading=false,acknowledgement=null,selected=null,error=null,invalidLink=false,playlistConfirmation=null)
        return ImportSubmission(candidate.scope,source).also {submission=it}
    }
    /** A read-only confirmation stage. The exact source remains owned by its Discover capability. */
    @Synchronized fun prepareSource(candidate:ImportView,choice:SourceChoice):Boolean {
        if(!current(candidate)||mutable.value.pending||mutable.value.consumed||!session.current(choice.scope)||!choice.valid()||choice.consumed||!choice.candidate.downloadable)return false
        read=null;mutable.value=mutable.value.copy(sourcePlan=ImportSourcePlan(candidate,choice),playlistChoices=emptyList(),playlistTotal=null,chosenPlaylist=null,loading=false,error=null)
        return true
    }
    private fun ownsPlan(candidate:ImportView,plan:ImportSourcePlan)=synchronized(this){current(candidate)&&plan.view===candidate&&mutable.value.sourcePlan===plan&&plan.choice.valid()&&!plan.choice.consumed}
    @Synchronized fun cancelSourcePlan(candidate:ImportView,plan:ImportSourcePlan) {
        if(current(candidate)&&mutable.value.sourcePlan===plan){read=null;mutable.value=mutable.value.copy(sourcePlan=null,playlistChoices=emptyList(),playlistTotal=null,chosenPlaylist=null,loading=false,error=null)}
    }
    fun loadSourcePlaylists(candidate:ImportView,plan:ImportSourcePlan,more:Boolean=false) {
        val offset=synchronized(this){
            if(!ownsPlan(candidate,plan)||more&&(mutable.value.playlistTotal==null||mutable.value.playlistChoices.size>=mutable.value.playlistTotal!!))return
            if(more)mutable.value.playlistChoices.size else 0
        }
        val token=beginRead(candidate) ?: return
        fun valid()=ownsRead(candidate,token)&&ownsPlan(candidate,plan)
        try {
            val page=api.playlists(candidate.scope,offset,::valid)
            if(!valid()){finishRead(candidate,token,SafeFailure.Reason.Retired);return}
            finishRead(candidate,token){s->
                val rows=if(more)s.playlistChoices+page.rows else page.rows
                if(rows.map {it.id}.distinct().size!=rows.size||rows.size>page.total||page.rows.isEmpty()&&rows.size<page.total)throw SafeFailure(SafeFailure.Reason.InvalidResponse)
                s.copy(playlistChoices=rows,playlistTotal=page.total,chosenPlaylist=s.chosenPlaylist?.let {target->rows.firstOrNull {it.id==target.id}})
            }
        }catch(e:Exception){finishRead(candidate,token,(e as? SafeFailure)?.reason ?: SafeFailure.Reason.Network)}
    }
    @Synchronized fun chooseSourcePlaylist(candidate:ImportView,plan:ImportSourcePlan,row:PlaylistSummary?):Boolean {
        if(!ownsPlan(candidate,plan)||mutable.value.loading||row!=null&&mutable.value.playlistChoices.none {it===row})return false
        mutable.value=mutable.value.copy(chosenPlaylist=row);return true
    }
    @Synchronized fun claimPlannedSource(candidate:ImportView,plan:ImportSourcePlan):ImportSubmission? {
        if(!ownsPlan(candidate,plan)||mutable.value.loading)return null
        return claimSource(candidate,plan.choice,mutable.value.chosenPlaylist?.id)
    }
    @Synchronized fun claimSource(candidate:ImportView,choice:SourceChoice,playlist:PlaylistId?=null):ImportSubmission? {
        if(!current(candidate)||mutable.value.pending||mutable.value.consumed||!session.current(choice.scope)||!choice.valid()||choice.consumed||choice.selection.id in consumedSourceSessions||!choice.candidate.downloadable)return null
        try {if(api.intakeReceipts.entries(session.endpoint.identity,candidate.scope.accountId).any {it.sessionId==choice.selection.id&&it.phase!="refused"})return null}catch(_:Exception){mutable.value=mutable.value.copy(error=SafeFailure.Reason.StoreRejected);return null}
        choice.consumed=true;consumedSourceSessions.add(choice.selection.id);identityVersion++;read=null
        mutable.value=ImportsState(draft=ImportDraft(choice.candidate.source.url),pending=true,consumed=true,recent=mutable.value.recent,sourceReceipt=SourceImportReceipt(choice))
        return ImportSubmission(candidate.scope,choice.candidate.source,choice,playlist).also {submission=it}
    }
    private fun beginRead(candidate:ImportView,identity:Long?=null):Any? = synchronized(this) {
        if(!current(candidate)||mutable.value.loading||mutable.value.pending||(identity!=null&&identity!=identityVersion))return null
        Any().also {read=it;mutable.value=mutable.value.copy(loading=true,error=null)}
    }
    private fun ownsRead(candidate:ImportView,token:Any)=synchronized(this){current(candidate)&&read===token}
    private fun finishRead(candidate:ImportView,token:Any,error:SafeFailure.Reason?=null,accept:(ImportsState)->ImportsState={it}) = synchronized(this) {
        if(ownsRead(candidate,token)){
            val previous=mutable.value
            val accepted=accept(previous)
            if(accepted.selected!==previous.selected)identityVersion++
            mutable.value=accepted.copy(loading=false,error=error);read=null
        }
    }
    fun check(candidate:ImportView) {
        val captured=synchronized(this){if(!current(candidate))return;Pair(mutable.value.selected?.id ?: mutable.value.acknowledgement?.id,identityVersion)}
        val id=captured.first ?: return
        beforeIdentityReadAdmission?.invoke()
        val token=beginRead(candidate,captured.second) ?: return
        try {
            val job=api.importJob(candidate.scope,id){ownsRead(candidate,token)}
            val membership=confirmPlaylist(candidate,job){ownsRead(candidate,token)}
            finishRead(candidate,token){it.copy(selected=job,playlistConfirmation=membership)}
        }
        catch(e:Exception){finishRead(candidate,token,(e as? SafeFailure)?.reason ?: SafeFailure.Reason.Network)}
    }
    fun recent(candidate:ImportView) {
        val token=beginRead(candidate) ?: return
        try {val jobs=api.recentImports(candidate.scope){ownsRead(candidate,token)};finishRead(candidate,token){it.copy(recent=jobs)}}
        catch(e:Exception){finishRead(candidate,token,(e as? SafeFailure)?.reason ?: SafeFailure.Reason.Network)}
    }
    @Synchronized fun select(candidate:ImportView,job:ImportJob) {
        if(!current(candidate)||mutable.value.pending||mutable.value.recent.none {it===job})return
        identityVersion++;read=null
        mutable.value=mutable.value.copy(selected=job,acknowledgement=null,loading=false,error=null,playlistConfirmation=null)
    }
    @Synchronized fun another(candidate:ImportView) {
        if(!current(candidate)||mutable.value.pending||mutable.value.sourceReceipt?.phase?.let {it !in setOf(SourceImportPhase.Accepted,SourceImportPhase.DecisionRefused)}==true)return
        // The old submission object can never dispatch again, even when its presentation is retired.
        identityVersion++;submission=null;read=null;mutable.value=ImportsState(recent=mutable.value.recent)
    }
    fun openLibrary(candidate:ImportView,expected:ImportJob?=state.value.selected):Boolean {
        val captured=synchronized(this){if(!current(candidate)||mutable.value.selected!==expected)return false;Pair(mutable.value.selected,identityVersion)}
        val selected=captured.first ?: return false
        val track=selected.track?.takeIf {selected.status==ImportStatus.Complete} ?: return false
        beforeIdentityReadAdmission?.invoke()
        val token=beginRead(candidate,captured.second) ?: return false
        // The sole Library owner certifies its actual generation-fenced read and paged row.
        val accepted=library.revealImported(track){ownsRead(candidate,token)}
        finishRead(candidate,token,if(accepted)null else SafeFailure.Reason.Network)
        return accepted && synchronized(this){current(candidate)&&identityVersion==captured.second&&mutable.value.selected===selected}
    }
    @Synchronized fun openPlaylistTarget(candidate:ImportView,expected:ImportPlaylistConfirmation,open:(PlaylistId)->Unit):Boolean {
        val selected=mutable.value.selected ?: return false
        if(!current(candidate)||mutable.value.pending||mutable.value.loading||mutable.value.playlistConfirmation!==expected||expected.phase!=ImportPlaylistPhase.Confirmed||selected.id!=expected.job||selected.track!=expected.track||selected.status!=ImportStatus.Complete)return false
        open(expected.playlist);return true
    }
    @Synchronized fun retire() {identityVersion++;hydrated=false;consumedSourceSessions.clear();owner=null;view=null;submission=null;read=null;mutable.value=ImportsState()}
    /** The backend attaches the captured target. Completion never issues a second playlist write. */
    private fun confirmPlaylist(candidate:ImportView,job:ImportJob,valid:()->Boolean):ImportPlaylistConfirmation? {
        val target=try {api.intakeReceipts.entries(session.endpoint.identity,candidate.scope.accountId).lastOrNull {it.kind=="source"&&it.job==job.id.value}?.playlistId?.let(::PlaylistId)}catch(_:Exception){throw SafeFailure(SafeFailure.Reason.StoreRejected)} ?: return null
        fun result(phase:ImportPlaylistPhase)=ImportPlaylistConfirmation(target,job.id,job.track,phase)
        val track=job.track?.takeIf {job.status==ImportStatus.Complete} ?: return result(ImportPlaylistPhase.AwaitingImport)
        if(api.trackDetailsSnapshot(candidate.scope,track,valid)==null)return result(ImportPlaylistPhase.AwaitingLibrary)
        val detail=api.playlistDetail(candidate.scope,target,valid)
        return result(if(detail.tracks.any {it.id==track})ImportPlaylistPhase.Confirmed else ImportPlaylistPhase.AwaitingMembership)
    }
    private fun owns(candidate:ImportSubmission)=synchronized(this){submission===candidate&&!candidate.canceled&&session.current(candidate.scope)}
    private fun publishSource(candidate:ImportSubmission,receipt:SourceImportReceipt,error:SafeFailure.Reason?=null,ack:ImportAcknowledgement?=null) = synchronized(this) {
        if(owns(candidate)) {
            if(ack!=null)identityVersion++
            mutable.value=mutable.value.copy(pending=false,sourceReceipt=receipt,error=error,acknowledgement=ack ?: mutable.value.acknowledgement,selected=if(ack!=null)null else mutable.value.selected,playlistConfirmation=if(ack!=null)null else mutable.value.playlistConfirmation)
        }
    }
    private fun submitSource(candidate:ImportSubmission) {
        val choice=candidate.choice ?: return
        var entered=false
        val receipt=mutable.value.sourceReceipt ?: return
        try {
            val decision=api.createSourceDecision(candidate.scope,choice,{owns(candidate)},admit={
                synchronized(this){(owns(candidate)&&choice.valid()).also {if(it){entered=true;candidate.wireEntered=true}}}
            },playlistId=candidate.playlist)
            val saved=receipt.copy(decision=decision,phase=SourceImportPhase.Queueing)
            synchronized(this){if(owns(candidate))mutable.value=mutable.value.copy(sourceReceipt=saved)}
            queueSource(candidate,saved) {choice.valid()}
        }catch(e:Exception){
            val reason=(e as? SafeFailure)?.reason ?: SafeFailure.Reason.Uncertain
            publishSource(candidate,receipt.copy(phase=if(!entered||reason==SafeFailure.Reason.Refused)SourceImportPhase.DecisionRefused else SourceImportPhase.DecisionUncertain),reason)
        }
    }
    private fun queueSource(candidate:ImportSubmission,receipt:SourceImportReceipt,admit:()->Boolean) {
        val decision=receipt.decision ?: return
        try {
            val ack=api.queueSourceDecision(candidate.scope,decision,{owns(candidate)},admit)
            publishSource(candidate,receipt.copy(phase=SourceImportPhase.Accepted),ack=ack)
        }catch(e:Exception){val reason=(e as? SafeFailure)?.reason ?: SafeFailure.Reason.Uncertain
            publishSource(candidate,receipt.copy(phase=if(reason in setOf(SafeFailure.Reason.Refused,SafeFailure.Reason.Retired))SourceImportPhase.QueueRefused else SourceImportPhase.QueueUncertain),reason)}
    }
    /** Explicit same-decision retry only; cannot save another selection decision. */
    fun retrySource(candidate:ImportView,expected:SourceImportReceipt) {
        val captured=synchronized(this){
            if(!current(candidate)||mutable.value.sourceReceipt!==expected||mutable.value.pending||mutable.value.loading||expected.decision==null||expected.phase !in setOf(SourceImportPhase.QueueRefused,SourceImportPhase.QueueUncertain,SourceImportPhase.ReadbackFailed))return
            val post=submission ?: return
            val receipt=expected.copy(phase=SourceImportPhase.Queueing)
            read=null;mutable.value=mutable.value.copy(pending=true,error=null,sourceReceipt=receipt);post to receipt
        }
        queueSource(captured.first,captured.second) {current(candidate)}
    }
    /** Read-only correlation of the original captured target, never a replay. */
    fun recoverSource(candidate:ImportView,expected:SourceImportReceipt) {
        val token=beginRead(candidate) ?: return
        val post=synchronized(this){if(mutable.value.sourceReceipt!==expected){finishRead(candidate,token);return};submission} ?: run {finishRead(candidate,token);return}
        fun valid()=ownsRead(candidate,token)&&owns(post)&&mutable.value.sourceReceipt===expected
        try {
            val decision=expected.decision?.let {api.sourceDecision(candidate.scope,it,::valid)} ?: api.findSourceDecision(candidate.scope,expected.choice,::valid)
            // SQL attachment precedes Redis publication. Only the job reader certifies publication.
            val publication=decision?.job?.let {id->runCatching {api.importJob(candidate.scope,id,::valid)}}
            val job=publication?.getOrNull()
            synchronized(this){if(valid()){
                val ack=job?.let {ImportAcknowledgement(it.id,it.status)}
                // Absence cannot prove an uncertain POST never committed. Keep original locked,
                // including the exact recovered decision needed for explicit publication retry.
                if(ack!=null || (decision!=null && mutable.value.selected!=null))identityVersion++
                mutable.value=mutable.value.copy(selected=if(decision!=null)null else mutable.value.selected,playlistConfirmation=if(decision!=null)null else mutable.value.playlistConfirmation,sourceReceipt=expected.copy(decision=decision ?: expected.decision,phase=if(ack!=null)SourceImportPhase.Accepted else if(decision!=null)SourceImportPhase.QueueRefused else SourceImportPhase.DecisionUncertain),acknowledgement=ack ?: mutable.value.acknowledgement,error=null)
            }}
            finishRead(candidate,token,publication?.exceptionOrNull()?.let {(it as? SafeFailure)?.reason ?: SafeFailure.Reason.Network})
        }catch(e:Exception){synchronized(this){if(valid())mutable.value=mutable.value.copy(sourceReceipt=expected.copy(phase=SourceImportPhase.ReadbackFailed))};finishRead(candidate,token,(e as? SafeFailure)?.reason ?: SafeFailure.Reason.Network)}
    }
    @Synchronized fun selectRetained(candidate:ImportView,id:ImportJobId):Boolean {
        if(!current(candidate)||mutable.value.pending)return false
        val receipt=try {api.intakeReceipts.entries(session.endpoint.identity,candidate.scope.accountId).lastOrNull {it.job==id.value}}catch(_:Exception){null} ?: return false
        identityVersion++;read=null
        mutable.value=ImportsState(consumed=true,acknowledgement=ImportAcknowledgement(id,ImportStatus.Queued),durableReceipt=receipt,recent=mutable.value.recent)
        return true
    }
    fun recoverDurable(candidate:ImportView,expected:com.soundq.android.data.acquisition.IntakeReceipt) {
        if(synchronized(this){mutable.value.durableReceipt!==expected})return
        val token=beginRead(candidate) ?: return
        fun valid()=ownsRead(candidate,token)&&mutable.value.durableReceipt===expected
        var recoveredDecision:SourceDecision?=null
        try {
            val decision=if(expected.kind=="source"&&expected.job==null)api.recoverDurableSource(candidate.scope,expected,::valid) else null
            recoveredDecision=decision
            if(decision!=null)synchronized(this){if(valid()){
                api.intakeReceipts.finish(session.endpoint.identity,candidate.scope.accountId,expected,"accepted",decisionId=decision.id)
                if(mutable.value.selected!=null)identityVersion++
                mutable.value=mutable.value.copy(selected=null,playlistConfirmation=null)
            }}
            val job=(expected.job?.let(::ImportJobId) ?: decision?.job)?.let {api.importJob(candidate.scope,it,::valid)}
            if(valid()&&decision!=null)api.intakeReceipts.finish(session.endpoint.identity,candidate.scope.accountId,expected,"accepted",job?.id?.value,decision.id)
            val membership=job?.let {confirmPlaylist(candidate,it,::valid)}
            finishRead(candidate,token){s->s.copy(selected=job,durableReceipt=expected.copy(job=job?.id?.value ?: expected.job,decisionId=decision?.id ?: expected.decisionId),playlistConfirmation=membership)}
        }catch(e:Exception){finishRead(candidate,token,(e as? SafeFailure)?.reason ?: SafeFailure.Reason.Network){s->s.copy(durableReceipt=expected.copy(decisionId=recoveredDecision?.id ?: expected.decisionId))}}
    }
    fun retryDurablePublication(candidate:ImportView,expected:com.soundq.android.data.acquisition.IntakeReceipt) {
        val decision=synchronized(this){
            if(!current(candidate)||mutable.value.durableReceipt!==expected||mutable.value.pending||mutable.value.loading||expected.kind!="source"||expected.job!=null)return
            SourceDecision(expected.decisionId ?: return,expected.sessionId ?: return,expected.candidateId ?: return,null).also {mutable.value=mutable.value.copy(pending=true,error=null)}
        }
        try {
            val ack=api.queueSourceDecision(candidate.scope,decision,{session.current(candidate.scope)},{current(candidate)})
            synchronized(this){if(session.current(candidate.scope)&&mutable.value.durableReceipt===expected){identityVersion++;mutable.value=mutable.value.copy(pending=false,selected=null,acknowledgement=ack,durableReceipt=expected.copy(job=ack.id.value),error=null,playlistConfirmation=null)}}
        }catch(e:Exception){synchronized(this){if(session.current(candidate.scope)&&mutable.value.durableReceipt===expected)mutable.value=mutable.value.copy(pending=false,error=(e as? SafeFailure)?.reason ?: SafeFailure.Reason.Uncertain)}}
    }
    fun submit(candidate:ImportSubmission) {
        synchronized(this) {
            if(submission!==candidate||candidate.dispatched||!session.current(candidate.scope))return
            candidate.dispatched=true
        }
        if(candidate.choice!=null){submitSource(candidate);return}
        try {
            // Closing a route does not revoke an already dispatched account-owned receipt.
            val ack=api.createImport(candidate.scope,candidate.source,admit={synchronized(this){
                (owns(candidate)&&view?.let(::current)==true).also {if(it)candidate.wireEntered=true}
            }},current={owns(candidate)})
            synchronized(this){if(submission===candidate && session.current(candidate.scope))mutable.value=mutable.value.copy(pending=false,acknowledgement=ack,error=null)}
        } catch(e:Exception) {
            synchronized(this){if(submission===candidate && session.current(candidate.scope))mutable.value=mutable.value.copy(pending=false,error=(e as? SafeFailure)?.reason ?: SafeFailure.Reason.Uncertain)}
        }
    }
}
