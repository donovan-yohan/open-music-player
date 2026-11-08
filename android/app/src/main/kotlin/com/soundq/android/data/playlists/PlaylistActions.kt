package com.soundq.android.data.playlists

/** Caller-owned destination actions; enqueue is supplied by the ViewModel's IO scope. */
class PlaylistActions(private val repository: PlaylistRepository, private val enqueue: (() -> Unit) -> Unit) {
    private val owner = repository.captureList()
    val capture: PlaylistListCapture? get() = owner?.let { repository.captureList(it) }
    fun reload() { owner?.let { repository.requestRead(it) }?.let(enqueue) }
    fun refine(query: PlaylistQuery) { owner?.let { repository.requestRead(it, query) }?.let(enqueue) }
    fun create(capture: PlaylistListCapture, draft: PlaylistDraft) { enqueue { repository.create(capture, draft) } }
    fun startNew(draft: PlaylistDraft) { owner?.let { repository.startNew(it, draft) } }
    fun close() { owner?.let { repository.retire(it) } }
}
