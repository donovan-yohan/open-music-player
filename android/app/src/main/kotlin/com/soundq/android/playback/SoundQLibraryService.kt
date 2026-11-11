package com.soundq.android.playback

import android.os.Bundle
import android.net.Uri
import androidx.media3.common.*
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.*
import androidx.media3.session.MediaLibraryService.*
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.*
import com.soundq.android.*
import com.soundq.android.data.*
import com.soundq.android.playback.system.*
import com.soundq.android.data.timeline.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.coroutines.*
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** One service Player owns the occurrence timeline and one native callback output. */
@androidx.annotation.OptIn(UnstableApi::class)
class SoundQLibraryService : MediaLibraryService() {
    private var session:MediaLibrarySession?=null
    private lateinit var player:Player
    private lateinit var transport:ServiceTransportPlayer
    private val jobs=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
    private val grants=ConcurrentHashMap<String,MediaGrant>()
    private val mixGrants=ConcurrentHashMap<String,com.soundq.android.playback.mix.MixGrant>()
    @Volatile private var selectionEpoch=0L
    private var clockRevision=0L
    private val serviceIncarnation=UUID.randomUUID().toString()
    private var sourceQueueIncarnation=UUID.randomUUID().toString()
    private var acceptedArrangement:AcceptedArrangement?=null
    private var tempoCaller: Pair<MediaSession.ControllerInfo, TempoPreviewLease>? = null
    private val pendingTempoBegins = mutableMapOf<MediaSession.ControllerInfo, java.util.concurrent.atomic.AtomicBoolean>()
    private var arrangementItems:List<MediaItem>?=null
    private var pendingArrangement:Pair<AcceptedArrangement,Long>?=null
    private fun sourceOccurrences():List<QueueOccurrence> = (0 until player.mediaItemCount).map {i ->
        val m=player.getMediaItemAt(i);val e=m.mediaMetadata.extras
        QueueOccurrence(m.mediaId,e?.getLong("trackId") ?: 0,m.mediaMetadata.title?.toString().orEmpty(),m.mediaMetadata.artist?.toString().orEmpty(),e?.getBoolean("manual")==true,e?.getLong("durationMs") ?: 0,QueueOrigin.read(e?.getString("origin"),e?.getBoolean("manual")==true),PlaybackRef.read(e?.getString("playbackRef")))
    }
    private fun arrangementCurrent(accepted:AcceptedArrangement):Boolean {
        val scope=account ?: return false
        return acceptedArrangement===accepted && accepted.identity.service==serviceIncarnation &&
            accepted.identity.queue==sourceQueueIncarnation && accepted.identity.accountEpoch==scope.epoch &&
            graph.session.current(scope) && player.currentMediaItem?.mediaId==accepted.identity.install
    }
    private fun arrangementReady() {
        val pending=pendingArrangement ?: return
        if(player.playbackState!=Player.STATE_READY)return
        pendingArrangement=null
        val accepted=pending.first;val scope=account ?: return
        if(pending.second==selectionEpoch && arrangementCurrent(accepted))graph.timeline.completeAudition(accepted.identity.install,scope,accepted.document){player.play()}
        graph.timeline.retireAudition(accepted.identity.install)
    }
    private fun retireArrangement() {tempoCaller=null;retiringLiveQualifications.clear();liveQualifications.clear();pendingArrangement=null;acceptedArrangement=null;arrangementItems=null;sourceQueueIncarnation=UUID.randomUUID().toString()}
    private val mixLoads=java.util.concurrent.atomic.AtomicInteger()
    private lateinit var graph:AppGraph
    private lateinit var artwork:ScopedArtworkLoader
    private var account:AccountScope?=null
    private var undo:List<MediaItem>?=null
    private var undoScope:AccountScope?=null
    private var undoVersion=-1L
    private var undoIndex=0
    private var undoPosition=0L
    private var restoring=false
    private var rejectedQueue=false
    private var restoredIdentity:String?=null
    private var saveJob:Job?=null
    private val queueFileLock=Any()
    @Volatile private var queueSaveEpoch=0L
    private lateinit var catalog:SystemMediaCatalog
    private lateinit var interruptions:SystemAudioInterruption
    private lateinit var recorder:ServicePlayRecorder
    private lateinit var continuation:ServiceLibraryContinuation
    private var playbackWakeLock: android.os.PowerManager.WakeLock? = null

    private fun updatePlaybackWakeLock() {
        val lock = playbackWakeLock ?: return
        val needed = player.playWhenReady && player.playbackState in setOf(Player.STATE_BUFFERING, Player.STATE_READY)
        if (needed && !lock.isHeld) lock.acquire()
        else if (!needed && lock.isHeld) lock.release()
    }

    private data class LikeTarget(val item:MediaItem,val view:LibraryRepository.LikeView)
    private var likeTarget:LikeTarget?=null
    private var likeToken:String?=null
    private var likeReadItem:MediaItem?=null

    private fun currentLikeTarget():LikeTarget? {
        val scope=account?.takeIf(graph.session::remoteCurrent) ?: return null
        val item=player.currentMediaItem ?: return null
        val uri=item.localConfiguration?.uri ?: return null
        if(uri.scheme!="soundq" || item.mediaMetadata.extras?.getBoolean("localOnly")==true)return null
        val grant=grants[uri.toString()] ?: return null
        if(grant.localOnly || !graph.session.remoteCurrent(grant.scope) || grant.scope.epoch!=scope.epoch)return null
        val view=graph.library.likeView(scope,grant.track)
        if(view==null) {
            if(likeReadItem!==item) {
                likeReadItem=item
                jobs.launch {
                    try {withContext(Dispatchers.IO){graph.library.reconcileLike(scope,grant.track)}}catch(_:Exception){/* Unknown stays unavailable. */}
                    finally {refreshLikeButton()}
                }
            }
            return null
        }
        if(view.track.liked==null)return null
        return LikeTarget(item,view)
    }
    private fun refreshLikeButton() {
        val next=currentLikeTarget()
        val prior=likeTarget
        if(next==null){likeTarget=null;likeToken=null}
        else if(prior?.item!==next.item || prior.view!==next.view) {likeTarget=next;likeToken=LIKE+UUID.randomUUID()}
        val token=likeToken
        val buttons=if(next==null||token==null)emptyList() else listOf(CommandButton.Builder(if(next.view.track.liked==true)CommandButton.ICON_HEART_FILLED else CommandButton.ICON_HEART_UNFILLED)
            .setDisplayName(if(next.view.outcome in setOf(MutationOutcome.Uncertain,MutationOutcome.ReadbackFailed))"Reload Like status" else if(next.view.track.liked==true)"Unlike" else "Like")
            .setSessionCommand(SessionCommand(token,Bundle.EMPTY)).setEnabled(next.view.outcome!=MutationOutcome.Pending).setSlots(CommandButton.SLOT_OVERFLOW).build())
        session?.setMediaButtonPreferences(buttons)
        session?.connectedControllers?.forEach {controller->session?.setAvailableCommands(controller,sessionCommands(controller),commands(graph.session.capture()!=null||localAccess(),controller))}
    }
    private fun likeCommand(controller:MediaSession.ControllerInfo,command:SessionCommand):ListenableFuture<SessionResult> {
        if(!admitted(controller))return Futures.immediateFuture(SessionResult(SessionError.ERROR_PERMISSION_DENIED))
        val captured=likeTarget
        val actual=currentLikeTarget()
        if(command.customAction!=likeToken || captured==null || actual?.item!==captured.item || actual.view!==captured.view) {
            refreshLikeButton();return Futures.immediateFuture(SessionResult(SessionError.ERROR_INVALID_STATE))
        }
        val reconcile=captured.view.outcome in setOf(MutationOutcome.Uncertain,MutationOutcome.ReadbackFailed)
        val receipt=if(reconcile)null else graph.library.offerLike(captured.view.scope,captured.view.track.id)?.takeIf {it.view===captured.view}?.let(graph.library::claimLike)
        if(!reconcile&&receipt==null){refreshLikeButton();return Futures.immediateFuture(SessionResult(SessionError.ERROR_INVALID_STATE))}
        likeToken=null;likeTarget=null;refreshLikeButton()
        val result=SettableFuture.create<SessionResult>()
        jobs.launch {
            try {
                val outcome=withContext(Dispatchers.IO) {
                    if(reconcile){graph.library.reconcileLike(captured.view.scope,captured.view.track.id);MutationOutcome.Confirmed}
                    else graph.library.executeLike(receipt!!)
                }
                result.set(SessionResult(if(outcome==MutationOutcome.Confirmed)SessionResult.RESULT_SUCCESS else SessionError.ERROR_INVALID_STATE))
            } catch(_:Exception){result.set(SessionResult(SessionError.ERROR_INVALID_STATE))}
            finally {refreshLikeButton()}
        }.invokeOnCompletion {
            receipt?.let(graph.library::abandonLike)
            result.set(SessionResult(SessionError.ERROR_INVALID_STATE))
        }
        return result
    }

