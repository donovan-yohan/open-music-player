package com.soundq.android.data.connect

import com.soundq.android.data.*
import com.soundq.android.playback.PlaybackProjection
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import java.time.Instant
import java.util.UUID

/** Application lifetime, not panel lifetime. Blocking calls settle before another exchange starts. */
class DevicePresence(private val api:SoundQApi,private val playback:StateFlow<PlaybackProjection>,private val jobs:CoroutineScope,private val clock:()->Instant={Instant.now()}) {
    private val mutable=MutableStateFlow(PresenceState())
    val state:StateFlow<PresenceState> = mutable.asStateFlow()
    @Volatile private var scope:AccountScope?=null
    @Volatile private var proof:WriterProof?=null
    @Volatile private var panel=false
    private var device=UUID.randomUUID().toString()
    private var writer=secret()
    @Volatile private var lease:ConnectedDevice?=null
    private var sequence=0L
    private var due=Instant.MIN
    private var pollDue=Instant.MIN
    @Volatile private var generation=0L
    private var attachedGeneration=-1L
    private var running:Job?=null
    @Volatile private var disconnectedScope:AccountScope?=null
    fun start() {if(running!=null)return;running=jobs.launch(Dispatchers.IO){while(isActive){step();delay(1_000)}}}
    fun visible(value:Boolean) {panel=value;if(value)pollDue=Instant.MIN}
    fun capture():WriterProof?=proof?.takeIf {it.current()}
    fun reconnect(){disconnectedScope=null;due=Instant.MIN}
    fun retire() {generation++;proof=null;mutable.value=PresenceState()}
    /** Also used by deterministic TLS tests. No offline metadata queue. */
    @Synchronized fun step() {
        if(attachedGeneration!=generation){scope=null;lease=null;sequence=0;due=Instant.MIN;pollDue=Instant.MIN;device=UUID.randomUUID().toString();writer=secret();attachedGeneration=generation}
        val current=api.session.capture()?.takeIf {api.session.remoteCurrent(it)&&api.session.state.value is AuthState.SignedIn}
        if(playback.value.localOnly)return
        disconnectedScope?.let {if(api.session.remoteCurrent(it))return else disconnectedScope=null}
        val old=scope
        if(old!=null&&!api.session.remoteCurrent(old)){retire();scope=null;lease=null;sequence=0;due=Instant.MIN;device=UUID.randomUUID().toString();writer=secret();attachedGeneration=generation}
        if(current==null)return
        if(scope==null)scope=current
        val owner=scope ?: return
        val epoch=generation
        val valid={generation==epoch&&api.session.remoteCurrent(owner)&&!playback.value.localOnly}
        if(!valid())return
        if(!clock().isBefore(due)) {
            try {
                mutable.value=mutable.value.copy(status=if(lease==null)PresenceStatus.Connecting else mutable.value.status)
                if(lease==null || !clock().isBefore(lease!!.expires)) {
                    proof=null
                    if(lease!=null){device=UUID.randomUUID().toString();writer=secret()}
                    val registered=ConnectedDevice.parse(api.privateExchange(owner,"/me/devices","POST",buildJsonObject {put("deviceId",device);put("label","SoundQ Android");put("platform","android");put("writerSecret",writer)},201,valid).getValue("device").jsonObject)
                    require(registered.deviceId==device)
                    if(!valid())return
                    lease=registered;sequence=registered.sequence
                }
                val before=lease!!
                val next=++sequence
                val report=buildJsonObject {put("leaseId",before.leaseId);put("writerSecret",writer);put("sequence",next);put("playback",metadata(playback.value,owner))}
                val result=ConnectedDevice.parse(api.privateExchange(owner,"/me/devices/$device","PUT",report,200,valid).getValue("device").jsonObject)
                require(result.deviceId==device&&result.leaseId==before.leaseId&&result.sequence==next)
                if(!valid())return
                lease=result
                val incarnation=epoch
                val leaseId=result.leaseId
                proof=WriterProof(owner,device,leaseId,writer){generation==incarnation&&api.session.remoteCurrent(owner)&&!playback.value.localOnly&&lease?.let {it.leaseId==leaseId&&clock().isBefore(it.expires)}==true&&mutable.value.status!=PresenceStatus.Disabled}
                mutable.value=mutable.value.copy(status=PresenceStatus.Online)
                due=clock().plusSeconds(5)
            }catch(e:Exception) {
                if(!valid())return
                val status=(e as? FeatureFailure)?.status ?: 0
                if(status in setOf(403,409,410)){proof=null;lease=null;device=UUID.randomUUID().toString();writer=secret()}
                mutable.value=mutable.value.copy(status=if(status==503)PresenceStatus.Disabled else PresenceStatus.Offline)
                due=clock().plusMillis(LeaseRecovery.delayMillis(status))
            }
        }
        if(panel&&!clock().isBefore(pollDue)&&valid()) {
            pollDue=clock().plusSeconds(5)
            try {
                val result=DeviceList.parse(api.privateExchange(owner,"/me/devices",valid={valid()&&panel}))
                if(valid()&&panel)mutable.value=mutable.value.copy(devices=result.devices,listFailed=false)
            }catch(e:Exception){if(valid()&&panel){mutable.value=mutable.value.copy(listFailed=true);pollDue=clock().plusMillis(LeaseRecovery.delayMillis((e as? FeatureFailure)?.status ?: 0))}}
        }
    }
    /** Explicit disconnect only. Logout relies on synchronous account revocation and server lease expiry. */
    @Synchronized fun disconnect() {
        val captured=proof
        val deleteEligible=captured?.current()==true
        disconnectedScope=scope?.takeIf {api.session.remoteCurrent(it)}
            ?: api.session.capture()?.takeIf {api.session.remoteCurrent(it)}
        // Local revocation is unconditional and precedes even a held best-effort DELETE.
        retire()
        val retiredGeneration=generation
        if(captured!=null&&deleteEligible)try {
            val body=JsonObject(captured.body().filterKeys {it!="deviceId"})
            // The retired proof must stay invalid. Only its original cleanup capability may dispatch.
            api.privateExchange(captured.scope,"/me/devices/${captured.device}","DELETE",body,204){
                generation==retiredGeneration&&disconnectedScope===captured.scope&&api.session.remoteCurrent(captured.scope)&&!playback.value.localOnly
            }
        }catch(_:Exception){}
    }
    fun close(){running?.cancel();running=null;retire()}
    private fun metadata(p:PlaybackProjection,owner:AccountScope):JsonElement {
        if(p.accountEpoch!=owner.epoch||p.localOnly||p.title==null||p.selectedOccurrence==null)return JsonNull
        val row=p.queue.firstOrNull {it.occurrenceId==p.selectedOccurrence} ?: return JsonNull
        return buildJsonObject {
            put("sessionId",p.sessionIdentity);put("queueItemId",row.occurrenceId)
            put("track",buildJsonObject {put("trackId",row.trackId);put("title",bounded(row.title,200));put("artist",bounded(row.artist,200))})
            put("playing",p.isPlaying);put("processingState",if(p.preparing)"buffering" else "ready")
            put("positionMs",p.positionMs.coerceIn(0,9_007_199_254_740_991));put("durationMs",p.durationMs.coerceIn(0,9_007_199_254_740_991));put("activeVoiceCount",if(p.isPlaying)1 else 0)
        }
    }
}
