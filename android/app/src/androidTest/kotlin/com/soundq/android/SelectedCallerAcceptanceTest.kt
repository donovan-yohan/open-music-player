package com.soundq.android

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import com.soundq.android.data.offline.DownloadStatus
import com.soundq.android.playback.SoundQLibraryService
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger
import javax.crypto.KeyGenerator
import kotlin.math.*

/** Preparatory ordinary Native qualification. Parent runs each method in fresh instrumentation. */
class SelectedCallerAcceptanceTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val app get() = instrumentation.targetContext.applicationContext as CallbackFrontendFixtureApplication
    private val outside = !hasAnyAncestor(isDialog())
    private fun row() = hasClickAction() and hasAnyDescendant(hasText("Fixture 1")) and
        hasAnyDescendant(hasContentDescription("More for Fixture 1")) and outside
    private fun action(name: String, dialog: Boolean = false) = compose.onNode(hasContentDescription(name) and
        if (dialog) hasAnyAncestor(isDialog()) else outside)
    private fun click(text: String) = compose.onAllNodesWithText(text).filterToOne(hasClickAction()).performScrollTo().performClick()
    private fun model() = compose.runOnIdle { ViewModelProvider(compose.activity)[ProductViewModel::class.java] }
    private fun output(name: String, text: String) {
        val label = InstrumentationRegistry.getArguments().getString("captureLabel") ?: "default"
        require(label.matches(Regex("[a-zA-Z0-9-]+")))
        val dir = File(instrumentation.targetContext.getExternalFilesDir(null), "listening-20261105/$label")
        check(dir.mkdirs() || dir.isDirectory)
        File(dir, "$name.txt").writeText(text)
    }
    private fun pause(model: ProductViewModel) {
        assertEquals("com.soundq.android.playback.nativeengine.NativeCallbackPlayer", app.callbackPlayer.javaClass.name)
        compose.onNode(row(), useUnmergedTree = true).performScrollTo().performClick()
        try {
            compose.waitUntil(20000) { model.playback.value.let { it.title == "Fixture 1" && it.isPlaying && it.positionMs >= 300 } }
        } catch (failure: Throwable) {
            runCatching {
                val state = model.playback.value
                val observed = runCatching { compose.runOnIdle { acknowledgedQueueObservation(model).diagnostic.toString() } }
                    .getOrElse { "unavailable:${it.javaClass.simpleName}" }
                output("pause-failure", "connection=${state.connection}\ntitle=${state.title}\nplaying=${state.isPlaying}\n" +
                    "preparing=${state.preparing}\ncanPlay=${state.canPlay}\nlocalOnly=${state.localOnly}\nsource=${state.source}\n" +
                    "cursor=${state.positionMs}\nduration=${state.durationMs}\nselected=${state.selectedOccurrence}\nqueue=${state.queue.map { it.trackId }}\n" +
                    "error=${state.error?.replace(Regex("""https?://\S+|file://\S+"""),"[uri]")}\n" +
                    "modelUsesInstalledGraph=${model.graph === app.graph}\nobservation=$observed\n")
                captureListeningStage("pause-failure")
            }.exceptionOrNull()?.let(failure::addSuppressed)
            throw failure
        }
        action("Pause").performClick()
        compose.waitUntil(10000) { !model.playback.value.isPlaying && !model.playback.value.preparing }
    }
    private fun half(model: ProductViewModel) {
        val before = model.playback.value
        compose.onNode(hasContentDescription("Fixture 1, Synthetic ensemble") and outside).performClick()
        action("Playback position", true).performSemanticsAction(SemanticsActions.SetProgress) { it(.5f) }
        compose.waitUntil(10000) { model.playback.value.let {
            it.selectedOccurrence == before.selectedOccurrence && !it.isPlaying && !it.preparing && abs(it.positionMs - 6000) <= 100
        } }
        action("Close Now playing", true).performClick()
        assertEquals(before.selectedOccurrence, model.playback.value.selectedOccurrence)
        assertNull(model.playback.value.error)
    }
    private fun paint(): Pair<Int, Int> {
        val node = compose.onNode(hasTestTag("compact-artwork") and outside, useUnmergedTree = true).fetchSemanticsNode()
        val b = node.boundsInRoot
        return compose.runOnIdle {
            val view = (node.root as ViewRootForTest).view
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            try {
                view.draw(Canvas(bitmap))
                var colored = 0; var area = 0
                for (y in ceil(b.top).toInt() until floor(b.bottom).toInt())
                    for (x in ceil(b.left).toInt() until floor(b.right).toInt()) {
                        area++
                        if (bitmap.getPixel(x,y) == android.graphics.Color.MAGENTA) colored++
                    }
                colored to area
            } finally { bitmap.recycle() }
        }
    }
    private fun clockAndProgress(model: ProductViewModel, stage: String, colored: Boolean) {
        // Capture the complete phone BEFORE geometry assertions, including on a genuine regression.
        captureListeningStage(stage)
        val art = compose.onNode(hasTestTag("compact-artwork") and outside, useUnmergedTree = true).fetchSemanticsNode()
        val identity = compose.onNode(hasContentDescription("Fixture 1, Synthetic ensemble") and hasClickAction() and outside)
            .fetchSemanticsNode()
        val band = SemanticsMatcher("actual compact band and footer") {
            it.boundsInRoot.top >= art.boundsInRoot.top - 3 * compose.density.density &&
                it.boundsInRoot.bottom <= identity.parent!!.boundsInRoot.bottom + 60 * compose.density.density
        } and outside
        val clock = compose.onNode(hasText("0:06 / 0:12") and band, useUnmergedTree = true).assertIsDisplayed()
        val layouts = mutableListOf<TextLayoutResult>()
        clock.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        val layout = layouts.single()
        val token = clock.fetchSemanticsNode()
        val allocation = token.boundsInRoot
        val parent = token.parent!!.boundsInRoot
        val pixels = if (colored) paint() else 0 to 0
        // Real owning View paint, not an app-output substitute. Layout containment
        // proves complete allocation; distinctive ink in EACH nonspace glyph proves paint.
        val glyphInk = compose.runOnIdle {
            val view = (token.root as ViewRootForTest).view
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            try {
                view.draw(Canvas(bitmap))
                val background = bitmap.getPixel(floor(allocation.left).toInt(), floor(allocation.top).toInt())
                layout.layoutInput.text.text.indices.filter { !layout.layoutInput.text.text[it].isWhitespace() }.map { i ->
                    val g = layout.getBoundingBox(i)
                    var ink = 0
                    val left = max(0,ceil(allocation.left + g.left).toInt())
                    val right = min(bitmap.width,floor(allocation.left + g.right).toInt())
                    val top = max(0,ceil(allocation.top + g.top).toInt())
                    val bottom = min(bitmap.height,floor(allocation.top + g.bottom).toInt())
                    for(y in top until bottom) for(x in left until right) if(bitmap.getPixel(x,y) != background) ink++
                    i to ink
                }
            } finally { bitmap.recycle() }
        }
        val controls = listOf("Play", "Open listening queue").map { name -> name to action(name).fetchSemanticsNode().boundsInRoot }
        output(stage, "fontScale=${compose.density.fontScale}\nart=${art.boundsInRoot}\nidentity=${identity.boundsInRoot}\n" +
            "clock=$allocation\nclockParent=$parent\nnaturalClockWidth=${layout.multiParagraph.intrinsics.maxIntrinsicWidth}\n" +
            "layoutSize=${layout.size}\nparagraphWidth=${layout.multiParagraph.width}\ninputConstraints=${layout.layoutInput.constraints}\n" +
            "inputMaxLines=${layout.layoutInput.maxLines}\ninputSoftWrap=${layout.layoutInput.softWrap}\nlineLeft=${layout.getLineLeft(0)}\nlineRight=${layout.getLineRight(0)}\n" +
            "didOverflowWidth=${layout.didOverflowWidth}\ndidOverflowHeight=${layout.didOverflowHeight}\n" +
            "glyphInk=$glyphInk\nartChildren=${art.children.map { it.boundsInRoot }}\nmagenta=${pixels.first}\nouterArea=${pixels.second}\ncontrols=$controls\n" +
            "occurrence=${model.playback.value.selectedOccurrence}\ncursor=${model.playback.value.positionMs}\n")
        if (colored) {
            assertEquals("Outer admitted art cell remains square", art.boundsInRoot.width, art.boundsInRoot.height, 1f)
            assertEquals("Artwork square follows actual identity-row height", identity.boundsInRoot.height, art.boundsInRoot.height, 1f)
            assertTrue("Admitted pixels fill >=90% of OUTER art cell: $pixels", pixels.second > 0 && pixels.first.toDouble()/pixels.second >= .90)
        }
        assertTrue("Every nonspace clock glyph paints inside its allocated cell: $glyphInk", glyphInk.all { it.second > 0 })
        // Compose 1.12.1 reconstructs a wider semantics paragraph for simple String Text.
        // ClockLayoutObservationControlTest proves fit/real-clipping sensitivity without changing that path.
        assertTrue("Painted clock lines fit their allocated cell", (0 until layout.lineCount).all {
            layout.getLineLeft(it)>=-.5f && layout.getLineRight(it)<=allocation.width+.5f
        })
        assertFalse("Clock must not overflow vertically", layout.didOverflowHeight)
        assertEquals(1, layout.lineCount)
        assertTrue("Natural unwrapped clock fits actual allocation", layout.multiParagraph.intrinsics.maxIntrinsicWidth <= allocation.width + .5f)
        assertTrue("Clock allocation fits actual parent", allocation.left >= parent.left - .5f && allocation.right <= parent.right + .5f && allocation.top >= parent.top - .5f && allocation.bottom <= parent.bottom + .5f)
        for (i in layout.layoutInput.text.text.indices) {
            val glyph = layout.getBoundingBox(i)
            assertTrue("Full glyph $i fits clock allocation", glyph.left >= -.5f && glyph.right <= allocation.width + .5f && glyph.top >= -.5f && glyph.bottom <= allocation.height + .5f)
        }
        for ((name,b) in controls) assertTrue("$name retains >=48dp cells", b.width + 1 >= 48 * compose.density.density && b.height + 1 >= 48 * compose.density.density)
        val progress = compose.onNode(band and SemanticsMatcher.keyIsDefined(SemanticsProperties.ProgressBarRangeInfo), useUnmergedTree = true)
            .assertIsDisplayed().fetchSemanticsNode().config[SemanticsProperties.ProgressBarRangeInfo]
        assertNotEquals(ProgressBarRangeInfo.Indeterminate, progress)
        assertEquals(model.playback.value.positionMs.toFloat()/model.playback.value.durationMs,
            (progress.current-progress.range.start)/(progress.range.endInclusive-progress.range.start), .015f)
        assertNull(model.playback.value.error)
    }

    @Test fun selectedCompactArtworkFillsActualRowAndClockAllocation() {
        val original = ProductTransportFixture.server.dispatcher
        val cover = Bitmap.createBitmap(320,320,Bitmap.Config.ARGB_8888).let { b ->
            try { b.eraseColor(android.graphics.Color.MAGENTA); java.io.ByteArrayOutputStream().also { check(b.compress(Bitmap.CompressFormat.PNG,100,it)) }.toByteArray() }
            finally { b.recycle() }
        }
        val rows = (1..3).joinToString(",") { id ->
            """{"id":$id,"title":"Fixture $id","artist":"Synthetic ensemble","duration_ms":12000,"cover_art_url":"${ProductTransportFixture.origin.resolve("/selected-caller-magenta.png")}"}"""
        }
        ProductTransportFixture.server.dispatcher = object: Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when(request.url.encodedPath) {
                "/api/v1/library" -> MockResponse.Builder().addHeader("Content-Type","application/json").body("""{"tracks":[$rows],"total":3,"limit":20,"offset":0}""").build()
                "/selected-caller-magenta.png" -> {
                    assertNull(request.headers["Authorization"]); assertNull(request.headers["Cookie"])
                    MockResponse.Builder().addHeader("Content-Type","image/png").body(Buffer().write(cover)).build()
                }
                else -> original.dispatch(request) // preserve original MP3, analysis and grant owners
            }
        }
        try {
            compose.runOnIdle { app.graph.session.retire() }
            compose.waitUntil(10000) { compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithContentDescription("Email").performTextInput("selected-caller@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            click("Sign in")
            compose.waitUntil(15000) { app.graph.library.state.value.let { !it.loading && it.rows.size == 3 } }
            val model = model(); pause(model); half(model)
            compose.waitUntil(10000) { paint().first > 100 }
            clockAndProgress(model,"selected-compact-art-clock",true)
            assertTrue(ProductTransportFixture.requests.any { it.startsWith("GET /media/") })
        } finally { ProductTransportFixture.server.dispatcher = original; compose.runOnIdle { app.graph.session.retire() } }
    }

    @Test fun deviceOnlyDownloadedMp3KeepsSourceClockWithoutRemoteAuthority() = withOwnedDeviceOnly { graph, clears, sessionFile, pool, before ->
        val scope = checkNotNull(graph.session.capture())
        assertTrue(graph.session.current(scope)); assertFalse(graph.session.remoteCurrent(scope))
        val sessionBytes = pool.submit<ByteArray> { sessionFile.readBytes() }.get(5,TimeUnit.SECONDS)
        val downloads = pool.submit<Map<String,List<Byte>>> { files(File(graph.directory,"device-downloads")) }.get(5,TimeUnit.SECONDS)
        val mp3 = instrumentation.context.assets.open("callback/frontend.mp3").use { it.readBytes().toList() }
        assertTrue("Completed owned download contains the real MP3 fixture, not a predecessor WAV", downloads.values.any { it == mp3 })
        val model = model(); pause(model)
        val occurrence = model.playback.value.selectedOccurrence
        half(model)
        clockAndProgress(model,"device-only-mp3-half-song",false)
        assertTrue(model.playback.value.localOnly)
        assertEquals(occurrence,model.playback.value.selectedOccurrence)
        assertTrue(graph.session.current(scope)); assertFalse(graph.session.remoteCurrent(scope))
        for (label in listOf("Home","Discover","Library","Playlists"))
            compose.onAllNodes(hasText(label) and SemanticsMatcher.expectValue(SemanticsProperties.Role,androidx.compose.ui.semantics.Role.Tab)).assertCountEquals(0)
        assertEquals(0,clears.get())
        assertArrayEquals(sessionBytes,pool.submit<ByteArray> { sessionFile.readBytes() }.get(5,TimeUnit.SECONDS))
        assertEquals(downloads,pool.submit<Map<String,List<Byte>>> { files(File(graph.directory,"device-downloads")) }.get(5,TimeUnit.SECONDS))
        output("device-only-no-egress","before=$before\nafter=${ProductTransportFixture.requests.size}\nlocalOnly=${model.playback.value.localOnly}\ncurrentScope=${graph.session.current(scope)}\nremoteScope=${graph.session.remoteCurrent(scope)}\n")
        assertEquals("No remote HTTP after ordinary Listen offline entry",before,ProductTransportFixture.requests.size)
    }
    private fun files(root: File): Map<String,List<Byte>> = root.walkTopDown().filter { it.isFile }.associate { it.relativeTo(root).path to it.readBytes().toList() }
    private fun withOwnedDeviceOnly(body:(AppGraph,AtomicInteger,File,ExecutorService,Int)->Unit) {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val old=app.graph;val pool=Executors.newSingleThreadExecutor();val clears=AtomicInteger()
        val original=ProductTransportFixture.server.dispatcher
        var replacement:AppGraph?=null
        var primary:Throwable?=null
        try {
            val prepared=pool.submit<AppGraph> {
                val key=KeyGenerator.getInstance("AES").apply {init(256)}.generateKey()
                val file=File(old.directory,"selected-caller-fixture.session")
                val encrypted=EncryptedSessionStore(file){key}
                val seed=AppGraph(app,old.endpoint,app.fixtureClient,encrypted,app.fixtureClient)
                try {
                    check(seed.session.accept(seed.session.beginIntent(),SecretTokens("synthetic-fixture-access","synthetic-fixture-refresh","fixture-account")))
                    val scope=seed.session.capture()!!;seed.downloads.load(scope)
                    if(seed.downloads.state.value.rows.none {it.track.id==TrackId(1)&&it.status==DownloadStatus.Complete}) {
                        seed.downloads.transfer(checkNotNull(seed.downloads.claim(scope,Track(TrackId(1),"Fixture 1","Synthetic ensemble",durationMs=12000)){true}))
                    }
                } finally {seed.close()}
                AppGraph(app,old.endpoint,app.fixtureClient,object:SessionStore {
                    override fun load(endpoint:ApiEndpoint)=encrypted.load(endpoint)
                    override fun save(endpoint:ApiEndpoint,tokens:SecretTokens)=encrypted.save(endpoint,tokens)
                    override fun clear(){clears.incrementAndGet();encrypted.clear()}
                },app.fixtureClient)
            }.get(15,TimeUnit.SECONDS)
            replacement=prepared
            compose.runOnIdle {
                compose.activity.stopService(android.content.Intent(app,SoundQLibraryService::class.java))
                compose.activity.viewModelStore.clear();old.close();app.graph=prepared
            }
            compose.activityRule.scenario.recreate()
            compose.waitUntil(10000){compose.onAllNodesWithText("More options").fetchSemanticsNodes().isNotEmpty()||compose.onAllNodesWithText("Use device downloads").fetchSemanticsNodes().isNotEmpty()}
            val before=ProductTransportFixture.requests.size
            if(compose.onAllNodesWithText("Use device downloads").fetchSemanticsNodes().isNotEmpty())click("Use device downloads")
            else {click("More options");click("Listen offline")}
            compose.waitUntil(10000){prepared.session.state.value is AuthState.DeviceOnly&&prepared.downloads.state.value.ready&&prepared.downloads.state.value.rows.any {it.status==DownloadStatus.Complete}}
            compose.onNodeWithText("Downloads").assertIsDisplayed()
            compose.waitForIdle();captureListeningStage("owned-offline-downloads")
            assertEquals(before,ProductTransportFixture.requests.size)
            body(prepared,clears,File(prepared.directory,"selected-caller-fixture.session"),pool,before)
        } catch(error:Throwable) {primary=error;throw error}
        finally {
            val cleanup=runCatching {
                try {
                    ProductTransportFixture.server.dispatcher=original
                    compose.runOnIdle {compose.activity.stopService(android.content.Intent(app,SoundQLibraryService::class.java));replacement?.close()}
                    // Leave a fresh signed-out in-memory fixture graph for the next class, without clearing any saved bytes.
                    val reset=pool.submit<AppGraph> {
                        AppGraph(app,old.endpoint,app.fixtureClient,object:SessionStore {
                            private var saved:SecretTokens?=null
                            override fun load(endpoint:ApiEndpoint)=saved
                            override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){saved=tokens}
                            override fun clear(){saved=null}
                        },app.fixtureClient).also {it.api.restore()}
                    }.get(10,TimeUnit.SECONDS)
                    compose.runOnIdle {app.graph=reset}
                } finally {pool.shutdownNow();check(pool.awaitTermination(5,TimeUnit.SECONDS))}
            }.exceptionOrNull()
            if(cleanup!=null) {if(primary!=null)primary.addSuppressed(cleanup) else throw cleanup}
        }
    }
}
