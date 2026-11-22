package com.soundq.android.data

import com.soundq.android.data.catalog.CatalogActions
import com.soundq.android.data.catalog.CatalogRepository
import com.soundq.android.data.discovery.*
import com.soundq.android.data.imports.ImportRepository
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.RecordedRequest
import okhttp3.Call
import okhttp3.EventListener
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit.SECONDS

class UnifiedDiscoverTest {
    @Test fun missingCatalogUsesOneMetadataOnlyLegacyReadAndNextSearchSeesUpgrade() = HttpsFixture().use { f ->
        val session = account(f)
        val api = SoundQApi(session, f.client)
        val repo = DiscoveryRepository(session, api, unifiedSearch = true)
        val view = repo.open()!!
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val query = request.url.queryParameter("q").orEmpty()
                return when (request.family) {
                    "artist", "album" -> if (query == "Genesis") missingRoute() else if (request.family == "artist")
                        page("artist", CatalogContractTest.A, "Upgraded artist") else catalogPage(emptyList())
                    "musicbrainz" -> MockResponse.Builder().body("""{"query":"$query","results":[],"sections":[{"kind":"artists","items":[${artistRow(0, "Genesis", 100)}]},{"kind":"albums","items":[{"kind":"album","id":"${CatalogContractTest.G}","title":"Genesis Live"}]}],"providers":[{"provider":"musicbrainz","status":"ok","resultCount":2}]}""").build()
                    "youtube" -> songs(query, listOf(songRow(0, "Genesis", "Grimes")))
                    "soundcloud" -> songEmpty(query, "soundcloud")
                    else -> when (request.url.encodedPath) {
                        "/api/v1/artists/${artistId(0)}" -> MockResponse.Builder().body("""{"id":"${artistId(0)}","name":"Genesis","releases":[]}""").build()
                        "/api/v1/source-selections" -> MockResponse.Builder().code(400).build()
                        else -> error("unexpected Discover request: ${request.url}")
                    }
                }
            }
        }
        assertEquals(0, f.server.requestCount)
        repo.edit(view, "Genesis")
        val draft = repo.state.value.draft
        repo.searchBlocking(view, draft)
        assertEquals(setOf("Genesis", "Genesis Live"), repo.state.value.items.filterIsInstance<DiscoveryResultRow.Entity>().map { it.entity.title }.toSet())
        assertEquals(5, f.server.requestCount)
        val calls = List(5) { f.server.takeRequest(4, SECONDS)!! }
        assertRequests("Genesis", calls.filter { it.family != "musicbrainz" })
        val metadata = calls.single { it.family == "musicbrainz" }
        assertEquals("/api/v1/discovery/search", metadata.url.encodedPath)
        assertEquals("Bearer fixture", metadata.headers["Authorization"])
        assertEquals("Genesis", metadata.url.queryParameter("q"))
        val song = repo.state.value.items.filterIsInstance<DiscoveryResultRow.Source>().single()
        repo.selectType(view, DiscoveryResultType.Song)
        assertSame(song, repo.state.value.items.single())
        val exact = repo.sourceRowChoice(view, song.batch, song.row) { true }!!
        assertSame(song.row, exact.candidate)
        assertSame(song.batch.selection, exact.selection)
        assertEquals(SESSION, exact.selection.id)
        assertEquals(listOf("Genesis"), repo.state.value.recent)
        val intake = ImportRepository(session, api, LibraryRepository(session, api::library, api::like))
        val importView = intake.open()!!
        intake.submit(intake.claimSource(importView, exact)!!)
        val add = f.server.takeRequest(4, SECONDS)!!
        assertEquals("POST", add.method)
        assertEquals("/api/v1/source-selections", add.url.encodedPath)
        val decision = Json.parseToJsonElement(add.body!!.utf8()).jsonObject
        assertEquals(JsonPrimitive(SESSION), decision["sessionId"])
        assertEquals(JsonPrimitive(song.row.id), decision["candidateId"])
        assertTrue(intake.sourceSessionConsumed(exact))

        repo.selectType(view, DiscoveryResultType.Artist)
        assertFalse(exact.valid())
        assertSame(draft, repo.state.value.draft)
        val artist = (repo.state.value.items.single() as DiscoveryResultRow.Entity).entity
        val artistDetails = repo.details(view, artist)!!
        val catalog = CatalogRepository(api)
        CatalogActions(catalog) { it() }.use { actions ->
            assertTrue(actions.discover(artistDetails))
            assertEquals("/api/v1/artists/${artistId(0)}", f.server.takeRequest(4, SECONDS)!!.url.encodedPath)
            assertEquals(artistId(0), catalog.state.value.artist!!.row.id.value)
        }
        repo.selectType(view, DiscoveryResultType.Album)
        assertFalse(artistDetails.valid())
        val album = (repo.state.value.items.single() as DiscoveryResultRow.Entity).entity
        val albumDetails = repo.details(view, album)!!
        CatalogActions(catalog) { it() }.use { actions ->
            assertTrue(actions.discover(albumDetails))
            assertEquals(CatalogContractTest.G, catalog.state.value.group!!.id.value)
            assertNull(catalog.state.value.album)
        }
        assertEquals(7, f.server.requestCount) // No typed browse, continuation, or new source sessions.

        repo.edit(view, "Upgrade")
        assertFalse(albumDetails.valid())
        repo.searchBlocking(view, repo.state.value.draft)
        assertRequests("Upgrade", List(4) { f.server.takeRequest(4, SECONDS)!! })
        assertEquals(listOf("Upgraded artist"), repo.state.value.items.filterIsInstance<DiscoveryResultRow.Entity>().map { it.entity.title })
        assertEquals(11, f.server.requestCount)
    }

    @Test fun genesisSongArrivesFirstWithoutBuryingTheBandBehindTheWholeProviderBatch() = genesisRace(songFirst = true)

    @Test fun missingCatalogDoesNotTurnUnconfirmedLegacyFamiliesIntoEmptySuccess() = HttpsFixture().use { f ->
        val repo = account(f).let { DiscoveryRepository(it, SoundQApi(it, f.client), unifiedSearch = true) }
        val view = repo.open()!!
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val q = checkNotNull(request.url.queryParameter("q"))
                return when (request.family) {
                    "artist", "album" -> if (q == "partial") missingRoute() else MockResponse.Builder().code(404)
                        .addHeader("Content-Type", "application/json").body("""{"code":"NOT_FOUND"}""").build()
                    "musicbrainz" -> MockResponse.Builder().body("""{"query":"$q","results":[],"sections":[{"kind":"artists","items":[${artistRow(0, q, 100)}]}],"providers":[{"provider":"musicbrainz","status":"failed","resultCount":1}]}""").build()
                    "youtube", "soundcloud" -> songEmpty(q, request.family!!)
                    else -> error("unexpected Discover request: ${request.url}")
                }
            }
        }
        repo.edit(view, "partial")
        repo.searchBlocking(view, repo.state.value.draft)
        val state = repo.state.value
        assertEquals(DiscoveryCatalogStatus.Legacy(partial = true), state.catalog[DiscoveryResultType.Artist])
        assertTrue((state.items.single() as DiscoveryResultRow.Entity).entity.legacyDetails)
        repo.selectType(view, DiscoveryResultType.Album)
        assertEquals(DiscoveryPhase.Failed, repo.state.value.phase)
        assertTrue(repo.state.value.catalog[DiscoveryResultType.Album] is DiscoveryCatalogStatus.Unavailable)
        assertEquals(5, f.server.requestCount)

        repo.edit(view, "other-404")
        repo.searchBlocking(view, repo.state.value.draft)
        val attempts = List(9) { f.server.takeRequest(4, SECONDS)!! }.filter { it.url.queryParameter("q") == "other-404" }
        assertRequests("other-404", attempts)
        assertTrue(repo.state.value.catalog.values.all { it is DiscoveryCatalogStatus.Unavailable })
        assertEquals(9, f.server.requestCount)
    }

    @Test fun accountReplacementCancelsHeldLegacyReadAndRetestsTypedRoutes() = HttpsFixture().use { f ->
        val session = account(f)
        val release = CountDownLatch(1)
        val cancelled = CountDownLatch(1)
        val worker = Executors.newSingleThreadExecutor()
        val client = f.client.newBuilder().eventListener(object : EventListener() {
            override fun callFailed(call: Call, ioe: IOException) {
                if (call.isCanceled() && call.request().url.queryParameter("providers") == "musicbrainz") cancelled.countDown()
            }
        }).build()
        val repo = DiscoveryRepository(session, SoundQApi(session, client), unifiedSearch = true)
        val view = repo.open()!!
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val q = checkNotNull(request.url.queryParameter("q"))
                return when (request.family) {
                    "artist", "album" -> if (q == "obsolete") missingRoute() else if (request.family == "album")
                        page("album", CatalogContractTest.G, "Successor album") else catalogPage(emptyList())
                    "musicbrainz" -> { check(release.await(10, SECONDS)); MockResponse.Builder().code(503).build() }
                    "youtube", "soundcloud" -> songEmpty(q, request.family!!)
                    else -> error("unexpected Discover request: ${request.url}")
                }
            }
        }
        try {
            repo.edit(view, "obsolete")
            val held = repo.claimSearch(view, repo.state.value.draft)!!
            val retired = worker.submit { repo.searchBlocking(held) }
            val received = List(5) { f.server.takeRequest(4, SECONDS)!! }
            assertRequests("obsolete", received.filter { it.family != "musicbrainz" })
            assertEquals("Bearer fixture", received.single { it.family == "musicbrainz" }.headers["Authorization"])
            assertTrue(session.accept(session.beginIntent(), SecretTokens("successor", "new-refresh", CatalogContractTest.G)))
            val replacement = repo.open()!!
            assertTrue(cancelled.await(4, SECONDS))
            retired.get(4, SECONDS)
            assertEquals(1L, release.count)
            assertEquals(5, f.server.requestCount)
            assertNull(repo.claimSearch(view, held.draft))
            repo.edit(replacement, "fresh")
            repo.searchBlocking(replacement, repo.state.value.draft)
            val next = List(4) { f.server.takeRequest(4, SECONDS)!! }
            assertEquals(setOf("artist", "album", "youtube", "soundcloud"), next.map { it.family }.toSet())
            assertTrue(next.all { it.headers["Authorization"] == "Bearer successor" && it.url.queryParameter("q") == "fresh" })
            assertEquals(listOf("Successor album"), repo.state.value.items.map(::rowTitle))
            assertEquals(listOf("fresh"), repo.state.value.recent)
            assertEquals(9, f.server.requestCount)
        } finally { release.countDown(); worker.shutdownNow() }
    }

    @Test fun genesisBandArrivesFirstWithoutWaitingForTheGrimesSong() = genesisRace(songFirst = false)

    private fun genesisRace(songFirst: Boolean) {
        HttpsFixture().use { f ->
            val allowSong = CountDownLatch(if (songFirst) 0 else 1)
            val allowArtist = CountDownLatch(if (songFirst) 1 else 0)
            val executor = Executors.newSingleThreadExecutor()
            val query = "Genesis"
            val titles = (1..8).map { "Unrelated song $it" } + listOf("Turn It On Again", "The Musical Box", "Genesis Live", "Genesis")
            val artists = (1..7).map { "Unrelated artist $it" } + "Genesis"
            val repo = account(f).let { DiscoveryRepository(it, SoundQApi(it, f.client), unifiedSearch = true) }
            val view = repo.open()!!
            f.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = when (request.family) {
                    "youtube" -> {
                        check(allowSong.await(10, SECONDS))
                        songs(query, titles.mapIndexed { i, title ->
                            songRow(i, title, when (i) { 8, 9 -> "Genesis"; 11 -> "Grimes"; else -> "Other credit" })
                        })
                    }
                    "artist" -> {
                        check(allowArtist.await(10, SECONDS))
                        catalogPage(artists.mapIndexed { i, title -> artistRow(i, title, if (i == 7) 1 else 100) })
                    }
                    "album" -> catalogPage(emptyList())
                    "soundcloud" -> songEmpty(query, "soundcloud")
                    else -> MockResponse.Builder().code(404).build()
                }
            }
            try {
                repo.edit(view, query)
                val draft = repo.state.value.draft
                val admitted = repo.claimSearch(view, draft)!!
                val pending = executor.submit { repo.searchBlocking(admitted) }
                assertRequests(query, List(4) { f.server.takeRequest(4, SECONDS)!! })
                await { repo.state.value.items.isNotEmpty() }
                assertEquals(DiscoveryPhase.Ready, repo.state.value.phase)
                assertTrue(repo.state.value.searchActive)
                assertFalse(pending.isDone)
                val early = repo.state.value.items
                val inspected = if (songFirst) {
                    assertEquals(listOf("Genesis", "Genesis Live", "Turn It On Again"), early.map(::rowTitle))
                    val grimes = early.first() as DiscoveryResultRow.Source
                    assertEquals("Grimes", grimes.row.artist)
                    repo.inspect(view, grimes.row)!!
                } else null
                val details = if (!songFirst) {
                    assertEquals(listOf("Genesis"), early.map(::rowTitle))
                    val band = early.single() as DiscoveryResultRow.Entity
                    assertEquals(DiscoveryCatalogTarget.Artist(com.soundq.android.data.catalog.ArtistMbid(artistId(7))), band.entity.catalogTarget)
                    repo.details(view, band.entity)!!
                } else null

                allowSong.countDown(); allowArtist.countDown()
                pending.get(5, SECONDS)
                val mixed = repo.state.value.items
                val ids = if (songFirst) listOf("song-11", "song-10", "song-8", artistId(7))
                    else listOf(artistId(7), "song-11", "song-10", "song-8")
                assertEquals(ids, mixed.map { row -> when (row) {
                    is DiscoveryResultRow.Source -> row.row.id
                    is DiscoveryResultRow.Entity -> row.entity.id
                } })
                early.forEachIndexed { i, row -> assertSame(row, mixed[i]) }
                if (inspected != null) {
                    assertSame(inspected, repo.state.value.inspected)
                    assertTrue(inspected.valid())
                }
                if (details != null) assertTrue(details.valid())
                val grimes = mixed.filterIsInstance<DiscoveryResultRow.Source>().first()
                val choice = repo.sourceRowChoice(view, grimes.batch, grimes.row) { true }!!
                assertSame(grimes.row, choice.candidate)
                assertSame(grimes.batch.selection, choice.selection)
                assertEquals(SESSION, choice.selection.id)

                assertNull(repo.selectType(view, DiscoveryResultType.Song))
                assertEquals(titles, repo.state.value.items.map(::rowTitle))
                assertSame(grimes, repo.state.value.items.last())
                assertNull(repo.selectType(view, DiscoveryResultType.Artist))
                assertEquals(artists, repo.state.value.items.map(::rowTitle))
                assertSame(mixed.filterIsInstance<DiscoveryResultRow.Entity>().single(), repo.state.value.items.last())
                assertNull(repo.selectType(view, DiscoveryResultType.All))
                mixed.forEachIndexed { i, row -> assertSame(row, repo.state.value.items[i]) }
                assertSame(draft, repo.state.value.draft)
                assertEquals(query, repo.state.value.results!!.query)
                assertEquals(listOf(query), repo.state.value.recent)
                assertNull(repo.claimSearch(view, draft))
                assertEquals(4, f.server.requestCount)
            } finally {
                allowSong.countDown(); allowArtist.countDown(); executor.shutdownNow()
            }
        }
    }

    @Test fun artistPlusTitleUsesCreditsAndTokenBoundariesRatherThanUploaderOrSubstring() {
        HttpsFixture().use { f ->
            val query = "ＧＲＩＭＥＳ + Genesis"
            val repo = account(f).let { DiscoveryRepository(it, SoundQApi(it, f.client), unifiedSearch = true) }
            val view = repo.open()!!
            f.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = when (request.family) {
                    "youtube" -> songs(query, listOf(
                        songRow(0, "Pathogenesis", "Grimeson", uploader = "Grimes Genesis"),
                        songRow(1, "Pathogenesis", "Grimeson"),
                        songRow(2, "Genesis (Live)", "Other credit", uploader = "Grimes"),
                        songRow(3, "Genesis", "Grimes"),
                        songRow(4, "Genesis", "Other credit"),
                    ))
                    "artist", "album" -> catalogPage(emptyList())
                    "soundcloud" -> songEmpty(query, "soundcloud")
                    else -> MockResponse.Builder().code(404).build()
                }
            }
            repo.edit(view, query)
            repo.searchBlocking(view, repo.state.value.draft)
            assertRequests(query, List(4) { f.server.takeRequest(4, SECONDS)!! })
            assertEquals(listOf("song-3", "song-2", "song-4"), repo.state.value.items.map { (it as DiscoveryResultRow.Source).row.id })
            assertEquals(4, f.server.requestCount)
        }
    }

    @Test fun metadataThenExactSourcePublishWhileOtherFamiliesAreHeldAndTabsReuseThem() {
        HttpsFixture().use { f ->
            val session = account(f)
            val api = SoundQApi(session, f.client)
            val repo = DiscoveryRepository(session, api, unifiedSearch = true)
            val view = repo.open()!!
            val allowSong = CountDownLatch(1)
            val allowCloud = CountDownLatch(1)
            val allowAlbum = CountDownLatch(1)
            val albumReads = java.util.concurrent.atomic.AtomicInteger()
            val executor = Executors.newSingleThreadExecutor()
            val query = "Björk & ... /?+"
            f.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = when (request.family) {
                    "artist" -> page("artist", CatalogContractTest.A, "Fixture artist")
                    "album" -> if (albumReads.incrementAndGet() == 1) {
                        check(allowAlbum.await(10, SECONDS))
                        MockResponse.Builder().code(503).addHeader("Retry-After", "0").build()
                    } else page("album", CatalogContractTest.G, "Fixture album")
                    "youtube" -> {
                        check(allowSong.await(10, SECONDS))
                        songs(query, listOf(songRow(0, "Source fallback", "First credit"), songRow(1, "Other fallback", "Other credit")))
                    }
                    "soundcloud" -> { check(allowCloud.await(10, SECONDS)); songEmpty(query, "soundcloud") }
                    else -> MockResponse.Builder().code(404).build()
                }
            }
            try {
                assertEquals(DiscoveryResultType.All, repo.state.value.resultType)
                repo.edit(view, query)
                val draft = repo.state.value.draft
                val admitted = repo.claimSearch(view, draft)!!
                val pending = executor.submit { repo.searchBlocking(admitted) }
                assertRequests(query, List(4) { f.server.takeRequest(4, SECONDS)!! })
                await { repo.state.value.items.size == 1 }
                val early = repo.state.value.items.single() as DiscoveryResultRow.Entity
                assertEquals(DiscoveryPhase.Ready, repo.state.value.phase)
                assertTrue(repo.state.value.pendingProviders)
                assertEquals(DiscoveryCatalogStatus.Ready(hasMore = true), repo.state.value.catalog[DiscoveryResultType.Artist])
                val details = repo.details(view, early.entity)!!
                assertEquals(DiscoveryCatalogTarget.Artist(com.soundq.android.data.catalog.ArtistMbid(CatalogContractTest.A)), details.target)
                assertNull(repo.claimSearch(view, draft))

                allowSong.countDown()
                await { repo.state.value.items.any { it is DiscoveryResultRow.Source } }
                assertEquals(listOf("Fixture artist", "Source fallback"), repo.state.value.items.map(::rowTitle))
                assertSame(early, repo.state.value.items.first())
                assertTrue(details.valid()) // a peer must not invalidate an exact open destination
                val source = repo.state.value.items.last() as DiscoveryResultRow.Source
                val choice = repo.sourceRowChoice(view, source.batch, source.row) { true }!!
                assertSame(source.row, choice.candidate)
                assertSame(source.batch.selection, choice.selection)
                assertEquals(SESSION, choice.selection.id)
                assertTrue(choice.valid())

                assertNull(repo.selectType(view, DiscoveryResultType.Artist))
                assertEquals(listOf(early), repo.state.value.items)
                assertFalse(choice.valid())
                assertFalse(details.valid())
                assertNull(repo.selectType(view, DiscoveryResultType.Song))
                assertEquals(listOf("Source fallback", "Other fallback"), repo.state.value.items.map(::rowTitle))
                assertSame(source, repo.state.value.items.first())
                assertNull(repo.selectType(view, DiscoveryResultType.Album))
                assertEquals(DiscoveryPhase.Loading, repo.state.value.phase)
                assertNull(repo.selectType(view, DiscoveryResultType.All))
                assertEquals(listOf(early, source), repo.state.value.items)
                assertSame(draft, repo.state.value.draft)
                assertEquals(listOf(query), repo.state.value.recent)
                assertEquals(4, f.server.requestCount)
                assertFalse(pending.isDone)

                allowAlbum.countDown()
                await { repo.state.value.catalog[DiscoveryResultType.Album] is DiscoveryCatalogStatus.Unavailable }
                assertEquals(DiscoveryPhase.Ready, repo.state.value.phase)
                assertEquals(listOf(early, source), repo.state.value.items)
                assertTrue(repo.state.value.pendingProviders)
                assertNull(repo.selectType(view, DiscoveryResultType.Album))
                assertEquals(DiscoveryPhase.Failed, repo.state.value.phase)
                assertTrue(repo.state.value.items.isEmpty())
                assertNull(repo.claimSearch(view, draft)) // a stable draft does not re-admit automatically
                assertEquals(4, f.server.requestCount)
                val albumRetry = checkNotNull(repo.claimSearch(view, draft, retry = true)) { "an explicitly retried album must not wait for SoundCloud" }
                repo.searchBlocking(albumRetry)
                val retry = f.server.takeRequest(3, SECONDS)!!
                assertEquals("album", retry.family)
                assertEquals(query, retry.url.queryParameter("q"))
                assertEquals("0", retry.url.queryParameter("offset"))
                assertEquals(5, f.server.requestCount)
                assertFalse(pending.isDone)
                assertNull(repo.selectType(view, DiscoveryResultType.All))
                assertEquals(listOf(early, source), repo.state.value.items.take(2))
                assertEquals(DiscoveryResultType.Album, repo.state.value.items.last().type)
                assertSame(source.batch.selection, repo.sourceRowChoice(view, source.batch, source.row) { true }!!.selection)
                allowCloud.countDown()
                pending.get(5, SECONDS)
                assertFalse(repo.state.value.pendingProviders)
                assertFalse(repo.state.value.searchActive)
                assertEquals(5, f.server.requestCount)
            } finally {
                allowSong.countDown(); allowCloud.countDown(); allowAlbum.countDown(); executor.shutdownNow()
            }
        }
    }

    @Test fun supersedingCancelsEveryHeldWireBeforeReplyAndNewAlbumRemainsAnExactGroup() {
        HttpsFixture().use { f ->
            val cancelled = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
            val failures = CountDownLatch(4)
            val client = f.client.newBuilder().eventListener(object : EventListener() {
                override fun callFailed(call: Call, ioe: IOException) {
                    val url = call.request().url
                    if (call.isCanceled() && url.queryParameter("q") == "held") {
                        cancelled += (url.queryParameter("kind") ?: url.queryParameter("providers")!!)
                        failures.countDown()
                    }
                }
            }).build()
            val session = account(f)
            val api = SoundQApi(session, client)
            val repo = DiscoveryRepository(session, api, unifiedSearch = true)
            val view = repo.open()!!
            val release = CountDownLatch(1)
            val executor = Executors.newSingleThreadExecutor()
            f.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val q = request.url.queryParameter("q")
                    if (q == "held") {
                        check(release.await(12, SECONDS))
                        return MockResponse.Builder().code(503).build()
                    }
                    return when (request.family) {
                        "album" -> page("album", CatalogContractTest.G, "Exact group")
                        "artist" -> MockResponse.Builder().body("""{"results":[],"hasMore":false}""").build()
                        "youtube", "soundcloud" -> songEmpty(q!!, request.family!!)
                        else -> MockResponse.Builder().code(404).build()
                    }
                }
            }
            try {
                repo.edit(view, "held")
                val old = repo.claimSearch(view, repo.state.value.draft)!!
                val retired = executor.submit { repo.searchBlocking(old) }
                assertRequests("held", List(4) { f.server.takeRequest(4, SECONDS)!! })
                assertNull(repo.selectType(view, DiscoveryResultType.Artist))
                repo.edit(view, "replacement")
                assertEquals(DiscoveryResultType.All, repo.state.value.resultType)
                assertTrue("all real Calls must cancel before the reply gate opens", failures.await(4, SECONDS))
                retired.get(4, SECONDS)
                assertEquals(1L, release.count)
                assertEquals(setOf("youtube", "soundcloud", "artist", "album"), cancelled)
                repo.searchBlocking(view, repo.state.value.draft)
                assertRequests("replacement", List(4) { f.server.takeRequest(4, SECONDS)!! })
                val entity = (repo.state.value.items.single() as DiscoveryResultRow.Entity).entity
                val opened = repo.details(view, entity)!!
                val catalog = CatalogRepository(api)
                val actions = CatalogActions(catalog) { it() }
                assertTrue(actions.discover(opened))
                assertEquals(CatalogContractTest.G, catalog.state.value.group!!.id.value)
                assertNull(catalog.state.value.album)
                actions.close()
                assertEquals(8, f.server.requestCount)
                assertNull(repo.selectType(view, DiscoveryResultType.Artist))
                assertEquals(DiscoveryPhase.Ready, repo.state.value.phase) // successful zero, not unavailable
                assertTrue(repo.state.value.items.isEmpty())
                assertEquals(DiscoveryCatalogStatus.Ready(false), repo.state.value.catalog[DiscoveryResultType.Artist])
                assertFalse(opened.valid())
            } finally { release.countDown(); executor.shutdownNow() }
        }
    }

    @Test fun allRetriesOnlyTheFailedFamilyAndKeepsExistingRowAndActionProvenance() = HttpsFixture().use { f ->
        val session = account(f)
        val repo = DiscoveryRepository(session, SoundQApi(session, f.client), unifiedSearch = true)
        val view = repo.open()!!
        val query = "Genesis"
        val type = DiscoveryResultType.Artist
        val attempts = java.util.concurrent.atomic.AtomicInteger()
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.family) {
                "artist" -> if (attempts.incrementAndGet() <= 2) MockResponse.Builder().code(503).addHeader("Retry-After", "0").build()
                    else page("artist", CatalogContractTest.A, "Genesis")
                "album" -> page("album", CatalogContractTest.G, "Genesis")
                "youtube" -> songs(query, listOf(songRow(0, "Genesis", "Grimes")))
                "soundcloud" -> songEmpty(query, "soundcloud")
                else -> MockResponse.Builder().code(404).build()
            }
        }
        repo.edit(view, query)
        val draft = repo.state.value.draft
        repo.searchBlocking(view, draft)
        assertRequests(query, List(4) { f.server.takeRequest(4, SECONDS)!! })
        val before = repo.state.value
        val entity = before.items.filterIsInstance<DiscoveryResultRow.Entity>().single().entity
        val source = before.items.filterIsInstance<DiscoveryResultRow.Source>().single()
        val details = checkNotNull(repo.details(view, entity))
        val inspection = checkNotNull(repo.inspect(view, source.row))
        val choice = checkNotNull(repo.sourceRowChoice(view, source.batch, source.row) { true })
        val failed = before.catalog.getValue(type) as DiscoveryCatalogStatus.Unavailable
        fun assertRetained() {
            val state = repo.state.value
            assertSame(draft, state.draft)
            assertSame(before.recent, state.recent)
            assertSame(before.results!!.identity, state.results!!.identity)
            assertSame(before.catalog[DiscoveryResultType.Album], state.catalog[DiscoveryResultType.Album])
            assertEquals(DiscoveryResultType.All, state.resultType)
            before.items.forEachIndexed { i, row -> assertSame(row, state.items[i]) }
            assertSame(inspection, state.inspected)
            assertTrue(inspection.valid())
            assertTrue(choice.valid())
            assertTrue(details.valid())
        }
        fun assertOnlyArtistRequest(total: Int) {
            val request = checkNotNull(f.server.takeRequest(4, SECONDS))
            assertEquals("GET", request.method)
            assertEquals("Bearer fixture", request.headers["Authorization"])
            assertEquals("/api/v1/discovery/catalog", request.url.encodedPath)
            assertEquals("artist", request.family)
            assertEquals("0", request.url.queryParameter("offset"))
            assertEquals(query, request.url.queryParameter("q"))
            assertEquals(total, f.server.requestCount)
        }
        assertNull(repo.claimCatalogRetry(view, draft, DiscoveryResultType.Album, failed))
        assertNull(repo.claimSearch(view, draft))
        assertEquals(4, f.server.requestCount)
        val retry = checkNotNull(repo.claimCatalogRetry(view, draft, type, failed))
        assertNull(repo.claimCatalogRetry(view, draft, type, failed))
        assertRetained()
        repo.searchBlocking(retry)
        assertOnlyArtistRequest(5)
        assertRetained()
        val failedAgain = repo.state.value.catalog.getValue(type) as DiscoveryCatalogStatus.Unavailable
        assertNotSame(failed, failedAgain)
        assertNull(repo.claimCatalogRetry(view, draft, type, failed))
        assertFalse(repo.state.value.searchActive)
        repo.searchBlocking(checkNotNull(repo.claimCatalogRetry(view, draft, type, failedAgain)))
        assertOnlyArtistRequest(6)
        assertRetained()
        assertEquals(before.items.size + 1, repo.state.value.items.size)
        assertEquals(type, repo.state.value.items.last().type)
        assertEquals(DiscoveryCatalogStatus.Ready(hasMore = true), repo.state.value.catalog[type])
    }

    @Test fun editingRetiresAHeldFamilyRetryWithoutRebindingItsReply() = HttpsFixture().use { f ->
        val release = CountDownLatch(1)
        val cancelled = CountDownLatch(1)
        val attempts = java.util.concurrent.atomic.AtomicInteger()
        val worker = Executors.newSingleThreadExecutor()
        val session = account(f)
        val client = f.client.newBuilder().eventListener(object : EventListener() {
            override fun callFailed(call: Call, ioe: IOException) {
                if (call.isCanceled() && call.request().url.queryParameter("kind") == "album") cancelled.countDown()
            }
        }).build()
        val repo = DiscoveryRepository(session, SoundQApi(session, client), unifiedSearch = true)
        val view = repo.open()!!
        val type = DiscoveryResultType.Album
        f.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val query = checkNotNull(request.url.queryParameter("q"))
                return when (request.family) {
                    "album" -> if (query == "old") {
                        if (attempts.incrementAndGet() == 1) MockResponse.Builder().code(503).build()
                        else { check(release.await(8, SECONDS)); page("album", CatalogContractTest.G, "Old album") }
                    } else page("album", CatalogContractTest.G, "New album")
                    "artist" -> catalogPage(emptyList())
                    "youtube", "soundcloud" -> songEmpty(query, request.family!!)
                    else -> MockResponse.Builder().code(404).build()
                }
            }
        }
        try {
            repo.edit(view, "old")
            val draft = repo.state.value.draft
            repo.searchBlocking(view, draft)
            assertRequests("old", List(4) { f.server.takeRequest(4, SECONDS)!! })
            val failed = repo.state.value.catalog.getValue(type) as DiscoveryCatalogStatus.Unavailable
            val retry = checkNotNull(repo.claimCatalogRetry(view, draft, type, failed))
            val held = worker.submit { repo.searchBlocking(retry) }
            val request = checkNotNull(f.server.takeRequest(4, SECONDS))
            assertEquals("album", request.family)
            assertEquals("old", request.url.queryParameter("q"))
            repo.edit(view, "new")
            val replacement = repo.state.value.draft
            assertTrue("retirement must cancel the entered retry before the reply is released", cancelled.await(4, SECONDS))
            held.get(4, SECONDS)
            assertNull(repo.claimCatalogRetry(view, draft, type, failed))
            assertEquals(1L, release.count)
            assertEquals(5, f.server.requestCount)
            release.countDown()
            repo.searchBlocking(view, replacement)
            assertRequests("new", List(4) { f.server.takeRequest(4, SECONDS)!! })
            assertSame(replacement, repo.state.value.draft)
            assertEquals(listOf("New album"), repo.state.value.items.map(::rowTitle))
            assertEquals(9, f.server.requestCount)
        } finally { release.countDown(); worker.shutdownNow() }
    }

    @Test fun typedContinuationUsesRawOffsetAndLeavesTheMixedShortlistAlone() {
        HttpsFixture().use { f ->
            val session = account(f)
            val repo = DiscoveryRepository(session, SoundQApi(session, f.client), unifiedSearch = true)
            val view = repo.open()!!
            val type = DiscoveryResultType.Artist
            val query = "Genesis"
            val attempts = java.util.concurrent.atomic.AtomicInteger()
            f.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse = when (request.family) {
                    "youtube", "soundcloud" -> songEmpty(query, request.family!!)
                    "album" -> catalogPage(emptyList())
                    "artist" -> when (request.url.queryParameter("offset")) {
                        "0" -> page("artist",artistId(0),"Genesis")
                        "1" -> if (attempts.incrementAndGet()==1) MockResponse.Builder().code(503).build() else
                            MockResponse.Builder().body("""{"results":[${artistRow(0,"Genesis",100)},${artistRow(1,"Génesis",99)}],"hasMore":true}""").build()
                        "3" -> MockResponse.Builder().body("""{"results":[${artistRow(2,"Genesis Owusu",90)}],"hasMore":false}""").build()
                        else -> MockResponse.Builder().code(400).build()
                    }
                    else -> MockResponse.Builder().code(404).build()
                }
            }
            repo.edit(view,query)
            val draft=repo.state.value.draft
            repo.searchBlocking(view,draft)
            val early=repo.state.value.items.single()
            val initial=repo.state.value.catalog.getValue(type) as DiscoveryCatalogStatus.Ready
            assertNull(repo.claimCatalogContinuation(view,draft,type,initial))
            repo.selectType(view,type)
            val first=repo.claimCatalogContinuation(view,draft,type,initial)!!
            assertNull(repo.claimCatalogContinuation(view,draft,type,initial))
            repo.searchBlocking(first)
            val failed=repo.state.value.catalog.getValue(type) as DiscoveryCatalogStatus.Ready
            assertTrue(failed.continuationFailed)
            assertSame(early,repo.state.value.items.single())
            assertNull(repo.claimCatalogContinuation(view,draft,type,initial))
            repo.searchBlocking(repo.claimCatalogContinuation(view,draft,type,failed)!!)
            val next=repo.state.value.catalog.getValue(type) as DiscoveryCatalogStatus.Ready
            assertSame(early,repo.state.value.items.first())
            assertEquals(listOf("Genesis","Génesis"),repo.state.value.items.map(::rowTitle))
            repo.searchBlocking(repo.claimCatalogContinuation(view,draft,type,next)!!)
            assertEquals(listOf("Genesis","Génesis","Genesis Owusu"),repo.state.value.items.map(::rowTitle))
            assertEquals(DiscoveryCatalogStatus.Ready(false),repo.state.value.catalog[type])
            repo.selectType(view,DiscoveryResultType.All)
            assertSame(early,repo.state.value.items.single())
            assertEquals(7,f.server.requestCount)
            val reads=List(7) {f.server.takeRequest(3,SECONDS)!!}
            assertRequests(query,reads.take(4))
            assertEquals(listOf("1","1","3"),reads.drop(4).map {it.url.queryParameter("offset")})
            assertTrue(reads.drop(4).all {it.family=="artist"&&it.url.queryParameter("q")==query})
        }
    }

    @Test fun supportedUrlUsesOnlyOriginalResolverAndCannotBecomeCatalogSearch() {
        HttpsFixture().use { f ->
            val session = account(f)
            val repo = DiscoveryRepository(session, SoundQApi(session, f.client), unifiedSearch = true)
            val view = repo.open()!!
            val url = "https://youtu.be/fixture"
            f.reply("""{"candidate":${DiscoveryBoundaryTest.candidate()},"selectionRequired":true,"selectionSessionId":"$SESSION","selectionExpiresAt":"2099-01-01T00:00:00Z"}""")
            repo.edit(view, url)
            val draft = repo.state.value.draft
            repo.searchBlocking(view, draft)
            val row = repo.state.value.items.single() as DiscoveryResultRow.Source
            assertEquals(url, row.row.source.url)
            assertEquals(SESSION, repo.sourceRowChoice(view, row.batch, row.row) { true }!!.selection.id)
            assertNull(repo.selectType(view, DiscoveryResultType.Album))
            assertNull(repo.claimSearch(view, draft))
            assertEquals(DiscoveryResultType.All, repo.state.value.resultType)
            val request = f.server.takeRequest(3, SECONDS)!!
            assertEquals("POST", request.method)
            assertEquals("/api/v1/discovery/resolve-url", request.url.encodedPath)
            assertEquals("""{"url":"$url"}""", request.body!!.utf8())
            assertEquals(1, f.server.requestCount)
        }
    }

    @Test fun catalogDecoderRejectsWrongKindInvalidTargetsAndExcessRows() {
        fun decode(body: String) = DiscoveryJson.catalog(Json.parseToJsonElement(body).jsonObject, DiscoveryResultType.Album)
        fun row(i: Int, kind: String = "album") =
            """{"kind":"$kind","id":"123e4567-e89b-12d3-a456-42661417400$i","title":"Album $i","artistMbid":"${CatalogContractTest.A}","artist":"Music act","releaseDate":"2020","score":100}"""
        fun body(rows: List<String>) = """{"results":[${rows.joinToString()}],"hasMore":false}"""
        val good = decode(body((1..8).map { row(it) }))
        assertEquals(8, good.rows.size)
        assertFalse(good.hasMore)
        assertEquals(CatalogContractTest.A, good.rows.first().artistMbid)
        assertEquals(100, good.rows.first().score)
        for (bad in listOf(body((1..9).map { row(it) }), body(listOf(row(1), row(1))), body(listOf(row(1,"artist"))),
            body(listOf(row(1).replace(CatalogContractTest.A,"bad id"))), body(listOf(row(1))).replace("false", "\"false\""))) {
            assertEquals(SafeFailure.Reason.InvalidResponse, assertThrows(SafeFailure::class.java) { decode(bad) }.reason)
        }
    }

    @Test fun legacyMetadataNeedsAnExplicitGroupedEnvelopeWithoutSourceAuthority() {
        val envelope = """{"query":"seed","results":[],"sections":[],"providers":[{"provider":"musicbrainz","status":"ok"}]}"""
        fun decode(body: String) = DiscoveryJson.legacyCatalog(Json.parseToJsonElement(body).jsonObject, "seed")
        assertTrue(decode(envelope).entities.isEmpty())
        for (bad in listOf(envelope.replace("\"sections\":[],", ""), envelope.replace("musicbrainz", "youtube"),
            envelope.dropLast(1) + """, "selectionSessionId":"$SESSION", "selectionExpiresAt":"2099-01-01T00:00:00Z"}""")) {
            assertEquals(SafeFailure.Reason.InvalidResponse, assertThrows(SafeFailure::class.java) { decode(bad) }.reason)
        }
    }

    private fun account(f: HttpsFixture) = AccountSession(f.endpoint, MemoryStore()).apply {
        accept(beginIntent(), SecretTokens("fixture", "refresh", CatalogContractTest.A))
    }
    private val RecordedRequest.family get() = url.queryParameter("kind") ?: url.queryParameter("providers")
    private fun assertRequests(query: String, requests: List<RecordedRequest>) {
        assertEquals(setOf("youtube", "soundcloud", "artist", "album"), requests.map { it.family }.toSet())
        for (r in requests) {
            assertEquals("GET", r.method)
            assertEquals("Bearer fixture", r.headers["Authorization"])
            assertEquals(query, r.url.queryParameter("q"))
            if (r.family in setOf("artist", "album")) {
                assertEquals("/api/v1/discovery/catalog", r.url.encodedPath)
                assertEquals(setOf("q", "kind", "offset"), r.url.queryParameterNames)
                assertEquals("0", r.url.queryParameter("offset"))
            } else {
                assertEquals("/api/v1/discovery/search", r.url.encodedPath)
                assertEquals(setOf("q", "limit", "providers"), r.url.queryParameterNames)
                assertEquals("12", r.url.queryParameter("limit"))
            }
        }
    }
    private fun await(predicate: () -> Boolean) {
        val end = System.nanoTime() + SECONDS.toNanos(4)
        while (!predicate() && System.nanoTime() < end) Thread.sleep(5)
        assertTrue("publication did not arrive while the peer was held", predicate())
    }
    private fun page(kind: String, id: String, title: String) = MockResponse.Builder().body(
        """{"results":[{"kind":"$kind","id":"$id","title":"$title","score":100}],"hasMore":true}"""
    ).build()
    private fun songEmpty(q: String, provider: String) = MockResponse.Builder().body(
        """{"query":"$q","results":[],"providers":[{"provider":"$provider","status":"ok"}]}"""
    ).build()

    private fun rowTitle(row: DiscoveryResultRow) = when (row) {
        is DiscoveryResultRow.Source -> row.row.title
        is DiscoveryResultRow.Entity -> row.entity.title
    }

    private fun songRow(i: Int, title: String, artist: String, uploader: String = "") =
        """{"candidateId":"song-$i","provider":"youtube","sourceUrl":"https://youtu.be/fixture-$i","title":${JsonPrimitive(title)},"artist":${JsonPrimitive(artist)},"uploader":${JsonPrimitive(uploader)},"downloadable":true}"""

    private fun songs(query: String, rows: List<String>) = MockResponse.Builder().body(
        """{"query":${JsonPrimitive(query)},"results":[${rows.joinToString()}],"providers":[{"provider":"youtube","status":"ok"}],"selectionSessionId":"$SESSION","selectionExpiresAt":"2099-01-01T00:00:00Z"}"""
    ).build()

    private fun artistId(i: Int) = "123e4567-e89b-12d3-a456-42661417402$i"

    private fun artistRow(i: Int, title: String, score: Int) =
        """{"kind":"artist","id":"${artistId(i)}","title":${JsonPrimitive(title)},"score":$score}"""

    private fun catalogPage(rows: List<String>) = MockResponse.Builder().body(
        """{"results":[${rows.joinToString()}],"hasMore":false}"""
    ).build()

    private fun missingRoute() = MockResponse.Builder().code(404)
        .addHeader("Content-Type", "text/plain; charset=utf-8").body("404 page not found\n").build()

    companion object { private const val SESSION = "123e4567-e89b-12d3-a456-426614174010" }
}