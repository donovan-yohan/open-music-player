package com.soundq.android.playback.listening

import android.net.Uri
import androidx.media3.common.*
import androidx.media3.datasource.DataSource
import androidx.media3.exoplayer.ExoPlayer
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.soundq.android.AppGraph
import com.soundq.android.data.*
import com.soundq.android.data.timeline.*
import com.soundq.android.playback.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.combine
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/** A service-only natural source EOF signal. Dominance discontinuities are NOT completion. */
internal interface ListeningCompletionPlayer {
    fun addCompletionListener(listener:(MediaItem)->Unit)
    fun removeCompletionListener(listener:(MediaItem)->Unit)
}

/** Explicit, bounded internal service tracer; NOT the ordinary default or a settings consumer.
 * Owns the entire logical Player state/event surface. The single Exo output supplies the only clock.
 * Unsupported mutations/modes are not advertised. No saved/arrangement path enters this class.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class ListeningServicePlayer(
    private val output:ExoPlayer,
    private val graph:AppGraph,
    private val grants:ConcurrentHashMap<String,MediaGrant>,
    private val jobs:CoroutineScope,
    private val overlapMs:Long,
    private val install:(MediaItem,DataSource.Factory)->Unit,
    private val wake:(Long,()->Unit)->AutoCloseable = {position,action->
        val message=output.createMessage {_,_->action()}.setLooper(output.applicationLooper).setPosition(0,position).setDeleteAfterDelivery(false).send()
        AutoCloseable {message.cancel()}
    },
    private val rollingMp3:Boolean=false,
):SimpleBasePlayer(output.applicationLooper),ListeningCompletionPlayer {
    private var items=listOf<MediaItem>()
    private var queueScope:AccountScope?=null
    private var schedule=ListeningSchedule.compile(emptyList(),0)
    private var index=0
    private var position=0L
    private var state=Player.STATE_IDLE
    private var intent=false
    private var repeat=Player.REPEAT_MODE_OFF
    private var transportRevision=0L
    private var reconciling=false
    private var pausedSeekGlobal:Long?=null
    private var error:PlaybackException?=null
    @Volatile private var epoch=0L
    private var prepared:PreparedListening?=null
    private val retiredRenders=mutableListOf<PreparedListening>()
    fun residency()=prepared?.residency() ?: retiredRenders.lastOrNull()?.residency()
    private class ExhaustionCommit(val current:()->Boolean) {
        val result=CompletableDeferred<Boolean>()
        @Volatile var published=false
    }
    private var exhaustionCommit:ExhaustionCommit?=null
    private var pending:Job?=null
    private var acquisition:Job?=null
    private val preparing=AtomicInteger()
    val preparationSettled get()=preparing.get()==0
    private var lastGlobal=0L
    private val completed=mutableSetOf<String>()
    private val completions=mutableListOf<(MediaItem)->Unit>()
    private val wakes=mutableListOf<AutoCloseable>()
    private val listener=object:Player.Listener {
        override fun onEvents(player:Player,events:Player.Events){reconcile()}
        override fun onPlaybackStateChanged(playbackState:Int){reconcile()}
        override fun onPlayerError(failure:PlaybackException){error=failure;state=Player.STATE_IDLE;intent=false;invalidateState()}
    }
    private val accountJob=jobs.launch {
        combine(graph.session.state,graph.session.scopeRevision){state,_->state}.collect {auth->
            val scope=queueScope
            if(items.isNotEmpty() && (scope==null || !graph.session.current(scope))) {
                val resuming=scope!=null && graph.session.resumesLocal(scope)
                if(auth is AuthState.LocalLocked || resuming) {
                    position=sourcePosition();retirePending();transportRevision++;intent=false
                    output.pause();output.stop();retireRender();output.clearMediaItems();state=Player.STATE_IDLE
                    if(resuming)queueScope=graph.session.capture()
                }
                else clearQueue()
                invalidateState()
            }
        }
    }
    init {output.repeatMode=Player.REPEAT_MODE_OFF;output.shuffleModeEnabled=false;output.addListener(listener)}
    override fun addCompletionListener(listener:(MediaItem)->Unit){completions+=listener}
    override fun removeCompletionListener(listener:(MediaItem)->Unit){completions-=listener}
    private fun done():ListenableFuture<*> = Futures.immediateVoidFuture()
    private fun retirePending(){epoch++;pending?.cancel();pending=null;exhaustionCommit?.result?.complete(false);exhaustionCommit=null}
    private fun retireRender(){pausedSeekGlobal=null;wakes.forEach {it.close()};wakes.clear();prepared?.let {if(rollingMp3)retiredRenders.add(it);it.close()};prepared=null}
    private fun currentGlobal()=output.currentPosition.coerceIn(0,schedule.durationMs)
    private fun sourcePosition():Long = if(prepared==null)position else (currentGlobal()-schedule.occurrences[index].startMs).coerceIn(0,schedule.occurrences[index].source.durationMs)
    override fun getState():State {
        val commands=Player.Commands.Builder().addAll(Player.COMMAND_PLAY_PAUSE,Player.COMMAND_PREPARE,Player.COMMAND_STOP,Player.COMMAND_RELEASE,
            Player.COMMAND_CHANGE_MEDIA_ITEMS,Player.COMMAND_SET_MEDIA_ITEM,Player.COMMAND_GET_TIMELINE,Player.COMMAND_GET_CURRENT_MEDIA_ITEM,Player.COMMAND_GET_METADATA,
            Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,Player.COMMAND_SEEK_TO_MEDIA_ITEM,Player.COMMAND_SEEK_TO_DEFAULT_POSITION,Player.COMMAND_SET_REPEAT_MODE,
            Player.COMMAND_SEEK_TO_NEXT,Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,Player.COMMAND_SEEK_TO_PREVIOUS,Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM).build()
        val b=State.Builder().setAvailableCommands(commands).setPlayWhenReady(intent,Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .setPlaybackState(state).setIsLoading(state==Player.STATE_BUFFERING).setPlayerError(error).setRepeatMode(repeat)
            .setPlaylist(items.mapIndexed {i,item->MediaItemData.Builder(item.mediaId).setMediaItem(item).setIsSeekable(true)
                .setDurationUs(Math.multiplyExact(schedule.occurrences[i].source.durationMs,1000)).build()})
        if(items.isNotEmpty()) {
            // Suppliers belong to this immutable logical state, not the next selected index.
            val occurrence=schedule.occurrences[index]
            val start=occurrence.startMs;val duration=occurrence.source.durationMs
            val ready=prepared!=null;val fixed=position
            fun observed()=if(!ready)fixed else (currentGlobal()-start).coerceIn(0,duration)
            b.setCurrentMediaItemIndex(index).setContentPositionMs(PositionSupplier {observed()})
                .setContentBufferedPositionMs(PositionSupplier {
                    if(!ready)fixed else (minOf(output.bufferedPosition,occurrence.endMs)-start).coerceIn(observed(),duration)
                }).setTotalBufferedDurationMs(PositionSupplier {if(ready)output.totalBufferedDuration else 0})
        }
        return b.build()
    }
    override fun handleSetMediaItems(mediaItems:List<MediaItem>,startIndex:Int,startPositionMs:Long):ListenableFuture<*> {
        if(mediaItems.isEmpty())return clearQueue()
        val captured=mediaItems.toList()
        val next=compileItems(captured)
        val selected=if(startIndex==C.INDEX_UNSET)0 else startIndex
        require(selected in captured.indices)
        val local=if(startPositionMs==C.TIME_UNSET)0 else startPositionMs
        next.globalAt(captured[selected].mediaId,local)
        completed.clear()
        replaceQueue(captured,next,selected,local,false,false)
        return done()
    }
    private fun compileItems(captured:List<MediaItem>):ListeningSchedule {
        val sources=captured.map {m->
            val uri=m.localConfiguration?.uri ?: error("Resolved ordinary item required")
            require(uri.scheme=="soundq" && grants.containsKey(uri.toString()))
            graph.session.checkScope(grants.getValue(uri.toString()).scope)
            val e=m.mediaMetadata.extras!!
            TimelineSource(m.mediaId,e.getLong("trackId"),m.mediaMetadata.title?.toString().orEmpty(),e.getLong("durationMs"),when(e.getString("origin")){"Continuation"->QueueSegment.Continuation;"Manual"->QueueSegment.Manual;else->if(e.getBoolean("manual"))QueueSegment.Manual else QueueSegment.Context})
        }
        return validateMetadata(sources,0,0)
    }
    /** Pure admission: no grants, resource slots, IO or timeline mutation. */
    internal fun validateMetadata(sources:List<TimelineSource>,startIndex:Int,startPositionMs:Long):ListeningSchedule {
        require(sources.size<= (if(rollingMp3)500 else 2) && overlapMs in 1..12000)
        val result=ListeningSchedule.compile(sources,overlapMs)
        if(rollingMp3)RollingListeningPcm.checkedSize(result)
        if(sources.isNotEmpty()) {
            val selected=if(startIndex==C.INDEX_UNSET)0 else startIndex
            require(selected in sources.indices)
            result.globalAt(sources[selected].occurrence,if(startPositionMs==C.TIME_UNSET)0 else startPositionMs)
        }
        return result
    }
    private fun replaceQueue(captured:List<MediaItem>,next:ListeningSchedule,selected:Int,local:Long,playing:Boolean,prepare:Boolean,commit:ExhaustionCommit?=null) {
        val draining=acquisition
        transportRevision++
        retirePending();output.pause();output.stop();retireRender();output.clearMediaItems()
        exhaustionCommit=commit
        items=captured;schedule=next;index=selected;position=local;lastGlobal=next.globalAt(items[index].mediaId,position)
        queueScope=grants.getValue(items.first().localConfiguration!!.uri.toString()).scope
        intent=playing;state=Player.STATE_IDLE;error=null;completed.retainAll(captured.map {it.mediaId}.toSet())
        if(prepare) {
            if(preparing.get()==0)handlePrepare()
            else {
                val owner=epoch
                // The cancelled acquisition still owns its files until its finally has drained.
                state=Player.STATE_BUFFERING
                pending=jobs.launch(start=CoroutineStart.LAZY) {
                    draining?.join()
                    if(epoch==owner){pending=null;handlePrepare();invalidateState()}
                }.also {it.start()}
            }
        }
    }
    private fun clearQueue():ListenableFuture<*> {
        retirePending();transportRevision++;intent=false
        output.pause();output.stop();retireRender();output.clearMediaItems()
        items=emptyList();queueScope=null;schedule=ListeningSchedule.compile(emptyList(),overlapMs)
        index=0;position=0;lastGlobal=0;state=Player.STATE_IDLE;error=null;completed.clear()
        return done()
    }
    /** One looper-owned exhausted commit. Arbitrary live edits still use pausedMutation. */
    internal fun continueExhaustedQueue(appended:List<MediaItem>,accepted:()->Boolean,current:()->Boolean):Deferred<Boolean>? {
        val retained=items.mapNotNull {it.localConfiguration?.uri?.toString()}.toSet()
        val staged=appended.mapNotNull {it.localConfiguration?.uri?.toString()}.filter {it !in retained}.associateWith {grants[it]}
        var admitted=false
        try {
            if(!rollingMp3 || appended.isEmpty() || !accepted() || state!=Player.STATE_ENDED || !intent || repeat!=Player.REPEAT_MODE_OFF || index!=items.lastIndex)return null
            val captured=items+appended
            val metadata=compileItems(captured)
            val next=schedule.appendExhausted(metadata.occurrences.drop(items.size).map {it.source})
            RollingListeningPcm.checkedSize(next)
            if(!accepted())return null
            val commit=ExhaustionCommit(current)
            replaceQueue(captured,next,items.size,0,true,true,commit)
            admitted=true
            invalidateState()
            return commit.result
        }finally {if(!admitted)staged.forEach {(uri,grant)->if(grant!=null)grants.remove(uri,grant)}}
    }

    /** Paused edits may replace the finite render, never silently reload an on-air schedule. */
    private fun pausedMutation(captured:List<MediaItem>,fallback:Int,retainSelection:Boolean=true):ListenableFuture<*> {
        require(!intent)
        if(captured.isEmpty())return clearQueue()
        val next=compileItems(captured)
        captured.forEach {item->
            val permit=grants.getValue(item.localConfiguration!!.uri.toString())
            graph.session.checkScope(permit.scope)
        }
        val current=items.getOrNull(index)?.mediaId
        val retained=if(retainSelection)captured.indexOfFirst {it.mediaId==current}else -1
        val selected=if(retained>=0)retained else fallback.coerceIn(captured.indices)
        val local=if(retained>=0)sourcePosition()else 0
        next.globalAt(captured[selected].mediaId,local)
        if(retained<0)completed.remove(captured[selected].mediaId)
        val prepare=prepared!=null || pending!=null || preparing.get()!=0
        replaceQueue(captured,next,selected,local,false,prepare)
        return done()
    }
    override fun handleAddMediaItems(insertionIndex:Int,mediaItems:List<MediaItem>):ListenableFuture<*> {
        if(mediaItems.isEmpty())return done()
        return pausedMutation(items.toMutableList().apply {addAll(insertionIndex,mediaItems)},0)
    }
    override fun handleMoveMediaItems(fromIndex:Int,toIndex:Int,newIndex:Int):ListenableFuture<*> {
        if(fromIndex==toIndex || fromIndex==newIndex)return done()
        val captured=items.toMutableList().apply {
            val moved=subList(fromIndex,toIndex).toList();subList(fromIndex,toIndex).clear();addAll(newIndex,moved)
        }
        return pausedMutation(captured,0)
    }
    override fun handleReplaceMediaItems(fromIndex:Int,toIndex:Int,mediaItems:List<MediaItem>):ListenableFuture<*> {
        if(fromIndex==toIndex && mediaItems.isEmpty())return done()
        val captured=items.toMutableList().apply {subList(fromIndex,toIndex).clear();addAll(fromIndex,mediaItems)}
        return pausedMutation(captured,fromIndex,index !in fromIndex until toIndex)
    }
    override fun handleRemoveMediaItems(fromIndex:Int,toIndex:Int):ListenableFuture<*> {
        if(fromIndex==toIndex)return done()
        if(fromIndex==0 && toIndex==items.size)return clearQueue()
        val selectedRemoved=index in fromIndex until toIndex
        // Future/live revisions need emitted-PCM-frontier qualification. Do not silently restart them.
        require(selectedRemoved || !intent)
        val captured=items.toMutableList().apply {subList(fromIndex,toIndex).clear()}
        val next=compileItems(captured)
        val selected=if(selectedRemoved)minOf(fromIndex,captured.lastIndex)else if(index>=toIndex)index-(toIndex-fromIndex)else index
        val local=if(selectedRemoved)0 else sourcePosition()
        next.globalAt(captured[selected].mediaId,local)
        // Explicitly restarting the survivor at zero begins a new source completion cycle.
        if(selectedRemoved)completed.remove(captured[selected].mediaId)
        val prepare=prepared!=null || pending!=null || preparing.get()!=0
        replaceQueue(captured,next,selected,local,intent,prepare)
        return done()
    }
    override fun handlePrepare():ListenableFuture<*> {
        if(prepared!=null){error=null;output.prepare();state=Player.STATE_BUFFERING;return done()}
        if(pending!=null || preparing.get()!=0 || items.isEmpty())return done()
        val owner=++epoch
        val scope=graph.session.capture() ?: error("Account unavailable")
        val captured=items
        val permits=captured.associate {it.localConfiguration!!.uri.toString() to grants.getValue(it.localConfiguration!!.uri.toString())}
        val commit=exhaustionCommit
        fun valid()=epoch==owner && graph.session.current(scope) && permits.all {(uri,grant)->grants[uri]===grant} && (commit==null || commit.published || commit.current())
        retiredRenders.removeAll {it.released.isDone && !it.released.isCompletedExceptionally}
        val predecessors=retiredRenders.toList()
        state=Player.STATE_BUFFERING;error=null;preparing.incrementAndGet()
        pending=jobs.launch(start=CoroutineStart.LAZY) {
            var result:PreparedListening?=null
            var transferred=false
            try {
                withContext(Dispatchers.IO){
                    predecessors.forEach {it.released.get(15,java.util.concurrent.TimeUnit.SECONDS)}
                    check(valid())
                    result=if(rollingMp3)PreparedListening.prepareRolling(graph,grants,captured,schedule,::valid)
                        else PreparedListening.prepare(graph,grants,captured,schedule,::valid)
                }
                check(valid())
                prepared=result
                val item=MediaItem.Builder().setMediaId("render:$owner").setUri(Uri.parse("soundqlistening://render/$owner")).setMimeType("audio/wav").build()
                install(item,DataSource.Factory {result!!.acquire()})
                check(valid());transferred=true
                output.seekTo(schedule.globalAt(items[index].mediaId,position));lastGlobal=currentGlobal()
                output.prepare()
                val boundaries=(schedule.occurrences.map {it.endMs}+schedule.occurrences.drop(1).map {it.startMs+it.fadeInMs/2}).distinct().sorted()
                boundaries.forEach {at->wakes+=wake(at){if(valid())reconcile()}}
                check(valid())
                if(intent)output.play()
                commit?.published=true
                commit?.result?.complete(true)
                if(exhaustionCommit===commit)exhaustionCommit=null
            }catch(_:CancellationException){/* Retired intent cannot publish errors or success. */}
            catch(failure:Exception){if(valid()){error=PlaybackException("Internal listening tracer refused source",failure,PlaybackException.ERROR_CODE_IO_UNSPECIFIED);state=Player.STATE_IDLE;intent=false}}
            finally {if(commit?.published==false)commit.result.complete(false);if(!transferred){if(prepared===result)prepared=null;result?.close()};if(epoch==owner){if(commit?.published==false){intent=false;state=Player.STATE_IDLE};pending=null;invalidateState()};preparing.decrementAndGet();if(acquisition===currentCoroutineContext()[Job])acquisition=null}
        }.also {acquisition=it;it.start()}
        return done()
    }
    override fun handleSetRepeatMode(repeatMode:Int):ListenableFuture<*> {
        repeat=repeatMode
        if(exhaustionCommit!=null){retirePending();intent=false;state=Player.STATE_IDLE}
        return done()
    }
    override fun handleSetPlayWhenReady(playWhenReady:Boolean):ListenableFuture<*> {
        transportRevision++
        intent=playWhenReady && items.isNotEmpty() && queueScope?.let(graph.session::current)==true
        if(intent)pausedSeekGlobal=null
        if(!intent){output.pause();if(pending!=null){retirePending();state=Player.STATE_IDLE}}
        else if(prepared!=null)output.play()
        return done()
    }
    override fun handleStop():ListenableFuture<*> {position=if(items.isEmpty())0 else sourcePosition();intent=false;retirePending();output.stop();retireRender();state=Player.STATE_IDLE;return done()}
    override fun handleRelease():ListenableFuture<*> {accountJob.cancel();retirePending();output.removeListener(listener);output.stop();retireRender();output.release();return done()}
    override fun handleSeek(mediaItemIndex:Int,positionMs:Long,seekCommand:Int):ListenableFuture<*> {
        if(items.isEmpty())return done()
        val next=seekCommand==Player.COMMAND_SEEK_TO_NEXT || seekCommand==Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM
        val previous=seekCommand==Player.COMMAND_SEEK_TO_PREVIOUS || seekCommand==Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM
        // Navigation is occurrence policy, not the toolkit's position-based Previous heuristic.
        val i=when {
            next && index<items.lastIndex->index+1
            next && repeat==Player.REPEAT_MODE_ALL->0
            next && repeat==Player.REPEAT_MODE_ONE->index
            next->return done()
            previous->(index-1).coerceAtLeast(0)
            else->if(mediaItemIndex==C.INDEX_UNSET)index else mediaItemIndex
        }
        val p=if(positionMs==C.TIME_UNSET)0 else positionMs
        val local=if(next || previous)0 else p
        val global=schedule.globalAt(items[i].mediaId,local)
        if(pending!=null){retirePending();state=Player.STATE_IDLE;intent=false}
        transportRevision++;index=i;position=local;lastGlobal=global
        pausedSeekGlobal=if(intent)null else global
        if(prepared!=null) {
            // Inline Exo callbacks cannot replace the command's explicit occurrence.
            val wasReconciling=reconciling;reconciling=true
            try {output.seekTo(global);state=output.playbackState}finally{reconciling=wasReconciling}
        }
        return done()
    }
    companion object {
        /** Internal composition only: use the service's existing output, never construct a second player.
         * Not called by ordinary queue/settings commands until the remaining compatibility gates close.
         */
        fun createRollingMp3(output:ExoPlayer,graph:AppGraph,grants:ConcurrentHashMap<String,MediaGrant>,jobs:CoroutineScope,overlapMs:Long):ListeningServicePlayer =
            ListeningServicePlayer(output,graph,grants,jobs,overlapMs,{item,factory->
                output.setMediaSource(androidx.media3.exoplayer.source.ProgressiveMediaSource.Factory(factory).createMediaSource(item))
            },rollingMp3=true)
        fun create(output:ExoPlayer,graph:AppGraph,grants:ConcurrentHashMap<String,MediaGrant>,jobs:CoroutineScope,overlapMs:Long):ListeningServicePlayer =
            ListeningServicePlayer(output,graph,grants,jobs,overlapMs,{item,factory->
                output.setMediaSource(androidx.media3.exoplayer.source.ProgressiveMediaSource.Factory(factory).createMediaSource(item))
            })
    }
    /** Wake-up/event reconciliation reads the sole output clock; it never advances a timer. */
    fun reconcile() {
        if(reconciling || prepared==null || items.isEmpty())return
        reconciling=true
        try {
            val owner=epoch;val render=prepared;val revision=transportRevision
            val scope=items.first().localConfiguration?.uri?.toString()?.let {grants[it]?.scope}
            fun current()=epoch==owner && prepared===render && scope!=null && graph.session.current(scope)
            val global=currentGlobal()
            val crossed=schedule.occurrences.filter {it.endMs>lastGlobal && it.endMs<=global && it.source.occurrence !in completed}
            lastGlobal=global
            // Readiness/aggregate events at a paused seek target are not clock progress.
            // Play or a changed physical position restores ordinary dominance observation.
            if(intent || pausedSeekGlobal!=global) {
                pausedSeekGlobal=null
                val selected=schedule.observe(global).selected
                if(selected!=null){index=items.indexOfFirst {it.mediaId==selected.occurrence.source.occurrence};position=selected.sourceMs}
                else if(global==schedule.durationMs){index=items.lastIndex;position=schedule.occurrences.last().source.durationMs}
            }
            state=output.playbackState
            // Midpoint publishes selection only. EOF keeps its captured outgoing occurrence identity.
            invalidateState()
            if(!current())return
            for(c in crossed) {
                completed+=c.source.occurrence
                val item=items.single {it.mediaId==c.source.occurrence}
                for(callback in completions.toList()) {
                    if(!current())return
                    callback(item)
                }
                if(!current() || transportRevision!=revision)return
                if(repeat==Player.REPEAT_MODE_ONE && intent) {
                    index=items.indexOfFirst {it.mediaId==c.source.occurrence};position=0;lastGlobal=c.startMs
                    // A source-local cycle must not revive earlier overlapping occurrences.
                    completed+=schedule.occurrences.filter {it.endMs<=c.endMs}.map {it.source.occurrence}
                    completed.remove(c.source.occurrence)
                    output.seekTo(c.startMs)
                    if(output.playbackState==Player.STATE_ENDED)output.prepare()
                    state=output.playbackState
                    invalidateState()
                    return
                }
            }
            if(crossed.isNotEmpty() && global==schedule.durationMs && repeat==Player.REPEAT_MODE_ALL && intent) {
                index=0;position=0;lastGlobal=0;completed.clear()
                output.seekTo(0)
                if(output.playbackState==Player.STATE_ENDED)output.prepare()
                state=output.playbackState
                invalidateState()
            }
        }finally {reconciling=false}
    }
}
