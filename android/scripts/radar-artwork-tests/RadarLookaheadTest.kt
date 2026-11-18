package com.soundq.android.product.discovery

import androidx.compose.foundation.lazy.*
import androidx.compose.runtime.HostComposition
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.soundq.android.data.*
import com.soundq.android.data.discovery.*
import com.soundq.android.product.artwork.PaintBinding
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import mockwebserver3.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File
import java.awt.image.BufferedImage
import java.util.concurrent.*
import javax.imageio.ImageIO

/** Actual Discover row binding, accepted Radar, typed CAA and source-artwork bodies.
 * The host supplies the layout/apply schedule and Bitmap facade, not native scroll or paint. */
class RadarLookaheadTest {
    private class Fixture(val metadata: HttpsFixture, val art: CaaTlsFixture) {
        private val store = object : SessionStore {
            override fun load(endpoint: ApiEndpoint): SecretTokens? = null
            override fun save(endpoint: ApiEndpoint, tokens: SecretTokens) {}
            override fun clear() {}
        }
        val session = AccountSession(metadata.endpoint, store).apply {
            accept(beginIntent(), SecretTokens("synthetic-access", "fixture-refresh", "A"))
        }
        val repository = DiscoveryRepository(session, SoundQApi(session, metadata.client), radarAdmitted = true)
        val view = repository.open()!!
        val draft = repository.state.value.draft
        val surface = RadarArtworkRoute()
        private val viewJob = SupervisorJob()
        private val model = RadarViewModel(RadarGraph(repository), CoroutineScope(viewJob))
        val navSlot = HostComposition.Slot()
        fun route() = HostComposition.render(navSlot) { hostRadarRoute(model, view, surface) }
        fun settleActions() = runBlocking { withTimeout(5_000) { viewJob.children.toList().joinAll() } }
        val lifecycle = LifecycleOwner().also { LocalLifecycleOwner.current = it }.lifecycle
        val page: RadarPage
        val paths = CopyOnWriteArrayList<String>()
        @Volatile var hold: (Int) -> Unit = {}
        init {
            repository.showRadar(view) { true }
            val base = Json.parseToJsonElement(File(System.getProperty("soundq.radar.wire")).readText()).jsonObject
            val template = base.getValue("items").jsonArray.single().jsonObject
            val rows = (0 until 20).map { i ->
                JsonObject(template + mapOf(
                    "title" to JsonPrimitive("Synthetic cover $i"),
                    "recordingMbid" to JsonPrimitive(id(100 + i)),
                    "releaseGroupMbid" to JsonPrimitive(id(i + 1)),
                ))
            }
            val coverage = JsonObject(base.getValue("coverage").jsonObject +
                listOf("knownTotal", "retrieved", "deduped", "returned").associateWith { JsonPrimitive(rows.size) })
            metadata.reply(JsonObject(base + mapOf("policyVersion" to JsonPrimitive("recording-radar-v2"),
                "items" to JsonArray(rows), "coverage" to coverage)).toString())
            repository.loadRadar(repository.claimRadar(view)!!)
            page = repository.radar.value.page!!
            assertEquals(20, page.songs.size)
            assertEquals("recording-radar-v2", metadata.server.takeRequest(2, TimeUnit.SECONDS)!!.headers["X-SoundQ-Radar-Policy"])
            art.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val requested = request.url.encodedPath
                    paths += requested
                    val index = (0 until 20).single { requested == path(it) }
                    assertNull(request.headers["Authorization"])
                    hold(index)
                    return imageResponse(index)
                }
            }
        }
        val pool = RadarArtworkPool(reader = { art.read(it) })
        val full = HostComposition.Slot().let { slot ->
            HostComposition.render(slot) { hostFullRadarScroll(view, repository.radar.value) }
        }
        val slots = (0 until 20).associateWith { HostComposition.Slot() }
        fun layout(first: Int, visibleCount: Int = 4) {
            full.layoutInfo = LazyListLayoutInfo((first until first + visibleCount).map { i ->
                LazyListItemInfo("radar:${page.songs[i].recording.value}", (i - first) * 72, 72)
            }, 0, visibleCount * 72)
        }
        fun row(index: Int, fullList: Boolean = true): () -> android.graphics.Bitmap? {
            return HostComposition.render(slots.getValue(index)) {
                hostRadarRowArtwork(art.client, repository, view, page, page.songs[index], draft, surface, fullList, full, pool)
                PaintBinding.bitmap
            }
        }
        fun applyAhead(indices: IntRange) {
            // Native cache-window scheduling is the one collaborator we cannot mount on host.
            // Apply only the supplied viewport-ahead candidates when the actual caller opts in.
            if (full.cacheWindow != null) indices.forEach { row(it) }
        }
        fun dispose(index: Int) = HostComposition.dispose(slots.getValue(index))
        fun close() { HostComposition.dispose(navSlot); slots.values.forEach(HostComposition::dispose); repository.retire(); viewJob.cancel(); settleActions(); settle(pool) }
    }

    @Test fun fullListAcquiresDistinctUnseenCoversBeforeEntryAndReusesPixels() = fixture { f ->
        f.layout(0)
        f.row(0, fullList = false)
        settle(f.pool)
        assertEquals(listOf(path(0)), f.paths.toList())
        f.dispose(0)
        f.applyAhead(4..7)
        settle(f.pool)
        assertEquals("unseen next viewport acquires before any entry", setOf(path(0), path(4), path(5), path(6), path(7)), f.paths.toSet())
        f.layout(3)
        val pixels = f.row(6)()
        assertNotNull("entering row has its own already-decoded pixels", pixels)
        assertEquals(22, pixels!!.width)
        assertEquals(1, f.paths.count { it == path(6) })
        assertEquals(1, f.metadata.server.requestCount)
    }

    @Test fun activeSpeculationLeavesBothVisiblePathsFreeAndQueuedRadarPromotesInPlace() = fixture { f ->
        f.layout(0)
        val held = CountDownLatch(1)
        val release = CountDownLatch(1)
        val radarEntered = CountDownLatch(1)
        val releaseRadar = CountDownLatch(1)
        f.hold = { i ->
            if (i == 4) { held.countDown(); check(release.await(6, TimeUnit.SECONDS)) }
            if (i == 5) { radarEntered.countDown(); check(releaseRadar.await(6, TimeUnit.SECONDS)) }
        }
        val sourceSlot = HostComposition.Slot()
        try {
            f.applyAhead(4..7)
            assertTrue("offscreen typed read reached TLS", held.await(2, TimeUnit.SECONDS))
            assertEquals("only one speculative job may contend for three shared permits", 1, f.pool.resources()[1])
            assertEquals(listOf(path(4)), f.paths.toList())
            f.layout(5)
            val promoted = f.row(5)
            assertTrue("queued Radar work starts before held speculation exits", radarEntered.await(2, TimeUnit.SECONDS))
            f.metadata.server.enqueue(imageResponse(2))
            fun renderSource() {
                HostComposition.render(sourceSlot) {
                    DiscoveryArtwork(f.metadata.client, f.metadata.server.url("/visible-source").toString(), f.view) {
                        f.repository.current(f.view)
                    }
                }
            }
            await { renderSource(); PaintBinding.sourceImage?.width == 18 }
            assertEquals("source completed while both Radar requests are held", 1L, releaseRadar.count)
            releaseRadar.countDown()
            await { promoted()?.width == 21 }
            assertEquals("speculative transfer remains held", 1L, release.count)
            assertEquals(1, f.paths.count { it == path(5) })
            assertEquals("/visible-source", f.metadata.server.takeRequest(2, TimeUnit.SECONDS)!!.url.encodedPath)
            // Share a held speculative flight with a different authorized visible subscriber.
            f.layout(3)
            val sameCover = HostComposition.Slot()
            try {
                val peer = HostComposition.render(sameCover) {
                    RadarArtwork(f.art.client, f.repository, f.view, f.page, f.page.songs[4], f.draft, f.surface, f.pool)
                    PaintBinding.bitmap
                }
                f.dispose(4)
                assertNull(peer())
                release.countDown()
                await { peer()?.width == 20 }
                settle(f.pool)
                assertEquals("promotion/coalescing never duplicate the transfer", 1, f.paths.count { it == path(4) })
                assertEquals(1, f.paths.count { it == path(5) })
            } finally { HostComposition.dispose(sameCover) }
        } finally {
            release.countDown()
            releaseRadar.countDown()
            HostComposition.dispose(sourceSlot)
        }
    }

    @Test fun foregroundAndViewRetirementCancelHeldAndPendingUnseenReads() {
        for (foreground in listOf(true, false)) fixture { f ->
            f.layout(0)
            val held = CountDownLatch(1)
            val release = CountDownLatch(1)
            val decoding = RadarArtworkPool(decode = { data ->
                held.countDown(); check(release.await(6, TimeUnit.SECONDS))
                com.soundq.android.product.artwork.decodeArtwork(data, 192)
            }, reader = { f.art.read(it) })
            fun row(index: Int): () -> android.graphics.Bitmap? = HostComposition.render(f.slots.getValue(index)) {
                hostRadarRowArtwork(f.art.client, f.repository, f.view, f.page, f.page.songs[index], f.draft, f.surface, true, f.full, decoding)
                PaintBinding.bitmap
            }
            assertNotNull("full list opts into native cache window", f.full.cacheWindow)
            val old = row(4)
            try {
                assertTrue(held.await(2, TimeUnit.SECONDS))
                row(5); row(6)
                if (foreground) f.lifecycle.dispatch(Lifecycle.State.STARTED) else f.repository.close(f.view)
                assertNull(old())
                assertEquals("retired decode is still charged until actual exit", 1, decoding.resources()[1])
                release.countDown()
                settle(decoding)
                assertEquals(listOf(path(4)), f.paths.toList())
                assertEquals(0, decoding.resources()[2])
                if (foreground) f.lifecycle.dispatch(Lifecycle.State.RESUMED)
                assertNull("return cannot revive an old subscriber", old())
            } finally { release.countDown(); (4..6).forEach(f::dispose); settle(decoding) }
        }
    }

    @Test fun backToPreviewFencesPendingFullArtworkBeforeOldSlotDisposal() = retainedFullSlot(reenterBeforeDrain = false)

    @Test fun fullPreviewFullDoesNotReviveRetainedFullArtwork() = retainedFullSlot(reenterBeforeDrain = true)

    private fun retainedFullSlot(reenterBeforeDrain: Boolean) = fixture { f ->
        f.layout(0)
        val held = CountDownLatch(1)
        val release = CountDownLatch(1)
        val decoding = RadarArtworkPool(decode = { data ->
            val image = com.soundq.android.product.artwork.decodeArtwork(data, 192)
            if (image?.width == 20) { held.countDown(); check(release.await(6, TimeUnit.SECONDS)) }
            image
        }, reader = { f.art.read(it) })
        val freshSlot = HostComposition.Slot()
        fun row(route: HostRadarRoute, index: Int, slot: HostComposition.Slot = f.slots.getValue(index)) =
            HostComposition.render(slot) {
                route.row(f.art.client, f.repository, f.view, f.page, f.page.songs[index], f.draft, f.full, decoding)
                PaintBinding.bitmap to PaintBinding.published
            }
        fun previewRoute() = f.route().also { assertFalse("actual Back writer selected preview", it.full) }
        try {
            val preview = previewRoute()
            if (reenterBeforeDrain) preview.headingAll() else preview.rowAll()
            val full = f.route()
            assertTrue(full.full)
            val (active, activePublished) = row(full, 4)
            assertTrue("old unseen release reached real decode", held.await(2, TimeUnit.SECONDS))
            val (pending, pendingPublished) = row(full, 5)
            assertEquals(listOf(2, 1, 0, 0), decoding.resources())
            assertEquals(listOf(path(4)), f.paths.toList())

            if (reenterBeforeDrain) full.headerBack() else full.systemBack()
            assertTrue(f.repository.radarCurrent(f.view, f.page, f.page.songs[5], f.draft))
            val earlyFull = if (reenterBeforeDrain) {
                previewRoute().rowAll()
                f.route().also { assertTrue(it.full) }
            } else null // For the ordinary Back case even the route parent has not reapplied.
            // No old row rebind, draw read, disposal or new lease sweeps the pool before drain.
            assertEquals(listOf(2, 1, 0, 0), decoding.resources())
            release.countDown()
            settle(decoding)
            assertEquals("old full pending lease must not dispatch after Back (reentered=$reenterBeforeDrain)", listOf(path(4)), f.paths.toList())
            assertEquals("old decode must not enter the shared cache", 0, decoding.resources()[2])
            assertNull("held old decode must not publish", activePublished.value)
            assertNull("pending old row must not publish", pendingPublished.value)
            assertNull(active()); assertNull(pending())

            val freshFull = earlyFull ?: run { previewRoute().headingAll(); f.route() }
            assertTrue(freshFull.full)
            val (fresh, freshPublished) = row(freshFull, 5, freshSlot)
            settle(decoding)
            assertEquals(21, freshPublished.value?.width)
            assertEquals(listOf(path(4), path(5)), f.paths.toList())
            assertNull("fresh full owner must not revive old handles", pending())
            val pixels = fresh()
            val draw = DrawBoundary()
            draw.paint(pixels, fresh)
            assertEquals(1, draw.images)
            freshFull.systemBack()
            draw.paint(pixels, fresh)
            assertEquals("checked draw refuses an immediately retired, still-mounted full slot", 1, draw.images)
            assertEquals(1, f.metadata.server.requestCount)
        } finally {
            release.countDown()
            HostComposition.dispose(freshSlot)
            f.dispose(4); f.dispose(5)
            settle(decoding)
        }
    }

    @Test fun songEvidenceRetiresHeldAndPendingArtworkBeforeSlotCleanup() = evidenceCover(dismissBeforeDrain = false)

    @Test fun rapidSongEvidenceDismissDoesNotReviveRetainedArtwork() = evidenceCover(dismissBeforeDrain = true)

    private fun evidenceCover(dismissBeforeDrain: Boolean) = fixture { f ->
        f.layout(0)
        val held = CountDownLatch(1)
        val release = CountDownLatch(1)
        val pool = RadarArtworkPool(decode = { data ->
            val pixels = com.soundq.android.product.artwork.decodeArtwork(data, 192)
            if (pixels?.width == 20) { held.countDown(); check(release.await(6, TimeUnit.SECONDS)) }
            pixels
        }, reader = { f.art.read(it) })
        val freshSlot = HostComposition.Slot()
        fun bind(route: HostRadarRoute, index: Int, slot: HostComposition.Slot = f.slots.getValue(index)) =
            HostComposition.render(slot) {
                route.row(f.art.client, f.repository, f.view, f.page, f.page.songs[index], f.draft, f.full, pool)
                PaintBinding.bitmap to PaintBinding.published
            }
        try {
            f.route().rowAll()
            val full = f.route(); assertTrue(full.full)
            val (active, activePublished) = bind(full, 4)
            assertTrue("old speculative decode reached loopback and holds its permit", held.await(2, TimeUnit.SECONDS))
            val (pending, pendingPublished) = bind(full, 5)
            assertEquals(listOf(2, 1, 0, 0), pool.resources())
            full.open(f.page.songs.first())()
            val covered = f.route()
            val sheet = checkNotNull(covered.evidence)
            assertTrue(covered.full && covered.hasEvidence())
            assertTrue("sheet keeps the original repository landing", f.repository.radarCurrent(f.view, f.page, f.page.songs[5], f.draft))
            if (dismissBeforeDrain) sheet.dismiss() // No uncovered route apply until after the old finally.
            assertEquals(listOf(2, 1, 0, 0), pool.resources())
            assertEquals(listOf(path(4)), f.paths.toList())
            release.countDown()
            settle(pool)
            assertEquals("retired unseen slot must not dispatch (dismissed=$dismissBeforeDrain)", listOf(path(4)), f.paths.toList())
            assertEquals("no retired cache publication", 0, pool.resources()[2])
            assertNull(activePublished.value); assertNull(pendingPublished.value)
            assertNull(active()); assertNull(pending())
            assertEquals(dismissBeforeDrain, !covered.hasEvidence())
            assertNull("covered list grants no fresh row owner", covered.owner)
            if (!dismissBeforeDrain) sheet.dismiss()
            val fresh = f.route()
            assertTrue(fresh.full); assertNull(fresh.evidence); assertNotSame(full.owner, fresh.owner)
            val (pixels, _) = bind(fresh, 5, freshSlot)
            settle(pool)
            assertEquals(21, pixels()?.width)
            assertNull("fresh owner cannot lend authority to pending handle", pending())
            assertEquals(listOf(path(4), path(5)), f.paths.toList())
            assertEquals(1, f.metadata.server.requestCount)
        } finally {
            release.countDown()
            HostComposition.dispose(freshSlot)
            f.dispose(4); f.dispose(5); settle(pool)
        }
    }

    @Test fun songEvidenceRetainedRowAndSheetCallbacksCannotTargetSuccessor() = fixture { f ->
        f.route().headingAll()
        val song = f.page.songs.first()
        val oldOpen = f.route().open(song)
        oldOpen()
        val a = checkNotNull(f.route().evidence)
        a.dismiss()
        oldOpen()
        assertFalse("retained row cannot reopen a dismissed sheet", f.route().hasEvidence())
        f.route().open(song)()
        val b = f.route()
        val current = checkNotNull(b.evidence)
        a.dismiss()
        assertTrue("same-song successor survives old dismiss", b.hasEvidence())
        enqueueFind(f, song)
        checkNotNull(a.find)()
        f.settleActions()
        assertEquals("old sheet cannot issue membership even with same accepted row", 1, f.metadata.server.requestCount)
        checkNotNull(current.find)()
        verifyFind(f, song)
    }

    @Test fun currentSongEvidenceFindSourcesPreservesLandingAndAutoDismissesOnDraftChange() = fixture { f ->
        val preview = f.route()
        val song = f.page.songs.first()
        preview.open(song)()
        val current = checkNotNull(f.route().evidence)
        assertTrue(f.repository.radarCurrent(f.view, f.page, song, f.draft))
        enqueueFind(f, song)
        checkNotNull(current.find)()
        verifyFind(f, song)
        // The view, accepted page and old blank draft can all return through real search Back.
        val invalid = f.route()
        assertNull(invalid.evidence)
        assertFalse("invalidation clears the selection, not just the rendered sheet", invalid.hasEvidence())
        assertTrue(f.repository.back(f.view))
        assertTrue(f.repository.radarCurrent(f.view, f.page, song, f.draft))
        assertNull("auto-dismissed sheet cannot revive on return to the same draft", f.route().evidence)
        val fresh = f.route()
        val owner = checkNotNull(fresh.owner)
        assertNotSame(preview.owner, owner)
        fresh.open(song)()
        assertNotNull(f.route().evidence)
        assertEquals(3, f.metadata.server.requestCount)
    }

    private fun enqueueFind(f: Fixture, song: RadarSong) {
        val query = JsonPrimitive("${song.title} ${song.artist}")
        f.metadata.reply("""{"recordingMbid":"${song.recording.value}","inLibrary":false}""")
        f.metadata.reply("""{"query":$query,"results":[],"providers":[{"provider":"youtube","status":"ok"}]}""")
    }

    private fun verifyFind(f: Fixture, song: RadarSong) {
        f.settleActions()
        val membership = checkNotNull(f.metadata.server.takeRequest(2, TimeUnit.SECONDS))
        assertEquals("/api/v1/me/discovery/releases/${song.recording.value}/membership", membership.url.encodedPath)
        val search = checkNotNull(f.metadata.server.takeRequest(2, TimeUnit.SECONDS))
        assertEquals("/api/v1/discovery/search", search.url.encodedPath)
        assertEquals("${song.title} ${song.artist}", search.url.queryParameter("q"))
        assertEquals("youtube,soundcloud,musicbrainz", search.url.queryParameter("providers"))
        assertEquals(DiscoveryPhase.Ready, f.repository.state.value.phase)
        assertEquals(search.url.queryParameter("q"), f.repository.state.value.results?.query)
        assertEquals(3, f.metadata.server.requestCount)
    }

    private fun fixture(test: (Fixture) -> Unit) = HttpsFixture().use { metadata ->
        CaaTlsFixture().use { art -> val f = Fixture(metadata, art); try { test(f) } finally { f.close() } }
    }

    companion object {
        private fun id(n: Int) = "%08x-1111-4111-8111-111111111111".format(n)
        private fun path(index: Int) = "/release-group/${id(index + 1)}/front-250"
        private fun imageResponse(index: Int): MockResponse {
            val bytes = ByteArrayOutputStream()
            ImageIO.write(BufferedImage(16 + index, 16, BufferedImage.TYPE_INT_RGB), "png", bytes)
            return MockResponse.Builder().body(Buffer().write(bytes.toByteArray())).build()
        }
        private fun await(done: () -> Boolean) {
            val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
            while (!done() && System.nanoTime() < end) Thread.sleep(2)
            assertTrue("timed out waiting for the production artwork boundary", done())
        }
        private fun settle(pool: RadarArtworkPool) = await { pool.resources()[1] == 0 }
    }
}