    override fun onCreate() {
        super.onCreate()
        graph=(application as SoundQApplication).graph
        graph.jamAdmission.attachOwner(serviceIncarnation)
        catalog=SystemMediaCatalog(graph.session,graph.api::library) {scope ->
            graph.downloads.load(scope)
            graph.downloads.state.value.rows.filter {it.status==com.soundq.android.data.offline.DownloadStatus.Complete}.map {it.track}
        }
        player = try { (application as SoundQApplication).createCallbackLibraryPlayer(grants, jobs) }
            catch (failure: Throwable) { jobs.cancel(); throw failure }
        if (checkSelfPermission(android.Manifest.permission.WAKE_LOCK) == android.content.pm.PackageManager.PERMISSION_GRANTED) {
            playbackWakeLock = getSystemService(android.os.PowerManager::class.java)
                .newWakeLock(android.os.PowerManager.PARTIAL_WAKE_LOCK, "SoundQ:native-playback")
                .apply { setReferenceCounted(false) }
        }
        transport=ServiceTransportPlayer(player){account?.let(graph.session::current)==true||localAccess()}
        continuation=ServiceLibraryContinuation(player,transport,graph,jobs) {tracks,valid ->
            val prior=grants.keys.toSet()
            try {
                graph.rememberTracks(tracks)
                resolve(tracks.map {MediaItem.Builder().setMediaId(it.id.value.toString()).build()}).map {item ->
                    item.buildUpon().setMediaMetadata(item.mediaMetadata.buildUpon().setExtras(Bundle(item.mediaMetadata.extras).apply {putString("origin","Continuation")}).build()).build()
                }.also {check(valid())}
            }catch(failure:Exception){grants.keys.filter {it !in prior}.forEach(grants::remove);throw failure}
        }
        transport.onIntentChanged=continuation::command
        interruptions=SystemAudioInterruption(this,player,{account?.let(graph.session::current)==true||localAccess()},{graph.contextStarts.retire();(player as? com.soundq.android.playback.nativeengine.NativeCallbackPlayer)?.retirePerformanceTransport();transport.retire();selectionEpoch++})
        recorder=ServicePlayRecorder(player,graph.session,graph.api)
        artwork=ScopedArtworkLoader(graph)
        val activity=android.app.PendingIntent.getActivity(this,0,android.content.Intent(this,MainActivity::class.java),android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT)
        session=MediaLibrarySession.Builder(this,transport,Callback()).setBitmapLoader(artwork).setSessionActivity(activity).build()
        (player as? com.soundq.android.playback.nativeengine.NativeCallbackPlayer)?.onPerformanceChanged={validateLiveQualifications();publishSessionExtras()}
        publishSessionExtras()
        player.addListener(object:Player.Listener {
            override fun onEvents(player: Player, events: Player.Events) {
                updatePlaybackWakeLock()
                if(events.containsAny(Player.EVENT_TIMELINE_CHANGED,Player.EVENT_MEDIA_ITEM_TRANSITION,
                    Player.EVENT_POSITION_DISCONTINUITY,Player.EVENT_SHUFFLE_MODE_ENABLED_CHANGED))publishSessionExtras()
            }
            override fun onPlaybackStateChanged(playbackState:Int) {arrangementReady();if(acceptedArrangement==null)continuation.ended(playbackState)}
            override fun onPlayerError(error:PlaybackException) {pendingArrangement=null}
            override fun onAvailableCommandsChanged(availableCommands:Player.Commands) {refreshLikeButton()}
            override fun onTimelineChanged(timeline:Timeline,reason:Int) {
                clockRevision++
                // setShuffleOrder synchronously publishes a timeline but changes no rows,
                // grants or queue incarnation. The shuffle callback handles mode intent.
                if((player as? ServiceQueuePlayer)?.changingTraversal==true)return
                continuation.timelineChanged()
                if(reason==Player.TIMELINE_CHANGE_REASON_PLAYLIST_CHANGED) {
                    val accepted=acceptedArrangement
                    if(accepted==null || accepted.identity.install!=player.currentMediaItem?.mediaId)retireArrangement()
                }
                graph.jamAdmission.replaceOwner();publishSessionExtras();refreshLikeButton()
                val retained=(0 until player.mediaItemCount).mapNotNull {player.getMediaItemAt(it).localConfiguration?.uri?.toString()}.toSet()
                val sourceRetained=arrangementItems.orEmpty().mapNotNull {it.localConfiguration?.uri?.toString()}.toSet()
                grants.keys.retainAll(retained+sourceRetained);mixGrants.entries.toList().filter {it.key !in retained}.forEach {(uri,grant)->if(mixGrants.remove(uri,grant))grant.close()}
                scheduleSave()
            }
            override fun onIsPlayingChanged(isPlaying:Boolean) {continuation.playingChanged(isPlaying);scheduleSave()}
            override fun onPositionDiscontinuity(oldPosition:Player.PositionInfo,newPosition:Player.PositionInfo,reason:Int) {clockRevision++;continuation.positionChanged(reason);scheduleSave()}
            override fun onMediaItemTransition(mediaItem:MediaItem?,reason:Int) {clockRevision++;continuation.transition();refreshLikeButton()}
            override fun onRepeatModeChanged(repeatMode:Int) {continuation.repeatChanged();scheduleSave()}
            override fun onShuffleModeEnabledChanged(shuffleModeEnabled:Boolean) {clockRevision++;continuation.shuffleChanged();scheduleSave()}
        })
        jobs.launch {graph.phoneAudio.state.collect {phone->
            session?.connectedControllers?.forEach {c->session?.setAvailableCommands(c,sessionCommands(c),commands(account!=null||localAccess(),c))}
            if(phone.ready&&account==null&&localAccess())restoreGuestQueue()
        }}
        jobs.launch(Dispatchers.Main) {graph.library.likeRevision.collect {refreshLikeButton()}}
        jobs.launch(Dispatchers.Main) {graph.crossfadePreferences.state.collect {publishSessionExtras()}}
        jobs.observeAccountState(graph.session) {observation ->
                val state=observation.state
                if(state is AuthState.LocalLocked) {
                    continuation.accountRetired()
                    graph.jamAdmission.bindAccount(null)
                    selectionEpoch++;pendingArrangement=null;mixGrants.values.forEach {it.close()};saveJob?.cancel();interruptions.command();transport.retire();player.pause();player.stop();grants.clear();undo=null;undoScope=null
                    graph.jamAdmission.replaceOwner();publishSessionExtras();refreshLikeButton()
                    session?.connectedControllers?.forEach {controller->session?.setAvailableCommands(controller,sessionCommands(controller),commands(false,controller))}
                    return@observeAccountState
                }
                val seen=acceptedArrangement
                val scope=account
                if(seen!=null && scope!=null && !graph.session.current(scope) && state !is AuthState.LocalLocked && !graph.session.resumesLocal(scope))retireArrangement()
                val next=graph.session.capture()
                if(next!=null&&account?.let(graph.session::resumesLocal)==true) {
                    player.pause();player.stop()
                    if(player is com.soundq.android.playback.nativeengine.NativeCallbackPlayer && acceptedArrangement!=null) {
                        val originals=arrangementItems.orEmpty()
                        retireArrangement()
                        originals.forEach {item->item.localConfiguration?.uri?.let {uri->grants[uri.toString()]=grantFor(item,next,renewal=true)}}
                        player.setMediaItems(originals)
                    }
                    // Same local session, new capabilities. Preserve occurrence/position and stay paused.
                    (0 until player.mediaItemCount).forEach {i->val item=player.getMediaItemAt(i);item.localConfiguration?.uri?.let {uri->
                        if(uri.scheme=="soundqmix")mixGrants[uri.toString()]?.let {prior->prior.close();mixGrants[uri.toString()]=com.soundq.android.playback.mix.MixGrant(next,prior.plan)}
                        else grants[uri.toString()]=grantFor(item,next,renewal=true)
                    }}
                    account=next
                    acceptedArrangement=acceptedArrangement?.let {it.copy(identity=it.identity.copy(accountEpoch=next.epoch))}
                }
                if(account!=null && (next==null || !graph.session.current(account!!))) {
                    continuation.accountRetired()
                    selectionEpoch++;mixGrants.values.forEach {it.close()};mixGrants.clear();saveJob?.cancel();account=null;restoring=true
                    transport.retire();interruptions.command();player.pause();player.stop();player.clearMediaItems();grants.clear();undo=null;undoScope=null
                    // Only the Library producer can distinguish its new read from retired account state.
                    graph.retireCatalogAfterPlaybackAccount()
                    graph.jamAdmission.replaceOwner();publishSessionExtras();refreshLikeButton()
                    restoring=false;restoredIdentity=null;rejectedQueue=false
                }
                account=next
                graph.jamAdmission.bindAccount(next)
                publishSessionExtras();refreshLikeButton()
                if(next!=null && graph.session.state.value is AuthState.DeviceOnly) {
                    withContext(Dispatchers.IO) {graph.downloads.load(next)}
                }
                if(next!=null && restoredIdentity!=next.accountId) {restoredIdentity=next.accountId;restoreQueue(next)}
                session?.connectedControllers?.forEach {controller ->
                    session?.setAvailableCommands(controller,sessionCommands(controller),commands(next!=null||localAccess(),controller))
                }
        }
    }
    private fun own(controller:MediaSession.ControllerInfo)=controller.uid==applicationInfo.uid
    private fun admitted(controller:MediaSession.ControllerInfo):Boolean {
        // Legacy MediaSession only marks package verification from API 33 onward.
        val verified=controller.isPackageNameVerified || (android.os.Build.VERSION.SDK_INT<33 &&
            packageManager.getPackagesForUid(controller.uid)?.contains(controller.packageName)==true)
        return systemControllerAllowed(own(controller),controller.isTrusted,verified)
    }
    override fun onGetSession(controllerInfo:MediaSession.ControllerInfo):MediaLibrarySession? = session.takeIf {admitted(controllerInfo)}
    override fun onDestroy() {
        continuation.close()
        graph.contextStarts.retire()
        graph.jamAdmission.detachOwner()
        selectionEpoch++;transport.retire();jobs.cancel();mixGrants.values.forEach {it.close()};mixGrants.clear();grants.clear();undo=null
        recorder.close();interruptions.close();session?.release();session=null;player.release()
        playbackWakeLock?.let { if (it.isHeld) it.release() };playbackWakeLock=null
        artwork.close();super.onDestroy()
    }
    private fun queueFile(scope:AccountScope):java.io.File {
        val hash=java.security.MessageDigest.getInstance("SHA-256").digest((graph.endpoint.identity+"\u0000"+scope.accountId).toByteArray()).joinToString("") {"%02x".format(it)}
        return java.io.File(graph.directory,"queue-$hash.json")
    }
    private fun queueObservation(scope:AccountScope):QueueSnapshot {
        return QueueSnapshot(graph.endpoint.identity,scope.accountId,(0 until player.mediaItemCount).map {i ->
        val m=player.getMediaItemAt(i);val e=m.mediaMetadata.extras!!
        SavedOccurrence(m.mediaId,e.getLong("trackId"),m.mediaMetadata.title?.toString().orEmpty(),m.mediaMetadata.artist?.toString().orEmpty(),e.getBoolean("manual"),e.getBoolean("localOnly"),e.getLong("durationMs"),QueueOrigin.read(e.getString("origin"),e.getBoolean("manual")),com.soundq.android.data.jam.JamOccurrence.decode(e.getString("soundqJam")),PlaybackRef.read(e.getString("playbackRef")))
    },player.currentMediaItemIndex.coerceAtLeast(0),player.currentPosition.coerceAtLeast(0),player.shuffleModeEnabled,when(player.repeatMode) {
        Player.REPEAT_MODE_ONE -> SavedRepeatMode.One
        Player.REPEAT_MODE_ALL -> SavedRepeatMode.All
        else -> SavedRepeatMode.Off
        })
    }
    /** Both ordinary delayed saves and acknowledged Jam observations use one writer. */
    private fun writeQueueObservation(scope:AccountScope,observed:QueueSnapshot) {
        graph.session.checkScope(scope)
        QueueSnapshotStore(queueFile(scope)).write(observed){graph.session.current(scope)}
    }
    private fun saveJamQueue() {
        val scope=account ?: throw SafeFailure(SafeFailure.Reason.Retired)
        graph.session.checkScope(scope);require(!restoring&&!rejectedQueue)
        require((0 until player.mediaItemCount).all {player.getMediaItemAt(it).localConfiguration?.uri?.scheme=="soundq"})
        saveJob?.cancel();val stamp=++queueSaveEpoch;val observed=queueObservation(scope)
        synchronized(queueFileLock){require(stamp==queueSaveEpoch);writeQueueObservation(scope,observed)}
    }
    private fun scheduleSave() {
        if(account==null){scheduleGuestSave();return}
        if(restoring||rejectedQueue || (0 until player.mediaItemCount).any {player.getMediaItemAt(it).localConfiguration?.uri?.scheme in setOf("soundqmix","soundqarrangement")})return
        val scope=account ?: return
        if(!graph.session.current(scope))return
        saveJob?.cancel()
        val stamp=++queueSaveEpoch
        saveJob=jobs.launch {
            delay(300)
            if(restoring||rejectedQueue||!graph.session.current(scope) || (0 until player.mediaItemCount).any {player.getMediaItemAt(it).localConfiguration?.uri?.scheme in setOf("soundqmix","soundqarrangement")})return@launch
            val observed=queueObservation(scope)
            withContext(Dispatchers.IO) {
                synchronized(queueFileLock) {
                    if(stamp!=queueSaveEpoch||!graph.session.current(scope))return@synchronized
                    runCatching {writeQueueObservation(scope,observed)}
                }
            }
        }
    }
    private fun restoreQueue(scope:AccountScope) {
        val revision=transport.revision
        val selection=selectionEpoch
        jobs.launch {
            val saved=try {readSavedQueue(scope)}catch(_:Exception){null} ?: return@launch
            if(!graph.session.current(scope)||player.mediaItemCount>0||transport.revision!=revision||selectionEpoch!=selection)return@launch
            restoring=true
            val prior=grants.keys.toSet()
            try {
                val items=savedItems(scope,saved)
                player.pause();player.restoringShuffle(saved.shuffleEnabled) {player.setMediaItems(items,saved.selected,saved.position)} // never prepare/play on restore
                restoreModes(saved)
                transport.selectionCommitted()
            }catch(_:Exception) {
                rejectedQueue=true
                grants.keys.filter {it !in prior}.forEach(grants::remove)
                transport.rejectSelection()
            }finally {restoring=false}
        }
    }
    private fun <T> Player.restoringShuffle(enabled:Boolean,action:()->T):T {
        val callback = this as? com.soundq.android.playback.nativeengine.NativeCallbackPlayer
        if (callback != null) return callback.restoringShuffle(enabled, action)
        val ordinary=this as? ServiceQueuePlayer
        if(ordinary!=null)return ordinary.restoringShuffle(enabled,action)
        require(!enabled)
        return action()
    }
    private fun restoreModes(saved:QueueSnapshot) {
        player.shuffleModeEnabled=saved.shuffleEnabled
        player.repeatMode=when(saved.loopMode) {
            SavedRepeatMode.Off -> Player.REPEAT_MODE_OFF
            SavedRepeatMode.One -> Player.REPEAT_MODE_ONE
            SavedRepeatMode.All -> Player.REPEAT_MODE_ALL
        }
    }
    private suspend fun readSavedQueue(scope:AccountScope):QueueSnapshot? {
        val file=queueFile(scope)
        val saved=withContext(Dispatchers.IO) {try {QueueSnapshotStore(file).read(graph.endpoint.identity,scope.accountId){graph.session.current(scope)}}catch(_:Exception){null}}
        graph.session.checkScope(scope)
        if(saved==null && file.exists())rejectedQueue=true
        if(saved!=null && !savedCompatible(saved)){rejectedQueue=true;return null}
        return saved
    }
    private fun savedCompatible(saved:QueueSnapshot):Boolean {
        val bounded=player as? com.soundq.android.playback.listening.ListeningServicePlayer ?: return true
        return runCatching {
            require(!saved.shuffleEnabled)
            bounded.validateMetadata(saved.items.map {TimelineSource(it.occurrence,it.track,it.title,it.durationMs,when(it.origin){QueueOrigin.Continuation->QueueSegment.Continuation;QueueOrigin.Manual->QueueSegment.Manual;else->QueueSegment.Context})},saved.selected,saved.position)
        }.isSuccess
    }
    private fun savedItems(scope:AccountScope,saved:QueueSnapshot):List<MediaItem> {
        graph.session.checkScope(scope)
        require(savedCompatible(saved))
        return saved.items.map {i ->
            val uri=Uri.parse(if(i.ref is PlaybackRef.Device)"soundqdevice://source/${i.occurrence}" else "soundq://track/${i.track}/${i.occurrence}")
            grants[uri.toString()]=if(i.ref is PlaybackRef.Device)MediaGrant(i.ref,graph.session.version(),graph.phoneAudio.authorityVersion) else MediaGrant(scope,TrackId(i.track),i.localOnly)
            val extras=Bundle().apply {putLong("trackId",i.track);putString("occurrenceId",i.occurrence);putBoolean("manual",i.manual);putBoolean("localOnly",i.localOnly);putLong("durationMs",i.durationMs);putString("origin",i.origin.name)}
            extras.putString("playbackRef",saved.reference(i).wire())
            i.jam?.let {extras.putString("soundqJam",it.encode())}
            MediaItem.Builder().setMediaId(i.occurrence).setUri(uri).setMediaMetadata(MediaMetadata.Builder().setTitle(i.title).setArtist(i.artist).setIsPlayable(true).setIsBrowsable(false).setExtras(extras).build()).build()
        }
    }
    private fun commands(auth:Boolean,controller:MediaSession.ControllerInfo):Player.Commands {
        val builder=Player.Commands.Builder().add(Player.COMMAND_GET_TIMELINE).add(Player.COMMAND_GET_CURRENT_MEDIA_ITEM).add(Player.COMMAND_GET_METADATA)
        if(auth && admitted(controller)) {
            if(own(controller))builder.addAllCommands()
            else builder.addAll(Player.COMMAND_PLAY_PAUSE,Player.COMMAND_PREPARE,Player.COMMAND_STOP,Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
                Player.COMMAND_SEEK_TO_PREVIOUS,Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,Player.COMMAND_SEEK_TO_NEXT,Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
                Player.COMMAND_SEEK_TO_MEDIA_ITEM,Player.COMMAND_SET_MEDIA_ITEM,Player.COMMAND_CHANGE_MEDIA_ITEMS,Player.COMMAND_SET_REPEAT_MODE,Player.COMMAND_SET_SHUFFLE_MODE)
        }
        val offered=builder.build()
        return Player.Commands.Builder().apply {
            for(i in 0 until offered.size())if(player.availableCommands.contains(offered[i]))add(offered[i])
        }.build()
    }
    private fun supportsSourceActions() = player !is com.soundq.android.playback.listening.ListeningServicePlayer
    private fun supportsArrangementActions() = supportsSourceActions()
    private fun supportsMixActions() = supportsSourceActions() && player !is com.soundq.android.playback.nativeengine.NativeCallbackPlayer
    private fun sessionCommands(controller:MediaSession.ControllerInfo):SessionCommands {
        val builder=SessionCommands.Builder().add(SessionCommand.COMMAND_CODE_LIBRARY_GET_LIBRARY_ROOT)
            .add(SessionCommand.COMMAND_CODE_LIBRARY_GET_CHILDREN).add(SessionCommand.COMMAND_CODE_LIBRARY_GET_ITEM)
            .add(SessionCommand.COMMAND_CODE_LIBRARY_SEARCH).add(SessionCommand.COMMAND_CODE_LIBRARY_GET_SEARCH_RESULT)
            .add(SessionCommand.COMMAND_CODE_LIBRARY_SUBSCRIBE).add(SessionCommand.COMMAND_CODE_LIBRARY_UNSUBSCRIBE)
        if(admitted(controller))likeToken?.let {builder.add(SessionCommand(it,Bundle.EMPTY))}
        if(own(controller)) {
            if(player is com.soundq.android.playback.nativeengine.NativeCallbackPlayer && account?.let(graph.session::current)==true)builder.add(SessionCommand(CLOCK_SEEK,Bundle.EMPTY))
            builder.add(SessionCommand(UNDO,Bundle.EMPTY))
            if(player is com.soundq.android.playback.nativeengine.NativeCallbackPlayer)builder.add(SessionCommand(START_CONTEXT,Bundle.EMPTY))
            if (supportsSourceActions()) builder.add(SessionCommand(JAM_ADMIT, Bundle.EMPTY))
            if (player is com.soundq.android.playback.nativeengine.NativeCallbackPlayer && account?.let(graph.session::current)==true)PerformanceCommands.all.forEach {builder.add(SessionCommand(it,Bundle.EMPTY))}
            if (supportsMixActions()) builder.add(SessionCommand(PLAY_MIX, Bundle.EMPTY))
            if (supportsArrangementActions()) builder.add(SessionCommand(APPLY_ARRANGEMENT, Bundle.EMPTY)).add(SessionCommand(RETURN_SOURCES, Bundle.EMPTY))
        }
        return builder.build()
    }
    /** No clock authority for a backend whose overlap/global schedule is not projected here. */
    private fun clockProjection():PlaybackProjection? {
        if(player !is com.soundq.android.playback.nativeengine.NativeCallbackPlayer)return null
        val scope=account?.takeIf(graph.session::current) ?: return null
        val selected=player.currentMediaItem?.mediaId ?: return null
        if(acceptedArrangement!=null||player.currentMediaItem?.localConfiguration?.uri?.scheme!="soundq")return null
        // A planned fade already invalidates a concatenated inverse, even before
        // either deck overlaps. Song timing remains authoritative; Queue timing
        // requires the real accepted overlap schedule, which is not exposed here.
        val fade=graph.crossfadePreferences.state.value
        val spans=if(fade.ready&&!fade.error&&fade.seconds==0)player.acceptedClockSpans() else null
        val full=PlaybackClockAuthority(ClockOwner(serviceIncarnation,scope.epoch,sourceQueueIncarnation,clockRevision,selected),spans)
        // Publish and validate the same bounded authority, including Song seeks
        // when a future complete-context payload cannot fit in session extras.
        val authority=if(Json.encodeToString(full).length<=96*1024)full else full.copy(spans=null)
        return PlaybackProjection(connection=PlaybackProjection.Connection.Connected,selectedOccurrence=selected,
            positionMs=player.currentPosition,durationMs=player.duration,accountEpoch=scope.epoch,
            source=PlaybackSource.Queue,
            arrangementService=serviceIncarnation,sourceQueueIncarnation=sourceQueueIncarnation,clockAuthority=authority)
    }
    private fun seekClock(args:Bundle):ListenableFuture<SessionResult> {
        fun refused()=Futures.immediateFuture(SessionResult(SessionError.ERROR_INVALID_STATE))
        val raw=args.getString("clockSeek")?.takeIf {it.length<=96*1024} ?: return refused()
        val request=runCatching {Json.decodeFromString<ClockSeek>(raw)}.getOrNull() ?: return refused()
        val p=clockProjection() ?: return refused()
        if(p.clockAuthority!=request.authority)return refused()
        val target=projectPlayerClock(p,request.mode).destination(request.positionMs) ?: return refused()
        if(target!=request.destination)return refused()
        val native=player as? com.soundq.android.playback.nativeengine.NativeCallbackPlayer ?: return refused()
        val index=(0 until player.mediaItemCount).singleOrNull {player.getMediaItemAt(it).mediaId==target.occurrence} ?: return refused()
        val scope=account ?: return refused()
        val accepted=acceptedArrangement
        val queue=sourceQueueIncarnation
        val epoch=++selectionEpoch
        graph.contextStarts.retire()
        pendingArrangement=null;graph.timeline.cancelAudition();continuation.command();interruptions.command();transport.retire()
        fun current()=selectionEpoch==epoch&&account===scope&&graph.session.current(scope)&&sourceQueueIncarnation==queue&&acceptedArrangement===accepted
        return future {
            // The coroutine starts on the service looper. Recheck after scheduling, before dispatch.
            val ok=current()&&clockProjection()?.clockAuthority==request.authority&&native.seekClock(index,target.positionMs,::current)
            publishSessionExtras()
            SessionResult(if(ok&&current())SessionResult.RESULT_SUCCESS else SessionError.ERROR_INVALID_STATE)
        }
    }
    private fun publishSessionExtras(){session?.setSessionExtras(Bundle().apply {
        clockProjection()?.clockAuthority?.let {authority->
            val raw=Json.encodeToString(authority)
            putString("playbackClock",if(raw.length<=96*1024)raw else Json.encodeToString(authority.copy(spans=null)))
        }
        putBoolean("canUndo",undo!=null);putString("incarnation",graph.jamAdmission.incarnation);putLong("accountEpoch",account?.takeIf {graph.session.current(it)}?.epoch ?: -1)
        putString("arrangementService",serviceIncarnation);putString("sourceQueueIncarnation",sourceQueueIncarnation)
        (player as? com.soundq.android.playback.nativeengine.NativeCallbackPlayer)?.tempoPreviewState?.let {
            putString(PerformanceCommands.TEMPO_STATE, Json.encodeToString(it))
        }
        acceptedArrangement?.takeIf {arrangementCurrent(it)}?.let {
            putString("acceptedArrangement",Json.encodeToString(it))
            val native=player as? com.soundq.android.playback.nativeengine.NativeCallbackPlayer
            val validPerformance=native?.performanceDecks.orEmpty().filterValues {deck->
                val checks=liveQualifications[deck.target.occurrence]
                checks==null || checks.first()&&checks.second()
            }
            putString(PerformanceCommands.DECKS,Json.encodeToString(validPerformance))
            putBoolean("canPerformArrangement",native?.canPerform(it.identity)==true)
        }
    })}
    private var guestRestoredVersion=-1L
    private var guestRejectedQueue=false
    // Guest saves wait for the saved-queue read to finish, then replay once from the settled player.
    private var guestRestoresPending=0
    private var guestSaveDeferred=false
    private fun guestFile()=java.io.File(graph.directory,"phone-queue-guest.json")
    private fun scheduleGuestSave() {
        if(restoring||guestRejectedQueue||!localAccess())return
        if(guestRestoresPending>0){guestSaveDeferred=true;saveJob?.cancel();queueSaveEpoch++;return}
        val version=graph.session.version()
        val rows=(0 until player.mediaItemCount).map {i->player.getMediaItemAt(i)}
        if(rows.any {PlaybackRef.read(it.mediaMetadata.extras?.getString("playbackRef")) !is PlaybackRef.Device})return
        val saved=QueueSnapshot(graph.endpoint.identity,"guest",rows.map {m->val e=m.mediaMetadata.extras!!;SavedOccurrence(m.mediaId,0,m.mediaMetadata.title.toString(),m.mediaMetadata.artist.toString(),e.getBoolean("manual"),true,e.getLong("durationMs"),QueueOrigin.read(e.getString("origin"),e.getBoolean("manual")),ref=PlaybackRef.read(e.getString("playbackRef")))},player.currentMediaItemIndex.coerceAtLeast(0),player.currentPosition.coerceAtLeast(0),player.shuffleModeEnabled,when(player.repeatMode){Player.REPEAT_MODE_ONE->SavedRepeatMode.One;Player.REPEAT_MODE_ALL->SavedRepeatMode.All;else->SavedRepeatMode.Off})
        saveJob?.cancel();val stamp=++queueSaveEpoch
        saveJob=jobs.launch {delay(300);withContext(Dispatchers.IO){synchronized(queueFileLock){if(stamp==queueSaveEpoch&&graph.session.owns(version)&&localAccess())runCatching {QueueSnapshotStore(guestFile()).write(saved){graph.session.owns(version)&&localAccess()}}}}}
    }
    private fun restoreGuestQueue() {
        val version=graph.session.version();if(guestRestoredVersion==version)return;guestRestoredVersion=version
        val command=transport.revision;val selection=selectionEpoch
        // A save captured before or during this read must not replace the queue it reads.
        if(saveJob?.isActive==true)guestSaveDeferred=true
        saveJob?.cancel();queueSaveEpoch++;guestRestoresPending++
        jobs.launch {
            try {
                val saved=withContext(Dispatchers.IO){runCatching {QueueSnapshotStore(guestFile()).read(graph.endpoint.identity,"guest"){graph.session.owns(version)}}.getOrNull()} ?: return@launch
                if(!localAccess()||!graph.session.owns(version)||account!=null||player.mediaItemCount>0||transport.revision!=command||selectionEpoch!=selection)return@launch
                restoring=true
                try {
                    val rows=saved.items.map {i->val ref=i.ref as? PlaybackRef.Device ?: error("Guest server source refused");val uri=Uri.parse("soundqdevice://source/${i.occurrence}");grants[uri.toString()]=MediaGrant(ref,version,graph.phoneAudio.authorityVersion)
                        val e=Bundle().apply {putString("playbackRef",ref.wire());putBoolean("localOnly",true);putBoolean("manual",i.manual);putString("origin",i.origin.name);putLong("durationMs",i.durationMs)}
                        MediaItem.Builder().setMediaId(i.occurrence).setUri(uri).setMediaMetadata(MediaMetadata.Builder().setTitle(i.title).setArtist(i.artist).setExtras(e).setIsPlayable(true).setIsBrowsable(false).build()).build()}
                    player.pause();player.restoringShuffle(saved.shuffleEnabled){player.setMediaItems(rows,saved.selected,saved.position)};restoreModes(saved);transport.selectionCommitted()
                    // Release only the guest hold after this exact snapshot is admitted successfully.
                    guestRejectedQueue=false
                }catch(_:Exception){guestRejectedQueue=true;transport.rejectSelection()}finally{restoring=false}
            } finally {
                // Completion, skip or failure all settle the read; replay a suppressed save from current state.
                if(--guestRestoresPending==0&&guestSaveDeferred){guestSaveDeferred=false;scheduleSave()}
            }
        }
    }
    private fun renewPhoneGrants() {
        if(!localAccess())return
        (0 until player.mediaItemCount).forEach {i->val item=player.getMediaItemAt(i);val uri=item.localConfiguration?.uri
            val prior=uri?.let {grants[it.toString()]}
            if(prior?.device!=null&&!prior.current(graph)&&graph.phoneAudio.observed(prior.device)!=null)
                grants[uri.toString()]=MediaGrant(prior.device,graph.session.version(),graph.phoneAudio.authorityVersion)
        }
    }
    private fun localAccess()=graph.phoneAudio.current(graph.session.version())
    private fun resolveDevice(item:MediaItem):MediaItem {
        require(item.localConfiguration==null&&item.requestMetadata.mediaUri==null)
        val ref=PlaybackRef.read(item.requestMetadata.extras?.getString("playbackRef")) as? PlaybackRef.Device ?: error("Device identity required")
        require(item.mediaId=="device:${ref.id}")
        val row=graph.phoneAudio.observed(ref) ?: throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
        check(localAccess())
        val occurrence=UUID.randomUUID().toString()
        val uri=Uri.parse("soundqdevice://source/$occurrence")
        val extras=Bundle().apply {putString("playbackRef",ref.wire());putString("occurrenceId",occurrence);putBoolean("manual",item.requestMetadata.extras?.getBoolean("manual")==true);putBoolean("localOnly",true);putLong("durationMs",row.durationMs ?: 0);putString("origin",if(item.requestMetadata.extras?.getBoolean("manual")==true)"Manual" else "Context")}
        return MediaItem.Builder().setMediaId(occurrence).setUri(uri).setMediaMetadata(MediaMetadata.Builder().setTitle(row.metadata.displayTitle).setArtist(row.metadata.artist.orEmpty()).setAlbumTitle(row.metadata.album.orEmpty()).setIsPlayable(true).setIsBrowsable(false).setExtras(extras).build()).build()
    }
    /** Same-session renewal can run before phone audio accepts the resumed version. Its device grant is
     * minted for that version and stays non-current until acceptance; PREPARE renews it if authority moved. */
    private fun grantFor(item:MediaItem,scope:AccountScope?,renewal:Boolean=false):MediaGrant {
        val ref=PlaybackRef.read(item.mediaMetadata.extras?.getString("playbackRef"))
        return if(ref is PlaybackRef.Device) {check(renewal||localAccess());MediaGrant(ref,graph.session.version(),graph.phoneAudio.authorityVersion)}
        else MediaGrant(requireNotNull(scope),TrackId(item.mediaMetadata.extras!!.getLong("trackId")),item.mediaMetadata.extras!!.getBoolean("localOnly"))
    }
    private fun resolve(items:List<MediaItem>,startIndex:Int=0,startPositionMs:Long=0,compose:((List<MediaItem>)->List<MediaItem>)?=null):List<MediaItem> {
        val scope=graph.session.capture()
        require(scope!=null||localAccess())
        require(items.size<=QueuePolicy.MAX_CONTEXT_TRACKS) // Eager controller requests stay bounded.

        val accepted=items.map {item ->
            require(item.localConfiguration==null) // reject ALL caller URLs, even same-origin
            if(item.mediaId.startsWith("device:"))return@map resolveDevice(item)
            requireNotNull(scope)
            val id=TrackId(item.mediaId.toLongOrNull() ?: throw IllegalArgumentException("Track ID required"))
            val track=graph.track(id) ?: throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
            val localOnly=item.requestMetadata.extras?.getBoolean("localOnly")==true || !graph.session.remoteCurrent(scope)
            val occurrence=UUID.randomUUID().toString()
            val uri=Uri.parse("soundq://track/${id.value}/$occurrence")
            val extra=Bundle().apply {putLong("trackId",id.value);putString("playbackRef",PlaybackRef.Server(graph.endpoint.identity,scope.accountId,id.value).wire());putString("occurrenceId",occurrence);putBoolean("manual",item.requestMetadata.extras?.getBoolean("manual")==true);putBoolean("localOnly",localOnly);putLong("durationMs",track.durationMs);putString("origin",if(item.requestMetadata.extras?.getBoolean("manual")==true)"Manual" else "Context")}

            MediaItem.Builder().setMediaId(occurrence).setUri(uri).setMimeType("audio/*")
                .setMediaMetadata(MediaMetadata.Builder().setTitle(track.title).setArtist(track.artist).setAlbumTitle(track.album)
                    .setArtworkUri(track.artwork?.takeIf {!localOnly && graph.session.remoteCurrent(scope)}?.let(Uri::parse)).setIsPlayable(true).setIsBrowsable(false).setExtras(extra).build()).build()
        }
        if(scope!=null)graph.session.checkScope(scope) else check(localAccess())
        val final=compose?.invoke(accepted) ?: accepted
        validateSelection(final,startIndex,startPositionMs)
        accepted.forEach {item ->grants[item.localConfiguration!!.uri.toString()]=grantFor(item,scope)}
        return final
    }
    private fun validateSelection(items:List<MediaItem>,index:Int,position:Long) {
        require(QueuePolicy.acceptsAppend(0,items.size))
        var bytes=0L
        items.forEach {item->
            val row=QueuePolicy.metadataBytes(item.mediaId,item.mediaMetadata.title?.toString().orEmpty(),item.mediaMetadata.artist?.toString().orEmpty())
            require(row<=500_000);bytes+=row;require(bytes<=QueuePolicy.MAX_METADATA_BYTES)
        }
        val bounded=player as? com.soundq.android.playback.listening.ListeningServicePlayer ?: return
        bounded.validateMetadata(items.map {item->
            val e=item.mediaMetadata.extras ?: throw IllegalArgumentException("Source metadata required")
            require(item.localConfiguration?.uri?.scheme=="soundq")
            TimelineSource(item.mediaId,e.getLong("trackId"),item.mediaMetadata.title?.toString().orEmpty(),e.getLong("durationMs"),when(e.getString("origin")){"Continuation"->QueueSegment.Continuation;"Manual"->QueueSegment.Manual;else->if(e.getBoolean("manual"))QueueSegment.Manual else QueueSegment.Context})
        },index,position)
    }
    private fun validateInsertion(items:List<MediaItem>) {
        if(player !is com.soundq.android.playback.listening.ListeningServicePlayer || items.isEmpty())return
        val old=(0 until player.mediaItemCount).map(player::getMediaItemAt)
        // Media3's onAdd callback omits its eventual insertion index. Admit only metadata
        // valid at every legal position; the raw owner checks the actual index again.
        for(index in 0..old.size)validateSelection(old.toMutableList().apply {addAll(index,items)},0,0)
    }
    private fun performanceCommand(controller:MediaSession.ControllerInfo,action:String,args:Bundle):ListenableFuture<SessionResult> {
        fun refused(code:Int=SessionError.ERROR_INVALID_STATE)=Futures.immediateFuture(SessionResult(code))
        if(!own(controller)||!admitted(controller))return refused(SessionError.ERROR_PERMISSION_DENIED)
        val native=player as? com.soundq.android.playback.nativeengine.NativeCallbackPlayer ?: return refused(SessionError.ERROR_NOT_SUPPORTED)
        val accepted=acceptedArrangement ?: return refused()
        val target=PerformanceCommands.read<PerformanceTarget>(args,"target") ?: return refused(SessionError.ERROR_BAD_VALUE)
        val scope=account ?: return refused(SessionError.ERROR_PERMISSION_DENIED)
        val selection=selectionEpoch
        fun current()=selectionEpoch==selection && acceptedArrangement===accepted && accepted.identity.service==serviceIncarnation &&
            accepted.identity.queue==sourceQueueIncarnation && accepted.identity.accountEpoch==scope.epoch && target.identity==accepted.identity && graph.session.current(scope)
        if(!current() || (action != PerformanceCommands.TEMPO_CANCEL && !native.canPerform(target.identity)))return refused()
        val clip=accepted.document.clips.singleOrNull {it.occurrence==target.occurrence} ?: return refused(SessionError.ERROR_BAD_VALUE)
        if (action in PerformanceCommands.tempo) {
            fun result(ok: Boolean, extra: Bundle = Bundle.EMPTY) = SessionResult(if (ok) SessionResult.RESULT_SUCCESS else SessionError.ERROR_INVALID_STATE, extra)
            if (action == PerformanceCommands.TEMPO_BEGIN) {
                val source = PerformanceCommands.read<TempoSourceIdentity>(args, "source") ?: return refused(SessionError.ERROR_BAD_VALUE)
                if (graph.timeline.state.value.document != accepted.document) return refused()
                val qualification = graph.timeline.qualifyTempo(scope, source) ?: return refused()
                val admission = java.util.concurrent.atomic.AtomicBoolean(true)
                pendingTempoBegins.put(controller, admission)?.set(false)
                return future {
                    try {
                        val lease = native.beginTempo(target, source, qualification) { admission.get() && current() }
                        if (lease != null) tempoCaller = controller to lease
                        result(lease != null, Bundle().apply {
                            lease?.let { putString("lease", Json.encodeToString(it)) }
                            if (lease == null) putString("message", "Live preview is unavailable or native history has no restoration capacity. Shared Auto/phase transitions must be disabled and applied separately before live BPM editing.")
                        })
                    } finally { pendingTempoBegins.remove(controller, admission) }
                }
            }
            val lease = PerformanceCommands.read<TempoPreviewLease>(args, "lease")?.takeIf { it.target == target } ?: return refused(SessionError.ERROR_BAD_VALUE)
            if (tempoCaller?.let { it.first == controller && it.second == lease } != true) return refused(SessionError.ERROR_PERMISSION_DENIED)
            if (action == PerformanceCommands.TEMPO_PREVIEW) return Futures.immediateFuture(result(native.previewTempo(lease,
                args.getLong("revision", -1), args.getDouble("bpm", Double.NaN), args.getLong("glideMs", 0))))
            val response = SettableFuture.create<SessionResult>()
            if (action == PerformanceCommands.TEMPO_CANCEL) {
                native.cancelTempo(lease) { restored -> if (tempoCaller?.second == lease) tempoCaller = null; response.set(result(restored, Bundle().apply {
                    putString("message", native.tempoPreviewState?.message)
                })); publishSessionExtras() }
                return response
            }
            native.saveTempo(lease, args.getLong("revision", -1), commit = { bpm, owns ->
                val original = graph.timeline.state.value.document
                val candidate = runCatching { original.withPlaybackTempo(TempoPlaybackIntent(lease.source, bpm)) }.getOrNull()
                // Serialize final receipt, durable write and identity adoption on service Main.
                // Native callback/control owner remain independent; no transport can interleave this commit.
                val saved = candidate != null && original == accepted.document &&
                    graph.timeline.commitContinuingTempo(TimelineTempoEdit(original, candidate)) { current() && owns() }
                if (saved && current()) graph.timeline.state.value.document else null
            }) { document ->
                if (document != null && current()) {
                    if (tempoCaller?.second == lease) tempoCaller = null
                    // A durable edit does not replace the native installed schedule or its source anchor.
                    acceptedArrangement = accepted.copy(identity = accepted.identity.copy(revision = document.revision), document = document)
                }
                response.set(result(document != null, Bundle().apply { putString("message", native.tempoPreviewState?.message) }))
                publishSessionExtras()
            }
            return response
        }
        val event=args.getLong("eventNanos",-1)
        if(action==PerformanceCommands.BEGIN) {
            val result=SettableFuture.create<SessionResult>()
            native.beginScratch(target,event,{!result.isCancelled&&current()}) {lease ->
                result.set(if(lease==null)SessionResult(SessionError.ERROR_INVALID_STATE) else SessionResult(SessionResult.RESULT_SUCCESS,Bundle().apply {putString("lease",Json.encodeToString(lease))}))
            }
            return result
        }
        if(action in listOf(PerformanceCommands.MOVE,PerformanceCommands.END,PerformanceCommands.CANCEL)) {
            val lease=PerformanceCommands.read<ScratchLease>(args,"lease")?.takeIf {it.target==target} ?: return refused(SessionError.ERROR_BAD_VALUE)
            val ok=if(action==PerformanceCommands.MOVE)native.moveScratch(lease,args.getDouble("rate",Double.NaN),event)
                else native.finishScratch(lease,event,action==PerformanceCommands.CANCEL)
            return Futures.immediateFuture(SessionResult(if(ok)SessionResult.RESULT_SUCCESS else SessionError.ERROR_INVALID_STATE))
        }
        if(action==PerformanceCommands.UNLINK)return future {
            val ok=native.unlinkIncoming(target.identity,target.occurrence,::current)
            if(ok)validateLiveQualifications()
            SessionResult(if(ok)SessionResult.RESULT_SUCCESS else SessionError.ERROR_INVALID_STATE)
        }
        if(action!=PerformanceCommands.SYNC)return refused(SessionError.ERROR_NOT_SUPPORTED)
        val reference=args.getString("reference") ?: return refused(SessionError.ERROR_BAD_VALUE)
        val referenceClip=accepted.document.clips.singleOrNull {it.occurrence==reference} ?: return refused(SessionError.ERROR_BAD_VALUE)
        val a=PerformanceCommands.read<QualifiedLiveGrid>(args,"referenceGrid") ?: return refused(SessionError.ERROR_BAD_VALUE)
        val b=PerformanceCommands.read<QualifiedLiveGrid>(args,"incomingGrid") ?: return refused(SessionError.ERROR_BAD_VALUE)
        val beats=args.getInt("beats")
        if(!a.valid(referenceClip.sourceDurationMs,beats)||!b.valid(clip.sourceDurationMs,beats))return refused(SessionError.ERROR_BAD_VALUE)
        fun qualify(c:TimelineClip,g:QualifiedLiveGrid)=graph.timeline.qualifyLiveGrid(scope,c.track,c.sourceDurationMs,g.sourceKey,g.revision,g.bpm,g.anchorMs,g.groupOriginMs,g.provenance)
        val qa=qualify(referenceClip,a) ?: return refused()
        val qb=qualify(clip,b) ?: return refused()
        return future {
            val ok=native.syncIncoming(target.identity,reference,target.occurrence,beats,a,b,qualified={qa()&&qb()}){current()}
            if(ok) {liveQualifications[target.occurrence]=qa to qb;validateLiveQualifications()}
            SessionResult(if(ok)SessionResult.RESULT_SUCCESS else SessionError.ERROR_INVALID_STATE)
        }
    }
    /** Bounded ticket transport for complete metadata. No old-player effect before admission. */
    private fun startContext(args:Bundle):ListenableFuture<SessionResult> {
        val native=player as? com.soundq.android.playback.nativeengine.NativeCallbackPlayer
            ?: return Futures.immediateFuture(SessionResult(SessionError.ERROR_NOT_SUPPORTED))
        val scope=graph.session.capture() ?: return Futures.immediateFuture(SessionResult(SessionError.ERROR_PERMISSION_DENIED))
        val capture=args.getString("ticket")?.let(graph.contextStarts::claim)
            ?: return Futures.immediateFuture(SessionResult(SessionError.ERROR_BAD_VALUE))
        val epoch=++selectionEpoch
        val revision=transport.revision
        fun current()=selectionEpoch==epoch && transport.revision==revision && graph.session.current(scope) &&
            graph.contextStarts.current(capture) && capture.endpoint==graph.endpoint.identity && capture.account==scope.accountId
        return future {
            val prior=grants.keys.toSet()
            var installed=false
            try {
                require(current())
                val saved=withContext(Dispatchers.IO){requireNotNull(graph.contextStarts.read(capture))}
                require(current() && QueuePolicy.acceptsContext(saved.items.size) && saved.selected in saved.items.indices)
                val old=(0 until player.mediaItemCount).map(player::getMediaItemAt)
                val manual=QueuePolicy.carriedManual(old.map {it.mediaMetadata.extras?.getBoolean("manual")==true},player.currentMediaItemIndex,graph.queueSettings.state.value.keepQueued).map(old::get)
                require(QueuePolicy.acceptsAppend(saved.items.size,manual.size))
                val items=savedItems(scope,saved).toMutableList().apply {addAll(saved.selected+1,manual)}
                native.validateQueueMetadata(items)
                require(current())
                undo=old.takeIf {rows->rows.none {it.localConfiguration?.uri?.scheme in setOf("soundqmix","soundqarrangement")}}
                undoScope=scope;undoIndex=player.currentMediaItemIndex;undoPosition=player.currentPosition
                // Same canonical owner and exact occurrence IDs. No separately queued Play can
                // escape a refused replacement. Native metadata admission above is side-effect free.
                pendingArrangement=null;graph.timeline.cancelAudition();continuation.command();interruptions.command()
                transport.retire();player.pause();retireArrangement()
                player.restoringShuffle(player.shuffleModeEnabled) {player.setMediaItems(items,saved.selected,0)}
                installed=true;rejectedQueue=false;transport.selectionCommitted();publishSessionExtras()
                player.prepare();player.play()
                SessionResult(SessionResult.RESULT_SUCCESS)
            }catch(_:Exception){
                if(!installed)grants.keys.filter {it !in prior}.forEach(grants::remove)
                SessionResult(SessionError.ERROR_BAD_VALUE)
            }finally {withContext(NonCancellable+Dispatchers.IO){graph.contextStarts.finish(capture)}}
        }
    }
    private val liveQualifications=mutableMapOf<String,Pair<()->Boolean,()->Boolean>>()
    private val retiringLiveQualifications=mutableMapOf<String,Pair<()->Boolean,()->Boolean>>()
    private fun validateLiveQualifications() {
        val native=player as? com.soundq.android.playback.nativeengine.NativeCallbackPlayer ?: return
        val accepted=acceptedArrangement ?: return
        liveQualifications.entries.toList().forEach {(occurrence,checks)->
            if(native.syncRetirementObserved(accepted.identity,occurrence)) {
                // The player already observed Off for its exact captured sync.
                // Retire service records in that publication, before exposing Off.
                liveQualifications.remove(occurrence,checks)
                retiringLiveQualifications.remove(occurrence,checks)
            } else if(!checks.first()||!checks.second()) {
                native.revokePerformanceTarget(accepted.identity,occurrence)
                if(retiringLiveQualifications.putIfAbsent(occurrence,checks)==null)jobs.launch {
                    val ok=native.unlinkForRetirement(accepted.identity,occurrence){acceptedArrangement===accepted && liveQualifications[occurrence]===checks && graph.session.current(account ?: return@unlinkForRetirement false)}
                    // Accepted retirement stays fenced through subsequent native Off;
                    // do not enqueue another unlink on every performance poll.
                    if(!ok)retiringLiveQualifications.remove(occurrence,checks)
                }
            }
        }
    }

