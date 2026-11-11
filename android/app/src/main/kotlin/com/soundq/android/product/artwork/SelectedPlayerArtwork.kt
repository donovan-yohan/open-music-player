package com.soundq.android.product.artwork

import android.graphics.Bitmap
import com.soundq.android.data.*
import com.soundq.android.playback.*
import com.soundq.android.data.timeline.globalEndMs
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import okhttp3.*

/** Resolve only accepted native source occurrences. In overlap, the latest-starting sounding source owns
 * the decorative slot; tied starts are ambiguous and refuse. Silence has no upcoming-source guess. */
internal fun selectedArtworkSource(p:PlaybackProjection):QueueOccurrence? {
    if(p.connection!=PlaybackProjection.Connection.Connected||p.localOnly||p.accountEpoch<0||
        p.sessionIdentity.isBlank()||p.sessionIdentity=="redacted"||p.sourceQueueIncarnation.isBlank())return null
    if(p.source==PlaybackSource.Queue)return p.queue.singleOrNull {it.occurrenceId==p.selectedOccurrence}
        ?.takeIf {it.trackId>0&&it.occurrenceId.isNotBlank()}
    if(p.source!=PlaybackSource.Arrangement)return null
    val accepted=p.arrangement ?: return null
    val id=accepted.identity
    if(id.accountEpoch!=p.accountEpoch||id.service!=p.arrangementService||id.service.isBlank()||
        id.queue!=p.sourceQueueIncarnation||id.install.isBlank()||id.install!=p.selectedOccurrence||id.revision<0)return null
    val clips=accepted.document.clips
    if(clips.isEmpty()||clips.size>500||clips.map {it.occurrence}.distinct().size!=clips.size)return null
    val sounding=p.performanceDecks.filter {(occurrence,deck)->
        deck.target.identity==id&&deck.target.occurrence==occurrence&&deck.playing
    }.keys
    val active=if(sounding.isNotEmpty())clips.filter {it.occurrence in sounding}
        else clips.filter {p.positionMs>=it.globalStartMs&&p.positionMs<it.globalEndMs}
    val start=active.maxOfOrNull {it.globalStartMs} ?: return null
    val clip=active.singleOrNull {it.globalStartMs==start} ?: return null
    return accepted.sources.singleOrNull {it.occurrenceId==clip.occurrence&&it.trackId==clip.track}
        ?.takeIf {it.trackId>0&&it.occurrenceId.isNotBlank()}
}

/** Selection adapter only. Acquisition, decode limits and paint are shared with ordinary rows. */
internal class SelectedPlayerArtwork(
    private val session:AccountSession,
    mediaClient:OkHttpClient,
    private val playback:StateFlow<PlaybackProjection>,
    private val track:(TrackId)->Track?,
    private val shared:LibraryArtwork,
    private val ownsShared:Boolean,
):AutoCloseable {
    constructor(session:AccountSession,mediaClient:OkHttpClient,playback:StateFlow<PlaybackProjection>,track:(TrackId)->Track?):
        this(session,mediaClient,playback,track,LibraryArtwork(session,mediaClient),true)
    companion object {
        const val MAX_LEASES=LibraryArtwork.MAX_PLAYERS
        const val MAX_BYTES=LibraryArtwork.MAX_BYTES
        const val MAX_SIDE=LibraryArtwork.PLAYER_SIDE
    }
    internal data class Selection(val account:Long,val service:String,val queue:String,val incarnation:Long,
        val occurrence:String,val track:Long,val source:PlaybackSource,val install:ArrangementIdentity?)
    private fun selection(p:PlaybackProjection):Selection? {
        val row=selectedArtworkSource(p) ?: return null
        return Selection(p.accountEpoch,p.sessionIdentity,p.sourceQueueIncarnation,p.selectionIncarnation,
            row.occurrenceId,row.trackId,p.source,p.arrangement?.identity)
    }
    private val leases=mutableSetOf<Lease>()
    private var closed=false
    private val observer=CoroutineScope(SupervisorJob()+Dispatchers.Default)
    init {observer.launch(start=CoroutineStart.UNDISPATCHED) {playback.collect {sweep()}}}
    private fun sweep() {synchronized(this){leases.toList()}.forEach {it.current()}}
    @Synchronized fun open(observed:PlaybackProjection,current:()->Boolean):Lease {
        sweep()
        val selected=selection(observed)
        val scope=session.capture()?.takeIf {it.epoch==selected?.account}
        val metadata=selected?.let {track(TrackId(it.track))?.takeIf {row->row.id.value==it.track}}
        val alive=java.util.concurrent.atomic.AtomicBoolean(!closed)
        val row=shared.openPlayer(scope,metadata) {
            alive.get()&&selected!=null&&selection(playback.value)==selected&&current()&&
                metadata!=null&&track(metadata.id)?.artwork==metadata.artwork
        }
        return Lease(row,alive).also {if(it.current())leases.add(it)}
    }
    internal inner class Lease internal constructor(private val row:LibraryArtwork.Row,
        private val alive:java.util.concurrent.atomic.AtomicBoolean):AutoCloseable {
        val state:StateFlow<Bitmap?> = row.state
        fun current():Boolean {if(!alive.get()||!row.current()){close();return false};return true}
        fun bitmap():Bitmap?=if(current())row.bitmap()else null
        fun start() {if(current())row.start()}
        override fun close() {alive.set(false);row.close();synchronized(this@SelectedPlayerArtwork){leases.remove(this)}}
    }
    override fun close() {
        val old=synchronized(this){if(closed)return;closed=true;leases.toList()}
        old.forEach {it.close()};observer.cancel();if(ownsShared)shared.close()
    }
}
internal fun decodePlayerArtwork(data:ByteArray):Bitmap?=decodeArtwork(data,SelectedPlayerArtwork.MAX_SIDE)
