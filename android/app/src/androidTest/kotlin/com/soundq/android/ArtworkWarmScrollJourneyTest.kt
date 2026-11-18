package com.soundq.android

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.test.junit4.ComposeTestRule
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import mockwebserver3.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.ceil
import kotlin.math.floor

/** Actual Library lazy pointer journey. A blocked repeat fetch cannot hide behind a later painted frame. */
class ArtworkWarmScrollJourneyTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private fun row(title: String) = hasClickAction() and hasAnyDescendant(hasText(title)) and
        hasAnyDescendant(hasContentDescription("More for $title"))

    private fun pixels(title: String): Int {
        val node = compose.onNode(hasTestTag("media-artwork") and hasAnyAncestor(row(title)), useUnmergedTree = true)
            .assertIsDisplayed().fetchSemanticsNode()
        val bounds = node.boundsInRoot
        val root = node.root as ViewRootForTest
        return compose.runOnIdle {
            val view = root.view
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            try {
                view.draw(Canvas(bitmap))
                var count = 0
                for (y in ceil(bounds.top).toInt() until floor(bounds.bottom).toInt()) {
                    for (x in ceil(bounds.left).toInt() until floor(bounds.right).toInt()) {
                        if (bitmap.getPixel(x, y) == android.graphics.Color.MAGENTA) count++
                    }
                }
                count
            } finally { bitmap.recycle() }
        }
    }

    private fun visibleTitles(): List<String> {
        val viewport=compose.onNode(hasContentDescription("Library, 40 tracks") and hasScrollAction()).fetchSemanticsNode().boundsInRoot
        return compose.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsProperties.Text),useUnmergedTree=true)
            .fetchSemanticsNodes().filter {node->
                val row=generateSequence(node){it.parent}.firstOrNull {it.config.contains(androidx.compose.ui.semantics.SemanticsActions.OnClick)}
                row!=null&&row.layoutInfo.isPlaced&&row.boundsInRoot.intersect(viewport).let {b->b.width>0&&b.height>0}
            }.flatMap {it.config[SemanticsProperties.Text].map {text->text.text}.filter {text->text.matches(Regex("Warm [0-9]+"))}}
    }

    private fun awaitMountedCorpus(app:FixtureApplication) {
        val first=compose.onNode(row("Warm 1"),useUnmergedTree=true)
        // Acknowledged repository rows can still be unplaced behind the Settings
        // return. Settle the mounted corpus inside the original setup allowance.
        try {
            compose.waitUntil(10000) {
                app.graph.library.state.value.let {!it.loading&&it.rows.size==40&&it.completeProjection}&&first.isDisplayed()
            }
            first.assertIsDisplayed()
        } catch(failure:AssertionError) {
            captureListeningStage("artwork-corpus-not-mounted")
            throw failure
        }
    }

    @Test fun nextViewportUniqueCoverIsRequestedBeforeEntryAndReusedOnEntry() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val original=ProductTransportFixture.server.dispatcher
        val requests=java.util.concurrent.ConcurrentHashMap<Int,AtomicInteger>()
        val holdRepeats=AtomicBoolean(false);val release=CountDownLatch(1)
        var corpusRead: FutureTask<Unit>? = null
        fun color(index:Int)=android.graphics.Color.rgb(32+index*5,64+(index*7)%160,32+(index*11)%192)
        val covers=(1..40).associateWith {index->Bitmap.createBitmap(192,192,Bitmap.Config.ARGB_8888).let {bitmap->
            try {bitmap.eraseColor(color(index));java.io.ByteArrayOutputStream().also {assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG,100,it))}.toByteArray()}
            finally {bitmap.recycle()}
        }}
        val rows=(1..40).joinToString(",") {index->
            """{"id":${900000+index},"title":"Warm $index","artist":"Synthetic ensemble","duration_ms":12000,"cover_art_url":"${ProductTransportFixture.origin.resolve("/lookahead-$index.png")}"}"""
        }
        ProductTransportFixture.server.dispatcher=object:Dispatcher() {
            override fun dispatch(request:RecordedRequest):MockResponse {
                val path=request.url.encodedPath
                if(path=="/api/v1/library")return MockResponse.Builder().addHeader("Content-Type","application/json").body("""{"tracks":[$rows],"total":40,"limit":40,"offset":0}""").build()
                val index=Regex("/lookahead-([0-9]+)\\.png").matchEntire(path)?.groupValues?.get(1)?.toInt()
                if(index!=null) {
                    assertNull(request.headers["Authorization"]);assertNull(request.headers["Cookie"])
                    val count=requests.computeIfAbsent(index){AtomicInteger()}.incrementAndGet()
                    if(count>1&&holdRepeats.get())check(release.await(90,TimeUnit.SECONDS)){"Owned repeat gate was not released"}
                    return MockResponse.Builder().addHeader("Content-Type","image/png").body(Buffer().write(covers.getValue(index))).build()
                }
                return original.dispatch(request)
            }
        }
        try {
            compose.runOnIdle {app.graph.session.retire()}
            // Do not index or discard retained phone metadata to isolate this
            // server-only corpus. Select its ordinary source before signing in.
            compose.selectLibrarySource("Server")
            compose.signInThroughSettings("lookahead@example.test","test-only-password") {
                // This journey measures the settled Library at rest. Complete the real bounded
                // Server projection while Settings still covers it, inside the existing sign-in
                // wait. Otherwise a transient shorter viewport spends Compose's first prefetch
                // on the row that becomes visible when the loading notice disappears.
                val library = app.graph.library
                val expected = library.state.value
                if (app.graph.session.state.value !is com.soundq.android.data.AuthState.SignedIn ||
                    expected.loading || expected.rows.size != 40 || library.projectionScope(expected) == null
                ) return@signInThroughSettings false
                val read = corpusRead ?: FutureTask<Unit> { library.completeProjection(expected) }.also {
                    corpusRead = it
                    Thread(it, "fixture-artwork-corpus").apply { isDaemon = true }.start()
                }
                if (!read.isDone) return@signInThroughSettings false
                read.get()
                val complete = library.state.value
                check(complete.completeProjection && !complete.loading && complete.rows.size == 40 &&
                    library.projectionScope(complete) != null) { "Fixture Server corpus did not complete behind Settings" }
                true
            }
            awaitMountedCorpus(app)
            val list=compose.onNode(hasContentDescription("Library, 40 tracks") and hasScrollAction())
            val initial=visibleTitles().map {it.removePrefix("Warm ").toInt()};assertTrue(initial.isNotEmpty())
            val last=initial.max()
            val target=last+1
            assertTrue("Fixture needs an unseen next-window row and a far control",target<40)
            // Setup only: no pointer input yet. Distinct request + settled loader + retained
            // cache admission establish completed unseen acquisition/decode, not eventual entry paint.
            compose.waitUntil(10000){requests[target]?.get()==1&&app.graph.libraryArtwork.pendingWorkCount()==0&&
                app.graph.libraryArtwork.resources().cacheEntries>=requests.size}
            assertFalse("Target is still geometrically unseen after decode", "Warm $target" in visibleTitles())
            val slot=hasTestTag("media-artwork") and hasAnyAncestor(row("Warm $target"))
            assertNull("Target image itself must have zero viewport intersection after decode",thumbnailRaster(compose,list,slot,1f) {pixel,_,_->pixel==color(target)})
            val viewport=list.fetchSemanticsNode().boundsInRoot
            val rowHeight=compose.onNode(row("Warm 1"),useUnmergedTree=true).fetchSemanticsNode().size.height.toFloat()
            assertTrue(rowHeight>0)
            // Account for two partially visible boundary rows, not another page. No source
            // beyond one measured viewport plus boundary items may be requested while at rest.
            val windowEnd=(last+kotlin.math.ceil(viewport.height/rowHeight).toInt()+2).coerceAtMost(39)
            assertTrue("No whole-library warming: requests=${requests.keys}, last=$last, windowEnd=$windowEnd",requests.keys.all {it<=windowEnd})
            assertNull("Far source must not acquire at rest",requests[40])
            holdRepeats.set(true)
            captureListeningStage("artwork-lookahead-unseen-ready")
            val entry=slowThumbnailEntry(compose,list,hasTestTag("media-artwork") and hasAnyAncestor(row("Warm $target")),24f*thumbnailDensity()) {pixel,_,_->pixel==color(target)}
            // The immutable raster observation was made on the FIRST >=24dp slot intersection,
            // before pointer-up, screenshot idling or any image-ready wait.
            writeThumbnailObservation("remote-lookahead","initial=$initial\nlast=$last\ntarget=$target\nwindowEnd=$windowEnd\nrequests=${requests.mapValues {it.value.get()}}\nentry=$entry\n")
            captureListeningStage("artwork-lookahead-first-entry")
            assertTrue("Own distinct source color must already paint at first meaningful entry: $entry",entry.sampled>100&&entry.matching>=entry.sampled*0.9f)
            assertEquals("Entry must not refetch its warmed source",1,requests.getValue(target).get())
        } finally {
            corpusRead?.cancel(true)
            release.countDown()
            ProductTransportFixture.server.dispatcher=original
            compose.runOnIdle {app.graph.session.retire()}
        }
    }

    @Test fun actualForwardReverseScrollReusesPaintedArtworkWithoutAnotherFetch() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val app = instrumentation.targetContext.applicationContext as FixtureApplication
        val original = ProductTransportFixture.server.dispatcher
        val images = AtomicInteger()
        val holdAdditional = AtomicBoolean(false)
        val release = CountDownLatch(1)
        val cover = Bitmap.createBitmap(320, 320, Bitmap.Config.ARGB_8888).let { bitmap ->
            try {
                bitmap.eraseColor(android.graphics.Color.MAGENTA)
                java.io.ByteArrayOutputStream().also {
                    assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it))
                }.toByteArray()
            } finally { bitmap.recycle() }
        }
        val rows = (1..40).joinToString(",") { index ->
            """{"id":$index,"title":"Warm $index","artist":"Synthetic ensemble","duration_ms":12000,"cover_art_url":"${ProductTransportFixture.origin.resolve("/warm-album.png")}"}"""
        }
        ProductTransportFixture.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.url.encodedPath) {
                "/api/v1/library" -> MockResponse.Builder().addHeader("Content-Type", "application/json")
                    .body("""{"tracks":[$rows],"total":40,"limit":40,"offset":0}""").build()
                "/warm-album.png" -> {
                    assertNull(request.headers["Authorization"])
                    assertNull(request.headers["Cookie"])
                    images.incrementAndGet()
                    if (holdAdditional.get()) check(release.await(90, TimeUnit.SECONDS)) { "Owned repeat-fetch gate was not released" }
                    MockResponse.Builder().addHeader("Content-Type", "image/png").body(Buffer().write(cover)).build()
                }
                else -> original.dispatch(request)
            }
        }
        try {
            compose.runOnIdle { app.graph.session.retire() }
            compose.selectLibrarySource("Server")
            compose.signInThroughSettings("warm-artwork@example.test","test-only-password") {app.graph.session.state.value is com.soundq.android.data.AuthState.SignedIn}
            awaitMountedCorpus(app)
            compose.waitUntil(10000) { images.get() > 0 && pixels("Warm 1") > 100 }
            val initial = visibleTitles()
            val before = images.get()
            captureListeningStage("artwork-cold-loaded")
            holdAdditional.set(true)
            val list = compose.onNode(hasContentDescription("Library, 40 tracks") and hasScrollAction())
            repeat(4) { list.performTouchInput { swipeUp(durationMillis = 250) } }
            assertFalse("Warm 1 must leave the actual viewport", "Warm 1" in visibleTitles())
            val forward = visibleTitles()
            assertTrue("Pointer scrolling must change the real lazy viewport", forward.isNotEmpty() && forward != initial)
            captureListeningStage("artwork-forward")
            repeat(4) { list.performTouchInput { swipeDown(durationMillis = 250) } }
            compose.onNode(row("Warm 1"), useUnmergedTree = true).assertIsDisplayed()
            val returned = visibleTitles()
            val painted = pixels("Warm 1")
            val after = images.get()
            captureListeningStage("artwork-warm-return")
            val directory = File(instrumentation.targetContext.getExternalFilesDir(null), "listening-20261105")
            check(directory.mkdirs() || directory.isDirectory)
            File(directory, "warm-scroll-observation.txt").writeText(
                "initial=$initial\nforward=$forward\nreturned=$returned\nfetchesBefore=$before\nfetchesAfter=$after\nreturnedMagentaPixels=$painted\n"
            )
            assertTrue("Warm returned artwork must already paint while repeat network requests are held", painted > 100)
            assertEquals("Forward/reverse same-rendition reuse must not refetch the admitted shared source", before, after)
        } finally {
            release.countDown()
            ProductTransportFixture.server.dispatcher = original
            compose.runOnIdle { app.graph.session.retire() }
        }
    }
}

