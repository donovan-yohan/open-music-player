package com.soundq.android.product.discovery

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.soundq.android.data.catalog.RecordingMbid
import com.soundq.android.data.discovery.*
import com.soundq.android.data.imports.ImportView
import com.soundq.android.product.ProductViewModel
import com.soundq.android.product.artwork.ArtworkPaint
import com.soundq.designsystem.*
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.serialization.json.JsonObject
import okhttp3.OkHttpClient

/** Bounded detail subtree. The caller retains the Discover query, filters and list on exit. */
@Composable
internal fun DiscoverEntityPage(model: ProductViewModel, view: DiscoveryView, details: DiscoveryDetails,
    intake: ImportView?, onExit: () -> Unit, artworkRoot: RadarArtworkRoute? = null, isVisible: () -> Boolean = { true },
) {
    val root = remember(details, artworkRoot) { artworkRoot ?: RadarArtworkRoute() }
    val visible by rememberUpdatedState(isVisible)
    val navigation = remember(view, details, root) {
        val initial = when (val target = details.target) {
            is DiscoveryCatalogTarget.Artist -> EntityArtist(target.id, details.entity.title,
                details.entity.subtitle.takeIf { it.isNotBlank() })
            is DiscoveryCatalogTarget.Group -> EntityAlbum(target.id, details.entity.title,
                details.entity.artist.takeIf { it.isNotBlank() }, details.entity.releaseDate.takeIf { it.isNotBlank() })
        }
        EntityBrowseNavigation(initial) { view.scope === details.scope && details.valid() && visible() && root.current() }
    }
    val session = model.graph.session
    val auth by model.auth.collectAsStateWithLifecycle()
    val accountRevision by session.scopeRevision.collectAsStateWithLifecycle()
    val discovery by model.graph.discovery.state.collectAsStateWithLifecycle()
    val originCurrent = remember(navigation, auth, accountRevision, discovery) { details.valid() } && isVisible() && root.current()
    val visit = navigation.visit
    val actionRoot = remember(root, visit) { RadarArtworkRoute(root = root) }
    DisposableEffect(actionRoot) { onDispose { actionRoot.retire() } }
    val rowActions = rememberDiscoveryRowActions(model, view, actionRoot, originCurrent && visit != null)
    val imports by model.imports.collectAsStateWithLifecycle()
    val rowSurface = rowActions.surface
    val playback = object : EntityBrowseActions {
        override fun pending(row: Any) = rowActions.pending(row)
        override val canActivate = rowSurface != null
        override val canAdd = rowSurface != null && intake != null && !imports.pending && !rowActions.adding
        override fun preview(row: Any, recording: RecordingMbid, title: String, artist: String, current: () -> Boolean) {
            rowActions.preview(view, row, title, artist, { current() && rowSurface?.current() == true }) {
                model.graph.api.recordingPreviewSource(view.scope, recording, it)
            }
        }
        override fun add(row: Any, recording: RecordingMbid, current: () -> Boolean) {
            if (intake != null) rowActions.addRecording(view, intake, row, recording) { current() && rowSurface?.current() == true }
        }
    }
    DiscoverEntityBrowseContent(navigation, originCurrent, model.graph.mediaClient, playback, onExit, surfaceRoot = root) { route, calls, current ->
        model.graph.api.discoverBrowseBody(details.scope, route, calls, current)
    }
}

/** Reads and actions are injected only at the composed subtree boundary; production uses the existing owners. */
internal interface EntityBrowseActions {
    val canActivate: Boolean
    val canAdd: Boolean
    fun pending(row: Any): Boolean
    fun preview(row: Any, recording: RecordingMbid, title: String, artist: String, current: () -> Boolean)
    fun add(row: Any, recording: RecordingMbid, current: () -> Boolean)
}

private typealias EntityBrowseWire = (DiscoverBrowseRoute, DiscoveryCalls, () -> Boolean) -> JsonObject
private const val PREVIEW_ROWS = 5

