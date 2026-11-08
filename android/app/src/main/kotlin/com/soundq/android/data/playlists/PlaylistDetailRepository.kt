package com.soundq.android.data.playlists

import com.soundq.android.data.*
import com.soundq.android.playback.QueuePolicy
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** The detail route owns its reads and playback captures, not the player. */
data class PlaylistDetailState(val id: PlaylistId? = null, val detail: PlaylistDetail? = null, val loading: Boolean = false, val error: SafeFailure.Reason? = null)
class PlaylistDetailRequest internal constructor(internal val scope: AccountScope, internal val version: Long, val id: PlaylistId)
class PlaylistPlaybackCapture internal constructor(internal val scope: AccountScope, internal val version: Long, internal val detail: PlaylistDetail, internal val playbackVersion:Long)
class PlaylistDetailRepository(private val api: SoundQApi) {
    private val mutable = MutableStateFlow(PlaylistDetailState())
    val state: StateFlow<PlaylistDetailState> = mutable
    private var version = 0L
    private var playbackVersion=0L
    private var selected: PlaylistDetailRequest? = null
    @Synchronized fun select(id: PlaylistId): PlaylistDetailRequest? {
        val scope = api.session.capture() ?: return null
        version++
        mutable.value = PlaylistDetailState(id = id, loading = true)
        return PlaylistDetailRequest(scope, version, id).also { selected = it }
    }
    /** Preserve the accepted read but permanently revoke retained playback captures. */
    @Synchronized internal fun retirePlayback() {playbackVersion++}
    @Synchronized fun retire() { version++; selected = null; mutable.value = PlaylistDetailState() }
    @Synchronized fun capturePlayback(): PlaylistPlaybackCapture? {
        val request = selected ?: return null
        val detail = mutable.value.detail ?: return null
        if (!api.session.current(request.scope) || mutable.value.loading || mutable.value.error != null) return null
        return PlaylistPlaybackCapture(request.scope, version, detail,playbackVersion)
    }
    @Synchronized internal fun ownsPlayback(capture:PlaylistPlaybackCapture)=version==capture.version && playbackVersion==capture.playbackVersion && api.session.current(capture.scope) && mutable.value.detail===capture.detail
    @Synchronized fun play(capture: PlaylistPlaybackCapture, track: TrackId, consume: (List<Track>, Int) -> Unit): Boolean {
        if (!ownsPlayback(capture)) return false
        if (!QueuePolicy.acceptsContext(capture.detail.tracks.size)) return false
        val index = capture.detail.tracks.indexOfFirst { it.id == track }
        if (index < 0) return false
        consume(capture.detail.tracks.toList(), index)
        return true
    }
    /** Queue one original occurrence without interpreting Blend state or launching a context. */
    @Synchronized fun queue(capture:PlaylistPlaybackCapture,index:Int,track:Track,consume:(Track)->Unit):Boolean {
        if(!ownsPlayback(capture)||capture.detail.tracks.getOrNull(index)!==track)return false
        consume(track)
        return true
    }
    /** Feature-owned management may publish only into the exact acknowledged route it captured. */
    @Synchronized internal fun managementVersion(): Long = version
    @Synchronized internal fun managementDetail(): PlaylistDetail? = mutable.value.takeIf {
        selected?.let { request -> api.session.current(request.scope) } == true && !it.loading && it.error == null
    }?.detail
    @Synchronized internal fun ownsManagement(value: PlaylistDetail) = managementDetail() === value
    @Synchronized internal fun publishManagement(before: PlaylistDetail, after: PlaylistDetail?) {
        if (!ownsManagement(before)) return
        if (after == null) retire() else mutable.value = mutable.value.copy(detail = after, error = null, loading = false)
    }
    fun open(id: PlaylistId) { select(id)?.let(::load) }
    fun load(request: PlaylistDetailRequest) {
        fun owns() = synchronized(this) { selected === request && version == request.version && api.session.current(request.scope) }
        try {
            val detail = api.playlistDetail(request.scope, request.id, ::owns)
            synchronized(this) { if (owns()) mutable.value = PlaylistDetailState(id = request.id, detail = detail) }
        } catch (error: Exception) {
            synchronized(this) { if (owns()) mutable.value = PlaylistDetailState(id = request.id, error = (error as? SafeFailure)?.reason ?: SafeFailure.Reason.Network) }
        }
    }
}