/** A real root raster at a measured viewport intersection. Never an eventual image-ready poll. */
internal data class ThumbnailEntryRaster(val full:Rect,val visible:Rect,val matching:Int,val sampled:Int,val quadrants:Set<Int>,val steps:Int=0,val entryTrace:List<String> = emptyList())
internal fun thumbnailDensity()=InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
internal fun thumbnailRaster(compose:ComposeTestRule,list:SemanticsNodeInteraction,slot:SemanticsMatcher,minHeight:Float,
    expected:(Int,Float,Float)->Boolean):ThumbnailEntryRaster? {
    val node=compose.onAllNodes(slot,useUnmergedTree=true).fetchSemanticsNodes().singleOrNull() ?: return null
    val viewport=list.fetchSemanticsNode().boundsInRoot
    return compose.runOnIdle {
        if(!node.layoutInfo.isPlaced)return@runOnIdle null
        val full=Rect(node.positionInRoot,Size(node.size.width.toFloat(),node.size.height.toFloat()))
        val view=(node.root as ViewRootForTest).view
        val visible=full.intersect(viewport).intersect(node.boundsInRoot).intersect(Rect(0f,0f,view.width.toFloat(),view.height.toFloat()))
        if(visible.width<=0||visible.height<minHeight)return@runOnIdle null
        val bitmap=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
        try {
            view.draw(Canvas(bitmap))
            var matching=0;var sampled=0;val quadrants=mutableSetOf<Int>()
            for(y in ceil(visible.top).toInt() until floor(visible.bottom).toInt())for(x in ceil(visible.left).toInt() until floor(visible.right).toInt()) {
                val fx=(x-full.left)/full.width;val fy=(y-full.top)/full.height
                // Interior quadrants avoid sampling a fixture JPEG boundary or slot clipping edge.
                if(fx in .12f.. .88f&&fy in .12f.. .88f&&kotlin.math.abs(fx-.5f)>.08f&&kotlin.math.abs(fy-.5f)>.08f) {
                    sampled++;quadrants.add((if(fx<.5f)0 else 1)+(if(fy<.5f)0 else 2))
                    if(expected(bitmap.getPixel(x,y),fx,fy))matching++
                }
            }
            ThumbnailEntryRaster(full,visible,matching,sampled,quadrants)
        }finally {bitmap.recycle()}
    }
}
internal fun slowThumbnailEntry(compose:ComposeTestRule,list:SemanticsNodeInteraction,slot:SemanticsMatcher,minHeight:Float,
    expected:(Int,Float,Float)->Boolean):ThumbnailEntryRaster {
    val step=4f*thumbnailDensity()
    val trace=mutableListOf<String>();var previousTop:Float?=null
    assertNull("Target must begin outside the meaningful-entry region",thumbnailRaster(compose,list,slot,minHeight,expected))
    list.performTouchInput {down(Offset(center.x,height*.8f))}
    try {
        repeat(128) {index->
            list.performTouchInput {advanceEventTime(50);moveBy(Offset(0f,-step))}
            // Keep the real pointer held. No scrollTo, image wait, screenshot or retry after
            // this first geometric threshold: fallback/wrong-color pixels fail immediately.
            thumbnailRaster(compose,list,slot,1f,expected)?.let {sample->
                val delta=previousTop?.let {it-sample.full.top}
                trace.add("step=${index+1},top=${sample.full.top},visible=${sample.visible.height},delta=$delta")
                if(delta!=null)assertTrue("Measured native content must advance by small pointer steps: $trace",delta>=-.5f&&delta<=step*2+1f)
                previousTop=sample.full.top
                if(sample.visible.height>=minHeight) {
                    assertTrue("Must sample the first meaningful entry, not jump to a full row: $trace",sample.visible.height<=minHeight+step*2+1f)
                    return sample.copy(steps=index+1,entryTrace=trace.toList())
                }
            }
        }
        throw AssertionError("128 measured 4dp pointer steps did not reach the target")
    }finally {list.performTouchInput {advanceEventTime(200);up()}}
}
internal fun writeThumbnailObservation(name:String,text:String) {
    require(name.matches(Regex("[a-zA-Z0-9-]+")))
    val instrumentation=InstrumentationRegistry.getInstrumentation()
    val label=InstrumentationRegistry.getArguments().getString("captureLabel") ?: "default"
    require(label.matches(Regex("[a-zA-Z0-9-]+")))
    val directory=File(instrumentation.targetContext.getExternalFilesDir(null),"listening-20261105/$label")
    check(directory.mkdirs()||directory.isDirectory)
    File(directory,"$name.txt").writeText(text)
}