@Composable
internal fun DiscoverEntityBrowseContent(nav: EntityBrowseNavigation, originCurrent: Boolean, mediaClient: OkHttpClient?,
    actions: EntityBrowseActions, onExit: () -> Unit, surfaceRoot: RadarArtworkRoute? = null, wire: EntityBrowseWire,
) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(nav, lifecycle, originCurrent, surfaceRoot) {
        fun sync() = nav.setResumed(originCurrent && lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) {
            surfaceRoot?.current() != false
        }
        val observer = LifecycleEventObserver { _, _ -> sync() }
        lifecycle.addObserver(observer)
        sync()
        onDispose { nav.setResumed(false); lifecycle.removeObserver(observer) }
    }
    val visit = nav.visit
    val destination = nav.destination
    val focus = LocalFocusManager.current
    fun back() { focus.clearFocus(); nav.back(onExit) }
    BackHandler(enabled = originCurrent) { back() }
    fun open(group: DiscoverReleaseGroupRow) {
        focus.clearFocus()
        nav.push(EntityAlbum(group.id, group.title, group.artist,
            facts(group.primaryType, group.date, group.disambiguation).takeIf { it.isNotBlank() }))
    }
    fun shelf(artist: EntityArtist, kind: EntityShelf) {
        if (visit?.current() == true) nav.push(EntityDestination.Shelf(artist, kind))
    }
    val render = EntityBrowseRows(mediaClient, visit, actions, ::open)
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp), verticalAlignment = Alignment.CenterVertically) {
            SoundQIconButton(SoundQIcon.Back, "Back", ::back, outlined = false)
            val heading = (destination as? EntityArtist)?.takeIf { it.search != null }?.name ?: destination.label
            Text(heading, Modifier.weight(1f).padding(horizontal = SoundQ.spacing.gutter).semantics { heading() },
                style = SoundQ.typography.title, color = SoundQ.colors.text)
        }
        SoundQDivider()
        when (destination) {
            is EntityArtist -> {
                val search = destination.search
                if (search != null && validDiscoverArtistQuery(search.query)) ReadArtistSearch(destination, search, visit, wire)
                else if (search == null) ReadArtistOverview(destination, visit, wire)
                fun edit(value: TextFieldValue) {
                    // Several editor callbacks can arrive before the composition sees the new visit.
                    if (nav.destination === destination && nav.visit?.current() == true && destination.edit(value)) nav.renew()
                }
                SoundQSearchStrip(destination.editor, ::edit,
                    "Search this artist", "Search this artist", "Search this artist", "Clear artist search", null,
                    { edit(TextFieldValue()); focus.clearFocus() }, enabled = visit != null)
                LazyColumn(Modifier.fillMaxWidth().weight(1f).testTag("discover-artist-list"), state = destination.scroll) {
                    if (search == null) {
                        item("artist-intro") { EntityIntro(destination.name, destination.description, "Artist", destination.id.value) }
                        with(render) {
                            val top = destination.top.rows
                            if (top.isNotEmpty()) {
                                val all = { shelf(destination, EntityShelf.Top) }
                                section("top", "Top tracks", if (top.size > PREVIEW_ROWS) all else null)
                                songs("top", top.take(PREVIEW_ROWS), destination.name)
                                if (top.size > PREVIEW_ROWS) viewAll("top", "Top tracks", all)
                            }
                            releaseShelf("albums", "Albums", listOf(destination.albums), destination.name, false) {
                                shelf(destination, EntityShelf.Albums)
                            }
                            releaseShelf("singles", "Singles & EPs", listOf(destination.singles, destination.eps), destination.name, false) {
                                shelf(destination, EntityShelf.Singles)
                            }
                        }
                    } else if (!validDiscoverArtistQuery(search.query)) {
                        val message = if (search.query.toByteArray(Charsets.UTF_8).size > 160) "Search is too long"
                            else "Enter a song or album title"
                        feedback("query-invalid", message, FeedbackKind.Error)
                    } else with(render) {
                        if (search.songs.rows.isNotEmpty()) section("search-songs", "Songs")
                        songs("search-songs", search.songs.rows, destination.name)
                        continuation("search-songs", "songs", search.songs, "Could not search songs")
                        if (search.albums.rows.isNotEmpty()) section("search-albums", "Albums")
                        groups("search-albums", search.albums.rows, destination.name)
                        continuation("search-albums", "albums", search.albums, "Could not search albums")
                        if (search.songs.accepted && search.albums.accepted && search.songs.rows.isEmpty() && search.albums.rows.isEmpty()) {
                            feedback("search-empty", "No matches for this artist", FeedbackKind.Empty)
                        }
                    }
                }
            }
            is EntityDestination.Shelf -> {
                val artist = destination.artist
                if (destination.kind == EntityShelf.Albums) ReadDiscography(artist, artist.albums, DiscoverBrowseRoute.ReleaseType.Album, visit, wire)
                if (destination.kind == EntityShelf.Singles) {
                    ReadDiscography(artist, artist.singles, DiscoverBrowseRoute.ReleaseType.Single, visit, wire)
                    ReadDiscography(artist, artist.eps, DiscoverBrowseRoute.ReleaseType.EP, visit, wire)
                }
                LazyColumn(Modifier.fillMaxWidth().weight(1f).testTag("discover-artist-shelf"), state = destination.scroll) {
                    with(render) { when (destination.kind) {
                        EntityShelf.Top -> songs("all-top", artist.top.rows, artist.name)
                        EntityShelf.Albums -> releaseShelf("all-albums", destination.label, listOf(artist.albums), artist.name, true) {}
                        EntityShelf.Singles -> releaseShelf("all-singles", destination.label, listOf(artist.singles, artist.eps), artist.name, true) {}
                    } }
                }
            }
            is EntityAlbum -> {
                ReadEditions(destination, visit, wire)
                val trackPage = destination.trackPage
                if (trackPage != null) EntityBrowseRead(trackPage.details, visit) { _, calls, current ->
                    val route = DiscoverBrowseRoute.Tracklist(destination.group, trackPage.edition.id)
                    val list = DiscoverBrowseJson.tracklist(wire(route, calls, current), route)
                    DiscoverBrowsePage(listOf(list), null, false)
                }
                val tracklist = trackPage?.details?.rows?.singleOrNull()
                val edition = tracklist?.edition ?: trackPage?.edition
                LazyColumn(Modifier.fillMaxWidth().weight(1f).testTag("discover-album-list"), state = trackPage?.scroll ?: destination.unselectedScroll) {
                    item("album-intro") {
                        val artist = edition?.artist ?: destination.artist
                        val credits = edition?.credits.orEmpty().filter { it.name.isNotBlank() }.distinctBy { it.id }
                        EntityIntro(destination.name, artist.takeIf { credits.isEmpty() }, destination.releaseInfo ?: "Album", destination.group.value,
                            art = { EntityArtwork(mediaClient, edition?.let { CaaArtworkRef.Edition(it.id) }
                                ?: CaaArtworkRef.Group(destination.group), visit, 72.dp) })
                        credits.forEach { credit ->
                            DetailLink(credit.name, "Open artist ${credit.name}", enabled = visit != null) {
                                if (visit?.current() == true) nav.artist(credit)
                            }
                        }
                    }
                    if (edition != null) {
                        val alternatives = destination.editions.rows.size > 1 || destination.editions.canContinue || destination.editions.truncated
                        item("edition-selected") {
                            Column {
                                if (alternatives) DetailLink("Edition · ${edition.label}", "Choose edition", enabled = visit != null) {
                                    if (visit?.current() == true) nav.push(EntityDestination.Editions(destination))
                                } else {
                                    Text("Edition · ${edition.label}", Modifier.padding(SoundQ.spacing.gutter), style = SoundQ.typography.body)
                                    SoundQDivider()
                                }
                            }
                        }
                    } else if (destination.editions.rows.isNotEmpty()) {
                        item("edition-unselected") {
                            DetailLink("Choose edition", "Choose edition", enabled = visit != null) {
                                if (visit?.current() == true) nav.push(EntityDestination.Editions(destination))
                            }
                        }
                    } else {
                        continuation("album-editions", "editions", destination.editions, "Could not load editions")
                        if (destination.editions.accepted) feedback("editions-empty", "No editions listed", FeedbackKind.Empty)
                    }
                    if (trackPage != null) {
                        section("tracklist", "Tracklist", detail = tracklist?.let {
                            if (it.tracks.size == 1) "1 track" else "${it.tracks.size} tracks"
                        })
                        continuation("tracklist", "tracklist", trackPage.details, "Could not load tracklist")
                        if (tracklist != null) {
                            if (tracklist.tracks.isEmpty()) feedback("tracks-empty", "No tracks listed", FeedbackKind.Empty)
                            itemsIndexed(tracklist.tracks, key = { _, track -> "track:${track.id}" }) { index, track ->
                                Column {
                                    if (tracklist.edition.discCount > 1 && (index == 0 || tracklist.tracks[index - 1].disc != track.disc)) {
                                        SectionHeader("Disc ${track.disc}")
                                    }
                                    NumberedDiscoverTrack(track, tracklist.edition.artist.orEmpty(), visit, actions)
                                }
                            }
                        }
                    }
                }
            }
            is EntityDestination.Editions -> {
                val album = destination.album
                ReadEditions(album, visit, wire)
                val editions = album.editions.rows
                val matchingLabels = editions.groupingBy { it.label }.eachCount()
                LazyColumn(Modifier.fillMaxWidth().weight(1f).testTag("discover-editions-list"), state = destination.scroll) {
                    items(editions, key = { "edition:${it.id.value}" }) { edition ->
                        val selected = album.trackPage?.edition?.id == edition.id
                        val label = if (matchingLabels.getValue(edition.label) > 1) "${edition.label} · ${edition.id.value.take(8)}" else edition.label
                        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).mediaRowBottomRule()
                            .selectable(selected, enabled = visit != null, role = Role.RadioButton) {
                                if (visit?.current() == true) { visit.retire(); album.select(edition); back() }
                            }.padding(horizontal = SoundQ.spacing.gutter, vertical = SoundQ.spacing.small),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(label, Modifier.weight(1f), style = SoundQ.typography.body)
                            if (selected) Text("Selected", style = SoundQ.typography.caption, color = SoundQ.colors.primary)
                        }
                    }
                    continuation("edition", "editions", album.editions, "Could not load editions")
                }
            }
        }
    }
}

