package com.soundq.android.data

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl

/** Build-time identity; never a user-editable navigation setting. */
class ApiEndpoint private constructor(val base: HttpUrl) {
    val identity: String get() = base.toString().removeSuffix("/")
    companion object {
        fun parse(value: String): ApiEndpoint {
            require(value.isNotEmpty() && value.none { it.isWhitespace() || it.code < 32 || it.code == 127 || it in "\\\\?#@%" })
            require(Regex("^https://[^/]+/api/v1/?$").matches(value))
            val url = value.toHttpUrl()
            require(url.scheme == "https" && url.username.isEmpty() && url.password.isEmpty() && url.encodedPath in listOf("/api/v1", "/api/v1/"))
            return ApiEndpoint(url)
        }
    }
}
@JvmInline value class TrackId(val value: Long) { init { require(value > 0) } }
@JvmInline value class OccurrenceId(val value: String) { init { require(value.isNotBlank()) } }
data class Track(val id: TrackId, val title: String, val artist: String = "", val album: String = "", val durationMs: Long = 0, val liked: Boolean? = null, val artwork: String? = null)
enum class LibrarySort(val wire: String) { Added("added_at"), Title("title"), Artist("artist"), Duration("duration") }
data class LibraryQuery(val text: String = "", val sort: LibrarySort = LibrarySort.Added, val ascending: Boolean = false, val liked: Boolean = false, val verified: Boolean? = null, val genre: String = "", val collection: LibraryCollection? = null)
data class LibraryAnalysisFacts(val status:String?=null,val bpm:Double?=null,val musicalKey:String?=null,val camelot:String?=null)
data class LibraryPage(val tracks: List<Track>, val total: Int, val limit: Int, val offset: Int, internal val scannedIds:List<Long> = tracks.map {it.id.value}, val analysis:Map<TrackId,LibraryAnalysisFacts> = emptyMap())
enum class MutationOutcome { Pending, Confirmed, Refused, Uncertain, ReadbackFailed }
class SafeFailure(val reason: Reason) : java.io.IOException(reason.message) {
    enum class Reason(val message: String) {
        Retired("Session changed. Sign in again."), Endpoint("Server configuration is invalid."),
        Refused("The server refused this request."), Network("Could not reach the server."),
        Uncertain("Not confirmed. Reload before trying again."), Storage("Session could not be saved securely. Retry saving."),
        StoreRejected("Saved session is unreadable or belongs to another server. It has not been changed."),
        ServiceUnavailable("This server feature is disabled or temporarily unavailable."), Capacity("The server research capacity is exhausted. Try again later."),
        InvalidResponse("The server returned an invalid response."), AudioUnavailable("Audio is unavailable for this track.")
    }
    override fun toString(): String = "SoundQ: ${reason.message}"
}
/** Deliberately not a data class: no token-bearing debug output. */
class SecretTokens(val access: String, val refresh: String, val accountId: String) {
    init { require(access.isNotBlank() && refresh.isNotBlank() && accountId.isNotBlank()) }
    override fun toString(): String = "SecretTokens([redacted])"
}
interface SessionStore {
    fun load(endpoint: ApiEndpoint): SecretTokens?
    fun save(endpoint: ApiEndpoint, tokens: SecretTokens)
    fun clear()
}
sealed interface AuthState {
    data object Restoring : AuthState
    /** Local app gate only. Never server-authenticated authority. */
    data object LocalLocked : AuthState
    data class SignedOut(val error: SafeFailure.Reason? = null, val uncertain: Boolean = false) : AuthState
    data object Pending : AuthState
    data class SaveRequired(val reason: SafeFailure.Reason = SafeFailure.Reason.Storage) : AuthState
    data class SignedIn(val accountId: String) : AuthState
    /** Accepted device identity only; never proof of a live server session. */
    data class DeviceOnly(val accountId: String) : AuthState
}