    private inner class Callback:MediaLibrarySession.Callback {
        override fun onDisconnected(session:MediaSession,controller:MediaSession.ControllerInfo) {
            pendingTempoBegins.remove(controller)?.set(false)
            if(own(controller)) (player as? com.soundq.android.playback.nativeengine.NativeCallbackPlayer)?.let {
                if (tempoCaller?.first == controller) { tempoCaller = null; it.cancelOwnedTempo() }
                // Scratch retirement must not retire another controller's tempo lease or async restoration.
                if (it.tempoPreviewState?.phase !in listOf(TempoPreviewPhase.Ready, TempoPreviewPhase.Preparing,
                        TempoPreviewPhase.Applied, TempoPreviewPhase.Saving, TempoPreviewPhase.Restoring, TempoPreviewPhase.Refused)) it.revokePerformance()
            }
        }
        override fun onConnect(session:MediaSession,controller:MediaSession.ControllerInfo):MediaSession.ConnectionResult =
            if(!admitted(controller))MediaSession.ConnectionResult.reject() else
            MediaSession.ConnectionResult.AcceptedResultBuilder().setAvailablePlayerCommands(commands(graph.session.capture()!=null||localAccess(),controller)).setAvailableSessionCommands(sessionCommands(controller)).build()
        @Suppress("DEPRECATION")
        override fun onPlayerCommandRequest(session:MediaSession,controller:MediaSession.ControllerInfo,playerCommand:Int):Int {
            val scope=graph.session.capture()
            if(scope==null&&!localAccess())return SessionError.ERROR_PERMISSION_DENIED
            if(!admitted(controller))return SessionError.ERROR_PERMISSION_DENIED
            if(playerCommand==Player.COMMAND_PREPARE)renewPhoneGrants()
            if(account?.let { !graph.session.current(it) }==true) return SessionError.ERROR_PERMISSION_DENIED

            // Retire held PLAY_MIX at request admission, before Media3 queues the seek.
            if(playerCommand in setOf(
                Player.COMMAND_CHANGE_MEDIA_ITEMS,Player.COMMAND_PLAY_PAUSE,Player.COMMAND_STOP,
                Player.COMMAND_SEEK_TO_DEFAULT_POSITION,Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
                Player.COMMAND_SEEK_TO_MEDIA_ITEM,Player.COMMAND_SEEK_TO_NEXT,Player.COMMAND_SEEK_TO_PREVIOUS,
                Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
                Player.COMMAND_SEEK_BACK,Player.COMMAND_SEEK_FORWARD
            ))selectionEpoch++
            // Admission precedes Media3's controller FIFO. Play and Pause have the same
            // command code; only the actual player call may change pending read intent.
            if(playerCommand !in listOf(Player.COMMAND_GET_TIMELINE,Player.COMMAND_GET_CURRENT_MEDIA_ITEM,Player.COMMAND_GET_METADATA)) {
                graph.contextStarts.retire()
                if(playerCommand in setOf(Player.COMMAND_STOP,Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,Player.COMMAND_SEEK_TO_MEDIA_ITEM,
                    Player.COMMAND_SEEK_TO_DEFAULT_POSITION,Player.COMMAND_SEEK_TO_NEXT,Player.COMMAND_SEEK_TO_PREVIOUS,
                    Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,Player.COMMAND_CHANGE_MEDIA_ITEMS))
                    (player as? com.soundq.android.playback.nativeengine.NativeCallbackPlayer)?.retirePerformanceTransport()
                else (player as? com.soundq.android.playback.nativeengine.NativeCallbackPlayer)?.revokePerformance()
                pendingArrangement=null;graph.timeline.cancelAudition()
                continuation.command()
                interruptions.command()
                if(playerCommand !in listOf(Player.COMMAND_PLAY_PAUSE,Player.COMMAND_PREPARE))transport.retire()
            }
            if(acceptedArrangement!=null && playerCommand==Player.COMMAND_CHANGE_MEDIA_ITEMS)return SessionError.ERROR_INVALID_STATE
            if(playerCommand==Player.COMMAND_CHANGE_MEDIA_ITEMS) {
                undoScope=scope;undoVersion=graph.session.version()
                undo=(0 until player.mediaItemCount).map(player::getMediaItemAt).takeIf {items->items.none {it.localConfiguration?.uri?.scheme in setOf("soundqmix","soundqarrangement")}};undoIndex=player.currentMediaItemIndex;undoPosition=player.currentPosition
                publishSessionExtras()
                // Mutation is always paused; explicit Play remains the only resume admission.
                transport.pause()
            }
            return SessionResult.RESULT_SUCCESS
        }
        override fun onAddMediaItems(mediaSession:MediaSession,controller:MediaSession.ControllerInfo,mediaItems:List<MediaItem>):ListenableFuture<List<MediaItem>> =
            try {Futures.immediateFuture(resolve(browserRequests(controller,mediaItems),compose={next->validateInsertion(next);next}))}catch(_:Exception){transport.rejectSelection();Futures.immediateFailedFuture(SafeFailure(SafeFailure.Reason.AudioUnavailable))}
        override fun onSetMediaItems(mediaSession:MediaSession,controller:MediaSession.ControllerInfo,mediaItems:List<MediaItem>,startIndex:Int,startPositionMs:Long):ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
            transport.retire()
            return try {
                if(mediaItems.size==1 && mediaItems[0].requestMetadata.searchQuery!=null) {
                    require(admitted(controller) && mediaItems[0].localConfiguration==null && mediaItems[0].requestMetadata.mediaUri==null)
                    val query=mediaItems[0].requestMetadata.searchQuery!!
                    val scope=graph.session.capture() ?: throw SafeFailure(SafeFailure.Reason.Retired)
                    val owner=transport.begin {graph.session.current(scope)}
                    jobs.launch {
                        yield() // finish the immediate Media3 handoff before a fast read can publish
                        var staged=emptySet<String>()
                        try {
                            val found=withContext(Dispatchers.IO){catalog.page(scope,false,query,0,20)}
                            if(!transport.accepts(owner))return@launch
                            graph.session.checkScope(scope)
                            val requests=found.tracks.map(::request)
                            require(requests.isNotEmpty())
                            val old=(0 until player.mediaItemCount).map(player::getMediaItemAt)
                            val manual=QueuePolicy.carriedManual(old.map {it.mediaMetadata.extras?.getBoolean("manual")==true},player.currentMediaItemIndex,graph.queueSettings.state.value.keepQueued).map(old::get)
                            val prior=grants.keys.toSet()
                            val items=resolve(requests,0,0){next->next.toMutableList().apply {addAll(1,manual)}}
                            staged=grants.keys.filter {it !in prior}.toSet()
                            transport.complete(owner,items,0,0)
                        }catch(_:Exception){staged.forEach(grants::remove);transport.fail(owner)}
                    }
                    // Never hold the controller FIFO behind IO: a later Pause must execute.
                    return Futures.immediateFuture(MediaSession.MediaItemsWithStartPosition(transport.handoff(),C.INDEX_UNSET,C.TIME_UNSET))
                }
                val old=(0 until player.mediaItemCount).map(player::getMediaItemAt)
                val manual=QueuePolicy.carriedManual(old.map {it.mediaMetadata.extras?.getBoolean("manual")==true},player.currentMediaItemIndex,graph.queueSettings.state.value.keepQueued).map(old::get)
                val start=if(startIndex==C.INDEX_UNSET) 0 else startIndex
                val resolved=resolve(browserRequests(controller,mediaItems),start,startPositionMs) {next->
                    require(start in next.indices)
                    next.toMutableList().apply {addAll(start+1,manual)}
                }
                Futures.immediateFuture(MediaSession.MediaItemsWithStartPosition(resolved,start,startPositionMs))
            }catch(_:Exception){transport.rejectSelection();Futures.immediateFailedFuture(SafeFailure(SafeFailure.Reason.AudioUnavailable))}
        }
        override fun onPlaybackResumption(mediaSession:MediaSession,controller:MediaSession.ControllerInfo,isForPlayback:Boolean):ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
            if(!admitted(controller))return Futures.immediateFailedFuture(SafeFailure(SafeFailure.Reason.Retired))
            val scope=graph.session.capture() ?: return Futures.immediateFailedFuture(SafeFailure(SafeFailure.Reason.Retired))
            if(!isForPlayback)return future {
                val saved=readSavedQueue(scope) ?: throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
                graph.session.checkScope(scope)
                MediaSession.MediaItemsWithStartPosition(savedItems(scope,saved),saved.selected,saved.position)
            }
            if(!transport.resolving) {
                val owner=transport.begin {graph.session.current(scope)}
                jobs.launch {
                    yield() // do not publish ahead of the immediate resumption continuation
                    var staged=emptySet<String>()
                    try {
                        val saved=readSavedQueue(scope) ?: throw SafeFailure(SafeFailure.Reason.AudioUnavailable)
                        if(!transport.accepts(owner))return@launch
                        require(saved.items.isNotEmpty())
                        val prior=grants.keys.toSet()
                        val items=savedItems(scope,saved)
                        staged=grants.keys.filter {it !in prior}.toSet()
                        restoring=true
                        try {restoreModes(saved);player.restoringShuffle(saved.shuffleEnabled) {transport.complete(owner,items,saved.selected,saved.position)}}
                        finally {restoring=false}
                    }catch(_:Exception){staged.forEach(grants::remove);transport.fail(owner)}
                }
            }
            // Pinned Media3 plays on success AND failure. Complete its continuation now;
            // only the service-owned read may later install items/execute deferred intent.
            return Futures.immediateFuture(MediaSession.MediaItemsWithStartPosition(transport.handoff(),C.INDEX_UNSET,C.TIME_UNSET))
        }
        override fun onCustomCommand(session:MediaSession,controller:MediaSession.ControllerInfo,customCommand:SessionCommand,args:Bundle):ListenableFuture<SessionResult> {
            if(customCommand.customAction.startsWith(LIKE))return likeCommand(controller,customCommand)
            if(!own(controller))return Futures.immediateFuture(SessionResult(SessionError.ERROR_PERMISSION_DENIED))
            if(customCommand.customAction==START_CONTEXT)return startContext(args)
            if(customCommand.customAction==CLOCK_SEEK)return seekClock(args)
            graph.contextStarts.retire()
            if(customCommand.customAction in PerformanceCommands.all)return performanceCommand(controller,customCommand.customAction,args)
            // Preflight before any preparation, grant creation or queue mutation.
            if ((!supportsMixActions() && customCommand.customAction == PLAY_MIX) || (!supportsArrangementActions() && customCommand.customAction in setOf(APPLY_ARRANGEMENT, RETURN_SOURCES))) return Futures.immediateFuture(SessionResult(SessionError.ERROR_NOT_SUPPORTED))
            if (!supportsSourceActions() && customCommand.customAction == JAM_ADMIT) return Futures.immediateFuture(SessionResult(SessionError.ERROR_NOT_SUPPORTED))
            if(customCommand.customAction==APPLY_ARRANGEMENT) {
                return try {
                    val scope=graph.session.capture() ?: throw IllegalArgumentException()
                    require(account?.epoch==scope.epoch && graph.session.current(scope))
                    require(args.getString("service")==serviceIncarnation && args.getString("queue")==sourceQueueIncarnation && args.getLong("accountEpoch")==scope.epoch)
                    val raw=args.getString("document") ?: throw IllegalArgumentException()
                    require(raw.toByteArray().size<=192*1024)
                    val document=projectTempoDocument(Json.decodeFromString<TimelineDocument>(raw))
                    val request=args.getString("request") ?: throw IllegalArgumentException()
                    require(graph.timeline.admitsAudition(request,scope,document))
                    val sources=acceptedArrangement?.sources ?: sourceOccurrences()
                    require(sources.all {it.trackId>0 && it.durationMs>0} && document.matchesOccurrences(sources.map {it.occurrenceId to it.trackId}))
                    require(document.clips.zip(sources).all {(clip,source)->clip.sourceDurationMs==source.durationMs})
                    val native=player as? com.soundq.android.playback.nativeengine.NativeCallbackPlayer
                    val payload=if(native!=null)document.nativeArrangementPayload() else null
                    val plan=if(native==null)document.arrangementPlan() else null
                    val position=args.getLong("positionMs",0)
                    require(position in 0..(payload?.durationMs ?: requireNotNull(plan).duration))
                    val identity=ArrangementIdentity(serviceIncarnation,scope.epoch,sourceQueueIncarnation,document.revision,request)
                    val accepted=AcceptedArrangement(identity,document,sources.toList())
                    val uri=Uri.parse(if(player is com.soundq.android.playback.nativeengine.NativeCallbackPlayer) "soundqarrangement://schedule/${identity.install}" else "soundqmix://arrangement/${identity.install}")
                    val metadata=document.arrangementMetadata(position) {occurrence->sources.firstOrNull {it.occurrenceId==occurrence}?.let {it.title to it.artist}}
                    val item=MediaItem.Builder().setMediaId(identity.install).setUri(uri).apply {if(uri.scheme=="soundqmix")setMimeType("audio/wav")}
                        .setMediaMetadata(MediaMetadata.Builder().setTitle(metadata.title).setArtist(metadata.artist).setIsPlayable(true).setIsBrowsable(false).build()).build()
                    require(graph.session.current(scope) && graph.timeline.admitsAudition(request,scope,document))
                    val sourceItems=arrangementItems ?: (0 until player.mediaItemCount).map(player::getMediaItemAt)
                    if(native!=null) {
                        if(mixLoads.incrementAndGet()>1){mixLoads.decrementAndGet();return Futures.immediateFuture(SessionResult(SessionError.ERROR_INVALID_STATE))}
                        val priorEpoch=selectionEpoch
                        val priorAccepted=acceptedArrangement
                        val result=SettableFuture.create<SessionResult>()
                        val job=jobs.launch {
                            var candidate:com.soundq.android.playback.nativeengine.NativeCallbackArrangement?=null
                            var installed=false
                            try {
                                fun current()=selectionEpoch==priorEpoch && acceptedArrangement===priorAccepted && graph.session.current(scope) && graph.timeline.admitsAudition(request,scope,document)
                                candidate=native.prepareArrangement(document,sourceItems,::current)
                                require(current())
                                require(graph.timeline.installAudition(request,scope,document) {
                                    val epoch=++selectionEpoch;interruptions.command();transport.retire()
                                    saveJob?.cancel();undo=null;undoScope=null;player.pause()
                                    arrangementItems=sourceItems;acceptedArrangement=accepted;pendingArrangement=accepted to epoch
                                    // Candidate source guard belongs to preparation. Native install below
                                    // captures its independent committed generation and exact grant set.
                                    native.installArrangement(requireNotNull(candidate),item,sourceItems)
                                    // The native graph installs paused at zero. Its existing
                                    // deferred seek/ACK fence must settle before READY can play.
                                    if(position>0)native.seekTo(position)
                                    native.bindPerformance(identity)
                                    installed=true
                                    transport.selectionCommitted();publishSessionExtras()
                                })
                                result.set(SessionResult(SessionResult.RESULT_SUCCESS,Bundle().apply {putString("acceptedArrangement",Json.encodeToString(accepted))}))
                            }catch(_:Exception){result.set(SessionResult(SessionError.ERROR_BAD_VALUE))}
                            finally {if(!installed)candidate?.let {native.discardArrangement(it)}}
                        }
                        job.invokeOnCompletion {mixLoads.decrementAndGet();if(!result.isDone)result.set(SessionResult(SessionError.ERROR_BAD_VALUE))}
                        result.addListener({if(result.isCancelled)job.cancel()},MoreExecutors.directExecutor())
                        return result
                    }
                    require(graph.timeline.installAudition(request,scope,document) {
                        val epoch=++selectionEpoch;interruptions.command();transport.retire()
                        saveJob?.cancel();undo=null;undoScope=null;player.pause()
                        arrangementItems=sourceItems;acceptedArrangement=accepted;pendingArrangement=accepted to epoch
                        mixGrants[uri.toString()]=com.soundq.android.playback.mix.MixGrant(scope,requireNotNull(plan))
                        // Install ACK is not audible proof. READY rechecks the exact intent before playing.
                        player.setMediaItem(item);if(position>0)player.seekTo(position);transport.selectionCommitted();player.prepare();publishSessionExtras()
                    })
                    Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS,Bundle().apply {putString("acceptedArrangement",Json.encodeToString(accepted))}))
                }catch(_:Exception){Futures.immediateFuture(SessionResult(SessionError.ERROR_BAD_VALUE))}
            }
            if(customCommand.customAction==RETURN_SOURCES) {
                pendingArrangement=null
                val scope=graph.session.capture() ?: return Futures.immediateFuture(SessionResult(SessionError.ERROR_PERMISSION_DENIED))
                val accepted=acceptedArrangement ?: return Futures.immediateFuture(SessionResult(SessionError.ERROR_INVALID_STATE))
                val items=arrangementItems ?: return Futures.immediateFuture(SessionResult(SessionError.ERROR_INVALID_STATE))
                if(!arrangementCurrent(accepted))return Futures.immediateFuture(SessionResult(SessionError.ERROR_PERMISSION_DENIED))
                val native=player as? com.soundq.android.playback.nativeengine.NativeCallbackPlayer
                if(native!=null) {
                    val selection=++selectionEpoch
                    native.revokePerformance();interruptions.command();transport.retire();player.pause()
                    return future {
                        fun current()=selectionEpoch==selection&&acceptedArrangement===accepted&&graph.session.current(scope)
                        val actual=native.sourceReturn(accepted.identity,::current)
                        if(!current()||actual==null)SessionResult(SessionError.ERROR_INVALID_STATE)
                        else {
                            val index=items.indexOfFirst {it.mediaId==actual.first}
                            require(index>=0)
                            retireArrangement();player.setMediaItems(items,index,actual.second)
                            transport.selectionCommitted();publishSessionExtras()
                            SessionResult(SessionResult.RESULT_SUCCESS)
                        }
                    }
                }
                val global=player.currentPosition
                val clip=accepted.document.clips.firstOrNull {global>=it.globalStartMs&&global<it.globalEndMs} ?: accepted.document.clips.first()
                val index=items.indexOfFirst {it.mediaId==clip.occurrence}.coerceAtLeast(0)
                if(player !is com.soundq.android.playback.nativeengine.NativeCallbackPlayer)items.forEach {m->m.localConfiguration?.uri?.let {uri->grants[uri.toString()]=MediaGrant(scope,TrackId(m.mediaMetadata.extras!!.getLong("trackId")),m.mediaMetadata.extras!!.getBoolean("localOnly"))}}
                selectionEpoch++;interruptions.command();transport.retire();player.pause();retireArrangement()
                player.setMediaItems(items,index,clip.sourceAt(global).coerceIn(clip.sourceInMs,clip.sourceOutMs));transport.selectionCommitted();publishSessionExtras()
                return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
            }
            if(customCommand.customAction==UNDO){pendingArrangement=null;graph.timeline.cancelAudition()}
            if(customCommand.customAction==PLAY_MIX) {
                val scope=graph.session.capture() ?: return Futures.immediateFuture(SessionResult(SessionError.ERROR_PERMISSION_DENIED))
                val id=args.getString("planId") ?: return Futures.immediateFuture(SessionResult(SessionError.ERROR_BAD_VALUE))
                val version=args.getLong("version")
                val startOccurrence=args.getString("startOccurrence")
                val playlistStart=args.getString("playlistStart")
                if(playlistStart!=null && !graph.playlistBlend.startCurrent(playlistStart,scope))return Futures.immediateFuture(SessionResult(SessionError.ERROR_BAD_VALUE))
                if(mixLoads.incrementAndGet()>1){mixLoads.decrementAndGet();return Futures.immediateFuture(SessionResult(SessionError.ERROR_INVALID_STATE))}
                val epoch=++selectionEpoch
                interruptions.command();transport.retire()
                val result=SettableFuture.create<SessionResult>()
                var prepared:com.soundq.android.playback.mix.PreparedMix?=null
                var installed=false
                val job=jobs.launch {
                    try {
                        fun current()=epoch==selectionEpoch && graph.session.current(scope) && (playlistStart==null || graph.playlistBlend.startCurrent(playlistStart,scope))
                        val document=withContext(Dispatchers.IO) {graph.api.mixPlanDocument(scope,id,::current)}
                        val plan=document.plan
                        require(current() && plan.version==version && plan.playable())
                        val start=if(startOccurrence==null)0L else plan.clips.single {it.occurrence==startOccurrence}.start
                        withContext(Dispatchers.IO) {
                            prepared=com.soundq.android.playback.mix.PreparedMix.prepare(graph.directory,graph.session,graph.downloads,graph.api,scope,graph.mediaClient,plan,::current)
                        }
                        require(current() && prepared!!.admits())
                        val uri=Uri.parse("soundqmix://plan/${java.util.UUID.randomUUID()}")
                        val item=MediaItem.Builder().setMediaId("mix:${plan.id}:${plan.version}").setUri(uri).setMimeType("audio/wav")
                            .setMediaMetadata(MediaMetadata.Builder().setTitle(plan.name).setArtist("Saved mix").setIsPlayable(true).setIsBrowsable(false).setExtras(Bundle().apply {putString("mixPlanId",plan.id)}).build()).build()
                        val install:(com.soundq.android.data.mix.SavedMix,Long)->Unit={accepted,position->
                            require(epoch==selectionEpoch && graph.session.current(scope) && prepared!!.admits() && accepted==plan)
                            saveJob?.cancel();undo=null;undoScope=null
                            // Same ExoPlayer. Prepared source custody transfers to this exact grant.
                            player.pause();mixGrants[uri.toString()]=com.soundq.android.playback.mix.MixGrant(scope,accepted,prepared)
                            installed=true
                            player.setMediaItem(item);transport.selectionCommitted();if(position>0)player.seekTo(position);player.prepare();player.play()
                        }
                        if(playlistStart==null)install(plan,start)
                        else require(graph.playlistBlend.installStart(playlistStart,scope,document,install))
                        result.set(SessionResult(SessionResult.RESULT_SUCCESS))
                    }catch(_:Exception){result.set(SessionResult(SessionError.ERROR_BAD_VALUE))}
                    finally {if(!installed)prepared?.close()}
                }
                job.invokeOnCompletion {
                    playlistStart?.let(graph.playlistBlend::cancelStart);mixLoads.decrementAndGet()
                    if(!result.isDone)result.set(SessionResult(SessionError.ERROR_BAD_VALUE))
                }
                result.addListener({if(result.isCancelled)job.cancel()},MoreExecutors.directExecutor())
                return result
            }
            if(customCommand.customAction==JAM_ADMIT && acceptedArrangement!=null) {
                args.getString("ticket")?.let(graph.jamAdmission::refused)
                return Futures.immediateFuture(SessionResult(SessionError.ERROR_INVALID_STATE))
            }
            if(customCommand.customAction==JAM_ADMIT) {
                val ticket=args.getString("ticket") ?: return Futures.immediateFuture(SessionResult(SessionError.ERROR_BAD_VALUE))
                if(account?.let(graph.session::remoteCurrent)!=true || player.currentMediaItem?.mediaMetadata?.extras?.getBoolean("localOnly")==true) {
                    graph.jamAdmission.refused(ticket)
                    return Futures.immediateFuture(SessionResult(SessionError.ERROR_PERMISSION_DENIED))
                }
                val admitted=graph.jamAdmission.consumeWithProvenance(ticket) {track,provenance,lookupOnly ->
                    val known=if(provenance==null)emptyList()else (0 until player.mediaItemCount).map(player::getMediaItemAt).filter {
                        com.soundq.android.data.jam.JamOccurrence.decode(it.mediaMetadata.extras?.getString("soundqJam"))?.admissionKey==provenance.admissionKey
                    }
                    require(known.size<=1)
                    known.singleOrNull()?.let {item ->
                        require(com.soundq.android.data.jam.JamOccurrence.decode(item.mediaMetadata.extras?.getString("soundqJam"))==provenance&&item.mediaMetadata.extras?.getLong("trackId")==track.id.value)
                        saveJamQueue();return@consumeWithProvenance item.mediaId
                    }
                    require(!lookupOnly) // Missing canonical evidence is never permission to replay.
                    require(QueuePolicy.acceptsAppend(player.mediaItemCount,1))
                    if(provenance!=null)require((0 until player.mediaItemCount).all {player.getMediaItemAt(it).localConfiguration?.uri?.scheme=="soundq"})
                    transport.retire()
                    graph.rememberTracks(listOf(track))
                    val input=MediaItem.Builder().setMediaId(track.id.value.toString()).setRequestMetadata(MediaItem.RequestMetadata.Builder().setExtras(Bundle().apply {putBoolean("manual",true)}).build()).build()
                    val item=resolve(listOf(input)).single()
                    provenance?.let {item.mediaMetadata.extras!!.putString("soundqJam",it.encode())}
                    val origins=(0 until player.mediaItemCount).map {player.getMediaItemAt(it).mediaMetadata.extras?.getBoolean("manual")==true}
                    // The existing canonical owner inserts only. No prepare/play, including an empty queue.
                    if(player.mediaItemCount==0)player.pause()
                    player.addMediaItem(QueuePolicy.manualInsert(origins,player.currentMediaItemIndex),item)
                    transport.selectionCommitted()
                    if(provenance!=null)saveJamQueue()
                    item.mediaId
                }
                return Futures.immediateFuture(SessionResult(if(admitted)SessionResult.RESULT_SUCCESS else SessionError.ERROR_PERMISSION_DENIED))
            }
            if(!own(controller)||customCommand.customAction!=UNDO || (graph.session.capture()==null&&!localAccess())) return Futures.immediateFuture(SessionResult(SessionError.ERROR_PERMISSION_DENIED))
            val saved=undo ?: return Futures.immediateFuture(SessionResult(SessionError.ERROR_BAD_VALUE))
            // Reissue grant capabilities for exact previous occurrence IDs; never resurrect a retired account.
            val scope=undoScope
            if(scope==null&&(!localAccess()||!graph.session.owns(undoVersion)))return Futures.immediateFuture(SessionResult(SessionError.ERROR_PERMISSION_DENIED))
            if((scope!=null&&!graph.session.current(scope)) || account?.let { !graph.session.current(it) }==true) return Futures.immediateFuture(SessionResult(SessionError.ERROR_PERMISSION_DENIED))
            // Accepted Undo is a newer selection intent; direct player calls do not re-enter admission.
            selectionEpoch++
            val index=undoIndex.coerceAtLeast(0).coerceAtMost(saved.lastIndex.coerceAtLeast(0))
            try {validateSelection(saved,index,undoPosition)}catch(_:Exception){transport.rejectSelection();return Futures.immediateFuture(SessionResult(SessionError.ERROR_BAD_VALUE))}
            val prior=grants.keys.toSet()
            try {
                saved.forEach {item -> item.localConfiguration?.uri?.let {uri -> grants[uri.toString()]=grantFor(item,scope)}}
                transport.retire();player.pause();if(saved.isEmpty())player.clearMediaItems() else player.setMediaItems(saved,index,undoPosition)
                transport.selectionCommitted();undo=null;undoScope=null;publishSessionExtras()
            }catch(_:Exception){grants.keys.filter {it !in prior}.forEach(grants::remove);transport.rejectSelection();return Futures.immediateFuture(SessionResult(SessionError.ERROR_BAD_VALUE))}
            return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
        }
        private fun folder(id:String,title:String)=MediaItem.Builder().setMediaId(id).setMediaMetadata(MediaMetadata.Builder().setTitle(title).setIsBrowsable(true).setIsPlayable(false).setMediaType(MediaMetadata.MEDIA_TYPE_FOLDER_MIXED).build()).build()
        private fun root()=folder(FoundationCatalog.ROOT,"SoundQ")
        override fun onGetLibraryRoot(session:MediaLibrarySession,browser:MediaSession.ControllerInfo,params:LibraryParams?):ListenableFuture<LibraryResult<MediaItem>> = Futures.immediateFuture(LibraryResult.ofItem(root(),params))
        override fun onGetItem(session:MediaLibrarySession,browser:MediaSession.ControllerInfo,mediaId:String):ListenableFuture<LibraryResult<MediaItem>> {
            val scope=graph.session.capture()
            val item=when(mediaId){FoundationCatalog.ROOT->root();LIBRARY->folder(LIBRARY,"Library");DEVICE->folder(DEVICE,"On this device");else->scope?.let {catalog.item(it,mediaId)}?.let(::browserItem)}
            return Futures.immediateFuture(if(item!=null && (mediaId==FoundationCatalog.ROOT||scope!=null))LibraryResult.ofItem(item,null) else LibraryResult.ofError(SessionError.ERROR_PERMISSION_DENIED))
        }
        override fun onGetChildren(session:MediaLibrarySession,browser:MediaSession.ControllerInfo,parentId:String,page:Int,pageSize:Int,params:LibraryParams?):ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> = libraryRead {
            require(page>=0 && pageSize in 1..100 && page.toLong()*pageSize<=100_000)
            val scope=graph.session.capture()
            val items=if(parentId==FoundationCatalog.ROOT) {
                if(scope==null)emptyList() else listOfNotNull(if(graph.session.remoteCurrent(scope))folder(LIBRARY,"Library") else null,folder(DEVICE,"On this device")).drop(page*pageSize).take(pageSize)
            } else {
                require(parentId==LIBRARY||parentId==DEVICE)
                if(scope==null)throw SafeFailure(SafeFailure.Reason.Retired)
                withContext(Dispatchers.IO){catalog.page(scope,parentId==DEVICE,"",page,pageSize)}.tracks.map(::browserItem)
            }
            if(scope!=null)graph.session.checkScope(scope)
            LibraryResult.ofItemList(items,params)
        }
        override fun onSearch(session:MediaLibrarySession,browser:MediaSession.ControllerInfo,query:String,params:LibraryParams?):ListenableFuture<LibraryResult<Void>> = libraryRead {
            val scope=graph.session.capture() ?: throw SafeFailure(SafeFailure.Reason.Retired)
            val result=withContext(Dispatchers.IO){catalog.page(scope,false,query,0,20)}
            graph.session.checkScope(scope)
            session.notifySearchResultChanged(browser,query,result.total,params)
            LibraryResult.ofVoid(params)
        }
        override fun onGetSearchResult(session:MediaLibrarySession,browser:MediaSession.ControllerInfo,query:String,page:Int,pageSize:Int,params:LibraryParams?):ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> = libraryRead {
            val scope=graph.session.capture() ?: throw SafeFailure(SafeFailure.Reason.Retired)
            val result=withContext(Dispatchers.IO){catalog.page(scope,false,query,page,pageSize)}
            graph.session.checkScope(scope);LibraryResult.ofItemList(result.tracks.map(::browserItem),params)
        }
        override fun onSubscribe(session:MediaLibrarySession,browser:MediaSession.ControllerInfo,parentId:String,params:LibraryParams?):ListenableFuture<LibraryResult<Void>> = Futures.immediateFuture(
            if(parentId in listOf(FoundationCatalog.ROOT,LIBRARY,DEVICE))LibraryResult.ofVoid(params) else LibraryResult.ofError(SessionError.ERROR_BAD_VALUE))
    }
    private fun browserItem(row:SystemTrack):MediaItem {
        val metadata=MediaMetadata.Builder().setTitle(row.track.title).setArtist(row.track.artist).setAlbumTitle(row.track.album)
            .setIsPlayable(true).setIsBrowsable(false).setMediaType(MediaMetadata.MEDIA_TYPE_MUSIC)
        // Device entries never expose remote artwork, even while online.
        if(!row.localOnly)metadata.setArtworkUri(row.track.artwork?.let(Uri::parse))
        return MediaItem.Builder().setMediaId(row.mediaId).setMediaMetadata(metadata.build()).build()
    }
    private fun request(row:SystemTrack):MediaItem {
        graph.rememberTracks(listOf(row.track))
        return MediaItem.Builder().setMediaId(row.track.id.value.toString()).setRequestMetadata(MediaItem.RequestMetadata.Builder()
            .setExtras(Bundle().apply {putBoolean("localOnly",row.localOnly)}).build()).build()
    }
    private fun browserRequests(controller:MediaSession.ControllerInfo,items:List<MediaItem>):List<MediaItem> {
        require(admitted(controller))
        val scope=graph.session.capture()
        require(scope!=null||localAccess())
        return items.map {item ->
            require(item.localConfiguration==null && item.requestMetadata.mediaUri==null)
            if(own(controller) && (item.mediaId.toLongOrNull()!=null||item.mediaId.startsWith("device:")))item
            else request(catalog.item(requireNotNull(scope),item.mediaId) ?: throw SafeFailure(SafeFailure.Reason.AudioUnavailable))
        }
    }
    private fun <T> future(block:suspend ()->T):ListenableFuture<T> {
        val result=SettableFuture.create<T>()
        val job=jobs.launch {try {result.set(block())}catch(e:Exception){result.setException(e)}}
        result.addListener({if(result.isCancelled)job.cancel()},MoreExecutors.directExecutor())
        return result
    }
    private fun <T:Any> libraryRead(block:suspend ()->LibraryResult<T>):ListenableFuture<LibraryResult<T>> = future<LibraryResult<T>> {
        try {block()}catch(_:IllegalArgumentException){LibraryResult.ofError<T>(SessionError.ERROR_BAD_VALUE)}catch(_:Exception){LibraryResult.ofError<T>(SessionError.ERROR_PERMISSION_DENIED)}
    }
    companion object {const val START_CONTEXT="soundq.context.start";const val LIKE="soundq.library.like.";const val UNDO="soundq.queue.undo";const val LIBRARY="soundq:library";const val DEVICE="soundq:device";const val JAM_ADMIT="soundq.jam.admit";const val APPLY_ARRANGEMENT="soundq.arrangement.apply";const val RETURN_SOURCES="soundq.arrangement.sources";const val PLAY_MIX="soundq.mix.play"}
}