@Composable private fun ReadArtistOverview(artist: EntityArtist, visit: EntityBrowseVisit?, wire: EntityBrowseWire) {
    ReadDiscography(artist, artist.albums, DiscoverBrowseRoute.ReleaseType.Album, visit, wire)
    ReadDiscography(artist, artist.singles, DiscoverBrowseRoute.ReleaseType.Single, visit, wire)
    ReadDiscography(artist, artist.eps, DiscoverBrowseRoute.ReleaseType.EP, visit, wire)
    EntityBrowseRead(artist.top, visit) { _, calls, current ->
        DiscoverBrowsePage(DiscoverBrowseJson.topTracks(wire(DiscoverBrowseRoute.TopTracks(artist.id), calls, current)), null, false)
    }
}

@Composable private fun ReadDiscography(artist: EntityArtist, slot: EntityBrowseSlot<DiscoverReleaseGroupRow>,
    type: DiscoverBrowseRoute.ReleaseType, visit: EntityBrowseVisit?, wire: EntityBrowseWire,
) {
    EntityBrowseRead(slot, visit) { offset, calls, current ->
        val route = DiscoverBrowseRoute.Discography(artist.id, type, offset)
        DiscoverBrowseJson.discography(wire(route, calls, current), route)
    }
}

@Composable private fun ReadArtistSearch(artist: EntityArtist, search: EntityArtistSearch, visit: EntityBrowseVisit?, wire: EntityBrowseWire) {
    EntityBrowseRead(search.songs, visit, debounce = true) { offset, calls, current ->
        val route = DiscoverBrowseRoute.ArtistSearch(artist.id, DiscoverBrowseRoute.SearchKind.Songs, search.query, offset)
        DiscoverBrowseJson.recordings(wire(route, calls, current), route)
    }
    EntityBrowseRead(search.albums, visit, debounce = true) { offset, calls, current ->
        val route = DiscoverBrowseRoute.ArtistSearch(artist.id, DiscoverBrowseRoute.SearchKind.Albums, search.query, offset)
        DiscoverBrowseJson.albums(wire(route, calls, current), route)
    }
}

