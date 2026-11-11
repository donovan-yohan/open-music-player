package com.soundq.android.data.jam

import com.soundq.android.data.*
import com.soundq.android.data.connect.*
import com.soundq.android.playback.PlaybackProjection
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import java.time.Instant
import java.util.UUID

class JamConsent internal constructor(internal val epoch:Long)
/** Host application owner. Panel closure retires decisions, not host heartbeat or attempt history. */
class JamHostRepository(private val api:SoundQApi,private val presence:DevicePresence,private val playback:StateFlow<PlaybackProjection>,private val admission:JamAdmissionPort,private val send:(String)->Unit,private val jobs:CoroutineScope,private val receiptDirectory:java.io.File,private val clock:()->Instant={Instant.now()}) {
    private val mutable=MutableStateFlow(JamState())
    val state:StateFlow<JamState> = mutable.asStateFlow()
    private val lane=Any()
    @Volatile private var consentEpoch=0L
    @Volatile private var visible=false
    @Volatile private var epoch=0L
    @Volatile private var owner:WriterProof?=null

    private var hostSequence=0L
    private var heartbeatDue=Instant.MIN
    private var pollDue=Instant.MIN
    private var pendingCreate:String?=null
    private var automatic=false
    private var running:Job?=null
    fun start(){if(running!=null)return;running=jobs.launch(Dispatchers.IO){while(isActive){tick();delay(1_000)}}}
    @Synchronized fun open():JamConsent {visible=true;consentEpoch++;pollDue=Instant.MIN;return JamConsent(consentEpoch)}
    @Synchronized fun hide(consent:JamConsent){if(consent.epoch==consentEpoch){visible=false;consentEpoch++}}
    private fun consentCurrent(c:JamConsent)=visible&&c.epoch==consentEpoch
    fun current(c:JamConsent)=consentCurrent(c)&&api.session.state.value is AuthState.SignedIn
    fun retire(){epoch++;owner=null;visible=false;consentEpoch++;pendingCreate=null;automatic=false;mutable.value=JamState()}
    private fun valid(p:WriterProof,e:Long)=epoch==e&&owner===p&&p.current()
    private fun requireCurrent(v:()->Boolean){if(!v())throw SafeFailure(SafeFailure.Reason.Retired)}
    private fun proofBody(p:WriterProof,extra:JsonObject=buildJsonObject {})=JsonObject(extra+p.body(true))
    private fun exchange(p:WriterProof,path:String,method:String="GET",body:JsonObject?=null,status:Int=200,valid:()->Boolean)=api.privateExchange(p.scope,path,method,body,status,valid)
    private fun read(p:WriterProof,id:String,valid:()->Boolean):JamSnapshot=JamSnapshot.parse(exchange(p,"/jams/$id",valid=valid),true,id)
    private fun accept(s:JamSnapshot) {
        val before=mutable.value.snapshot
        if(before==null||before.id!=s.id||s.version>before.version||s.version==before.version&&!s.serverTime.isBefore(before.serverTime)) {
            // Heartbeat returns the PUBLIC DTO. Never erase private mappings from the last host read.
            val merged=if(!s.host&&before?.id==s.id) s.copy(requests=before.requests,host=true,authority=before.authority,members=before.members) else s
            mutable.value=mutable.value.copy(snapshot=merged)
        }
    }
    fun create(c:JamConsent,tracks:List<Track>,outsideDiscovery:Boolean=false)=synchronized(lane) {
        if(!consentCurrent(c)||mutable.value.snapshot!=null||mutable.value.uncertain)return@synchronized
        require(tracks.size in 1..20&&tracks.map {it.id}.distinct().size==tracks.size)
        val p=presence.capture() ?: run {mutable.value=mutable.value.copy(message="Wait for this device to connect.");return@synchronized}
        val e=++epoch;owner=p;hostSequence=0
        val valid={valid(p,e)&&consentCurrent(c)}
        val id=UUID.randomUUID().toString()
        pendingCreate=id
        mutable.value=JamState(busy=true)
        var createAttempted=false
        try {
            // Explicit selected numeric IDs must still exist in the current authenticated Library.
            val ids=tracks.map {ownedTrack(p.scope,it.id,valid).id}
            requireCurrent(valid)
            createAttempted=true
            val s=JamSnapshot.parse(exchange(p,"/jams","POST",proofBody(p,buildJsonObject {put("jamId",id);put("trackIds",JsonArray(ids.map {JsonPrimitive(it.value)}));put("allowOutsideDiscovery",outsideDiscovery)}),201,valid),false,id)
            requireCurrent(valid);accept(s);pendingCreate=null;heartbeatDue=clock();pollDue=clock()
        }catch(error:Exception){if(valid(p,e)){
            if(!createAttempted){pendingCreate=null;owner=null;mutable.value=JamState(message="Could not confirm selected songs in your current Library. Choose again.")}
            else mutable.value=mutable.value.copy(message="Jam creation was not confirmed. Check the same Jam without creating again.",uncertain=true)
        }}
        finally {mutable.value=mutable.value.copy(busy=false)}
    }
    fun invite(c:JamConsent)=synchronized(lane) {
        val p=owner ?: return@synchronized;val s=mutable.value.snapshot ?: return@synchronized;val e=epoch
        val valid={valid(p,e)&&consentCurrent(c)}
        if(!valid())return@synchronized
        mutable.value=mutable.value.copy(busy=true,invite=null)
        try {val i=JamInvite.parse(exchange(p,"/jams/${s.id}/invites","POST",proofBody(p),201,valid));if(valid())mutable.value=mutable.value.copy(invite=i,message=null)}
        catch(_:Exception){if(valid())mutable.value=mutable.value.copy(message="Invitation not confirmed. Request another explicitly.")}
        finally {mutable.value=mutable.value.copy(busy=false)}
    }
    private fun refuseLocalOnly(c:JamConsent):Boolean {
        if(!playback.value.localOnly)return false
        if(consentCurrent(c))mutable.value=mutable.value.copy(message="Jam actions are unavailable during device-only playback.")
        return true
    }
    fun refresh(c:JamConsent)=synchronized(lane) {
        if(refuseLocalOnly(c))return@synchronized
        val p=owner ?: return@synchronized;val id=mutable.value.snapshot?.id ?: pendingCreate ?: return@synchronized;val e=epoch
        // Cleanup may outlive the writer lease, but never the local-only network boundary.
        val valid={epoch==e&&owner===p&&api.session.remoteCurrent(p.scope)&&consentCurrent(c)&&!playback.value.localOnly}
        try {if(valid()){val snapshot=read(p,id,valid);requireCurrent(valid);accept(snapshot);pendingCreate=null;mutable.value=mutable.value.copy(uncertain=false,message=null)}}catch(_:Exception){if(valid())mutable.value=mutable.value.copy(message="Could not read this exact Jam. No create request was replayed.")}
    }
    private fun ownedTrack(scope:AccountScope,id:TrackId,valid:()->Boolean):Track {
        var offset=0
        repeat(1000) {
            requireCurrent(valid)
            val page=api.ownedLibraryPage(scope,LibraryQuery(),offset,valid)
            requireCurrent(valid)
            page.tracks.singleOrNull {it.id==id}?.let {return it}
            if(page.tracks.isEmpty()||offset+page.tracks.size>=page.total)throw SafeFailure(SafeFailure.Reason.Refused)
            offset+=page.tracks.size
        }
        throw SafeFailure(SafeFailure.Reason.InvalidResponse)
    }
    fun decide(c:JamConsent,request:JamRequest,approve:Boolean,reconcile:Boolean=false)=synchronized(lane) {
        if(mutable.value.snapshot?.authority!=null){decideModern(c,request,approve,reconcile);return@synchronized}
        val p=owner ?: return@synchronized;val initial=mutable.value.snapshot ?: return@synchronized;val e=epoch
        // Capture BEFORE host/library awaits, including same-content owner replacement.
        val incarnation=admission.incarnation ?: return@synchronized
        val base={valid(p,e)&&consentCurrent(c)}
        val beforeAdmission={base()&&admission.incarnation==incarnation}
        if(!beforeAdmission()||initial.requests.none {it===request})return@synchronized
        mutable.value=mutable.value.copy(busy=true,message=null)
        try {
            val fresh=read(p,initial.id,beforeAdmission);requireCurrent(beforeAdmission);accept(fresh)
            require(fresh.version==initial.version)
            val exact=fresh.requests.single {it.id==request.id}
            require(exact.catalogId==request.catalogId&&exact.trackId==request.trackId&&fresh.state=="open")
            fresh.authority?.let {require(it.ownerId==p.scope.accountId&&it.deviceId==p.device&&it.leaseId==p.lease)}
            val binding=java.security.MessageDigest.getInstance("SHA-256").digest((api.session.endpoint.identity+"\u0000"+p.scope.accountId+"\u0000"+(fresh.authority?.authGeneration ?: 0)+"\u0000"+fresh.id).toByteArray()).joinToString(""){"%02x".format(it)}
            val history=AdmissionHistory(java.io.File(receiptDirectory,"jam-admission-$binding.json"),binding)
            requireCurrent(beforeAdmission)
            if(exact.status in setOf("queued","declined"))return@synchronized
            var receipt=history.receipt(exact.id,exact.admissionKey)
            var status=if(approve)"queued" else "declined"
            if(approve) {
                if(history.attempted(exact.id)) {
                    if(!reconcile){mutable.value=mutable.value.copy(message="Already attempted. Reconcile without inserting again.");return@synchronized}
                    status=if(receipt==null)"uncertain" else "queued"
                }else {
                    if(reconcile||exact.status!="pending")return@synchronized
                    val track=ownedTrack(p.scope,exact.trackId ?: throw SafeFailure(SafeFailure.Reason.InvalidResponse),beforeAdmission)
                    requireCurrent(beforeAdmission)
                    if(!history.begin(exact.id,exact.admissionKey))throw SafeFailure(SafeFailure.Reason.Refused)
                    try {receipt=admission.request(p.scope,track,exact.id,incarnation,beforeAdmission,send);history.admitted(exact.id,receipt)}
                    catch(_:Exception){status="uncertain"}
                }
            }else if(history.attempted(exact.id)){mutable.value=mutable.value.copy(message="Admission was attempted. Reconcile instead of declining.");return@synchronized}
            // Admission legitimately advances the canonical timeline generation. Consent/account/proof stay fenced.
            val afterAdmission={base()&&when {reconcile->true;!approve->admission.incarnation==incarnation;else->admission.incarnation==(receipt?.ownerAfter ?: incarnation)}}
            requireCurrent(afterAdmission)
            val body=proofBody(p,buildJsonObject {put("expectedVersion",fresh.version);put("status",status);receipt?.takeIf {status=="queued"}?.let {put("receipt",it.json())}})
            val acknowledgement=exchange(p,"/jams/${fresh.id}/requests/${exact.id}","PUT",body,200,afterAdmission)
            decode {keys(acknowledgement,setOf("requestId","catalogItemId","displayName","status"));require(text(acknowledgement,"requestId",36)==exact.id&&text(acknowledgement,"catalogItemId",36)==exact.catalogId&&text(acknowledgement,"displayName",32)==exact.name&&text(acknowledgement,"status",16)==status)}
            requireCurrent(afterAdmission)
            val confirmed=read(p,fresh.id,base)
            require(confirmed.requests.single {it.id==exact.id}.status==status)
            accept(confirmed);mutable.value=mutable.value.copy(message=if(status=="uncertain")"Admission is uncertain. It will not be inserted again." else "Decision saved.")
        }catch(_:Exception){if(base())mutable.value=mutable.value.copy(message="Decision not confirmed. Reconcile reads the same request without inserting again.")}
        finally {mutable.value=mutable.value.copy(busy=false)}
    }
    private fun sha(value:String)=java.security.MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString(""){"%02x".format(it)}
    private fun history(p:WriterProof,s:JamSnapshot):AdmissionHistory {
        val binding=sha(api.session.endpoint.identity+"\u0000"+p.scope.accountId+"\u0000"+(s.authority?.authGeneration ?: 0)+"\u0000"+s.id)
        return AdmissionHistory(java.io.File(receiptDirectory,"jam-admission-$binding.json"),binding)
    }
    private fun fingerprint(q:JamRequest)=sha(buildJsonObject {
        put("catalogId",q.catalogId)
        if(q.source==null)put("trackId",q.trackId?.value) else q.source.let {source ->
            put("selectionSessionId",source.selectionSessionId);put("candidateId",source.candidateId)
            put("provider",source.provider);put("sourceId",source.sourceId);put("sourceUrl",q.selectedSource?.sourceUrl)
            put("title",source.title);put("artist",source.artist);put("durationMs",source.durationMs);put("expires",source.expires.toString())
        }
    }.toString())
    private fun authority(p:WriterProof,s:JamSnapshot) {
        val a=s.authority ?: throw SafeFailure(SafeFailure.Reason.InvalidResponse)
        require(s.host&&a.ownerId==p.scope.accountId&&a.deviceId==p.device&&a.leaseId==p.lease)
    }
    /** Explicit consent publishes one frozen approval, never an import inferred from a ready row. */
    private fun decideModern(c:JamConsent,request:JamRequest,approve:Boolean,reconcile:Boolean) {
        val p=owner ?: return;val initial=mutable.value.snapshot ?: return;val e=epoch
        val hostSession=admission.hostSession(p.scope);val generation=admission.incarnation
        val base={valid(p,e)&&consentCurrent(c)&&!playback.value.localOnly}
        val captured={base()&&(!approve||(hostSession!=null&&generation!=null&&admission.hostSession(p.scope)==hostSession&&admission.incarnation==generation))}
        if(!captured()||initial.requests.none {it===request})return
        mutable.value=mutable.value.copy(busy=true,message=null)
        try {
            val fresh=read(p,initial.id,captured);requireCurrent(captured);authority(p,fresh);accept(fresh)
            require(fresh.authority==initial.authority&&fresh.state=="open")
            val exact=fresh.requests.single {it.id==request.id};require(fingerprint(exact)==fingerprint(request))
            if(exact.status in setOf("queued","declined","withdrawn","failed","duplicate"))return
            val ledger=history(p,fresh)
            if(!approve) {
                require(!ledger.attempted(exact.id))
                exchange(p,"/jams/${fresh.id}/requests/${exact.id}","PUT",proofBody(p,buildJsonObject {put("expectedVersion",fresh.version);put("status","declined")}),200,captured)
                val confirmed=read(p,fresh.id,captured);require(confirmed.requests.single {it.id==exact.id}.status=="declined");accept(confirmed);return
            }
            val old=ledger.approval(exact.id)
            if(old==null){require(!reconcile&&exact.status=="pending"&&fresh.version==initial.version)}
            val intent=ledger.beginApproval(exact.id,old ?: ApprovalIntent(fingerprint(exact),fresh.version,hostSession!!,generation!!))
            require(intent.fingerprint==fingerprint(exact)&&intent.hostSession==hostSession&&intent.generation==generation)
            requireCurrent(captured)
            val approved=JamSnapshot.parse(exchange(p,"/jams/${fresh.id}/requests/${exact.id}/approval","POST",proofBody(p,buildJsonObject {
                put("expectedVersion",intent.expectedVersion);put("hostSessionId",intent.hostSession)
            }),200,captured),true,fresh.id)
            requireCurrent(captured);authority(p,approved)
            val chosen=approved.requests.single {it.id==exact.id}
            require(fingerprint(chosen)==intent.fingerprint&&chosen.hostSessionId==intent.hostSession&&chosen.approvalOrder>0)
            ledger.confirmApproval(exact.id,chosen.admissionKey ?: throw SafeFailure(SafeFailure.Reason.InvalidResponse))
            requireCurrent(captured)
            accept(approved);automatic=true;mutable.value=mutable.value.copy(message="Approved.")
            drainApproved(p,e)
        }catch(_:Exception){if(base())mutable.value=mutable.value.copy(message="Decision not confirmed. Check this request.")}
        finally {mutable.value=mutable.value.copy(busy=false)}
    }
    /** Only durably confirmed consent continues without a visible panel. */
    private fun drainApproved(p:WriterProof,e:Long) {
        repeat(50) {
            val initial=mutable.value.snapshot ?: return
            val base={valid(p,e)&&!playback.value.localOnly}
            if(!base())return
            val started=System.nanoTime();val fresh=read(p,initial.id,base);requireCurrent(base);authority(p,fresh);accept(fresh)
            val ledger=history(p,fresh)
            val next=fresh.requests.filter {it.approvalOrder>0&&it.status in setOf("approved","importing","ready","uncertain")&&ledger.approval(it.id)?.confirmed==true}.minByOrNull {it.approvalOrder}
                ?: run {automatic=false;return}
            val intent=ledger.approval(next.id)!!
            require(next.admissionKey==intent.admissionKey&&next.hostSessionId==intent.hostSession&&fingerprint(next)==intent.fingerprint)
            val member=fresh.members.single {it.id==next.memberId};require(!member.revoked)
            val expiry=minOf(member.expires,fresh.expires)
            val window=java.time.Duration.between(fresh.serverTime,expiry).toNanos().coerceIn(0,java.util.concurrent.TimeUnit.HOURS.toNanos(4))
            val scopeCurrent={base()&&admission.hostSession(p.scope)==intent.hostSession&&fresh.state=="open"&&clock().isBefore(expiry)&&System.nanoTime()-started<window}
            requireCurrent(scopeCurrent)
            if(next.status !in setOf("ready","uncertain"))return // Earlier acquisition holds all later admissions.
            var receipt=ledger.receipt(next.id,intent.admissionKey)
            if(receipt==null&&ledger.attempted(next.id)) {
                val observedGeneration=admission.incarnation ?: return
                val lookupCurrent={scopeCurrent()&&admission.incarnation==observedGeneration}
                try {
                    val track=ownedTrack(p.scope,next.trackId ?: throw SafeFailure(SafeFailure.Reason.InvalidResponse),lookupCurrent)
                    requireCurrent(lookupCurrent)
                    receipt=admission.lookupApproved(p.scope,track,next.id,observedGeneration,intent.hostSession,JamOccurrence(intent.admissionKey!!,next.id,intent.hostSession),lookupCurrent,send)
                    ledger.admitted(next.id,receipt)
                    // A read proves this occurrence, not the absence of intervening queue edits.
                    // Never advance sibling consent lineage from a reconciliation lookup.
                }catch(_:Exception) {
                    requireCurrent(scopeCurrent)
                    if(next.status!="uncertain")exchange(p,"/jams/${fresh.id}/requests/${next.id}","PUT",proofBody(p,buildJsonObject {put("expectedVersion",fresh.version);put("status","uncertain")}),200,scopeCurrent)
                    mutable.value=mutable.value.copy(message="Queue outcome not confirmed. Check this request.");return
                }
            }
            if(receipt==null) {
                if(!next.canAdmit)return
                val before={scopeCurrent()&&admission.incarnation==intent.generation}
                requireCurrent(before)
                val track=ownedTrack(p.scope,next.trackId ?: throw SafeFailure(SafeFailure.Reason.InvalidResponse),before)
                requireCurrent(before);require(ledger.begin(next.id,intent.admissionKey))
                receipt=admission.requestApproved(p.scope,track,next.id,intent.generation,intent.hostSession,JamOccurrence(intent.admissionKey!!,next.id,intent.hostSession),before,send)
                ledger.admitted(next.id,receipt)
                val after=receipt.ownerAfter ?: throw SafeFailure(SafeFailure.Reason.InvalidResponse)
                requireCurrent {scopeCurrent()&&admission.incarnation==after}
                // Never renew siblings from a refresh/equal queue: only this actual receipt.
                ledger.advanceApprovals(intent.hostSession,intent.generation,after)
            }
            val actual=receipt
            val after={scopeCurrent()&&actual.sessionId==intent.hostSession&&admission.incarnation==actual.ownerAfter}
            requireCurrent(after)
            exchange(p,"/jams/${fresh.id}/requests/${next.id}","PUT",proofBody(p,buildJsonObject {put("expectedVersion",fresh.version);put("status","queued");put("receipt",actual.json())}),200,after)
            val confirmed=read(p,fresh.id,after);val recorded=confirmed.requests.single {it.id==next.id}
            require(recorded.status=="queued"&&recorded.receipt?.json()==actual.json());accept(confirmed)
        }
    }
    fun end(c:JamConsent)=synchronized(lane) {
        if(refuseLocalOnly(c))return@synchronized
        val p=owner ?: return@synchronized;val s=mutable.value.snapshot ?: return@synchronized;val e=epoch
        // Cleanup may outlive the writer lease, but never the local-only network boundary.
        val valid={epoch==e&&owner===p&&api.session.remoteCurrent(p.scope)&&consentCurrent(c)&&!playback.value.localOnly}
        if(!valid())return@synchronized
        try {exchange(p,"/jams/${s.id}","DELETE",status=204,valid=valid);if(valid()){epoch++;owner=null;automatic=false;mutable.value=JamState(message="Jam ended.")}}
        catch(_:Exception){if(valid())mutable.value=mutable.value.copy(message="End not confirmed. Check this Jam before retrying.")}
    }
    fun tick()=synchronized(lane) {
        val p=owner ?: return@synchronized
        if(!api.session.remoteCurrent(p.scope)){retire();return@synchronized}
        if(playback.value.localOnly)return@synchronized
        if(!p.current()){mutable.value=mutable.value.copy(invite=null,message="Host device lease expired. End this Jam and create another explicitly.");return@synchronized}
        val s=mutable.value.snapshot ?: return@synchronized
        if(s.state in setOf("closed","expired")||!clock().isBefore(s.expires)){mutable.value=mutable.value.copy(invite=null,message="Jam ended or expired.");return@synchronized}
        val e=epoch;val valid={valid(p,e)}
        if(!clock().isBefore(heartbeatDue)) {
            heartbeatDue=clock().plusSeconds(5)
            try {
                val playing=playback.value
                val now=if(playing.accountEpoch!=p.scope.epoch||playing.localOnly||playing.title==null)JsonNull else buildJsonObject {put("title",bounded(playing.title,200));put("artist",bounded(playing.artist,200));put("playing",playing.isPlaying);put("positionMs",playing.positionMs.coerceIn(0,86400000));put("durationMs",playing.durationMs.coerceIn(0,86400000))}
                val beat=JamSnapshot.parse(exchange(p,"/jams/${s.id}/host","PUT",proofBody(p,buildJsonObject {put("hostSequence",++hostSequence);put("nowPlaying",now)}),200,valid),false,s.id)
                if(valid())accept(beat)
            }catch(e:Exception){if(valid()){heartbeatDue=clock().plusMillis(LeaseRecovery.delayMillis((e as? FeatureFailure)?.status ?: 0));mutable.value=mutable.value.copy(message="Host heartbeat unavailable. Retry is bounded.")}}
        }
        if((visible||automatic)&&!clock().isBefore(pollDue)) {
            val c=consentEpoch;val panelValid={valid()&&(automatic||visible&&consentEpoch==c)};pollDue=clock().plusSeconds(5)
            try {accept(read(p,s.id,panelValid))}catch(e:Exception){if(panelValid()){pollDue=clock().plusMillis(LeaseRecovery.delayMillis((e as? FeatureFailure)?.status ?: 0));mutable.value=mutable.value.copy(message="Requests unavailable. Retry.")}}
        }
        if(automatic&&valid())try {drainApproved(p,e)}catch(_:Exception){if(valid())mutable.value=mutable.value.copy(message="Queue update not confirmed. Check requests.")}
    }
    fun close(){running?.cancel();running=null;retire()}
}
