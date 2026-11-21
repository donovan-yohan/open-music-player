package com.soundq.android

import android.content.ContentValues
import android.os.Environment
import android.provider.MediaStore
import androidx.compose.ui.test.*
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import android.graphics.Bitmap
import android.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.text.TextLayoutResult
import com.soundq.android.data.AuthState
import com.soundq.android.data.discovery.CaaArtworkRead
import com.soundq.android.data.deviceaudio.LocalAppliedCover
import com.soundq.android.product.discovery.RadarArtworkPool
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.Socket
import java.net.SocketAddress
import javax.net.SocketFactory
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import okio.Buffer
import com.soundq.android.data.deviceaudio.LocalDisplayText
import com.soundq.android.data.deviceaudio.decodeDomain
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit.SECONDS
import java.util.concurrent.atomic.AtomicInteger
import java.util.UUID
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.RecordedRequest
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Ordinary Library → More → Enrich journey, using the real catalog, client, consent and device-only Apply. */
@SdkSuppress(minSdkVersion = 30)
class LocalEnrichmentJourneyTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val graph get() = (instrumentation.targetContext.applicationContext as FixtureApplication).graph
    private fun sheet(label: String) = compose.onNode(hasText(label) and hasAnyAncestor(isDialog()))
    private fun click(label: String) {
        compose.onNode(hasText(label) and hasClickAction() and hasAnyAncestor(isDialog())).performScrollTo().assertIsDisplayed().performClick()
    }
    private fun waitFor(label: String) = compose.waitUntil(15_000) { compose.onAllNodes(hasText(label) and hasAnyAncestor(isDialog())).fetchSemanticsNodes().isNotEmpty() }
    private fun open(title: String) {
        val more = "More for $title"
        compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasContentDescription(more))
        compose.onNodeWithContentDescription(more).assertIsDisplayed().performClick()
        click("Enrich metadata")
        waitFor("Look up metadata")
    }

    private fun uniquelyTaggedFixture(): Pair<String, ByteArray> {
        val bytes = instrumentation.context.assets.open("local-audio/embedded-cover.flac").use { it.readBytes() }
        val marker = "Mounted Long 601".encodeToByteArray()
        val title = "Cover QA ${UUID.randomUUID().toString().take(7)}"
        val replacement = title.encodeToByteArray()
        require(replacement.size == marker.size)
        val start = (0..bytes.size-marker.size).single { i -> marker.indices.all { j -> bytes[i+j] == marker[j] } }
        replacement.copyInto(bytes, start)
        return title to bytes
    }

    @Test fun discloseCancelPreviewAndApplyOnlyLocalText() {
        assertTrue("Test-owned AVD must grant all-files access to this fixture", Environment.isExternalStorageManager())
        compose.signInThroughSettings("enrich-fixture@example.test", "fixture-only-password") { graph.session.state.value is AuthState.SignedIn }
        compose.waitUntil(15_000) { graph.library.state.value.rows.size == 3 && graph.phoneAudio.state.value.ready }
        val media = instrumentation.targetContext.contentResolver
        val (originalTitle, original) = uniquelyTaggedFixture()
        val uri = checkNotNull(media.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, "enrich-fixture-original.flac")
            put(MediaStore.MediaColumns.MIME_TYPE, "audio/flac")
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_MUSIC + "/SoundQ Enrich qualification")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }))
        val server = ProductTransportFixture.server
        val fallback = server.dispatcher
        val received = CopyOnWriteArrayList<String>()
        val writes = CopyOnWriteArrayList<String>()
        val code = AtomicInteger(0)
        val entered = CountDownLatch(1)
        val releaseHeld = CountDownLatch(1)
        val ended = CountDownLatch(1)
        val acceptedTitle = "Qualified studio ${UUID.randomUUID().toString().take(8)}"
        val first = """{"recordingMbid":"11111111-2222-4333-8444-555555555555","title":"$acceptedTitle","artist":"Qualified artist","album":"Qualified album","durationMs":2000,"releaseMbid":"22222222-2222-4333-8444-555555555555"}"""
        val other = """{"recordingMbid":"33333333-2222-4333-8444-555555555555","title":"Different live recording","artist":"Other artist","durationMs":602000}"""
        val suggestions = """{"status":"suggestions","candidates":[$first,$other]}"""
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.url.encodedPath
                if (path != "/api/v1/musicbrainz/local-enrichment/suggestions") {
                    // AppGraph starts DevicePresence independently of Library or this journey.
                    // Its fixture 404 can schedule repeated registration POSTs; do not count
                    // that exact route as upload, verification, playback, or Enrich mutation.
                    val presenceRegistration = request.method == "POST" && path == "/api/v1/me/devices"
                    if (!presenceRegistration && request.method !in setOf("GET", "HEAD")) writes.add(request.method + " " + path)
                    return fallback.dispatch(request)
                }
                check(request.method == "POST" && request.url.query == null)
                check(request.headers["Authorization"] == "Bearer synthetic-fixture-access")
                check(request.headers["Cache-Control"] == "no-store")
                received.add(request.body!!.utf8())
                return when (code.get()) {
                    404 -> MockResponse.Builder().code(404).build()
                    1 -> MockResponse.Builder().body("""{"status":"no_match","candidates":[]}""").build()
                    2 -> MockResponse.Builder().body("""{"status":"ambiguous","reason":"similar_candidates","candidates":[$first,$other]}""").build()
                    3 -> {
                        entered.countDown(); check(releaseHeld.await(15, SECONDS)); ended.countDown()
                        MockResponse.Builder().body(suggestions).build()
                    }
                    4 -> MockResponse.Builder().body(suggestions).build()
                    else -> { writes.add("unexpected lookup"); MockResponse.Builder().code(503).build() }
                }
            }
        }
        try {
            media.openOutputStream(uri, "w")!!.use { it.write(original) }
            assertEquals(1, media.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null))
            val phone = graph.phoneAudio.awaitIndexed(uri) { it.metadata.title == originalTitle }
            // The FLAC contains no album tag. Android's audio index fills it with the directory;
            // this sentinel must not appear in the disclosed lookup or the exact request bodies.
            assertEquals("SoundQ Enrich qualification", phone.metadata.album)
            val title = phone.displayTitle
            val start = graph.controller.state.value
            fun row() = graph.phoneAudio.state.value.snapshot!!.files.single { it.owner == phone.owner }
            val history = graph.phoneAudio.state.value.snapshot!!.history
            assertTrue(received.isEmpty())
            open(title)
            sheet("No audio, file path, URI, fingerprint or artwork is sent.").performScrollTo().assertIsDisplayed()
            assertTrue("Opening consent must not look up anything", received.isEmpty())
            captureListeningStage("enrich-disclosure")
            click("Cancel")
            waitFor("Enrich metadata")
            assertTrue(received.isEmpty())
            assertNull(row().displayOverride)
            click("Enrich metadata"); waitFor("Look up metadata")
            code.set(404); click("Look up metadata"); waitFor("Enrich is not available on this server.")
            sheet("Apply selected details").assertDoesNotExist(); click("Cancel")
            click("Enrich metadata"); waitFor("Look up metadata")
            code.set(1); click("Look up metadata"); waitFor("No match found.")
            code.set(2); click("Look up metadata"); waitFor("MusicBrainz found similar matches. Refine the search or keep your current details.")
            sheet("Apply selected details").assertDoesNotExist()
            code.set(3); click("Look up metadata")
            compose.waitUntil(15_000) { entered.count == 0L }
            click("Cancel")
            releaseHeld.countDown(); assertTrue(ended.await(3, SECONDS))
            waitFor("Enrich metadata"); sheet("Review track details").assertDoesNotExist()
            assertNull(row().displayOverride)
            click("Enrich metadata"); waitFor("Look up metadata")
            click("Include duration: ${phone.durationMs} ms")
            compose.onNode(hasText("Search album (optional)") and hasSetTextAction() and hasAnyAncestor(isDialog()))
                .performScrollTo().performTextReplacement("Reviewed album")
            code.set(4); click("Look up metadata"); waitFor("Choose a MusicBrainz match")
            sheet("Apply selected details").assertDoesNotExist()
            click(acceptedTitle)
            sheet("Title · Current: $originalTitle").performScrollTo().assertIsDisplayed()
            sheet("Title · Suggested: $acceptedTitle").performScrollTo().assertIsDisplayed()
            sheet("Use suggested album: Qualified album").performScrollTo().assertIsOff()
            sheet("Use suggested title: $acceptedTitle").performScrollTo().assertIsOff()
            click("Use suggested title: $acceptedTitle")
            click("Use suggested artist: Qualified artist")
            sheet("Not previewed").performScrollTo().assertIsDisplayed()
            assertNull(row().displayOverride)
            captureListeningStage("enrich-preview")
            sheet("Apply selected details").performScrollTo().assertIsDisplayed()
            captureListeningStage("enrich-apply")
            code.set(0) // from here the fixture refuses any further lookup; Apply must not contact it.
            click("Apply selected details")
            waitFor("Metadata updated in SoundQ")
            assertEquals(LocalDisplayText(acceptedTitle, "Qualified artist", null), row().displayOverride?.text)
            assertEquals(phone.metadata, row().metadata)
            assertEquals(phone.aliases, row().aliases)
            assertEquals(history, graph.phoneAudio.state.value.snapshot!!.history)
            assertEquals(start.queue, graph.controller.state.value.queue)
            assertEquals(start.selectedOccurrence, graph.controller.state.value.selectedOccurrence)
            assertArrayEquals(original, media.openInputStream(uri)!!.use { it.readBytes() })
            assertEquals(List(4) { """{"title":"$originalTitle","artist":"Owned Mounted QA","durationMs":${phone.durationMs}}""" } +
                """{"title":"$originalTitle","artist":"Owned Mounted QA","album":"Reviewed album"}""", received.toList())
            assertTrue("No upload, verification, or playback mutation expected: $writes", writes.isEmpty())
            compose.onNodeWithContentDescription("Close $acceptedTitle").performScrollTo().performClick()
            val version = graph.session.version()
            // A newly indexed, test-owned marker positively proves the scan published, not
            // merely that the pre-existing complete snapshot was still exposed.
            val marker = checkNotNull(media.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, "enrich-scan-${UUID.randomUUID()}.flac")
                put(MediaStore.MediaColumns.MIME_TYPE, "audio/flac")
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_MUSIC + "/SoundQ Enrich qualification")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }))
            try {
                media.openOutputStream(marker, "w")!!.use { it.write(original) }
                assertEquals(1, media.update(marker, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null))
                assertNotEquals(phone.id, graph.phoneAudio.awaitIndexed(marker, { graph.session.owns(version) }).id)
                assertEquals(acceptedTitle, row().displayTitle)
            } finally { assertEquals(1, media.delete(marker, null, null)) }
            compose.activityRule.scenario.recreate()
            compose.waitUntil(15_000) { compose.onAllNodesWithContentDescription("Refine library").fetchSemanticsNodes().isNotEmpty() }
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasContentDescription("More for $acceptedTitle"))
            compose.onNodeWithContentDescription("More for $acceptedTitle").assertIsDisplayed()
            assertEquals("Qualified artist", row().displayArtist)
            assertEquals(5, received.size)
        } finally {
            releaseHeld.countDown()
            server.dispatcher = fallback
            assertEquals("Remove only the test-owned MediaStore item", 1, media.delete(uri, null, null))
        }
    }

    @Test fun abandonedApplyRecoversThroughOrdinaryLocalAudioSettings() {
        assertTrue(Environment.isExternalStorageManager())
        compose.signInThroughSettings("enrich-fixture@example.test", "fixture-only-password") { graph.session.state.value is AuthState.SignedIn }
        val app = instrumentation.targetContext.applicationContext as FixtureApplication
        val phone = graph.phoneAudio
        val version = graph.session.version()
        val media = app.contentResolver
        val (originalTitle, original) = uniquelyTaggedFixture()
        val acceptedTitle = "Recovered in Settings ${UUID.randomUUID().toString().take(8)}"
        val uri = checkNotNull(media.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, "settings-retry-${UUID.randomUUID()}.flac")
            put(MediaStore.MediaColumns.MIME_TYPE, "audio/flac")
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_MUSIC + "/SoundQ Enrich qualification")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }))
        val server = ProductTransportFixture.server
        val fallback = server.dispatcher
        val lookups = AtomicInteger()
        val injected = AtomicBoolean()
        val disk = java.io.File(graph.directory, "phone-listening.v1.json")
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.url.encodedPath != "/api/v1/musicbrainz/local-enrichment/suggestions") return fallback.dispatch(request)
                assertEquals("POST", request.method)
                if (lookups.incrementAndGet() != 1) return MockResponse.Builder().code(409).build()
                return MockResponse.Builder().body("""{"status":"suggestions","candidates":[{"recordingMbid":"11111111-2222-4333-8444-555555555555","title":"$acceptedTitle"}]}""").build()
            }
        }
        try {
            media.openOutputStream(uri, "w")!!.use { it.write(original) }
            assertEquals(1, media.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null))
            val row = phone.awaitIndexed(uri) { it.metadata.title == originalTitle }
            compose.waitUntil(15_000) { !phone.state.value.refreshing }
            open(originalTitle)
            click("Look up metadata")
            waitFor("Choose a MusicBrainz match")
            click(acceptedTitle)
            click("Use suggested title: $acceptedTitle")
            app.phoneAudioCommitFault = { phase ->
                if (phase == "afterReplace" && injected.compareAndSet(false, true)) throw java.io.IOException("Injected failure after atomic replace")
            }
            click("Apply selected details")
            waitFor("Save not confirmed.")
            app.phoneAudioCommitFault = null
            assertTrue(injected.get())
            val attempted = decodeDomain(disk.readBytes()).files.single { it.id == row.id }
            assertEquals(LocalDisplayText(acceptedTitle, null, null), attempted.displayOverride?.text)

            // Fixture reaches the already-accepted live-Check unpublication seam. The later
            // recovery must come only from a real tap on Settings' existing button.
            phone.refresh { phone.current(version) }
            compose.waitUntil(60_000) { phone.state.value.let { !it.ready && !it.refreshing && it.permission && it.snapshot == null && it.message != null } }
            sheet("Check saved details").performScrollTo().assertIsDisplayed()
            click("Close")
            compose.onNodeWithContentDescription("Close $originalTitle").performClick()
            compose.onNodeWithContentDescription("More for $originalTitle").assertDoesNotExist()
            compose.onNodeWithContentDescription("Settings").assertIsDisplayed().performClick()
            compose.onNode(hasText("Local audio") and hasClickAction()).performScrollTo().performClick()
            compose.onNode(hasText("Local audio") and isHeading()).assertIsDisplayed()
            assertNull("Mounting Settings is not a retry", phone.state.value.snapshot)
            compose.onNode(hasText("Try again") and hasClickAction()).performScrollTo().assertIsDisplayed().performClick()
            compose.waitUntil(60_000) { phone.state.value.let { !it.refreshing && it.snapshot?.files?.singleOrNull { file -> file.id == row.id }?.displayTitle == acceptedTitle } }
            val restored = phone.state.value.snapshot!!.files.single { it.id == row.id }
            assertEquals(row.owner, restored.owner)
            assertEquals(attempted.displayOverride, restored.displayOverride) // exact attempted revision; no second Apply
            assertArrayEquals(original, media.openInputStream(uri)!!.use { it.readBytes() })
            repeat(2) { compose.onNodeWithContentDescription("Back").performClick() }
            val more = "More for $acceptedTitle"
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasContentDescription(more))
            compose.onNodeWithContentDescription(more).assertIsDisplayed()
            assertEquals("Only the original consented lookup was sent", 1, lookups.get())
        } finally {
            app.phoneAudioCommitFault = null
            server.dispatcher = fallback
            assertEquals(1, media.delete(uri, null, null))
        }
    }

    @Test fun disclosePreviewAndApplyArtworkIndependently() {
        assertTrue(Environment.isExternalStorageManager())
        val enlarged = InstrumentationRegistry.getArguments().getString("enrichEnlarged") == "true"
        compose.signInThroughSettings("enrich-fixture@example.test", "fixture-only-password") { graph.session.state.value is AuthState.SignedIn }
        compose.waitUntil(15_000) { graph.library.state.value.rows.size == 3 && graph.phoneAudio.state.value.ready }
        val media = instrumentation.targetContext.contentResolver
        val (originalTitle, original) = uniquelyTaggedFixture()
        val uri = checkNotNull(media.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, if (enlarged) "enrich-art-owned-enlarged.flac" else "enrich-art-owned-original.flac")
            put(MediaStore.MediaColumns.MIME_TYPE, "audio/flac")
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_MUSIC + "/SoundQ Enrich artwork fixture")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }))
        val edition = "22222222-2222-4333-8444-555555555555"
        val group = "33333333-2222-4333-8444-555555555555"
        val title = "Enrich fixture ${if (enlarged) "accepted" else "normal"} cover ${UUID.randomUUID().toString().take(6)}"
        val suggestions = """{"status":"suggestions","candidates":[{"recordingMbid":"11111111-2222-4333-8444-555555555555","title":"$title","artist":"Unused proposed artist","releaseMbid":"$edition"},{"recordingMbid":"44444444-2222-4333-8444-555555555555","title":"Other candidate","releaseGroupMbid":"$group"}]}"""
        val cert = HeldCertificate.Builder().addSubjectAlternativeName("coverartarchive.org").addSubjectAlternativeName("archive.org").build()
        val trust = HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        val caa = MockWebServer().apply { useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory()); start() }
        val bound = caa.socketAddress.also { check(it.address.isLoopbackAddress) }
        val sockets = object: SocketFactory() {
            override fun createSocket(): Socket = object: Socket() {
                override fun connect(endpoint: SocketAddress, timeout: Int) { super.connect(bound, timeout) }
            }
            override fun createSocket(h: String, p: Int) = error("unexpected overload")
            override fun createSocket(h: String, p: Int, l: InetAddress, lp: Int) = error("unexpected overload")
            override fun createSocket(h: InetAddress, p: Int) = error("unexpected overload")
            override fun createSocket(h: InetAddress, p: Int, l: InetAddress, lp: Int) = error("unexpected overload")
        }
        val caaClient = OkHttpClient.Builder().dns { listOf(bound.address) }.socketFactory(sockets)
            .sslSocketFactory(trust.sslSocketFactory(), trust.trustManager)
            .addInterceptor { error("unstripped authenticated interceptor") }.build()
        val fallback = ProductTransportFixture.server.dispatcher
        val originalPool = graph.enrichmentArtworkPool
        val pool = RadarArtworkPool(reader = { CaaArtworkRead(caaClient, addressAllowed = { it == bound.address }) })
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val observations = CopyOnWriteArrayList<String>()
        val lookups = AtomicInteger()
        val applyStarted = java.util.concurrent.atomic.AtomicBoolean(false)
        val violations = CopyOnWriteArrayList<String>()
        var keepOriginal = false
        val bitmap = Bitmap.createBitmap(32, 32, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.MAGENTA) }
        val png = ByteArrayOutputStream().also { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)); bitmap.recycle() }.toByteArray()
        caa.dispatcher = object: Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val url = request.url
                val path = url.encodedPath
                if (applyStarted.get() || request.method != "GET" || url.query != null || request.bodySize != 0L ||
                    listOf("Authorization", "Proxy-Authorization", "Cookie", "Referer").any { request.headers[it] != null }) {
                    violations.add("unexpected CAA request shape"); return MockResponse.Builder().code(400).build()
                }
                val target = request.headers["Host"] + path
                observations.add(target)
                return when (target) {
                    "coverartarchive.org/release-group/$group/front-250" -> MockResponse.Builder().code(404).build()
                    "coverartarchive.org/release/$edition/front-250" -> {
                        if (entered.count > 0L) {
                            entered.countDown(); check(release.await(12, SECONDS))
                            MockResponse.Builder().body(Buffer().write(png)).build()
                        } else MockResponse.Builder().code(307).addHeader("Location", "https://archive.org/download/fixture/front.jpg").build()
                    }
                    "archive.org/download/fixture/front.jpg" -> MockResponse.Builder().addHeader("Content-Type", "image/png").body(Buffer().write(png)).build()
                    else -> { violations.add("unexpected CAA target"); MockResponse.Builder().code(400).build() }
                }
            }
        }
        ProductTransportFixture.server.dispatcher = object: Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.url.encodedPath.endsWith("/local-enrichment/suggestions")) {
                    lookups.incrementAndGet()
                    check(request.method == "POST" && request.headers["Authorization"] == "Bearer synthetic-fixture-access" &&
                        request.body!!.utf8().startsWith("{\"title\":\"$originalTitle\",\"artist\":\"Owned Mounted QA\",\"durationMs\":"))
                    return MockResponse.Builder().body(suggestions).build()
                }
                if (request.method !in setOf("GET", "HEAD") && request.url.encodedPath != "/api/v1/me/devices") violations.add("unexpected app wire mutation")
                return fallback.dispatch(request)
            }
        }
        try {
            graph.enrichmentArtworkPool = pool
            media.openOutputStream(uri, "w")!!.use { it.write(original) }
            assertEquals(1, media.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null))
            val phone = graph.phoneAudio.awaitIndexed(uri) { it.metadata.title == originalTitle }
            fun row() = graph.phoneAudio.state.value.snapshot!!.files.single { it.owner == phone.owner }
            val history = graph.phoneAudio.state.value.snapshot!!.history
            val selection = graph.controller.state.value.selectedOccurrence
            open(phone.displayTitle)
            click("Look up metadata"); waitFor("Choose a MusicBrainz match"); click("Other candidate")
            assertTrue(observations.isEmpty())
            sheet("Public release group ID: $group").performScrollTo().assertIsDisplayed()
            click("Preview artwork")
            waitFor("No artwork")
            sheet("Use previewed artwork").assertDoesNotExist()
            assertNull(row().displayOverride)
            click(title); click("Preview artwork"); compose.waitUntil(12_000) { entered.count == 0L }
            click("Other candidate")
            release.countDown()
            compose.waitUntil(12_000) { pool.resources()[1] == 0 }
            sheet("Use previewed artwork").assertDoesNotExist()
            assertNull(row().displayOverride)
            click(title); click("Preview artwork")
            waitFor("Use previewed artwork")
            sheet("Use previewed artwork").assertIsOff()
            val preview = compose.onNodeWithTag("enrich-suggested-cover-pixels").performScrollTo().assertIsDisplayed()
            compose.waitUntil(5_000) {
                val pixels = preview.captureToImage().toPixelMap()
                val c = pixels[pixels.width / 2, pixels.height / 2]
                c.red > 0.90f && c.green < 0.10f && c.blue > 0.90f
            }
            fun fullyVisible(node: SemanticsNodeInteraction) {
                val reported = node.assertIsDisplayed().fetchSemanticsNode()
                val measured = reported.layoutInfo.coordinates.size
                assertTrue("clipped width", reported.boundsInRoot.width >= measured.width - 1)
                assertTrue("clipped height", reported.boundsInRoot.height >= measured.height - 1)
            }
            if (enlarged) {
                for (field in listOf("title", "artist", "album")) {
                    val fieldTag = "enrich-field-$field"
                    fullyVisible(compose.onNodeWithTag(fieldTag).performScrollTo())
                    val labels = compose.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsActions.GetTextLayoutResult) and hasAnyAncestor(hasTestTag(fieldTag)), useUnmergedTree = true)
                    assertTrue(labels.fetchSemanticsNodes().size >= 3)
                    captureListeningStage("enrich-field-$field")
                    for (i in labels.fetchSemanticsNodes().indices) {
                        val layout = mutableListOf<TextLayoutResult>()
                        labels[i].performSemanticsAction(SemanticsActions.GetTextLayoutResult) { assertTrue(it(layout)) }
                        val result = layout.single()
                        assertTrue(result.layoutInput.density.fontScale >= 1.45f)
                        assertFalse("clipped $field '${result.layoutInput.text.text}' size=${result.size} " +
                            "constraints=${result.layoutInput.constraints} width=${result.didOverflowWidth} height=${result.didOverflowHeight}", result.hasVisualOverflow)
                        fullyVisible(labels[i])
                    }
                }
            }
            fullyVisible(compose.onNodeWithTag("enrich-artwork-pair").performScrollTo())
            fullyVisible(compose.onNodeWithTag("enrich-current-cover"))
            fullyVisible(compose.onNodeWithTag("enrich-suggested-cover"))
            val originalTile = compose.onNodeWithTag("enrich-current-cover-pixels")
            compose.waitUntil(5_000) {
                val raster = originalTile.captureToImage().toPixelMap()
                val c = raster[raster.width / 4, raster.height / 4]
                c.red > 0.65f && c.green < 0.55f && c.blue < 0.55f
            }
            captureListeningStage("enrich-cover-preview")
            sheet("Use suggested artist: Unused proposed artist").performScrollTo().assertIsOff()
            val titleToggle = sheet("Use suggested title: $title").performScrollTo().assertIsOff()
            if (enlarged) fullyVisible(titleToggle)
            click("Use suggested title: $title")
            val artworkToggle = sheet("Use previewed artwork").performScrollTo().assertIsOff()
            if (enlarged) fullyVisible(artworkToggle)
            click("Use previewed artwork")
            fullyVisible(sheet("Apply selected details").performScrollTo())
            if (enlarged) {
                fullyVisible(sheet("Keep current details").performScrollTo())
                captureListeningStage("enrich-review-actions")
            }
            assertNull(row().displayOverride)
            applyStarted.set(true)
            click("Apply selected details"); waitFor("Metadata updated in SoundQ")
            assertEquals(LocalDisplayText(title, null, null), row().displayOverride?.text)
            val cover = checkNotNull(row().displayOverride?.artwork)
            assertEquals(LocalAppliedCover.Kind.RELEASE, cover.kind)
            assertEquals(edition, cover.mbid)
            assertEquals(phone.metadata, row().metadata)
            assertEquals(history, graph.phoneAudio.state.value.snapshot!!.history)
            assertEquals(selection, graph.controller.state.value.selectedOccurrence)
            assertArrayEquals(original, media.openInputStream(uri)!!.use { it.readBytes() })
            assertEquals(1, lookups.get())
            assertEquals(listOf("coverartarchive.org/release-group/$group/front-250",
                "coverartarchive.org/release/$edition/front-250", "coverartarchive.org/release/$edition/front-250",
                "archive.org/download/fixture/front.jpg"), observations.toList())
            assertTrue(violations.toString(), violations.isEmpty())
            compose.onNodeWithContentDescription("Close $title").performScrollTo().performClick()
            val more = "More for $title"
            compose.onNode(hasScrollToIndexAction()).performScrollToNode(hasContentDescription(more))
            // Query the containing real Phone Library row, not the preview slot.
            val rowOwner = hasAnyDescendant(hasText(title)) and hasAnyDescendant(hasContentDescription(more)) and hasClickAction()
            val appliedRow = compose.onNode(hasTestTag("media-artwork") and hasAnyAncestor(rowOwner), useUnmergedTree = true)
            compose.waitUntil(8_000) {
                val pixels = appliedRow.captureToImage().toPixelMap()
                val c = pixels[pixels.width / 2, pixels.height / 2]
                c.red > 0.9f && c.green < 0.1f && c.blue > 0.9f
            }
            captureListeningStage("enrich-cover-applied")
            val marker = checkNotNull(media.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, "enrich-art-scan-${UUID.randomUUID()}.flac")
                put(MediaStore.MediaColumns.MIME_TYPE, "audio/flac")
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_MUSIC + "/SoundQ Enrich artwork fixture")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }))
            try {
                media.openOutputStream(marker, "w")!!.use { it.write(original) }
                assertEquals(1, media.update(marker, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null))
                val peer = graph.phoneAudio.awaitIndexed(marker)
                assertNotEquals(phone.id, peer.id)
                assertNull(peer.displayOverride)
                assertEquals(cover, row().displayOverride?.artwork)
                assertEquals(title, row().displayTitle)
                assertArrayEquals(original, media.openInputStream(uri)!!.use { it.readBytes() })
            } finally { assertEquals(1, media.delete(marker, null, null)) }
            assertEquals(1, lookups.get())
            assertEquals(4, observations.size)
            keepOriginal = InstrumentationRegistry.getArguments().getString("preserveEnrichOriginal") == "true"
        } finally {
            release.countDown()
            graph.enrichmentArtworkPool = originalPool
            ProductTransportFixture.server.dispatcher = fallback
            caa.close()
            caaClient.connectionPool.evictAll(); caaClient.dispatcher.executorService.shutdownNow()
            if (!keepOriginal) assertEquals(1, media.delete(uri, null, null))
        }
    }

}