@Composable private fun ReadEditions(album: EntityAlbum, visit: EntityBrowseVisit?, wire: EntityBrowseWire) {
    EntityBrowseRead(album.editions, visit, onAccepted = { page, offset ->
        if (offset == 0 && album.trackPage == null) defaultDiscoverEdition(page)?.let(album::select)
    }) { offset, calls, current ->
        val route = DiscoverBrowseRoute.Editions(album.group, offset)
        DiscoverBrowseJson.editions(wire(route, calls, current), route)
    }
}

private class EntityBrowseRows(private val client: OkHttpClient?, private val visit: EntityBrowseVisit?,
    private val actions: EntityBrowseActions, private val open: (DiscoverReleaseGroupRow) -> Unit,
) {
    fun LazyListScope.groups(key: String, rows: List<DiscoverReleaseGroupRow>, artist: String) {
        items(rows, key = { "$key:${it.id.value}" }) { row ->
            SoundQMediaRow(row.title, row.artist ?: artist, false, { if (visit?.current() == true) open(row) }, null,
                enabled = visit != null, artwork = { EntityArtwork(client, CaaArtworkRef.Group(row.id), visit, SoundQ.sizes.mediaRow) },
                supporting = facts(row.primaryType, row.date, row.disambiguation).takeIf { it.isNotBlank() })
        }
    }
    fun LazyListScope.songs(key: String, rows: List<DiscoverBrowseSong>, artist: String) {
        items(rows, key = { "$key:${it.recording.value}" }) { row ->
            val credit = row.artist ?: artist
            fun current() = visit?.current() == true
            SoundQMediaRow(row.title, credit, false, { actions.preview(row, row.recording, row.title, credit, ::current) }, null,
                enabled = visit != null && actions.canActivate, supporting = duration(row.durationMs),
                preview = SoundQMediaPreviewActions(actions.pending(row), visit != null && actions.canAdd) {
                    actions.add(row, row.recording, ::current)
                })
        }
    }
    fun LazyListScope.releaseShelf(key: String, label: String, slots: List<EntityBrowseSlot<DiscoverReleaseGroupRow>>,
        artist: String, full: Boolean, onAll: () -> Unit,
    ) {
        val rows = slots.flatMap { it.rows }.distinctBy { it.id }
        val all = rows.size > PREVIEW_ROWS || slots.any { it.canContinue }
        if (!full) section(key, label, if (all) onAll else null)
        groups(key, if (full) rows else rows.take(PREVIEW_ROWS), artist)
        if (rows.isEmpty() && slots.all { it.accepted }) feedback("$key-empty", "No releases listed", FeedbackKind.Empty)
        slots.forEachIndexed { i, slot ->
            val kind = if (slots.size == 1) label.lowercase() else if (i == 0) "singles" else "EPs"
            continuation("$key-$i", kind, slot, "Could not load $kind", showMore = full)
        }
        if (!full && all) viewAll(key, label, onAll)
    }
}

