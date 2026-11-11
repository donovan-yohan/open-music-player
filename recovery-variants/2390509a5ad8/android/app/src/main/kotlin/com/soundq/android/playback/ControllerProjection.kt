package com.soundq.android.playback

import android.content.ComponentName
import android.content.Context
import android.os.*
import androidx.media3.common.*
import androidx.media3.session.*
import com.soundq.android.data.*
import com.soundq.android.data.timeline.globalAt
import com.soundq.android.data.timeline.globalEndMs

import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.concurrent.Executor

@kotlinx.serialization.Serializable data class QueueOccurrence(val occurrenceId:String,val trackId:Long,val title:String,val artist:String,val manual:Boolean,val durationMs:Long=0,val origin:QueueOrigin=if(manual)QueueOrigin.Manual else QueueOrigin.Context)
enum class PlaybackSource {Queue,Arrangement,SavedMix}
data class PlaybackProjection(val connection:Connection=Connection.Connecting,val title:String?=null,val isPlaying:Boolean=false,val canPlay:Boolean=false,
    val artist:String="",val queue:List<QueueOccurrence> = emptyList(),val selectedOccurrence:String?=null,val positionMs:Long=0,val durationMs:Long=0,
    val canNext:Boolean=false,val canPrevious:Boolean=false,val shuffle:Boolean=false,val repeat:Int=Player.REPEAT_MODE_OFF,val error:String?=null,val preparing:Boolean=false,val canUndo:Boolean=false,val queueRevision:Long=0,val localOnly:Boolean=false,val sessionIdentity:String="redacted",internal val accountEpoch:Long=-1,val source:PlaybackSource=PlaybackSource.Queue,val arrangement:AcceptedArrangement?=null,val arrangementService:String="",val sourceQueueIncarnation:String="",val selectionIncarnation:Long=0,
    val canPlayMix:Boolean=false,val canAuditionArrangement:Boolean=false,
    val performanceDecks:Map<String,PerformanceDeck> = emptyMap(),val canPerformArrangement:Boolean=false,val tempoPreview:TempoPreviewState?=null) {
    enum class Connection {Connecting,Connected,Disconnected,Unavailable}
}
/** Disposable immutable projection and standard controller-command adapter; no playlist ownership. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class ControllerProjection(context:Context,private val sessionToken:SessionToken?=null):AutoCloseable {
    private val mutable=MutableStateFlow(PlaybackProjection())
    val state:StateFlow<PlaybackProjection> = mutable.asStateFlow()
    private val handler=Handler(Looper.getMainLooper())
    private var controller:MediaController?=null
    private var closed=false
    private var queueRevision=0L
    private var selectionIncarnation=0L
    private var observedSelection:List<Any?>?=null
    private var observedSelectionMediaId:String?=null
    /** Synchronous publication prevents StateFlow conflation from reviving A-B-A captures. */
    private fun retireSelection() {retireScratch();selectionIncarnation++;mutable.value=mutable.value.copy(selectionIncarnation=selectionIncarnation)}

    private var projectedQueue:List<QueueOccurrence> = emptyList()
    private var projectedRevision=-1L
    private var retries=0
    private fun reorderSnapshot():ReorderSnapshot<MediaController>? {
        if(state.value.source!=PlaybackSource.Queue || state.value.connection!=PlaybackProjection.Connection.Connected)return null
        val c=controller ?: return null
        if(closed||!connection.accepts(c)||!c.isCommandAvailable(Player.COMMAND_CHANGE_MEDIA_ITEMS))return null
        val order=(0 until c.mediaItemCount).map {c.getMediaItemAt(it).mediaId}
        return ReorderSnapshot(c,queueRevision,order)
    }
    private val reorder=QueueReorderCommands(::reorderSnapshot) {c,from,to->c.moveMediaItem(from,to)}
    fun captureReorder(authority:()->Boolean)=reorder.capture(authority)
    private val appContext=context.applicationContext
    private val listener=object:Player.Listener {
        override fun onMediaItemTransition(mediaItem:MediaItem?,reason:Int) {
            if(observedSelectionMediaId!=mediaItem?.mediaId){observedSelectionMediaId=mediaItem?.mediaId;retireSelection()}
        }
        override fun onTimelineChanged(timeline:Timeline,reason:Int){queueRevision++}
        override fun onEvents(player:Player,events:Player.Events){publish()}
    }
    private val tick=object:Runnable {override fun run(){if(!closed){publish();handler.postDelayed(this,500)}}}
    private lateinit var connection:ControllerConnection<MediaController>
    private val reconnect=Runnable {if(!closed){connection.close();connect()}}
    init {connect()}
    private fun connect() {
        if(closed)return
        var attempt:ControllerConnection<MediaController>?=null
        var earlyDisconnect:MediaController?=null
        val future=MediaController.Builder(appContext,sessionToken ?: SessionToken(appContext,ComponentName(appContext,SoundQLibraryService::class.java)))
            .setListener(object:MediaController.Listener {override fun onDisconnected(controller:MediaController){
                earlyDisconnect=controller;attempt?.disconnected(controller)
            }
            override fun onExtrasChanged(controller:MediaController,extras:Bundle){performancePublication++;publish()}
            override fun onAvailableSessionCommandsChanged(controller:MediaController,commands:SessionCommands){publish()}
            }).buildAsync()
        val next=ControllerConnection(future,Executor {handler.post(it)},{it.isConnected},
            {c -> controller=c;c.addListener(listener);handler.post(tick);retries=0;projectedRevision=-1},
            {c -> retireSelection();observedSelection=null;observedSelectionMediaId=null;c.removeListener(listener);controller=null;handler.removeCallbacks(tick)},
            {MediaController.releaseFuture(future)},
            {status -> if(status==PlaybackProjection.Connection.Connected)publish() else {
                mutable.value=PlaybackProjection(status)
                retireSyncAdmissions()
                if(!closed && retries<5){handler.removeCallbacks(reconnect);handler.postDelayed(reconnect,1000L shl retries);retries++}
            }})
        attempt=next;connection=next
        earlyDisconnect?.let(next::disconnected)
    }
    @Volatile private var contextIntent=0L
    private var contextError:String?=null
    private fun refuseContext(message:String) {contextError=message;mutable.value=mutable.value.copy(error=message)}
    internal fun captureContextRead():()->Boolean {
        contextError=null
        val revision=++contextIntent
        val c=controller ?: return {false}
        val owner=connection
        val graph=(appContext as com.soundq.android.SoundQApplication).graph
        val scope=graph.session.capture() ?: return {false}
        val command=graph.contextStarts.captureRead()
        return {!closed&&contextIntent==revision&&connection===owner&&owner.accepts(c)&&graph.session.current(scope)&&command()}
    }
    internal fun contextReadRefused(current:()->Boolean) {if(current())refuseContext("Playback context could not be loaded. The existing queue is unchanged.")}
    fun playContext(tracks:List<Track>,index:Int,localOnly:Boolean=false,valid:(()->Boolean)?=null) {
        contextIntent++;contextError=null
        val c=controller ?: return
        if(valid?.invoke()==false)return
        if(index !in tracks.indices || !QueuePolicy.acceptsContext(tracks.size)){refuseContext(QueuePolicy.CONTEXT_LIMIT_MESSAGE);return}
        if(tracks.size>QueuePolicy.MAX_CONTEXT_TRACKS){startLargeContext(tracks,index,localOnly,valid ?: {true});return}
        val extras=Bundle().apply {putBoolean("localOnly",localOnly)}
        c.setMediaItems(tracks.map {MediaItem.Builder().setMediaId(it.id.value.toString()).setRequestMetadata(MediaItem.RequestMetadata.Builder().setExtras(extras).build()).build()},index,0)
        c.prepare();c.play()
    }
    private fun startLargeContext(tracks:List<Track>,index:Int,localOnly:Boolean,valid:()->Boolean) {
        val c=controller ?: return
        val graph=(appContext as com.soundq.android.SoundQApplication).graph
        val scope=graph.session.capture() ?: return
        val intent=contextIntent
        val command=SessionCommand(SoundQLibraryService.START_CONTEXT,Bundle.EMPTY)
        if(!connection.accepts(c)||!c.isSessionCommandAvailable(command)){refuseContext("Playback context is unavailable. The existing queue is unchanged.");return}
        val capture=graph.contextStarts.capture(graph.endpoint.identity,scope.accountId) {
            !closed && intent==contextIntent && connection.accepts(c) && graph.session.current(scope) && valid()
        }
        val saved=QueueSnapshot(graph.endpoint.identity,scope.accountId,tracks.map {track->
            SavedOccurrence(java.util.UUID.randomUUID().toString(),track.id.value,track.title,track.artist,false,localOnly,track.durationMs)
        },index,0)
        graph.io.launch {
            try {
                graph.contextStarts.stage(capture,saved)
                handler.post {
                    if(!graph.contextStarts.current(capture)||!connection.accepts(c)) {graph.io.launch {graph.contextStarts.finish(capture)};return@post}
                    val result=c.sendCustomCommand(command,Bundle().apply {putString("ticket",capture.ticket)})
                    result.addListener({
                        if(runCatching {result.get().resultCode==SessionResult.RESULT_SUCCESS}.getOrDefault(false))return@addListener
                        if(!closed&&contextIntent==intent&&valid()&&connection.accepts(c))refuseContext("Playback context was refused. The existing queue is unchanged.")
                        graph.io.launch {graph.contextStarts.finish(capture)}
                    },Executor {handler.post(it)})
                }
            }catch(_:Exception){
                graph.contextStarts.finish(capture)
                handler.post {if(!closed&&contextIntent==intent&&valid()&&connection.accepts(c))refuseContext(QueuePolicy.CONTEXT_LIMIT_MESSAGE)}
            }
        }
    }
    fun enqueue(track:Track,next:Boolean,localOnly:Boolean=false) {
        contextIntent++
        val c=controller ?: return
        if(!QueuePolicy.acceptsAppend(c.mediaItemCount,1))return
        val extras=Bundle().apply {putBoolean("manual",true);putBoolean("localOnly",localOnly)}
        val item=MediaItem.Builder().setMediaId(track.id.value.toString()).setRequestMetadata(MediaItem.RequestMetadata.Builder().setExtras(extras).build()).build()
        val origins=(0 until c.mediaItemCount).map {c.getMediaItemAt(it).mediaMetadata.extras?.getBoolean("manual")==true}
        val index=if(next) (c.currentMediaItemIndex+1).coerceIn(0,c.mediaItemCount) else QueuePolicy.manualInsert(origins,c.currentMediaItemIndex)
        c.addMediaItem(index,item)
    }
    fun sendJamAdmission(ticket:String,onRefused:()->Unit) {
        contextIntent++;handler.post {
        val c=controller
        if(c==null||!connection.accepts(c)||!c.isSessionCommandAvailable(SessionCommand(SoundQLibraryService.JAM_ADMIT,Bundle.EMPTY))) {onRefused();return@post}
        val result=c.sendCustomCommand(SessionCommand(SoundQLibraryService.JAM_ADMIT,Bundle.EMPTY),Bundle().apply {putString("ticket",ticket)})
        result.addListener({try {if(result.get().resultCode!=SessionResult.RESULT_SUCCESS)onRefused()}catch(_:Exception){onRefused()}},Executor {handler.post(it)})
    }}
    fun toggle(){retireScratch();controller?.let {if(it.isPlaying || it.playWhenReady)it.pause() else {if(it.playbackState==Player.STATE_IDLE || it.playerError!=null)it.prepare();it.play()}}}
    fun pause(){contextIntent++;retireScratch();controller?.pause()}
    fun seek(position:Long){retireScratch();controller?.let {it.seekTo(position.coerceIn(0,it.duration.coerceAtLeast(0)))}}
    fun next(){contextIntent++;controller?.seekToNextMediaItem()}
    fun previous(){contextIntent++;controller?.seekToPrevious()}
    fun shuffle(){contextIntent++;controller?.let {it.shuffleModeEnabled=!it.shuffleModeEnabled}}
    fun repeat(){contextIntent++;controller?.let {it.repeatMode=when(it.repeatMode){Player.REPEAT_MODE_OFF->Player.REPEAT_MODE_ALL;Player.REPEAT_MODE_ALL->Player.REPEAT_MODE_ONE;else->Player.REPEAT_MODE_OFF}}}
    fun select(occurrence:String){contextIntent++;controller?.let {c -> val i=(0 until c.mediaItemCount).firstOrNull {c.getMediaItemAt(it).mediaId==occurrence} ?: return; c.pause();c.seekTo(i,0)}}
    fun seekOccurrence(occurrence:String,sourceMs:Long){contextIntent++;controller?.let {c -> val i=(0 until c.mediaItemCount).firstOrNull {c.getMediaItemAt(it).mediaId==occurrence} ?: return;c.pause();c.seekTo(i,sourceMs.coerceAtLeast(0))}}
    fun move(occurrence:String,delta:Int){contextIntent++;controller?.let {c -> val i=(0 until c.mediaItemCount).firstOrNull {c.getMediaItemAt(it).mediaId==occurrence} ?: return;val to=i+delta;if(to in 0 until c.mediaItemCount)c.moveMediaItem(i,to)}}
    fun moveTo(occurrence:String,to:Int){contextIntent++;controller?.let {c -> val i=(0 until c.mediaItemCount).firstOrNull {c.getMediaItemAt(it).mediaId==occurrence} ?: return;if(to in 0 until c.mediaItemCount)c.moveMediaItem(i,to)}}
    fun remove(occurrence:String){contextIntent++;controller?.let {c -> val i=(0 until c.mediaItemCount).firstOrNull {c.getMediaItemAt(it).mediaId==occurrence} ?: return;c.removeMediaItem(i)}}
    fun clear(){retireScratch();controller?.clearMediaItems()}
    fun playMix(plan:com.soundq.android.data.mix.SavedMix,startOccurrence:String?=null,playlistStart:String?=null,done:(Boolean)->Unit) {
        contextIntent++
        val c=controller ?: return done(false)
        if(!c.isSessionCommandAvailable(SessionCommand(SoundQLibraryService.PLAY_MIX,Bundle.EMPTY)))return done(false)
        val f=c.sendCustomCommand(SessionCommand(SoundQLibraryService.PLAY_MIX,Bundle.EMPTY),Bundle().apply {putString("planId",plan.id);putLong("version",plan.version);startOccurrence?.let {putString("startOccurrence",it)};playlistStart?.let {putString("playlistStart",it)}})
        f.addListener({done(!closed && connection.accepts(c) && runCatching {f.get().resultCode==SessionResult.RESULT_SUCCESS}.getOrDefault(false))},Executor {handler.post(it)})
    }
    fun applyArrangement(document:com.soundq.android.data.timeline.TimelineDocument,request:String,valid:()->Boolean,done:(ArrangementIdentity?)->Unit) {
        contextIntent++
        val c=controller ?: return done(null)
        if(!c.isSessionCommandAvailable(SessionCommand(SoundQLibraryService.APPLY_ARRANGEMENT,Bundle.EMPTY)))return done(null)
        val captured=state.value
        val raw=runCatching {document.nativeArrangementPayload();Json.encodeToString(document)}.getOrNull() ?: return done(null)
        if(!valid() || raw.toByteArray().size>192*1024)return done(null)
        // Read MediaController's current (including masked seek) cursor, not the
        // 500ms projection tick. Ordinary rows use source time; installed mixes
        // already use global time. Placement changes must not choose zero for us.
        val position=if(captured.arrangement?.identity?.install==c.currentMediaItem?.mediaId)c.currentPosition
            else document.clips.firstOrNull {it.occurrence==c.currentMediaItem?.mediaId}?.let {
                it.globalAt(c.currentPosition.coerceIn(it.sourceInMs,it.sourceOutMs))
            } ?: return done(null)
        val startPosition=position.coerceIn(0,document.clips.maxOf {it.globalEndMs})
        val f=c.sendCustomCommand(SessionCommand(SoundQLibraryService.APPLY_ARRANGEMENT,Bundle.EMPTY),Bundle().apply {
            putLong("positionMs",startPosition);putString("document",raw);putString("request",request);putString("service",captured.arrangementService);putString("queue",captured.sourceQueueIncarnation);putLong("accountEpoch",captured.accountEpoch)
        })
        f.addListener({
            publish()
            val accepted=runCatching {f.get().takeIf {it.resultCode==SessionResult.RESULT_SUCCESS}?.extras?.getString("acceptedArrangement")?.let {Json.decodeFromString<AcceptedArrangement>(it).withProjectedDocument()}}.getOrNull()
            done(accepted?.takeIf {!closed && connection.accepts(c) && valid() && it.document==document && it.identity==state.value.arrangement?.identity}?.identity)
        },Executor {handler.post(it)})
    }
    private var tempoRequest = 0L
    private var tempoLease: TempoPreviewLease? = null
    private var tempoRevision = 0L
    private var tempoClosed = false
    private data class TempoMotion(val lease: TempoPreviewLease, val revision: Long, val bpm: Double, val glideMs: Long)
    private var tempoLatest: TempoMotion? = null
    private var tempoInFlight = false
    fun beginTempo(identity: ArrangementIdentity, occurrence: String, source: com.soundq.android.data.timeline.TempoSourceIdentity,
        done: (TempoPreviewLease?, String?) -> Unit) {
        if (tempoLease != null) return done(null, "A BPM preview is already open. Save or Cancel it first.")
        val c = performanceController(identity) ?: return done(null, "Not playing this arrangement. Changes will be saved for the next Play.")
        val request = ++tempoRequest
        sendPerformance(c, PerformanceCommands.TEMPO_BEGIN, PerformanceCommands.target(PerformanceTarget(identity, occurrence)).apply {
            putString("source", Json.encodeToString(source))
        }) { result ->
            val lease = result?.takeIf { it.resultCode == SessionResult.RESULT_SUCCESS }?.let { PerformanceCommands.read<TempoPreviewLease>(it.extras, "lease") }
            if (request != tempoRequest || performanceController(identity) !== c) {
                if (lease != null) sendPerformance(c, PerformanceCommands.TEMPO_CANCEL, tempoArgs(lease))
                done(null, "Preview was retired.")
            } else {
                tempoLease = lease; tempoRevision = 0; tempoClosed = false
                done(lease, result?.extras?.getString("message") ?: if (lease == null) "Live preview refused. No BPM was saved. Cancel or disable the shared transition and apply it before retrying." else null)
            }
        }
    }
    private fun tempoArgs(lease: TempoPreviewLease) = PerformanceCommands.target(lease.target).apply { putString("lease", Json.encodeToString(lease)) }
    fun previewTempo(lease: TempoPreviewLease, bpm: Double, glideMs: Long = 0) {
        if (tempoLease != lease || tempoClosed) return
        tempoLatest = TempoMotion(lease, ++tempoRevision, bpm, glideMs)
        drainTempo()
    }
    private fun drainTempo() {
        if (tempoInFlight) return
        val motion = tempoLatest ?: return
        tempoLatest = null
        if (tempoLease != motion.lease || tempoClosed) return
        val c = performanceController(motion.lease.target.identity) ?: return
        tempoInFlight = true
        sendPerformance(c, PerformanceCommands.TEMPO_PREVIEW, tempoArgs(motion.lease).apply {
            putLong("revision", motion.revision); putDouble("bpm", motion.bpm); putLong("glideMs", motion.glideMs)
        }) { tempoInFlight = false; drainTempo() }
    }
    fun saveTempo(lease: TempoPreviewLease, done: (Boolean, String?) -> Unit) {
        if (tempoLease != lease || tempoClosed) return done(false, "Preview changed.")
        val c = performanceController(lease.target.identity) ?: return done(false, "Playback owner changed.")
        // MediaSession FIFO orders this one remaining motion ahead of Close.
        tempoLatest?.let { motion ->
            tempoLatest = null
            sendPerformance(c, PerformanceCommands.TEMPO_PREVIEW, tempoArgs(lease).apply {
                putLong("revision", motion.revision); putDouble("bpm", motion.bpm); putLong("glideMs", motion.glideMs)
            })
        }
        tempoClosed = true
        sendPerformance(c, PerformanceCommands.TEMPO_SAVE, tempoArgs(lease).apply { putLong("revision", tempoRevision) }) { result ->
            val ok = result?.resultCode == SessionResult.RESULT_SUCCESS
            if (tempoLease == lease) { if (ok) tempoLease = null else tempoClosed = false }
            publish(); done(ok, result?.extras?.getString("message") ?: if (!ok) "Save did not complete. Prior saved BPM is unchanged." else null)
        }
    }
    fun cancelTempo(lease: TempoPreviewLease?, done: (Boolean, String?) -> Unit = { _, _ -> }) {
        tempoRequest++
        if (lease == null) { done(true, null); return }
        if (tempoLease == lease) { tempoClosed = true; tempoLatest = null; tempoLease = null }
        val c = controller ?: return done(false, "Playback connection ended. Saved BPM is unchanged.")
        sendPerformance(c, PerformanceCommands.TEMPO_CANCEL, tempoArgs(lease)) { result ->
            publish(); done(result?.resultCode == SessionResult.RESULT_SUCCESS, result?.extras?.getString("message") ?: "Restore did not complete. Saved BPM is unchanged.")
        }
    }
    private var scratchRequest=0L
    private var lastScratchInput=0L
    private var scratchLease:ScratchLease?=null
    private data class ScratchMove(val lease:ScratchLease,val rate:Double,val event:Long)
    private var latestScratchMove:ScratchMove?=null
    private var moveInFlight=false
    private fun performanceController(identity:ArrangementIdentity):MediaController? {
        val c=controller ?: return null
        return c.takeIf {!closed&&connection.accepts(c)&&state.value.arrangement?.identity==identity&&
            c.currentMediaItem?.mediaId==identity.install&&c.sessionExtras.getLong("accountEpoch",-1)==identity.accountEpoch}
    }
    private fun sendPerformance(c:MediaController,action:String,args:Bundle,done:(SessionResult?)->Unit={}) {
        if(!c.isSessionCommandAvailable(SessionCommand(action,Bundle.EMPTY)))return done(null)
        val future=c.sendCustomCommand(SessionCommand(action,Bundle.EMPTY),args)
        future.addListener({done(runCatching {future.get()}.getOrNull())},Executor {handler.post(it)})
    }
    fun beginScratch(identity:ArrangementIdentity,occurrence:String,eventNanos:Long,done:(ScratchLease?)->Unit) {
        val c=performanceController(identity) ?: return done(null)
        if(!state.value.canPerformArrangement||scratchLease!=null)return done(null)
        val request=++scratchRequest
        lastScratchInput=eventNanos
        val target=PerformanceTarget(identity,occurrence)
        sendPerformance(c,PerformanceCommands.BEGIN,PerformanceCommands.target(target).apply {putLong("eventNanos",eventNanos)}) {result->
            val lease=result?.takeIf {it.resultCode==SessionResult.RESULT_SUCCESS}?.let {PerformanceCommands.read<ScratchLease>(it.extras,"lease")}
            if(lease==null)return@sendPerformance done(null)
            if(request!=scratchRequest || performanceController(identity)!==c || lease.target!=target) {
                sendPerformance(c,PerformanceCommands.CANCEL,PerformanceCommands.lease(lease,maxOf(android.os.SystemClock.uptimeMillis()*1_000_000L,eventNanos+1)))
                done(null)
            } else {scratchLease=lease;done(lease)}
        }
    }
    fun moveScratch(lease:ScratchLease,rate:Double,eventNanos:Long) {
        if(scratchLease!=lease||!rate.isFinite()||rate !in -8.0..8.0||eventNanos<=lastScratchInput)return
        lastScratchInput=eventNanos
        latestScratchMove=ScratchMove(lease,rate,eventNanos)
        drainScratchMove()
    }
    private fun drainScratchMove() {
        if(moveInFlight)return
        val move=latestScratchMove ?: return
        latestScratchMove=null
        if(scratchLease!=move.lease)return
        val c=performanceController(move.lease.target.identity) ?: return retireScratch()
        moveInFlight=true
        sendPerformance(c,PerformanceCommands.MOVE,PerformanceCommands.lease(move.lease,move.event).apply {putDouble("rate",move.rate)}) {
            moveInFlight=false
            if(it?.resultCode!=SessionResult.RESULT_SUCCESS&&scratchLease==move.lease)retireScratch()
            drainScratchMove()
        }
    }
    fun endScratch(lease:ScratchLease,eventNanos:Long)=finishScratch(lease,eventNanos,false)
    fun cancelScratch(lease:ScratchLease,eventNanos:Long)=finishScratch(lease,eventNanos,true)
    private fun finishScratch(lease:ScratchLease,eventNanos:Long,cancel:Boolean) {
        if(scratchLease!=lease)return
        val terminalEvent=maxOf(eventNanos,lastScratchInput+1)
        scratchRequest++;scratchLease=null;latestScratchMove=null
        val c=controller ?: return
        if(connection.accepts(c))sendPerformance(c,if(cancel)PerformanceCommands.CANCEL else PerformanceCommands.END,PerformanceCommands.lease(lease,terminalEvent))
    }
    private fun retireScratch() {
        contextIntent++
        scratchRequest++;latestScratchMove=null
        val lease=scratchLease ?: return
        finishScratch(lease,maxOf(android.os.SystemClock.uptimeMillis()*1_000_000L,lastScratchInput+1),true)
    }
    private class SyncAdmission(val identity:ArrangementIdentity) {
        var unlinkPublication:Long?=null
        var unlinkDone:((Boolean)->Unit)?=null
        fun completeUnlink(accepted:Boolean) {val done=unlinkDone;unlinkDone=null;done?.invoke(accepted)}
    }
    private val syncAdmissions=mutableMapOf<String,SyncAdmission>()
    private fun retireSyncAdmissions() {
        val retired=syncAdmissions.values.toList();syncAdmissions.clear()
        retired.forEach {it.completeUnlink(false)}
    }
    private var performancePublication=0L
    fun syncIncoming(identity:ArrangementIdentity,referenceOccurrence:String,incomingOccurrence:String,beats:Int,referenceGrid:QualifiedLiveGrid,incomingGrid:QualifiedLiveGrid,done:(Boolean)->Unit) {
        val c=performanceController(identity) ?: return done(false)
        if(incomingOccurrence in syncAdmissions)return done(false)
        val admission=SyncAdmission(identity)
        syncAdmissions[incomingOccurrence]=admission
        sendPerformance(c,PerformanceCommands.SYNC,PerformanceCommands.target(PerformanceTarget(identity,incomingOccurrence)).apply {
            putString("reference",referenceOccurrence);putInt("beats",beats)
            putString("referenceGrid",Json.encodeToString(referenceGrid));putString("incomingGrid",Json.encodeToString(incomingGrid))
        }) {result->
            // Null completion is uncertain, not permission to replay a grid.
            if(result!=null&&result.resultCode!=SessionResult.RESULT_SUCCESS&&syncAdmissions[incomingOccurrence]===admission) {
                syncAdmissions.remove(incomingOccurrence);admission.completeUnlink(false)
            }
            done(performanceController(identity)===c&&result?.resultCode==SessionResult.RESULT_SUCCESS)
        }
    }
    /** Success means this exact admission was cleared by a newer observed Off, not RPC admission. */
    fun unlinkIncoming(identity:ArrangementIdentity,incomingOccurrence:String,done:(Boolean)->Unit={}) {
        val c=performanceController(identity) ?: return done(false)
        val admission=syncAdmissions[incomingOccurrence] ?: SyncAdmission(identity).also {syncAdmissions[incomingOccurrence]=it}
        if(admission.identity!=identity||admission.unlinkDone!=null)return done(false)
        admission.unlinkDone=done
        sendPerformance(c,PerformanceCommands.UNLINK,PerformanceCommands.target(PerformanceTarget(identity,incomingOccurrence))) {result->
            if(syncAdmissions[incomingOccurrence]!==admission||admission.unlinkDone!==done)return@sendPerformance
            if(performanceController(identity)!==c) {
                syncAdmissions.remove(incomingOccurrence);admission.completeUnlink(false)
            } else if(result?.resultCode==SessionResult.RESULT_SUCCESS)admission.unlinkPublication=performancePublication
            else admission.completeUnlink(false) // Refusal/uncertainty never releases the canonical Sync latch.
        }
    }

    fun returnToSources(){retireScratch();controller?.sendCustomCommand(SessionCommand(SoundQLibraryService.RETURN_SOURCES,Bundle.EMPTY),Bundle.EMPTY)}
    fun seekArrangement(identity:ArrangementIdentity,globalMs:Long){
        val c=controller ?: return
        val accepted=state.value.arrangement ?: return
        if(accepted.identity!=identity || c.currentMediaItem?.mediaId!=identity.install || c.sessionExtras.getLong("accountEpoch",-1)!=identity.accountEpoch)return
        c.pause();c.seekTo(globalMs.coerceIn(0,c.duration.coerceAtLeast(0)))
    }
    fun undo(){contextIntent++;controller?.sendCustomCommand(SessionCommand(SoundQLibraryService.UNDO,Bundle.EMPTY),Bundle.EMPTY)}
    private fun publish() {
        if(closed)return
        val c=controller ?: return
        if(!connection.accepts(c)) return
        if(projectedRevision!=queueRevision) {
            projectedQueue=(0 until c.mediaItemCount).map {i -> val m=c.getMediaItemAt(i);QueueOccurrence(m.mediaId,m.mediaMetadata.extras?.getLong("trackId") ?: 0,m.mediaMetadata.title?.toString().orEmpty(),m.mediaMetadata.artist?.toString().orEmpty(),m.mediaMetadata.extras?.getBoolean("manual")==true,m.mediaMetadata.extras?.getLong("durationMs") ?: 0,QueueOrigin.read(m.mediaMetadata.extras?.getString("origin"),m.mediaMetadata.extras?.getBoolean("manual")==true))}
            projectedRevision=queueRevision
        }
        val accepted=c.sessionExtras.getString("acceptedArrangement")?.let {runCatching {Json.decodeFromString<AcceptedArrangement>(it).withProjectedDocument()}.getOrNull()}?.takeIf {
            it.identity.install==c.currentMediaItem?.mediaId && it.identity.accountEpoch==c.sessionExtras.getLong("accountEpoch",-1)
        }
        val source=if(accepted!=null)PlaybackSource.Arrangement else if(c.currentMediaItem?.mediaId?.startsWith("mix:")==true || c.currentMediaItem?.localConfiguration?.uri?.scheme=="soundqmix")PlaybackSource.SavedMix else PlaybackSource.Queue
        val queue=accepted?.sources ?: if(source==PlaybackSource.SavedMix)emptyList() else projectedQueue
        val selection=listOf(c.sessionExtras.getString("incarnation"),c.sessionExtras.getLong("accountEpoch",-1),c.sessionExtras.getString("sourceQueueIncarnation"),source,c.currentMediaItem?.mediaId,c.currentMediaItem?.mediaMetadata?.extras?.getBoolean("localOnly")==true)
        if(observedSelection!=selection){contextError=null;observedSelection=selection;observedSelectionMediaId=c.currentMediaItem?.mediaId;retireSelection()}
        val decks=PerformanceCommands.read<Map<String,PerformanceDeck>>(c.sessionExtras,PerformanceCommands.DECKS).orEmpty().filter {(id,deck)->id==deck.target.occurrence&&deck.target.identity==accepted?.identity}.entries.take(4).associate {it.toPair()}
        val completedUnlinks=syncAdmissions.entries.toList().mapNotNull {(occurrence,admission)->
            val retired=admission.identity!=accepted?.identity
            val observed=admission.unlinkPublication?.let {performancePublication>it&&decks[occurrence]?.syncState==LiveSyncState.Off}==true
            if((retired||observed)&&syncAdmissions.remove(occurrence,admission))admission to !retired else null
        }
        mutable.value=PlaybackProjection(PlaybackProjection.Connection.Connected,c.mediaMetadata.title?.toString(),c.isPlaying,c.isCommandAvailable(Player.COMMAND_PLAY_PAUSE)&&c.mediaItemCount>0,
            c.mediaMetadata.artist?.toString().orEmpty(),queue,c.currentMediaItem?.mediaId,c.currentPosition.coerceAtLeast(0),c.duration.coerceAtLeast(0),
            c.hasNextMediaItem(),c.hasPreviousMediaItem()||c.currentPosition>0,c.shuffleModeEnabled,c.repeatMode,
            if(c.playerError!=null) "Audio could not be played. Retry playback." else contextError,c.playbackState==Player.STATE_BUFFERING,c.sessionExtras.getBoolean("canUndo"),queueRevision,c.currentMediaItem?.mediaMetadata?.extras?.getBoolean("localOnly")==true,c.sessionExtras.getString("incarnation") ?: "redacted",c.sessionExtras.getLong("accountEpoch",-1),source,accepted,c.sessionExtras.getString("arrangementService").orEmpty(),c.sessionExtras.getString("sourceQueueIncarnation").orEmpty(),selectionIncarnation,
            canPlayMix=c.isSessionCommandAvailable(SessionCommand(SoundQLibraryService.PLAY_MIX,Bundle.EMPTY)),
            canAuditionArrangement=c.isSessionCommandAvailable(SessionCommand(SoundQLibraryService.APPLY_ARRANGEMENT,Bundle.EMPTY)),
            tempoPreview=PerformanceCommands.read<TempoPreviewState>(c.sessionExtras,PerformanceCommands.TEMPO_STATE),
            performanceDecks=decks,
            canPerformArrangement=accepted!=null&&c.sessionExtras.getBoolean("canPerformArrangement")&&c.isSessionCommandAvailable(SessionCommand(PerformanceCommands.BEGIN,Bundle.EMPTY)))
        completedUnlinks.forEach {(admission,observed)->admission.completeUnlink(observed)}
    }
    override fun close(){if(closed)return;cancelTempo(tempoLease);retireScratch();closed=true;handler.removeCallbacks(reconnect);handler.removeCallbacks(tick);connection.close();controller=null;retireSyncAdmissions();projectedQueue=emptyList()}
}
