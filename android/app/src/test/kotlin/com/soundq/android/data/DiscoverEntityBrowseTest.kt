package com.soundq.android.data

import com.soundq.android.data.catalog.ArtistMbid
import com.soundq.android.data.catalog.ReleaseGroupMbid
import com.soundq.android.data.catalog.ReleaseMbid
import com.soundq.android.data.discovery.DiscoverBrowseJson
import com.soundq.android.data.discovery.DiscoverBrowseRoute
import com.soundq.android.data.discovery.defaultDiscoverEdition
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Test

class DiscoverEntityBrowseTest {
    private val artist = ArtistMbid("821797e1-94c0-4e9c-88be-b49f971ada3b")
    private val other = ArtistMbid("d582fe36-46d3-4cc7-b6b2-64fed090b1f0")
    private val group = ReleaseGroupMbid("b139f140-6a40-4dd5-af24-d7df33beb6a9")
    private val edition = ReleaseMbid("4d7b84cb-78e2-4c5d-9c00-29f7fe52cd21")
    private val alternate = ReleaseMbid("b0fe46b5-fd0c-466e-9a50-007a527c734a")
    private val recording = "7c50feaa-cd49-4887-9904-309e67c27870"
    private val base = "https://fixture.invalid/api/v1".toHttpUrl()
    private fun json(raw: String) = Json.parseToJsonElement(raw).jsonObject
    private fun editionFields(id: ReleaseMbid, date: String, status: String = "Official") = """
        "releaseMbid":"${id.value}","releaseGroupMbid":"${group.value}","title":"Record",
        "artist":"Same Name","artistCredits":[{"mbid":"${artist.value}","name":"Same Name"}],
        "date":"$date","country":"GB","status":"$status","discCount":2,"formats":["CD"],
        "coverArtUrl":"https://coverartarchive.org/release/${id.value}/front-250"
    """.trim()

    @Test fun scopedSearchEncodesLiteralAndUsesCanonicalArtist() {
        val text = "a+b & B \"#\" / 東京"
        val route = DiscoverBrowseRoute.ArtistSearch(artist, DiscoverBrowseRoute.SearchKind.Songs, text, 7)
        val result = (base.toString() + route.path(base)).toHttpUrl()
        assertEquals("/api/v1/artists/${artist.value}/search", result.encodedPath)
        assertEquals(text, result.queryParameter("q"))
        assertEquals("song", result.queryParameter("kind"))
        assertEquals("7", result.queryParameter("offset"))
        assertEquals("20", result.queryParameter("limit"))
        assertThrows(IllegalArgumentException::class.java) { route.copy(query = "夜".repeat(54)) }
    }

    @Test fun sameDisplayArtistIsNotTheScopedArtistAndOffsetsFollowTheWire() {
        val route = DiscoverBrowseRoute.ArtistSearch(artist, DiscoverBrowseRoute.SearchKind.Songs, "Echo", 7)
        fun body(credit: ArtistMbid, next: Int) = json("""{"results":[{"recordingMbid":"$recording","title":"Echo","artist":"Same Name","artistCredits":[{"mbid":"${credit.value}","name":"Same Name"}]}],"offset":7,"limit":20,"total":15,"hasMore":true,"nextOffset":$next}""")
        val page = DiscoverBrowseJson.recordings(body(artist, 8), route)
        assertEquals(recording, page.rows.single().recording.value)
        assertEquals(8, page.nextOffset)
        assertThrows(SafeFailure::class.java) { DiscoverBrowseJson.recordings(body(other, 8), route) }
        assertThrows(SafeFailure::class.java) { DiscoverBrowseJson.recordings(body(artist, 27), route) }
    }

