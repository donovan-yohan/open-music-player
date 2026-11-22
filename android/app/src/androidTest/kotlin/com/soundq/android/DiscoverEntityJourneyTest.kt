package com.soundq.android

import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.soundq.android.data.catalog.ArtistMbid
import com.soundq.android.data.catalog.RecordingMbid
import com.soundq.android.data.catalog.ReleaseGroupMbid
import com.soundq.android.data.catalog.ReleaseMbid
import com.soundq.android.data.discovery.DiscoverBrowseRoute
import com.soundq.android.product.discovery.*
import com.soundq.designsystem.SoundQTheme
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Composes the production detail subtree against deterministic metadata only: no account, image or audio network. */
class DiscoverEntityJourneyTest {
    @get:Rule val compose = createComposeRule()
    private val artist = ArtistMbid("821797e1-94c0-4e9c-88be-b49f971ada3b")
    private val group = ReleaseGroupMbid("b139f140-6a40-4dd5-af24-d7df33beb6a9")
    private val original = ReleaseMbid("4d7b84cb-78e2-4c5d-9c00-29f7fe52cd21")
    private val alternate = ReleaseMbid("b0fe46b5-fd0c-466e-9a50-007a527c734a")
    private val recording = RecordingMbid("7c50feaa-cd49-4887-9904-309e67c27870")
    private val calls = CopyOnWriteArrayList<DiscoverBrowseRoute>()
    private val previews = CopyOnWriteArrayList<Pair<Any, RecordingMbid>>()
    private val adds = CopyOnWriteArrayList<Pair<Any, RecordingMbid>>()
    private val actions = object : EntityBrowseActions {
        override val canActivate = true
        override val canAdd = true
        override fun pending(row: Any) = false
        override fun preview(row: Any, recording: RecordingMbid, title: String, artist: String, current: () -> Boolean) {
            if (current()) previews.add(row to recording)
        }
        override fun add(row: Any, recording: RecordingMbid, current: () -> Boolean) {
            if (current()) adds.add(row to recording)
        }
    }

    private fun page(rows: List<String> = emptyList(), offset: Int = 0, total: Int = rows.size): String {
        val more = offset + rows.size < total
        val next = if (more) ",\"nextOffset\":${offset + rows.size}" else ""
        return """{"results":[${rows.joinToString()}],"offset":$offset,"limit":20,"total":$total,"hasMore":$more$next}"""
    }
    private fun groupRow(id: String, title: String) = """
        {"releaseGroupMbid":"$id","title":"$title","artist":"Same Name","primaryType":"Album",
         "firstReleaseDate":"1998","artistCredits":[{"mbid":"${artist.value}","name":"Same Name"}],"coverArtUrl":""}
    """.trim()
    private fun editionFields(id: ReleaseMbid, year: Int, discs: Int) = """
        "releaseMbid":"${id.value}","releaseGroupMbid":"${group.value}","title":"Exact Album",
        "artist":"Same Name","artistCredits":[{"mbid":"${artist.value}","name":"Same Name"}],
        "date":"$year-01-02","country":"GB","status":"Official","discCount":$discs,"formats":["CD"],"coverArtUrl":""
    """.trim()
    private fun track(id: String, title: String, disc: Int, position: Int, audio: Boolean = true) = """
        {"trackMbid":"$id","title":"$title","discPosition":$disc,"trackPosition":$position,
         "kind":"${if (audio) "track" else "data"}"${if (audio) ",\"recordingMbid\":\"${recording.value}\"" else ""}}
    """.trim()
    private fun trackId(index: Int) = "4e4e1016-4c0c-417b-ab7c-c4db1098a55$index"
    private fun tracklist(id: ReleaseMbid): String {
        val isOriginal = id == original
        val rows = if (isOriginal) listOf(track(trackId(1), "Original track", 1, 1)) else listOf(
            track(trackId(2), "First appearance", 1, 1), track(trackId(3), "Video data", 1, 2, audio = false),
            track(trackId(4), "Second appearance", 2, 1))
        return """{${editionFields(id, if (isOriginal) 1998 else 2012, if (isOriginal) 1 else 2)},"trackCount":${rows.size},"tracks":[${rows.joinToString()}]}"""
    }
    private fun mount(initial: EntityDestination, topGate: CountDownLatch? = null,
        visible: MutableState<Boolean>? = null, surface: MutableState<RadarArtworkRoute>? = null,
    ) {
        val nav = EntityBrowseNavigation(initial) { true }
        compose.setContent {
            SoundQTheme {
                DiscoverEntityBrowseContent(nav, originCurrent = visible?.value ?: true, mediaClient = null,
                    actions, onExit = {}, surfaceRoot = surface?.value) { route, _, current ->
                    check(current())
                    calls.add(route)
                    val body = when (route) {
                        is DiscoverBrowseRoute.TopTracks -> {
                            if (topGate != null && !topGate.await(10, TimeUnit.SECONDS)) error("Unreleased top-track fixture")
                            """{"results":[{"recordingMbid":"${recording.value}","title":"Top track fixture","listenCount":20}]}"""
                        }
                        is DiscoverBrowseRoute.Discography -> {
                            check(route.artist == artist)
                            when {
                                route.type != DiscoverBrowseRoute.ReleaseType.Album -> page()
                                route.offset == 0 -> page((1..6).map { groupRow("4e4e1016-4c0c-417b-ab7c-c4db1098a56$it", "Collection Album $it") }, total = 7)
                                route.offset == 6 -> page(listOf(groupRow(group.value, "Continued Album")), 6, 7)
                                else -> error("Unexpected discography offset")
                            }
                        }
                        is DiscoverBrowseRoute.ArtistSearch -> {
                            check(route.artist == artist && route.query == "Exact Album" && route.offset == 0)
                            if (route.kind == DiscoverBrowseRoute.SearchKind.Albums) page(listOf(groupRow(group.value,"Exact Album"))) else page()
                        }
                        is DiscoverBrowseRoute.Editions -> {
                            check(route.group == group && route.offset == 0)
                            page(listOf("{${editionFields(original,1998,1)}}", "{${editionFields(alternate,2012,2)}}"))
                        }
                        is DiscoverBrowseRoute.Tracklist -> { check(route.group == group); tracklist(route.edition) }
                    }
                    Json.parseToJsonElement(body).jsonObject
                }
            }
        }
    }
    private fun waitFor(matcher: SemanticsMatcher) {
        compose.waitUntil(5_000) { compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty() }
    }
    private fun scroll(tag: String, matcher: SemanticsMatcher): SemanticsNodeInteraction {
        compose.onNodeWithTag(tag).performScrollToNode(matcher)
        return compose.onNode(matcher)
    }

