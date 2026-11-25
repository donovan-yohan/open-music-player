package com.soundq.android.data.discovery

import com.soundq.android.data.SafeFailure
import com.soundq.android.data.catalog.ArtistMbid
import com.soundq.android.data.catalog.RecordingMbid
import com.soundq.android.data.catalog.ReleaseGroupMbid
import com.soundq.android.data.catalog.ReleaseMbid
import java.time.LocalDate
import java.util.UUID
import kotlinx.serialization.json.*
import okhttp3.HttpUrl

private const val ZERO_MBID = "00000000-0000-0000-0000-000000000000"
private const val PAGE_LIMIT = 20
private const val MAX_OFFSET = 10_000
private const val ARTIST_SEARCH_WINDOW = 500
private const val MBID_PATH = "[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"
private val browsePath = Regex("/(?:artists/$MBID_PATH/(?:discography|search|top-tracks)|release-groups/$MBID_PATH/editions|albums/$MBID_PATH/tracklist)")

internal fun isDiscoverBrowsePath(path: String): Boolean = browsePath.matches(path)

internal fun validDiscoverArtistQuery(query: String): Boolean = query.isNotBlank() &&
    query.toByteArray(Charsets.UTF_8).size <= 160 && query.none { it.isISOControl() }

/** No arbitrary path, URL, HTTP method or request body crosses the authenticated bridge. */
internal sealed class DiscoverBrowseRoute {
    enum class ReleaseType(val wire: String) { Album("album"), Single("single"), EP("ep") }
    enum class SearchKind(val wire: String) { Songs("song"), Albums("album") }

    data class Discography(val artist: ArtistMbid, val type: ReleaseType, val offset: Int) : DiscoverBrowseRoute() {
        init { require(artist.value != ZERO_MBID && offset in 0..MAX_OFFSET) }
    }
    data class ArtistSearch(val artist: ArtistMbid, val kind: SearchKind, val query: String, val offset: Int) : DiscoverBrowseRoute() {
        init { require(artist.value != ZERO_MBID && offset in 0 until ARTIST_SEARCH_WINDOW && validDiscoverArtistQuery(query)) }
    }
    data class Editions(val group: ReleaseGroupMbid, val offset: Int) : DiscoverBrowseRoute() {
        init { require(group.value != ZERO_MBID && offset in 0..MAX_OFFSET) }
    }
    data class Tracklist(val group: ReleaseGroupMbid, val edition: ReleaseMbid) : DiscoverBrowseRoute() {
        init { require(group.value != ZERO_MBID && edition.value != ZERO_MBID) }
    }
    data class TopTracks(val artist: ArtistMbid) : DiscoverBrowseRoute() {
        init { require(artist.value != ZERO_MBID) }
    }

    fun path(base: HttpUrl): String {
        fun paged(path: String, offset: Int, vararg extra: Pair<String, String>): String {
            val query = base.newBuilder().query(null).addQueryParameter("limit", PAGE_LIMIT.toString())
                .addQueryParameter("offset", offset.toString())
            extra.forEach { (key, value) -> query.addQueryParameter(key, value) }
            return "$path?${query.build().encodedQuery}"
        }
        return when (this) {
            is Discography -> paged("/artists/${artist.value}/discography", offset, "type" to type.wire)
            is ArtistSearch -> paged("/artists/${artist.value}/search", offset, "kind" to kind.wire, "q" to query)
            is Editions -> paged("/release-groups/${group.value}/editions", offset)
            is Tracklist -> "/albums/${edition.value}/tracklist"
            is TopTracks -> "/artists/${artist.value}/top-tracks"
        }
    }
}

