package com.soundq.nativepreview

import org.json.JSONArray
import org.json.JSONObject

/** Transient read admission only. The core snapshot remains row/favorite/queue truth. */
internal class LibraryBrowseState {
    data class RowOwner(val epoch: Long, val session: Long, val revision: Long)
    data class Identity(val liked: Boolean, val query: String, val sort: String = "added_at", val order: String = "desc")
    data class Read(val serial: Long, val account: Long, val epoch: Long, val identity: Identity, val offset: Int)
    private var serial = 0L
    private var account = -1L
    private var revision: Long? = null
    private var acknowledged: Identity? = null
    private var favoriteEpoch = -1L
    private var favoriteWasLiked = false
    private var appendValid = false
    var pending: Read? = null
        private set
    var favoritePending = false
        private set
    var invalid = false
        private set
    var failure: String? = null
        private set
    val liked get() = acknowledged?.liked == true
    val query get() = acknowledged?.query ?: ""
    val loading get() = pending != null
    val hasRead get() = acknowledged != null

    fun retire() {
        if (pending != null || favoritePending) invalid = true
        pending = null
        favoritePending = false
    }

    fun owns(snapshot: JSONObject, owner: RowOwner): Boolean =
        snapshot.optLong("epoch") == owner.epoch && snapshot.optLong("session") == owner.session &&
            snapshot.optLong("library_revision") == owner.revision

    fun rowOwner(snapshot: JSONObject) = RowOwner(snapshot.optLong("epoch"),snapshot.optLong("session"),snapshot.optLong("library_revision"))

    fun canUseRows(snapshot: JSONObject, epoch: Long): Boolean =
        snapshot.optBoolean("authenticated") && snapshot.optLong("epoch") == epoch &&
            pending == null && !invalid && !favoritePending && revision != null

    fun begin(snapshot: JSONObject, epoch: Long, scope: Long, identity: Identity, offset: Int): Read? {
        if (!snapshot.optBoolean("authenticated") || snapshot.optLong("epoch") != epoch || loading || favoritePending) return null
        account = scope
        val page = if (!invalid && appendValid && acknowledged == identity) offset.coerceAtLeast(0) else 0
        return Read(++serial, scope, epoch, identity, page).also { pending = it; failure = null }
    }

    /** Called before the command's snapshot publication, not from a UI timer. */
    fun finish(read: Read, result: JSONObject, epoch: Long, scope: Long): Boolean {
        if (pending != read || read.epoch != epoch || read.account != scope) return false
        pending = null
        val next = result.optJSONObject("snapshot")
        if (result.optBoolean("ok") && next != null && next.optBoolean("authenticated") &&
            next.optLong("epoch") == epoch && !next.optBoolean("library_unchanged") && next.has("library_revision")) {
            acknowledged = read.identity
            revision = next.optLong("library_revision")
            appendValid = true
            invalid = false
            failure = null
        } else {
            val code = result.optString("code").ifBlank { "binding_failure" }
            if (code == "invalid_query") appendValid = false
            failure = if (code == "invalid_query" && read.identity.query.toByteArray(Charsets.UTF_8).size <= 512)
                "This Library page is no longer current. Refresh Library to continue."
            else feedback(code)
        }
        return true
    }

    fun beginFavorite(snapshot: JSONObject, epoch: Long, id: Long, expected: Boolean): Boolean {
        if (!canUseRows(snapshot, epoch) || !contains(snapshot, id) || favorite(snapshot, id) != expected) return false
        favoritePending = true
        favoriteEpoch = epoch
        favoriteWasLiked = expected
        failure = null
        return true
    }

    fun finishFavorite(result: JSONObject) {
        favoritePending = false
        val next = result.optJSONObject("snapshot")
        if (result.optBoolean("ok") && next != null && next.optBoolean("authenticated") &&
            next.optLong("epoch") == favoriteEpoch && !next.optBoolean("library_unchanged") && next.has("library_revision")) {
            revision = next.optLong("library_revision")
            // Core retains acknowledged rows but revokes the Liked append query
            // after successful Unlike. Restart the next read; never skip rows.
            if (liked && favoriteWasLiked) appendValid = false
            failure = null
        } else {
            val code = result.optString("code")
            // An uncertain mutation is never retried by toggling an old heart.
            if (code == "favorite_uncertain" || code == "binding_failure") invalid = true
            failure = feedback(code)
        }
    }

    /** Preserve accepted display when a retired read has committed inside the core. */
    fun reconcile(previous: JSONObject, incoming: JSONObject, epoch: Long, scope: Long): JSONObject {
        if (account != scope || !incoming.optBoolean("authenticated")) {
            account = scope; pending = null; favoritePending = false; acknowledged = null
            revision = null; invalid = false; failure = null; appendValid = false
        }
        pending?.let { if (it.epoch != epoch || it.account != scope) { pending = null; invalid = true } }
        if (favoritePending && favoriteEpoch != epoch) { favoritePending = false; invalid = true }
        if (incoming.optBoolean("authenticated")) {
            val marker = if (incoming.has("library_revision")) incoming.optLong("library_revision") else null
            if (revision == null && !invalid && !loading) revision = marker
            if (revision != null && marker != revision) invalid = true
            if (invalid) {
                incoming.put("library", previous.optJSONArray("library") ?: JSONArray())
                    .put("total", previous.optLong("total")).put("offset", previous.optInt("offset"))
                    .put("library_revision", revision ?: 0L)
                // Retain acknowledged heart paint, never mutation authority.
                // canUseRows refuses all row actions until a read reconciles.
                incoming.put("favorite_track_ids",previous.optJSONArray("favorite_track_ids") ?: JSONArray())
            }
        }
        return incoming
    }

    companion object {
        fun contains(snapshot: JSONObject, id: Long): Boolean {
            val rows = snapshot.optJSONArray("library") ?: return false
            return (0 until rows.length()).any { rows.getJSONObject(it).optLong("id") == id }
        }
        fun favorite(snapshot: JSONObject, id: Long): Boolean {
            val ids = snapshot.optJSONArray("favorite_track_ids") ?: return false
            return (0 until ids.length()).any { ids.optLong(it) == id }
        }
        fun feedback(code: String): String = when (code) {
            "invalid_query" -> "Search is too long. Shorten it and search again."
            "unauthenticated", "authentication_failed" -> "Your session needs attention. Sign in again."
            "favorite_uncertain", "binding_failure" -> "Couldn't confirm the change. Refresh Library before trying again."
            "command_backpressure" -> "Playback is busy. Try again shortly."
            "network_unavailable", "api_unavailable" -> "Can't reach your music server. Check your connection, then refresh."
            "api_refused", "forbidden" -> "The server refused this request. Refresh or sign in again."
            "invalid_saved_queue", "queue_storage_failed", "cache_io" -> "Couldn't save the listening queue. Check available storage and try again."
            "native_playback_failed", "audio_failed", "playback_failed" -> "Couldn't play this track. Try playback again."
            else -> "Couldn't complete this request. Refresh Library or try playback again."
        }
    }
}