    @Test fun artistReadsIndependentlyPaginatesAndReturnsToItsSameScopedDraft() {
        val held = CountDownLatch(1)
        val initial = EntityArtist(artist, "Same Name")
        try {
            mount(initial, held)
            compose.waitUntil(5_000) { calls.any { it is DiscoverBrowseRoute.TopTracks } }
            waitFor(hasText("Collection Album 1"))
            compose.onNodeWithText("Top track fixture").assertDoesNotExist()
            assertTrue(calls.none { it is DiscoverBrowseRoute.Tracklist })
            held.countDown()
            val more = hasContentDescription("View all Albums")
            scroll("discover-artist-list", more).performClick()
            scroll("discover-artist-shelf", hasText("Show more albums")).performClick()
            compose.waitUntil(5_000) { initial.albums.rows.any { it.id == group } }
            scroll("discover-artist-shelf", hasText("Continued Album")).assertIsDisplayed()
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithContentDescription("Search this artist").performTextInput("Exact Album")
            val album = hasText("Exact Album") and hasClickAction() and !hasSetTextAction()
            waitFor(album)
            compose.waitUntil(5_000) { calls.count { it is DiscoverBrowseRoute.ArtistSearch } == 2 }
            compose.onNode(album).performClick()
            waitFor(hasText("Exact Album") and !hasSetTextAction())
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNode(album).assertIsDisplayed()
            compose.onNodeWithContentDescription("Clear artist search").performClick()
            scroll("discover-artist-list", hasText("MusicBrainz ID: ${artist.value}")).assertIsDisplayed()
            assertEquals(1, calls.count { it is DiscoverBrowseRoute.Discography && it.type == DiscoverBrowseRoute.ReleaseType.Album && it.offset == 0 })
            assertEquals(2, calls.count { it is DiscoverBrowseRoute.ArtistSearch })
        } finally { held.countDown() }
    }

    @Test fun directAlbumSwitchesExactEditionAndKeepsUnplayablePlacements() {
        val initial = EntityAlbum(group, "Exact Album", "Same Name", null)
        val visible = mutableStateOf(true)
        val surface = mutableStateOf(RadarArtworkRoute())
        mount(initial, visible = visible, surface = surface)
        val selector = hasContentDescription("Choose edition")
        waitFor(selector)
        compose.waitUntil(5_000) { initial.trackPage?.details?.accepted == true }
        scroll("discover-album-list", hasText("Original track")).assertIsDisplayed()
        scroll("discover-album-list", selector).performClick()
        compose.onNodeWithText("2012-01-02 · GB · CD · Official").performClick()
        val alternateLabel = hasText("Edition · 2012-01-02 · GB · CD · Official")
        waitFor(alternateLabel)
        compose.waitUntil(5_000) { initial.trackPage?.let { it.edition.id == alternate && it.details.accepted } == true }
        compose.onNodeWithTag("discover-album-list").performScrollToNode(hasText("Disc 2"))
        scroll("discover-album-list", hasText("Video data")).assertIsDisplayed()
        compose.onNodeWithText("Audio unavailable").assertIsDisplayed()
        compose.onNodeWithContentDescription("Add to Library: Video data").assertDoesNotExist()
        scroll("discover-album-list", hasText("Second appearance")).performClick()
        scroll("discover-album-list", hasContentDescription("Add to Library: Second appearance")).performClick()
        assertEquals(recording, previews.single().second)
        assertEquals(trackId(4), (previews.single().first as com.soundq.android.data.discovery.DiscoverBrowseTrack).id)
        assertSame(previews.single().first, adds.single().first)
        assertEquals(recording, adds.single().second)
        assertTrue(calls.contains(DiscoverBrowseRoute.Tracklist(group, alternate)))
        // The shell retires its surface when opening the player, not the accepted edition.
        val retainedTrackPage = initial.trackPage
        compose.runOnIdle { surface.value.retire(); visible.value = false; surface.value = RadarArtworkRoute() }
        compose.runOnIdle { visible.value = true }
        compose.onNodeWithText("Second appearance").assertIsDisplayed()
        assertSame(retainedTrackPage, initial.trackPage)
        scroll("discover-album-list", hasContentDescription("Open artist Same Name")).performClick()
        waitFor(hasText("MusicBrainz ID: ${artist.value}"))
        compose.onNodeWithContentDescription("Back").performClick()
        scroll("discover-album-list", alternateLabel).assertIsDisplayed()
        assertEquals(1, calls.count { it == DiscoverBrowseRoute.Tracklist(group, alternate) })
        assertEquals(1, calls.count { it == DiscoverBrowseRoute.Tracklist(group, original) })
        assertEquals(1, calls.count { it is DiscoverBrowseRoute.Editions })
    }
}