internal data class DiscoverBrowsePage<T>(val rows: List<T>, val nextOffset: Int?, val truncated: Boolean)
internal data class DiscoverArtistCredit(val id: ArtistMbid, val name: String)
internal data class DiscoverReleaseGroupRow(
    val id: ReleaseGroupMbid, val title: String, val artist: String?, val primaryType: String?,
    val date: String?, val disambiguation: String?,
)
internal data class DiscoverBrowseSong(
    val recording: RecordingMbid, val title: String, val artist: String?, val durationMs: Long?,
    val listenCount: Long? = null,
)
internal data class DiscoverBrowseEdition(
    val id: ReleaseMbid, val group: ReleaseGroupMbid, val title: String, val artist: String?,
    val credits: List<DiscoverArtistCredit>, val date: String?, val country: String?, val status: String?,
    val disambiguation: String?, val discCount: Int, val formats: List<String>,
) {
    val label: String get() = listOfNotNull(disambiguation, date, country,
        formats.takeIf { it.isNotEmpty() }?.joinToString(" / "), status)
        .joinToString(" · ").ifBlank { "Edition ${id.value.take(8)}" }
}
internal data class DiscoverBrowseTrack(
    val id: String, val recording: RecordingMbid?, val title: String, val artist: String?,
    val durationMs: Long?, val disc: Int, val position: Int, val number: String?, val kind: String,
) {
    val audioRecording get() = recording.takeUnless { kind == "data" }
}
internal data class DiscoverBrowseTracklist(val edition: DiscoverBrowseEdition, val tracks: List<DiscoverBrowseTrack>)

/** Select once at entry. Never claim this is the original pressing or retarget on continuation. */
internal fun defaultDiscoverEdition(page: DiscoverBrowsePage<DiscoverBrowseEdition>): DiscoverBrowseEdition? {
    if (page.nextOffset == null && !page.truncated && page.rows.size == 1) return page.rows.single()
    return page.rows.filter { it.status == "Official" && it.discCount > 0 && it.date?.let { date ->
        runCatching { LocalDate.parse(date) }.isSuccess
    } == true }.minWithOrNull(compareBy({ it.date }, { it.id.value }))
}

internal object DiscoverBrowseJson {
    fun discography(body: JsonObject, route: DiscoverBrowseRoute.Discography) = decode {
        page(body, route.offset) { group(it) }
    }
    fun albums(body: JsonObject, route: DiscoverBrowseRoute.ArtistSearch) = decode {
        require(route.kind == DiscoverBrowseRoute.SearchKind.Albums)
        page(body, route.offset, ARTIST_SEARCH_WINDOW) { row -> requireCredit(row, route.artist); group(row) }
    }
    fun recordings(body: JsonObject, route: DiscoverBrowseRoute.ArtistSearch) = decode {
        require(route.kind == DiscoverBrowseRoute.SearchKind.Songs)
        page(body, route.offset, ARTIST_SEARCH_WINDOW) { row -> requireCredit(row, route.artist); song(row) }
    }
    fun editions(body: JsonObject, route: DiscoverBrowseRoute.Editions) = decode {
        page(body, route.offset) { edition(it).also { row -> require(row.group == route.group) } }
    }
    fun tracklist(body: JsonObject, route: DiscoverBrowseRoute.Tracklist) = decode {
        val edition = edition(body).also { require(it.group == route.group && it.id == route.edition) }
        val tracks = body.array("tracks", 4096).map { track(it.jsonObject) }
        require(body.integer("trackCount") == tracks.size && tracks.map { it.id }.toSet().size == tracks.size)
        require(tracks.map { it.disc }.toSet().size <= edition.discCount)
        require(tracks.zipWithNext().all { (a, b) -> a.disc < b.disc || (a.disc == b.disc && a.position < b.position) })
        DiscoverBrowseTracklist(edition, tracks)
    }
    fun topTracks(body: JsonObject) = decode {
        body.array("results", 100).map { element ->
            val row = element.jsonObject
            song(row).copy(listenCount = row.getValue("listenCount").numericLong().also { require(it > 0) })
        }.distinctBy { it.recording }
    }

