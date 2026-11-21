package com.soundq.android.data.trackdetails

import com.soundq.android.data.*
import com.soundq.android.data.playlists.LibraryTrackCapture
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

@JvmInline value class RecordingMbid(val value:String) {
    init { require(Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}").matches(value)) }
}
data class MetadataDraft(val title:String?=null,val artist:String?=null,val album:String?=null) {
    init {listOf(title,artist,album).forEach {require(it==null||it.codePointCount(0,it.length)<=500)}}
    fun normalized()=MetadataDraft(title?.trim()?.takeIf {it.isNotEmpty()},artist?.trim()?.takeIf {it.isNotEmpty()},album?.trim()?.takeIf {it.isNotEmpty()})
}
data class TrackDetails(val track:Track,val edited:Boolean,val verified:Boolean,val sourceQuality:String?=null,val recording:RecordingMbid?=null,val suggestions:List<MatchSuggestion> = emptyList(),val sourceUrl:String?=null)
sealed interface DetailsAction {data class Metadata(val draft:MetadataDraft):DetailsAction; data object Remove:DetailsAction; data class Verification(val action:VerificationAction):DetailsAction; data class Analysis(val observed:AnalysisDetail,val correction:AnalysisCorrection):DetailsAction}
class PlayerDetailsCapture internal constructor(val scope:AccountScope,val trackId:TrackId,internal val valid:()->Boolean)
class DetailsRoute internal constructor(val scope:AccountScope,val trackId:TrackId,internal val sourceValid:()->Boolean={true},val fromPlayer:Boolean=false) {@Volatile internal var active=true}
class DetailsTicket internal constructor(val route:DetailsRoute,val observed:TrackDetails,val action:DetailsAction,internal val libraryState:LibraryState) {internal var consumed=false}
enum class RemovalIssue { NotSent, NotSentLocalCleanupFailed, Unconfirmed, ConfirmedLocalSettleFailed }
data class TrackDetailsState(val detail:TrackDetails?=null,val outcome:MutationOutcome?=null,val loading:Boolean=false,val error:SafeFailure.Reason?=null,val missing:Boolean=false,val analysis:AnalysisDetail?=null,val analysisError:SafeFailure.Reason?=null,val analysisAbsent:Boolean=false,val reconciled:Boolean=false,val removalBlocked:Boolean=false,val removalIssue:RemovalIssue?=null,private val outcomeDescribedByRemovalNotice:Boolean=false) {
    // A retained removal notice can outlive the command whose result it described.
    internal val genericOutcome get()=outcome.takeUnless {outcomeDescribedByRemovalNotice}
}
/** One observation and one non-replayable command per mounted, account-qualified route. */
class TrackDetailsRepository(private val api:SoundQApi,private val library:LibraryRepository) {
    private val mutable=MutableStateFlow(TrackDetailsState())
    val state:StateFlow<TrackDetailsState> = mutable
    @Volatile private var selected:DetailsRoute?=null
    private var ticket:DetailsTicket?=null
    private var readVersion=0L
    // Only the matching local retraction can retire a fence already shown to this route.
    private var presentedFence:LibraryRemovalFence?=null
    private var outcomeFence:UUID?=null
    private var removalResult:RemovalIssue?=null
    private fun resetRemoval() {presentedFence=null;outcomeFence=null;removalResult=null}

    private fun TrackDetailsState.withOutcome(value:MutationOutcome?,describedByRemovalNotice:Boolean=false)=
        copy(outcome=value,outcomeDescribedByRemovalNotice=describedByRemovalNotice)

    private fun TrackDetailsState.withRemovalNotice()=copy(
        removalBlocked=presentedFence!=null||removalResult==RemovalIssue.ConfirmedLocalSettleFailed,
        removalIssue=when {
            outcome==MutationOutcome.Pending -> null
            removalResult==RemovalIssue.ConfirmedLocalSettleFailed -> removalResult
            else -> when(presentedFence?.status) {
                LibraryRemovalFenceStatus.NotSentLocalCleanupFailed -> RemovalIssue.NotSentLocalCleanupFailed
                LibraryRemovalFenceStatus.Unconfirmed -> RemovalIssue.Unconfirmed
                null -> removalResult
            }
        })
    fun open(capture:LibraryTrackCapture):DetailsRoute? {
        if(!library.owns(capture)||!api.session.remoteCurrent(capture.scope))return null
        return admit(DetailsRoute(capture.scope,capture.track.id))
    }
    /** Queue metadata identifies the read target. Only the canonical owned-library GET grants writes. */
    fun capturePlayer(scope:AccountScope,observed:com.soundq.android.playback.PlaybackProjection,latest:()->com.soundq.android.playback.PlaybackProjection):PlayerDetailsCapture? {
        fun selected(p:com.soundq.android.playback.PlaybackProjection)=p.queue.singleOrNull {it.occurrenceId==p.selectedOccurrence}
        val row=selected(observed) ?: return null
        fun admitted(p:com.soundq.android.playback.PlaybackProjection)=api.session.remoteCurrent(scope)&&
            p.connection==com.soundq.android.playback.PlaybackProjection.Connection.Connected&&p.source==com.soundq.android.playback.PlaybackSource.Queue&&!p.localOnly&&
            p.accountEpoch==scope.epoch&&p.sessionIdentity.isNotBlank()&&p.sessionIdentity!="redacted"&&p.sourceQueueIncarnation.isNotBlank()&&selected(p)?.trackId?.let {it>0}==true
        fun valid():Boolean {
            val p=latest()
            return admitted(p)&&p.sessionIdentity==observed.sessionIdentity&&p.sourceQueueIncarnation==observed.sourceQueueIncarnation&&
                p.selectionIncarnation==observed.selectionIncarnation&&p.selectedOccurrence==observed.selectedOccurrence&&selected(p)?.trackId==row.trackId
        }
        if(!admitted(observed)||!valid())return null
        return PlayerDetailsCapture(scope,TrackId(row.trackId),::valid)
    }
    fun open(capture:PlayerDetailsCapture):DetailsRoute? {
        if(!capture.valid())return null
        return admit(DetailsRoute(capture.scope,capture.trackId,capture.valid,fromPlayer=true))
    }
    @Synchronized private fun admit(route:DetailsRoute):DetailsRoute? {
        if(!api.session.remoteCurrent(route.scope)||!route.sourceValid())return null
        selected?.active=false
        return route.also {selected=it;ticket=null;readVersion++;resetRemoval();mutable.value=TrackDetailsState()}
    }
    fun current(route:DetailsRoute)=selected===route&&route.active&&api.session.remoteCurrent(route.scope)&&route.sourceValid()
    @Synchronized fun close(route:DetailsRoute) {route.active=false;if(selected===route){selected=null;ticket=null;readVersion++;resetRemoval();mutable.value=TrackDetailsState()}}
    @Synchronized fun retire(){selected?.let(::close)}
    fun load(route:DetailsRoute) {
        val version=synchronized(this){if(!current(route)||ticket!=null||mutable.value.loading)return;readVersion++;mutable.value=mutable.value.copy(loading=true,error=null);readVersion}
        var retracted:UUID?=null
        try {
            retracted=api.retractUnenteredLibraryRemoval(route.scope,route.trackId){current(route)}
            val detail=api.trackDetailsSnapshot(route.scope,route.trackId){current(route)}
            publishLoad(route,version,retracted) {it.copy(detail=detail,missing=detail==null,error=null)}
            var analysis:AnalysisDetail?=null;var analysisError:SafeFailure.Reason?=null
            if(detail!=null)try {analysis=api.trackDetailsAnalysis(route.scope,route.trackId){current(route)}}catch(e:Exception){analysisError=(e as? SafeFailure)?.reason?:SafeFailure.Reason.Network}
            publishLoad(route,version,null) {it.copy(loading=false,analysis=analysis,analysisError=analysisError,analysisAbsent=analysis==null&&analysisError==null,reconciled=true)}
        } catch(e:Exception){publishLoad(route,version,retracted) {it.copy(loading=false,error=(e as? SafeFailure)?.reason?:SafeFailure.Reason.Network)}}
    }
    private fun publishLoad(route:DetailsRoute,version:Long,retracted:UUID?,update:(TrackDetailsState)->TrackDetailsState) {
        // Journal observation occurs before taking the Details monitor. Keep the live fence
        // stable through the paired notice/block publication, including when loading ends.
        api.observeLibraryRemovalFence(route.scope,route.trackId) {live->synchronized(this) {
            if(!current(route)||version!=readVersion)return@synchronized
            var next=update(mutable.value)
            if(retracted!=null) {
                if(presentedFence?.operation==retracted)presentedFence=null
                if(outcomeFence==retracted) {outcomeFence=null;next=next.withOutcome(null)}
            }
            if(live!=null)presentedFence=live
            mutable.value=next.withRemovalNotice()
        }}
    }
    @Synchronized fun claim(route:DetailsRoute,observed:TrackDetails,action:DetailsAction):DetailsTicket? {
        if(!current(route)||ticket!=null||mutable.value.loading||mutable.value.error!=null||mutable.value.detail!==observed||mutable.value.missing||(mutable.value.outcome in listOf(MutationOutcome.Uncertain,MutationOutcome.ReadbackFailed)&&!mutable.value.reconciled))return null
        if(action==DetailsAction.Remove&&mutable.value.removalBlocked)return null
        if(action is DetailsAction.Analysis&&mutable.value.analysis!==action.observed)return null
        if(action is DetailsAction.Verification&&action.action is VerificationAction.Confirm&&observed.suggestions.none {it===action.action.suggestion})return null
        return DetailsTicket(route,observed,action,library.state.value).also {
            ticket=it;readVersion++;outcomeFence=null
            if(removalResult==RemovalIssue.NotSent)removalResult=null
            mutable.value=mutable.value.copy(error=null,reconciled=false).withOutcome(MutationOutcome.Pending).withRemovalNotice()
        }
    }
    fun execute(command:DetailsTicket) {
        synchronized(this){if(ticket!==command||!current(command.route)||command.consumed)return;command.consumed=true}
        val route=command.route;val scope=route.scope;val id=route.trackId
        var outcome=MutationOutcome.Confirmed
        var result:RemovalIssue?=null
        var fence:LibraryRemovalFence?=null
        try {
            when(val action=command.action) {
                is DetailsAction.Metadata->api.trackDetailsMetadata(scope,id,action.draft){current(route)}
                DetailsAction.Remove->if(api.trackDetailsRemove(scope,id){current(route)}==LibraryRemovalReceipt.ConfirmedLocalSettleFailed)
                    result=RemovalIssue.ConfirmedLocalSettleFailed
                is DetailsAction.Analysis->api.trackDetailsCorrectAnalysis(scope,id,action.observed,action.correction){current(route)}
                is DetailsAction.Verification->api.trackDetailsVerify(scope,id,action.action){current(route)}
            }
        } catch(e:Exception){
            val failure=e as? SafeFailure
            fence=failure?.removalFence
            outcome=when(failure?.reason) {
                SafeFailure.Reason.Refused->MutationOutcome.Refused
                SafeFailure.Reason.RemovalNotSent->{result=RemovalIssue.NotSent;MutationOutcome.Refused}
                SafeFailure.Reason.RemovalNotSentLocalCleanupFailed->MutationOutcome.Refused
                else->MutationOutcome.Uncertain
            }
        }
        synchronized(this){
            if(ticket!==command||!current(route))return
            if(outcome!=MutationOutcome.Confirmed||result!=null) {
                if(result!=null)removalResult=result
                if(fence!=null) {presentedFence=fence;outcomeFence=fence.operation}
                mutable.value=mutable.value.withOutcome(if(result==RemovalIssue.ConfirmedLocalSettleFailed)
                    MutationOutcome.ReadbackFailed else outcome,describedByRemovalNotice=result!=null||fence!=null).withRemovalNotice()
            }
        }
        if(outcome==MutationOutcome.Confirmed) {
            try {
                if(command.action is DetailsAction.Analysis) {
                    val analysis=api.trackDetailsAnalysis(scope,id){current(route)} ?: throw SafeFailure(SafeFailure.Reason.InvalidResponse)
                    synchronized(this){if(ticket===command&&current(route))mutable.value=mutable.value.copy(analysis=analysis,analysisError=null,analysisAbsent=false)}
                } else {
                    val observed=api.trackDetailsSnapshot(scope,id){current(route)}
                    if(command.action==DetailsAction.Remove&&observed!=null)throw SafeFailure(SafeFailure.Reason.InvalidResponse)
                    val verification=(command.action as? DetailsAction.Verification)?.action
                    val expectedRecording=when(verification) {
                        is VerificationAction.Link->verification.recording
                        is VerificationAction.Confirm->verification.suggestion.recording
                        else->null
                    }
                    if(expectedRecording!=null&&(observed?.verified!=true||observed.recording?.value?.equals(expectedRecording.value,ignoreCase=true)!=true))throw SafeFailure(SafeFailure.Reason.InvalidResponse)
                    synchronized(this){if(ticket===command&&current(route))mutable.value=mutable.value.copy(detail=observed,missing=observed==null,error=null)}
                    if(current(route))library.refreshObserved(scope,command.libraryState){current(route)}
                }
                synchronized(this){if(ticket===command&&current(route))mutable.value=mutable.value.withOutcome(if(result==null)MutationOutcome.Confirmed else MutationOutcome.ReadbackFailed,describedByRemovalNotice=result!=null).withRemovalNotice()}
            } catch(_:Exception){synchronized(this){if(ticket===command&&current(route))mutable.value=mutable.value.withOutcome(MutationOutcome.ReadbackFailed,describedByRemovalNotice=result!=null).withRemovalNotice()}}
        }
        synchronized(this){if(ticket===command)ticket=null}
    }
}