@Composable private fun NumberedDiscoverTrack(row: DiscoverBrowseTrack, albumArtist: String, visit: EntityBrowseVisit?, actions: EntityBrowseActions) {
    val recording = row.audioRecording
    val artist = row.artist ?: albumArtist
    val busy = actions.pending(row)
    fun current() = visit?.current() == true
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).mediaRowBottomRule().testTag("edition-track:${row.id}"),
        verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.weight(1f).heightIn(min = 56.dp).then(if (recording == null) Modifier else Modifier.clickable(
            enabled = visit != null && actions.canActivate && !busy, role = Role.Button, onClickLabel = "Play preview") {
            actions.preview(row, recording, row.title, artist, ::current)
        }).padding(horizontal = SoundQ.spacing.gutter, vertical = SoundQ.spacing.small),
            horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(row.number ?: row.position.toString().padStart(2, '0'), style = SoundQ.typography.mono, color = SoundQ.colors.muted)
            Column(Modifier.weight(1f)) {
                Text(row.title, style = SoundQ.typography.body, color = SoundQ.colors.text)
                val note = if (recording == null) "Audio unavailable" else row.artist?.takeIf { it != albumArtist }
                if (note != null) Text(note, style = SoundQ.typography.caption, color = SoundQ.colors.muted)
            }
            duration(row.durationMs)?.let { Text(it, style = SoundQ.typography.mono, color = SoundQ.colors.muted) }
        }
        if (recording != null) {
            Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
                if (busy) CircularProgressIndicator(Modifier.size(18.dp).semantics { contentDescription = "Preparing preview" }, strokeWidth = 2.dp)
            }
            SoundQIconButton(SoundQIcon.Plus, "Add to Library: ${row.title}",
                { actions.add(row, recording, ::current) }, enabled = visit != null && actions.canAdd, outlined = false)
        }
    }
}

private fun duration(ms: Long?) = ms?.takeIf { it > 0 }?.let(::formatSongTime)
private fun facts(vararg values: String?) = values.filterNotNull().filter { it.isNotBlank() }.joinToString(" · ")

