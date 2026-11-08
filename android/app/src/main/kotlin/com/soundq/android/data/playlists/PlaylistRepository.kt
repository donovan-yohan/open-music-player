package com.soundq.android.data.playlists

import com.soundq.android.data.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** Account and destination scoped playlist owner. Blocking calls run on the caller's IO dispatcher. */
class PlaylistRepository(private val api: SoundQApi) {
    private val mutable = MutableStateFlow(PlaylistState())
    val state: StateFlow<PlaylistState> = mutable
    private var lifetime = 0L
    private var readVersion = 0L
    private var readScope: AccountScope? = null
    private var pending: Any? = null
    private var intent = 0L
    @Synchronized fun captureList(): PlaylistListCapture? = api.session.capture()?.let { PlaylistListCapture(it, lifetime, intent) }
    @Synchronized fun captureList(owner: PlaylistListCapture): PlaylistListCapture? = if (owns(owner)) PlaylistListCapture(owner.scope, lifetime, intent) else null
    @Synchronized private fun owns(capture: PlaylistListCapture): Boolean = lifetime == capture.lifetime && api.session.current(capture.scope)
    @Synchronized fun retire() { lifetime++; readVersion++; readScope = null; pending = null; mutable.value = PlaylistState() }
    @Synchronized fun retire(capture: PlaylistListCapture) { if (owns(capture)) retire() }

    fun reload() { captureList()?.let { reload(it) } ?: retire() }
    fun reload(capture: PlaylistListCapture) { requestRead(capture)?.invoke() }
    /** Claim the query before enqueue, not from a mutable destination when IO eventually starts. */
    @Synchronized internal fun requestRead(capture: PlaylistListCapture, requested: PlaylistQuery? = null): (() -> Unit)? {
        if (!owns(capture) || pending != null) return null
        val replacement = readScope?.let { !api.session.current(it) } == true
        val before = if (replacement) PlaylistState() else mutable.value
        val query = requested ?: before.query
        if (!replacement && before.loading && query == before.query) return null
        val version = ++readVersion
        readScope = capture.scope
        mutable.value = before.copy(query = query, rows = if (query == before.query) before.rows else emptyList(),
            total = if (query == before.query) before.total else null,
            loading = true, error = null, reconciled = false, renewedDraft = null)
        return {
            fun current() = synchronized(this) { owns(capture) && readVersion == version }
            try {
                val page = readAll(capture.scope, query, ::current)
                synchronized(this) {
                    if (current()) {
                        val state = mutable.value
                        mutable.value = state.copy(rows = page.rows, total = page.total, loading = false,
                            reconciled = state.uncertainDraft != null,
                            mutation = if (state.mutation?.outcome == MutationOutcome.ReadbackFailed && state.created != null) PlaylistMutation(MutationOutcome.Confirmed) else state.mutation)
                    }
                }
            } catch (error: Exception) {
                synchronized(this) { if (current()) mutable.value = mutable.value.copy(loading = false, error = reason(error)) }
            } finally {
                synchronized(this) {
                    // A retired account may clear only its own admitted loading ticket, not a replacement.
                    if (lifetime == capture.lifetime && readVersion == version && !api.session.current(capture.scope)) {
                        readScope = null
                        mutable.value = PlaylistState()
                    }
                }
            }
        }
    }

    /** Atomic full-corpus publication. A failed/changed/nonadvancing page never looks complete. */
    private fun readAll(scope: AccountScope, query: PlaylistQuery, valid: () -> Boolean): PlaylistPage {
        val rows = mutableListOf<PlaylistSummary>()
        val seen = mutableSetOf<PlaylistId>()
        var total: Int? = null
        var limit = 20
        do {
            val page = api.browsePlaylists(scope, rows.size, query.text, query.sort.wire, if (query.ascending) "asc" else "desc", valid)
            if (total != null && page.total != total || rows.size.toLong() + page.rows.size > page.total ||
                page.rows.isEmpty() && rows.size < page.total || page.rows.any { !seen.add(it.id) }) {
                throw SafeFailure(SafeFailure.Reason.InvalidResponse)
            }
            total = page.total; limit = page.limit; rows.addAll(page.rows)
        } while (rows.size < total)
        return PlaylistPage(rows.toList(), total, limit, 0)
    }

    @Synchronized fun startNew(capture: PlaylistListCapture, draft: PlaylistDraft): PlaylistListCapture? {
        if (!owns(capture) || pending != null || !mutable.value.canStartNew(draft)) return null
        intent++
        mutable.value = mutable.value.copy(renewedDraft = draft)
        return PlaylistListCapture(capture.scope, lifetime, intent)
    }

    fun create(capture: PlaylistListCapture, draft: PlaylistDraft) {
        val receipt = Any()
        synchronized(this) {
            if (!owns(capture) || capture.intent != intent || pending != null || !mutable.value.canCreate(draft)) return
            pending = receipt; readVersion++; intent++
            mutable.value = mutable.value.copy(loading = false, error = null, created = null, mutation = PlaylistMutation(MutationOutcome.Pending))
        }
        fun current() = synchronized(this) { owns(capture) && pending === receipt }
        var accepted: PlaylistSummary? = null
        var outcome = MutationOutcome.Confirmed
        var failure: SafeFailure.Reason? = null
        try {
            accepted = api.createPlaylist(capture.scope, draft, ::current)
        } catch (error: Exception) {
            failure = reason(error)
            outcome = if (failure == SafeFailure.Reason.Refused) MutationOutcome.Refused else MutationOutcome.Uncertain
        }
        if (!current()) return
        if (accepted != null) {
            try {
                val page = readAll(capture.scope, mutable.value.query, ::current)
                synchronized(this) {
                    if (current()) mutable.value = mutable.value.copy(rows = page.rows, total = page.total)
                }
            } catch (_: Exception) { outcome = MutationOutcome.ReadbackFailed; failure = SafeFailure.Reason.Network }
        }
        synchronized(this) {
            if (!current()) return
            mutable.value = mutable.value.copy(created = accepted, mutation = PlaylistMutation(outcome), error = failure,
                uncertainDraft = if (outcome == MutationOutcome.Uncertain) draft else null,
                reconciled = false, renewedDraft = null)
            pending = null
        }
    }
    private fun reason(error: Exception): SafeFailure.Reason = (error as? SafeFailure)?.reason ?: SafeFailure.Reason.Network
}