    @Test fun scopedSearchRecognizesTheFinalProviderPageWithoutRequestingAnImpossibleOffset() {
        val route = DiscoverBrowseRoute.ArtistSearch(artist, DiscoverBrowseRoute.SearchKind.Songs, "Echo", 499)
        val row = """{"recordingMbid":"$recording","title":"Echo","artistCredits":[{"mbid":"${artist.value}","name":"Artist"}]}"""
        val terminal = """{"results":[$row],"offset":499,"limit":20,"total":600,"hasMore":false,"truncated":true}"""
        val page = DiscoverBrowseJson.recordings(json(terminal), route)
        assertNull(page.nextOffset)
        assertTrue(page.truncated)
        assertThrows(IllegalArgumentException::class.java) { route.copy(offset = 500) }
        assertThrows(SafeFailure::class.java) {
            DiscoverBrowseJson.recordings(json(terminal.replace("$row]", "$row,$row]")), route)
        }
        assertEquals(500, DiscoverBrowseRoute.Discography(artist, DiscoverBrowseRoute.ReleaseType.Album, 500).offset)
    }

    @Test fun editionSelectionIsConcreteLabeledAndNeverSilentlyResolvesAnUndatedAmbiguity() {
        val route = DiscoverBrowseRoute.Editions(group, 0)
        fun page(first: String, second: String) = DiscoverBrowseJson.editions(json("""
            {"results":[{${editionFields(edition, first)}},{${editionFields(alternate, second)}}],"offset":0,"limit":20,"total":2,"hasMore":false}
        """), route)
        val distinct = page("2020-04-03", "1999-03-02")
        val selected = defaultDiscoverEdition(distinct)!!
        assertEquals(alternate, selected.id)
        assertTrue(selected.label.contains("1999-03-02"))
        assertNull(defaultDiscoverEdition(page("2020", "1999")))
        assertEquals("/albums/${alternate.value}/tracklist", DiscoverBrowseRoute.Tracklist(group, selected.id).path(base))
    }

    @Test fun completeEditionKeepsPlacementAndNonAudioRowsAndRejectsAnotherEdition() {
        val trackOne = "4e4e1016-4c0c-417b-ab7c-c4db1098a551"
        val trackTwo = "4e4e1016-4c0c-417b-ab7c-c4db1098a552"
        val dataTrack = "4e4e1016-4c0c-417b-ab7c-c4db1098a553"
        val body = json("""{${editionFields(edition,"2020-04-03")},"trackCount":3,"tracks":[
            {"trackMbid":"$trackOne","recordingMbid":"$recording","discPosition":1,"trackPosition":1,"number":"A1","kind":"track","title":"Echo","duration":123456},
            {"trackMbid":"$dataTrack","discPosition":1,"trackPosition":2,"kind":"data","title":"Video"},
            {"trackMbid":"$trackTwo","recordingMbid":"$recording","discPosition":2,"trackPosition":1,"kind":"track","title":"Echo"}
        ]}""")
        val list = DiscoverBrowseJson.tracklist(body, DiscoverBrowseRoute.Tracklist(group, edition))
        assertEquals(listOf(trackOne, dataTrack, trackTwo), list.tracks.map { it.id })
        assertEquals(listOf(1, 1, 2), list.tracks.map { it.disc })
        assertEquals("A1", list.tracks.first().number)
        assertNull(list.tracks[1].audioRecording)
        assertEquals(list.tracks.first().audioRecording, list.tracks.last().audioRecording)
        assertNull(list.tracks.last().durationMs)
        assertThrows(SafeFailure::class.java) { DiscoverBrowseJson.tracklist(body, DiscoverBrowseRoute.Tracklist(group, alternate)) }
    }

    @Test fun topTracksPreserveProducerRankingIncludingUnknownDuration() {
        val rows = DiscoverBrowseJson.topTracks(json("""{"results":[{"recordingMbid":"$recording","title":"Most played","listenCount":41},{"recordingMbid":"${alternate.value}","title":"Next","duration":150000,"listenCount":19}]}"""))
        assertEquals(listOf("Most played", "Next"), rows.map { it.title })
        assertEquals(listOf(41L, 19L), rows.map { it.listenCount })
        assertNull(rows.first().durationMs)
    }
}