private fun LazyListScope.viewAll(key: String, label: String, action: () -> Unit) {
    item("$key-all") { SoundQListActionRow("View all", action, description = "View all $label") }
}
private fun LazyListScope.section(key: String, label: String, action: (() -> Unit)? = null, detail: String? = null) {
    item("section-$key") { SectionHeader(label, action, detail) }
}
private fun LazyListScope.feedback(key: String, label: String, kind: FeedbackKind) {
    item(key) { Box(Modifier.padding(horizontal = SoundQ.spacing.gutter)) { SoundQFeedback(label, kind) } }
}
private fun LazyListScope.continuation(key: String, label: String, slot: EntityBrowseSlot<*>, failure: String, showMore: Boolean = true) {
    when {
        slot.failed -> item("$key-retry") {
            Box(Modifier.padding(horizontal = SoundQ.spacing.gutter)) {
                SoundQFeedback(failure, FeedbackKind.Error, action = "Retry", onAction = slot::request)
            }
        }
        slot.waiting -> item("$key-loading") { SoundQMediaRowSkeleton(showSupporting = false) }
        slot.canContinue && showMore -> item("$key-more") { SoundQListActionRow("Show more $label", slot::request) }
        slot.truncated && showMore -> feedback("$key-limit", "More results aren't available here", FeedbackKind.Notice)
    }
}

@Composable private fun SectionHeader(label: String, action: (() -> Unit)? = null, detail: String? = null) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).mediaRowBottomRule()
        .then(if (action == null) Modifier else Modifier.clickable(role = Role.Button, onClick = action))
        .padding(horizontal = SoundQ.spacing.gutter, vertical = SoundQ.spacing.small),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(label, Modifier.weight(1f).semantics { heading() }, style = SoundQ.typography.title, color = SoundQ.colors.text)
        if (detail != null) Text(detail, style = SoundQ.typography.caption, color = SoundQ.colors.muted)
        if (action != null) SoundQIcon(SoundQIcon.Arrow, null, tint = SoundQ.colors.primary)
    }
}

@Composable private fun DetailLink(text: String, label: String, enabled: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).mediaRowBottomRule().semantics { contentDescription = label }
        .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
        .padding(horizontal = SoundQ.spacing.gutter, vertical = SoundQ.spacing.small),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(text, Modifier.weight(1f), style = SoundQ.typography.body, color = SoundQ.colors.primary)
        SoundQIcon(SoundQIcon.Arrow, null, tint = SoundQ.colors.primary)
    }
}

@Composable private fun EntityIntro(title: String, subtitle: String?, kind: String, id: String, art: (@Composable () -> Unit)? = null) {
    Column {
        Row(Modifier.fillMaxWidth().padding(SoundQ.spacing.gutter), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            if (art != null) art()
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(kind, style = SoundQ.typography.caption, color = SoundQ.colors.muted)
                Text(title, Modifier.semantics { heading() }, style = SoundQ.typography.heading, color = SoundQ.colors.text)
                if (subtitle != null && subtitle != kind) Text(subtitle, style = SoundQ.typography.body, color = SoundQ.colors.muted)
            }
        }
        SoundQDivider()
        Text("MusicBrainz ID: $id", Modifier.padding(horizontal = SoundQ.spacing.gutter, vertical = 8.dp),
            style = SoundQ.typography.mono, color = SoundQ.colors.muted)
        SoundQDivider()
    }
}

private val entityArtworkPool = RadarArtworkPool()

@Composable private fun EntityArtwork(client: OkHttpClient?, ref: CaaArtworkRef, visit: EntityBrowseVisit?, size: androidx.compose.ui.unit.Dp) {
    if (client == null || visit == null) { SoundQArtworkSlot(size = size); return }
    val lease = remember(client, ref, visit) {
        val accepted = entityArtworkPool.open(client, ref, visit::current)
        object : RememberObserver {
            val value = accepted
            override fun onRemembered() = Unit
            override fun onForgotten() = accepted.close()
            override fun onAbandoned() = accepted.close()
        }
    }.value
    val mounted = remember(lease) { AtomicBoolean(true) }
    DisposableEffect(lease) {
        lease.start()
        onDispose { mounted.set(false); lease.close() }
    }
    ArtworkPaint(lease.state, lease::bitmap, mounted, size)
}