    private fun <T> page(body: JsonObject, offset: Int, resultWindow: Int? = null, project: (JsonObject) -> T): DiscoverBrowsePage<T> {
        require(body.integer("offset") == offset && body.integer("limit") == PAGE_LIMIT)
        val total = body.integer("total").also { require(it >= 0) }
        val lastOffset = resultWindow?.let { it - 1 } ?: MAX_OFFSET
        val maxRows = resultWindow?.let { minOf(PAGE_LIMIT, it - offset) } ?: PAGE_LIMIT
        val rows = body.array("results", maxRows).map { project(it.jsonObject) }
        val end = offset + rows.size
        require(if (rows.isEmpty()) offset >= total else end <= total)
        val more = body.getValue("hasMore").strictBoolean()
        val truncated = body["truncated"]?.strictBoolean() ?: false
        val next = body["nextOffset"]?.integer()
        require(more == (end < total && end <= lastOffset) && truncated == (end < total && end > lastOffset))
        require(if (more) next == end && end > offset else next == null)
        return DiscoverBrowsePage(rows, next, truncated)
    }
    private fun group(row: JsonObject) = DiscoverReleaseGroupRow(
        ReleaseGroupMbid(row.id("releaseGroupMbid")), row.title(), row.optional("artist"),
        row.optional("primaryType"), row.optional("firstReleaseDate"), row.optional("disambiguation"),
    )
    private fun song(row: JsonObject) = DiscoverBrowseSong(
        RecordingMbid(row.id("recordingMbid")), row.title(), row.optional("artist"), row.duration(),
    )
    private fun edition(row: JsonObject) = DiscoverBrowseEdition(
        ReleaseMbid(row.id("releaseMbid")), ReleaseGroupMbid(row.id("releaseGroupMbid")),
        row.title(), row.optional("artist"), credits(row), row.optional("date"), row.optional("country"),
        row.optional("status"), row.optional("disambiguation"), row.integer("discCount").also { require(it in 0..256) },
        row["formats"]?.jsonArray?.also { require(it.size <= 256) }?.map { it.string() }.orEmpty(),
    )
    private fun track(row: JsonObject): DiscoverBrowseTrack {
        val kind = row.getValue("kind").string().also { require(it in setOf("track", "pregap", "data")) }
        val recording = row["recordingMbid"]?.let { RecordingMbid(row.id("recordingMbid")) }
        require(kind == "data" || recording != null)
        return DiscoverBrowseTrack(row.id("trackMbid"), recording, row.title(),
            row.optional("artist"), row.duration(), row.integer("discPosition").also { require(it > 0) },
            row.integer("trackPosition").also { require(if (kind == "pregap") it == 0 else it > 0) },
            row.optional("number"), kind)
    }
    private fun credits(row: JsonObject): List<DiscoverArtistCredit> = row["artistCredits"]?.jsonArray
        ?.map { it.jsonObject.let { credit -> DiscoverArtistCredit(ArtistMbid(credit.id("mbid")), credit.getValue("name").string()) } }
        .orEmpty()
    private fun requireCredit(row: JsonObject, artist: ArtistMbid) {
        // The producer already checked the full credit list before projecting its bounded slice.
        val truncated = row["artistCreditsTruncated"]?.strictBoolean() ?: false
        require(credits(row).any { it.id == artist } || truncated)
    }
    private fun JsonObject.array(key: String, max: Int) = getValue(key).jsonArray.also { require(it.size <= max) }
    private fun JsonObject.title() = getValue("title").string().also { require(it.isNotBlank()) }
    private fun JsonObject.id(key: String) = getValue(key).string().also {
        require(it != ZERO_MBID && UUID.fromString(it).toString() == it)
    }
    private fun JsonObject.optional(key: String) = this[key]?.string()?.takeIf { it.isNotBlank() }
    private fun JsonObject.integer(key: String) = getValue(key).integer()
    private fun JsonObject.duration() = this["duration"]?.numericLong()?.also { require(it >= 0) }
    private fun JsonElement.string() = jsonPrimitive.also { require(it.isString) }.content
    private fun JsonElement.integer() = jsonPrimitive.also { require(!it.isString) }.int
    private fun JsonElement.numericLong() = jsonPrimitive.also { require(!it.isString) }.long
    private fun JsonElement.strictBoolean() = jsonPrimitive.also { require(!it.isString) }.boolean
    private inline fun <T> decode(block: () -> T): T = try { block() }
    catch (_: Exception) { throw SafeFailure(SafeFailure.Reason.InvalidResponse) }
}
