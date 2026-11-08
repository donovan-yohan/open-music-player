package com.soundq.android.data.playlists

import com.soundq.android.data.*
import com.soundq.android.data.mix.SavedMix
import com.soundq.android.playback.QueuePolicy
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.util.UUID

enum class BlendStatus { Plain, Generating, Ready, Unsupported, Refused, UnknownCreate, ReadbackFailed, Invalidated }
data class PlaylistBlendState(val status:BlendStatus=BlendStatus.Plain,val enabled:Boolean=false,val loading:Boolean=false,val transitions:List<kotlinx.serialization.json.JsonObject> = emptyList(),val notice:String?=null)
class BlendCapture internal constructor(internal val playback:PlaylistPlaybackCapture,internal val lifetime:Long)
sealed interface PlaylistLaunch {
    data class Plain(val tracks:List<Track>,val index:Int):PlaylistLaunch
    class Mixed internal constructor(val plan:SavedMix,val occurrence:String,val index:Int,internal val capture:BlendCapture,internal val ack:PlaylistBlendAck):PlaylistLaunch
    data object Refused:PlaylistLaunch
}
/** Route-owned capabilities, account-owned dispatched outcome. Never owns a player or queue. */
class PlaylistBlendRepository(private val api:SoundQApi,private val detail:PlaylistDetailRepository,private val downloads:com.soundq.android.data.offline.DeviceDownloads?=null) {
    private val mutable=MutableStateFlow(PlaylistBlendState())
    val state:StateFlow<PlaylistBlendState> = mutable
    private var lifetime=0L
    private var visible=true
    private class Operation(val capture:BlendCapture) {var entered=false;var running=false;var ack:PlaylistBlendAck?=null;var verified=false;var accepted:BlendCapture=capture;var outcomeScope:AccountScope=capture.playback.scope}
    private var operation:Operation?=null
    private val starts=mutableMapOf<String,PlaylistLaunch.Mixed>()
    private var readTicket=0L
    private class Reservation(val operation:Operation,val read:Long,val previous:Operation?,val prior:PlaylistBlendState,val generation:Boolean) {
        var started=false
        var consumed=false
        var scheduled=false
        lateinit var work:()->Unit
    }
    private var reservation:Reservation?=null
    /** Like AcquisitionRepository.schedule: completion owns cancellation before body entry. */
    fun schedule(scope:CoroutineScope,work:(()->Unit)?,dispatcher:CoroutineDispatcher=Dispatchers.IO):Job? {
        if(work==null)return null
        val token=synchronized(this){reservation?.takeIf {it.work===work && !it.scheduled && !it.consumed}?.also {it.scheduled=true}} ?: return null
        return scope.launch(dispatcher){work()}.also {job->job.invokeOnCompletion {synchronized(this){
            if(reservation===token && !token.started && !token.consumed) {
                token.consumed=true;reservation=null
                if(operation===token.operation) {
                    if(readTicket==token.read) {
                        if(token.generation)operation=token.previous
                        mutable.value=token.prior
                    } else {
                        // A local lock/route retirement may revoke publication without running work.
                        // This still owns its busy marker; never restore a retired capability.
                        if(token.generation)operation=null
                        mutable.value=mutable.value.copy(status=if(token.generation)BlendStatus.Refused else mutable.value.status,enabled=false,loading=false)
                    }
                }
            }
        }}}
    }
    private fun enter(token:Reservation):Boolean=synchronized(this) {
        if(token.consumed || reservation!==token)return false
        token.started=true;token.consumed=true;true
    }
    @Synchronized fun visible(value:Boolean) {
        if(visible==value)return
        visible=value;lifetime++;detail.retirePlayback();readTicket++;starts.clear()
        if(operation?.entered==false)operation=null
        val status=if(mutable.value.status==BlendStatus.Generating && operation?.entered==true) {
            if(operation?.ack!=null)BlendStatus.ReadbackFailed else BlendStatus.UnknownCreate
        } else mutable.value.status
        mutable.value=mutable.value.copy(status=status,loading=false)
    }
    // A local app lock revokes callbacks, not the server write outcome. Preserve its one-shot evidence.
    @Synchronized fun retireAccount() {
        starts.clear();lifetime++;readTicket++
        if(api.session.state.value is AuthState.LocalLocked)return
        if(operation?.outcomeScope?.let(::outcomeCurrent)!=true){operation=null;mutable.value=PlaylistBlendState()}
    }
    private fun outcomeCurrent(scope:AccountScope)=api.session.rotationCurrent(scope) || api.session.resumesLocal(scope)
    @Synchronized fun leave() {lifetime++;readTicket++;starts.clear();if(operation?.entered==false)operation=null;mutable.value=mutable.value.copy(enabled=false,loading=false)}
    private fun owns(c:BlendCapture)=visible && c.lifetime==lifetime && api.session.remoteCurrent(c.playback.scope) && detail.ownsPlayback(c.playback) && detail.ownsManagement(c.playback.detail)
    @Synchronized fun capture():BlendCapture? {
        val p=detail.capturePlayback() ?: return null
        if(!visible || !api.session.remoteCurrent(p.scope) || p.detail.playlist.draft.isPublic)return null
        operation?.let {if(api.session.resumesLocal(it.outcomeScope))it.outcomeScope=p.scope}
        return BlendCapture(p,lifetime)
    }
    @Synchronized fun choose(c:BlendCapture,mixed:Boolean):Boolean {
        if(!owns(c))return false
        if(mixed && mutable.value.status==BlendStatus.Unsupported) {mutable.value=mutable.value.copy(enabled=true);return true}
        if(mixed && (operation?.verified!=true || operation?.accepted?.playback?.detail!==c.playback.detail || mutable.value.status!=BlendStatus.Ready))return false
        starts.clear();mutable.value=mutable.value.copy(enabled=mixed,notice=null);return true
    }
    @Synchronized fun acceptedPlan():SavedMix?=operation?.takeIf {it.verified && detail.managementDetail()===it.accepted.playback.detail}?.ack?.document?.plan
    @Synchronized fun canRecover(c:BlendCapture):Boolean=owns(c) && operation?.ack!=null && !mutable.value.loading && operation?.outcomeScope?.let(::outcomeCurrent)==true && runCatching {PlaylistBlendJson.sources(operation!!.ack!!.document.plan,c.playback.detail)}.isSuccess
    @Synchronized fun canGenerate(c:BlendCapture):Boolean=owns(c) && c.playback.detail.tracks.size in 2..QueuePolicy.MAX_CONTEXT_TRACKS && c.playback.detail.tracks.all {it.durationMs>0} && !mutable.value.loading && (operation?.let {outcomeCurrent(it.outcomeScope) && it.entered && !it.verified}!=true)
    @Synchronized fun sourceChanged() {
        val op=operation ?: return
        if(op.verified && detail.managementDetail()!==op.accepted.playback.detail && detail.state.value.detail!=null) {
            starts.clear();mutable.value=mutable.value.copy(status=BlendStatus.Invalidated,enabled=false,notice="Playlist changed. Choose Plain or generate an updated Blend.")
        }
    }
    @Synchronized fun generate(c:BlendCapture):(() -> Unit)? {
        if(!owns(c) || c.playback.detail.tracks.size !in 2..QueuePolicy.MAX_CONTEXT_TRACKS || c.playback.detail.tracks.any {it.durationMs<=0})return null
        val previous=operation
        if(previous!=null && outcomeCurrent(previous.outcomeScope) && (previous.entered && !previous.verified || mutable.value.loading))return null
        val op=Operation(c)
        val token=Reservation(op,readTicket,previous,mutable.value,true);reservation=token
        operation=op;starts.clear()
        mutable.value=PlaylistBlendState(BlendStatus.Generating,true,true)
        token.work=work@{
            if(!enter(token))return@work
            synchronized(this) {
                if(operation!==op || op.running)return@work
                op.running=true
                if(!owns(c)) {operation=null;mutable.value=mutable.value.copy(status=BlendStatus.Refused,loading=false);return@work}
            }
            fun account()=synchronized(this){operation===op && outcomeCurrent(op.outcomeScope)}
            try {
                checkSources(c)
                val ack=api.playlistBlend(c.playback.scope,c.playback.detail,dispatch={synchronized(this){
                    if(operation!==op || op.entered || !owns(c))false else {op.entered=true;true}
                }},valid=::account)
                synchronized(this) {if(account())op.ack=ack}
                if(synchronized(this){owns(c) && account()})readback(op,c)
                else synchronized(this){if(account())mutable.value=mutable.value.copy(status=BlendStatus.ReadbackFailed,loading=false,notice="Blend saved. Read it back before listening.")}
            } catch(error:Exception) {synchronized(this) {
                if(account()) {
                    val reason=(error as? SafeFailure)?.reason
                    val refused=reason==SafeFailure.Reason.Refused
                    if(!op.entered || refused)operation=null
                    mutable.value=PlaylistBlendState(if(!op.entered || refused)BlendStatus.Refused else BlendStatus.UnknownCreate,enabled=mutable.value.enabled,notice=if(reason==SafeFailure.Reason.AudioUnavailable)"Blend sources are not available on this device. Check device downloads before generating." else if(!op.entered || refused)"Blend unavailable. The server may have disabled it." else "Blend creation was not confirmed. It will not be repeated.")
                }
            }}
        }
        return token.work
    }
    /** Device owner admission only; never starts an acquisition or separation job. Called on IO. */
    private fun checkSources(c:BlendCapture) {
        val owner=downloads ?: return // Source-independent repository fixtures omit the device boundary.
        val leases=mutableListOf<com.soundq.android.data.offline.LocalAudioLease>()
        try {
            if(!synchronized(this){owns(c)})throw SafeFailure(SafeFailure.Reason.Retired)
            owner.load(c.playback.scope)
            c.playback.detail.tracks.map {it.id}.distinct().forEach {id->
                leases+=owner.acquire(c.playback.scope,id) ?: throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
            }
            if(!synchronized(this){owns(c)})throw SafeFailure(SafeFailure.Reason.Retired)
        } finally {leases.forEach {it.close()}}
    }
    private fun readback(op:Operation,c:BlendCapture) {
        val ticket=synchronized(this){readTicket}
        val ack=op.ack ?: return
        fun valid()=synchronized(this){operation===op && owns(c) && readTicket==ticket}
        try {
            val observed=api.mixPlanDocument(c.playback.scope,ack.document.plan.id,::valid)
            require(observed.raw==ack.document.raw)
            PlaylistBlendJson.sources(observed.plan,c.playback.detail)
            checkSources(c)
            synchronized(this) {if(valid()) {
                op.verified=true;op.accepted=c
                mutable.value=PlaylistBlendState(if(observed.plan.playable())BlendStatus.Ready else BlendStatus.Unsupported,enabled=mutable.value.enabled,transitions=ack.transitions,notice=if(observed.plan.playable())null else "This Blend needs tempo playback that is not supported on this device. Choose Plain to listen.")
            }}
        } catch(_:Exception) {synchronized(this) {if(operation===op && readTicket==ticket && api.session.remoteCurrent(c.playback.scope))mutable.value=mutable.value.copy(status=BlendStatus.ReadbackFailed,loading=false,notice="Saved Blend could not be verified. Read back the saved version.")}}
    }
    @Synchronized fun recover(c:BlendCapture):(() -> Unit)? {
        val op=operation ?: return null
        val ack=op.ack ?: return null
        if(!owns(c) || mutable.value.loading || !outcomeCurrent(op.outcomeScope))return null
        if(runCatching {PlaylistBlendJson.sources(ack.document.plan,c.playback.detail)}.isFailure)return null
        val ticket=++readTicket
        val token=Reservation(op,ticket,null,mutable.value,false);reservation=token
        mutable.value=mutable.value.copy(loading=true)
        token.work=work@{
            if(!enter(token))return@work
            if(synchronized(this){operation===op && owns(c) && ticket==readTicket})readback(op,c)
            synchronized(this){if(operation===op && ticket==readTicket)mutable.value=mutable.value.copy(loading=false)}
        }
        return token.work
    }
    /** Compatibility for unique playlist membership; UI carries its exact row index. */
    fun launch(p:PlaylistPlaybackCapture,track:TrackId,shuffle:Boolean=false):PlaylistLaunch {
        val indices=p.detail.tracks.indices.filter {p.detail.tracks[it].id==track}
        return if(indices.size==1)launchAt(p,indices.single(),shuffle)else PlaylistLaunch.Refused
    }
    @Synchronized fun launchAt(p:PlaylistPlaybackCapture,index:Int,shuffle:Boolean=false):PlaylistLaunch {
        val c=BlendCapture(p,lifetime)
        if(!owns(c) || !QueuePolicy.acceptsContext(p.detail.tracks.size) || index !in p.detail.tracks.indices)return PlaylistLaunch.Refused
        if(shuffle)return PlaylistLaunch.Plain(p.detail.tracks.shuffled(),0)
        if(!mutable.value.enabled)return PlaylistLaunch.Plain(p.detail.tracks.toList(),index)
        val op=operation
        if(op?.verified==true && op.accepted.playback.detail===p.detail && mutable.value.status==BlendStatus.Ready) {
            val ack=op.ack!!
            if(runCatching {PlaylistBlendJson.sources(ack.document.plan,p.detail)}.isSuccess)return PlaylistLaunch.Mixed(ack.document.plan,ack.document.plan.clips[index].occurrence,index,c,ack)
        }
        if(op?.verified==true && op.accepted.playback.detail!==p.detail) {
            starts.clear();mutable.value=mutable.value.copy(status=BlendStatus.Invalidated,enabled=false,notice="Playlist changed. Playing the plain order.")
            return PlaylistLaunch.Plain(p.detail.tracks.toList(),index)
        }
        return PlaylistLaunch.Refused
    }
    @Synchronized fun reserveStart(launch:PlaylistLaunch.Mixed):String? {
        if(!owns(launch.capture) || !mutable.value.enabled || mutable.value.status!=BlendStatus.Ready || operation?.ack!==launch.ack)return null
        starts.clear()
        return UUID.randomUUID().toString().also {starts[it]=launch}
    }
    @Synchronized fun playbackRefused(launch:PlaylistLaunch.Mixed) {
        if(owns(launch.capture) && operation?.ack===launch.ack)mutable.value=mutable.value.copy(notice="Blend could not start. Playback was not retried. Check saved version and device downloads.")
    }
    @Synchronized fun pendingStarts()=starts.size
    @Synchronized fun cancelStart(token:String){starts.remove(token)}
    @Synchronized fun startCurrent(token:String,scope:AccountScope):Boolean=starts[token]?.let {it.capture.playback.scope.epoch==scope.epoch && api.session.remoteCurrent(scope) && owns(it.capture) && mutable.value.enabled && operation?.ack===it.ack}==true
    /** Invoked synchronously on the sole service thread after its GET. No caller time accepted. */
    @Synchronized fun installStart(token:String,scope:AccountScope,document:MixPlanDocument,install:(SavedMix,Long)->Unit):Boolean {
        val launch=starts.remove(token) ?: return false
        if(launch.capture.playback.scope.epoch!=scope.epoch || !api.session.remoteCurrent(scope) || !owns(launch.capture) || !mutable.value.enabled || operation?.ack!==launch.ack || document.raw!=launch.ack.document.raw || !document.plan.playable())return false
        val clip=document.plan.clips.singleOrNull {it.occurrence==launch.occurrence} ?: return false
        install(document.plan,clip.start);return true
    }
}
