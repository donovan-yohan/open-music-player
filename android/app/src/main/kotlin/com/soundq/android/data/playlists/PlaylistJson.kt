package com.soundq.android.data.playlists

import com.soundq.android.data.SafeFailure
import com.soundq.android.data.Track
import com.soundq.android.data.TrackId
import kotlinx.serialization.json.*

/** Go playlist DTOs use camelCase (Library has a separate snake_case contract). */
internal object PlaylistJson {
    fun draft(value: PlaylistDraft): JsonObject = buildJsonObject {
        put("name", value.name); put("description", value.description)
        put("coverUrl", value.coverUrl); put("isPublic", value.isPublic)
    }
    fun summary(body: JsonObject): PlaylistSummary = checked {
        PlaylistSummary(
            PlaylistId(scalar(body, "id").long),
            PlaylistDraft(string(body, "name"),
                optionalString(body, "description"),
                optionalString(body, "coverUrl"),
                scalar(body, "isPublic").boolean),
            scalar(body, "trackCount").int,
            scalar(body, "durationMs").long,
        ).also { require(it.trackCount >= 0 && it.durationMs >= 0) }
    }
    fun page(body: JsonObject, offset: Int): PlaylistPage = checked {
        PlaylistPage(body.getValue("data").jsonArray.map { summary(it.jsonObject) },
            body.getValue("total").jsonPrimitive.int,
            body.getValue("limit").jsonPrimitive.int,
            body.getValue("offset").jsonPrimitive.int).also {
            require(it.total >= 0 && it.limit in 1..500 && it.offset == offset && it.rows.size <= it.limit)
            require(it.rows.map { row -> row.id }.distinct().size == it.rows.size)
        }
    }
    fun detail(body: JsonObject, id: PlaylistId): PlaylistDetail = checked {
        val playlist = summary(body)
        require(playlist.id == id)
        val tracks = body.getValue("tracks").jsonArray.map { value ->
            val track = value.jsonObject
            Track(TrackId(scalar(track, "id").long), string(track, "title"),
                optionalString(track, "artist"), optionalString(track, "album"),
                if ("durationMs" in track) scalar(track, "durationMs").long else 0).also { require(it.durationMs >= 0) }
        }
        require(tracks.map { it.id }.distinct().size == tracks.size && tracks.size == playlist.trackCount)
        val seeds = body.getValue("tracks").jsonArray.mapNotNull { value ->
            val track = value.jsonObject
            val summary = track["analysisSummary"] as? JsonObject ?: return@mapNotNull null
            val bpm = ((summary["bpm"] as? JsonObject)?.get("value") as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull?.takeIf { it.isFinite() && it > 0 }
            val key = ((summary["camelot"] as? JsonObject)?.get("value") as? JsonPrimitive)?.takeIf { it.isString }?.content
            TrackId(scalar(track,"id").long) to PlaylistAnalysisSeed(bpm,key)
        }.toMap()
        val canManage = if ("canManage" in body) scalar(body, "canManage").boolean else !playlist.draft.isPublic
        PlaylistDetail(playlist, tracks, seeds, canManage)
    }
    /** This decoder is deliberately for a single distinct ID, not the batch repetition contract. */
    fun singleAdd(body: JsonObject, id: PlaylistId, track: TrackId): PlaylistAddAck = checked {
        fun ids(key: String) = body.getValue(key).jsonArray.map {
            val value = it.jsonPrimitive
            require(value !== JsonNull && !value.isString)
            TrackId(value.long)
        }
        val added = ids("added"); val skipped = ids("skipped")
        require(added + skipped == listOf(track))
        val playlist = summary(body.getValue("playlist").jsonObject)
        require(playlist.id == id && playlist.trackCount >= 1)
        PlaylistAddAck(playlist, added, skipped)
    }
    private fun scalar(body: JsonObject, key: String): JsonPrimitive = body.getValue(key).jsonPrimitive.also {
        require(it !== JsonNull && !it.isString)
    }
    private fun string(body: JsonObject, key: String): String = body.getValue(key).jsonPrimitive.let {
        require(it.isString); it.content
    }
    private fun optionalString(body: JsonObject, key: String): String = if (key in body) string(body, key) else ""
    private inline fun <T> checked(block: () -> T): T = try { block() }
    catch (_: Exception) { throw SafeFailure(SafeFailure.Reason.InvalidResponse) }
}
