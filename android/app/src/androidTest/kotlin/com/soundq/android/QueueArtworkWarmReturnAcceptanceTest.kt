package com.soundq.android

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.playback.PlaybackSource
import com.soundq.android.product.ProductViewModel
import mockwebserver3.*
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.ceil
import kotlin.math.floor

/** SC03 only. Ordinary MP3 service queue; actual Queue pointer owner and owning-View paint. */
class QueueArtworkWarmReturnAcceptanceTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private val dialog = hasAnyAncestor(isDialog())
    private val outside = !dialog
    private fun row(title: String) = hasClickAction() and hasAnyDescendant(hasText(title)) and
        hasAnyDescendant(hasContentDescription("More for $title"))
    private fun action(name: String, scope: SemanticsMatcher) = compose.onNode(hasContentDescription(name) and scope)
    // QueuePanel -> SoundQOccurrenceQueue(bounded=true) -> LazyColumn. No production tag needed.
    // Arrangement is rejected below; the sole dialog ScrollBy owner is the ordinary List lazy owner.
    private fun list() = compose.onNode(hasScrollAction() and dialog)
    private fun rowArt() = compose.onNode(hasTestTag("media-artwork") and dialog and
        hasAnyAncestor(row("Fixture 1")), useUnmergedTree = true)

    private data class Paint(val bounds: String, val magenta: Int, val area: Int)
    private fun paint(slot: SemanticsNodeInteraction): Paint {
        val node = slot.assertIsDisplayed().fetchSemanticsNode()
        val b = node.boundsInRoot
        return compose.runOnIdle {
            val view = (node.root as ViewRootForTest).view
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            try {
                view.draw(Canvas(bitmap))
                val left = ceil(b.left).toInt(); val top = ceil(b.top).toInt()
                val right = floor(b.right).toInt(); val bottom = floor(b.bottom).toInt()
                check(left >= 0 && top >= 0 && right <= bitmap.width && bottom <= bitmap.height)
                check(right > left && bottom > top)
                var colored = 0
                for (y in top until bottom) for (x in left until right)
                    if (bitmap.getPixel(x, y) == android.graphics.Color.MAGENTA) colored++
                Paint(b.toString(), colored, (right-left)*(bottom-top))
            } finally { bitmap.recycle() }
        }
    }
    private fun visibleRows(): List<String> {
        val viewport = list().fetchSemanticsNode().boundsInRoot
        return compose.onAllNodes(dialog and hasAnyAncestor(hasScrollAction()) and
            SemanticsMatcher.keyIsDefined(SemanticsProperties.ContentDescription), useUnmergedTree = true)
            .fetchSemanticsNodes().filter { n ->
                val b = n.boundsInRoot
                b.width > 0 && b.height > 0 && b.top < viewport.bottom && b.bottom > viewport.top
            }.flatMap { it.config[SemanticsProperties.ContentDescription] }
            .filter { it.matches(Regex("Reorder Fixture [0-9]+")) }
    }
    private fun output(name: String, text: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val label = InstrumentationRegistry.getArguments().getString("captureLabel") ?: "default"
        require(label.matches(Regex("[a-zA-Z0-9-]+")))
        val dir = File(instrumentation.targetContext.getExternalFilesDir(null), "listening-20261105/$label")
        check(dir.mkdirs() || dir.isDirectory)
        File(dir, "$name.txt").writeText(text)
    }
    private fun unchanged(model: ProductViewModel, before: SettledPausedSnapshot) {
        compose.runOnIdle {
            assertActualPausedUnchanged(before)
            val now = model.playback.value
            assertNull(now.error)
            assertFalse(now.isPlaying); assertFalse(now.preparing)
            assertEquals(before.projection.selectedOccurrence, now.selectedOccurrence)
            assertEquals(before.servicePositionMs, now.positionMs)
            assertEquals(before.projection.queue, now.queue)
            assertEquals(PlaybackSource.Queue, now.source)
        }
    }

    @Test fun ordinaryPausedQueuePointerWarmReturnPaintsWhileRepeatImagesAreHeld() {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as CallbackFrontendFixtureApplication
        val original = ProductTransportFixture.server.dispatcher
        val images = AtomicInteger()
        val held = AtomicInteger()
        val hold = AtomicBoolean(false)
        val release = CountDownLatch(1)
        val cover = Bitmap.createBitmap(320, 320, Bitmap.Config.ARGB_8888).let { bitmap ->
            try {
                bitmap.eraseColor(android.graphics.Color.MAGENTA)
                java.io.ByteArrayOutputStream().also {
                    check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it))
                }.toByteArray()
            } finally { bitmap.recycle() }
        }
        val rows = (1..40).joinToString(",") { id ->
            """{"id":$id,"title":"Fixture $id","artist":"Synthetic ensemble","duration_ms":12000,"cover_art_url":"${ProductTransportFixture.origin.resolve("/queue-warm-magenta.png")}"}"""
        }
        ProductTransportFixture.server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.url.encodedPath) {
                "/api/v1/library" -> {
                    // Keep the existing fixture account admission; this wrapper only expands its library.
                    if (request.headers["Authorization"] != "Bearer synthetic-fixture-access")
                        MockResponse.Builder().code(401).build()
                    else MockResponse.Builder().addHeader("Content-Type", "application/json")
                        .body("""{"tracks":[$rows],"total":40,"limit":40,"offset":0}""").build()
                }
                "/queue-warm-magenta.png" -> {
                    assertNull(request.headers["Authorization"]); assertNull(request.headers["Cookie"])
                    images.incrementAndGet()
                    if (hold.get()) {
                        held.incrementAndGet()
                        check(release.await(90, TimeUnit.SECONDS)) { "Repeat-image response gate expired before cleanup" }
                    }
                    MockResponse.Builder().addHeader("Content-Type", "image/png").body(Buffer().write(cover)).build()
                }
                else -> original.dispatch(request) // original MP3, analysis, descriptors and media grants
            }
        }
        var primary: Throwable? = null
        try {
            compose.runOnIdle { app.graph.session.retire() }
            compose.waitUntil(10000) { compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithContentDescription("Email").performTextInput("queue-warm@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(15000) { app.graph.library.state.value.let { !it.loading && it.rows.size == 40 } }
            val model = compose.runOnIdle { ViewModelProvider(compose.activity)[ProductViewModel::class.java] }
            compose.onNode(row("Fixture 1") and outside, useUnmergedTree = true).assertIsDisplayed().performClick()
            // Positive source readiness AND mounted Pause. A model-only wait races the control projection.
            compose.waitUntil(20000) {
                assertNull("Do not disguise a real playback error as readiness timeout", model.playback.value.error)
                model.playback.value.let { it.title == "Fixture 1" && it.isPlaying && it.positionMs >= 300 } &&
                    compose.runOnIdle {
                        assertNull(app.callbackPlayer.playerError)
                        app.callbackPlayer.isPlaying && app.callbackPlayer.currentPosition >= 300
                    } && compose.onAllNodes(hasContentDescription("Pause") and outside).fetchSemanticsNodes().isNotEmpty()
            }
            assertEquals("com.soundq.android.playback.nativeengine.NativeCallbackPlayer", app.callbackPlayer.javaClass.name)
            action("Pause", outside).assertIsDisplayed().performClick()
            val paused = compose.settledPausedPlayback(model)
            assertEquals(PlaybackSource.Queue, paused.projection.source)
            assertEquals((1L..40L).toList(), paused.projection.queue.map { it.trackId })
            assertEquals(paused.projection.queue.first().occurrenceId, paused.projection.selectedOccurrence)
            assertTrue(ProductTransportFixture.requests.any { it.startsWith("GET /media/") })
            val compact = compose.onNode(hasTestTag("compact-artwork") and outside, useUnmergedTree = true)
            compose.waitUntil(10000) { paint(compact).magenta > 100 }
            val rootPaint = paint(compact)
            captureListeningStage("queue-warm-root-paused")
            action("Open listening queue", outside).performClick()
            compose.waitUntil(10000) { compose.onAllNodes(hasText("List") and dialog).fetchSemanticsNodes().isNotEmpty() }
            compose.onNode(hasText("List") and hasClickAction() and dialog).performClick()
            compose.showSourceListeningQueue()
            list().assertIsDisplayed()
            compose.onNode(row("Fixture 1") and dialog, useUnmergedTree = true).assertIsDisplayed()
            // 192px Queue rows and 1024px compact/player renditions acquire independently.
            // Admit BOTH actual consumers before the gate. Never call a legitimate initial acquisition a refetch.
            val queueCompact = compose.onNode(hasTestTag("compact-artwork") and dialog, useUnmergedTree = true)
            compose.waitUntil(10000) { paint(rowArt()).magenta > 100 && paint(queueCompact).magenta > 100 }
            val firstPaint = paint(rowArt())
            val rowHeight = rowArt().fetchSemanticsNode().boundsInRoot.height
            val queuePlayerPaint = paint(queueCompact)
            val initial = visibleRows()
            assertTrue(initial.contains("Reorder Fixture 1"))
            unchanged(model, paused)
            captureListeningStage("queue-warm-initial")
            hold.set(true)
            val before = images.get()
            output("queue-warm-initial", "viewport=$initial\nrow=$firstPaint\nrootCompact=$rootPaint\nqueueCompact=$queuePlayerPaint\nfetches=$before\nselected=${paused.projection.selectedOccurrence}\nserviceCursor=${paused.servicePositionMs}\nqueue=${paused.projection.queue}\n")
            // x=25% is in the row body, away from the right-hand reorder pointer detector.
            repeat(4) { list().performTouchInput {
                swipe(Offset(width*.25f, height*.85f), Offset(width*.25f, height*.15f), 250)
            } }
            val forward = visibleRows()
            captureListeningStage("queue-warm-forward")
            output("queue-warm-forward", "viewport=$forward\nfetches=${images.get()}\nheld=${held.get()}\nselected=${model.playback.value.selectedOccurrence}\ncursor=${model.playback.value.positionMs}\nqueue=${model.playback.value.queue}\n")
            assertTrue("Real Queue pointer viewport must change", forward.isNotEmpty() && forward != initial)
            assertFalse("First row must actually leave viewport", forward.contains("Reorder Fixture 1"))
            unchanged(model, paused)
            // Do not fling through the list's top into the enclosing sheet's dismiss gesture.
            // Guide bounded real drags by observed row identity, stopping at actual first-row arrival.
            var returned = forward
            var reverseSteps = 0
            val reverseViewports = mutableListOf(forward)
            fun firstArtworkFullyVisible():Boolean {
                val viewport=list().fetchSemanticsNode().boundsInRoot
                val slots=compose.onAllNodes(hasTestTag("media-artwork") and dialog and hasAnyAncestor(row("Fixture 1")),useUnmergedTree=true).fetchSemanticsNodes()
                return slots.size==1 && slots.single().boundsInRoot.let {b->
                    b.height>=rowHeight-.5f && b.top>=viewport.top-.5f && b.bottom<=viewport.bottom+.5f
                }
            }
            // The forward gestures fling; reverse gestures intentionally do not. One slow
            // drag per occurrence bounds this driver without assuming equal fling distance.
            while (!firstArtworkFullyVisible() && reverseSteps < paused.projection.queue.size+1) {
                val firstIndex = returned.minOf { it.substringAfterLast(' ').toInt() } - 1
                val travel = minOf(list().fetchSemanticsNode().boundsInRoot.height*.5f, firstIndex.coerceAtLeast(1)*rowHeight*.45f)
                list().performTouchInput {
                    down(Offset(width*.25f,height*.15f))
                    moveBy(Offset(0f,travel),delayMillis=400)
                    advanceEventTime(120)
                    up()
                }
                reverseSteps++
                returned = visibleRows()
                reverseViewports.add(returned)
            }
            output("queue-warm-reverse","reverseSteps=$reverseSteps\nreverseViewports=$reverseViewports\nfirstArtworkFullyVisible=${firstArtworkFullyVisible()}\n")
            compose.onNode(row("Fixture 1") and dialog, useUnmergedTree = true).assertIsDisplayed()
            val returnedPaint = paint(rowArt()) // No eventual image wait on return; repeat responses remain held.
            val after = images.get()
            captureListeningStage("queue-warm-return")
            output("queue-warm-return", "initial=$initial\nforward=$forward\nreturned=$returned\nreverseSteps=$reverseSteps\nreverseViewports=$reverseViewports\nfetchesBefore=$before\nfetchesAfter=$after\nheld=${held.get()}\ngateStillHeld=${release.count == 1L}\nreturnedRow=$returnedPaint\nselected=${model.playback.value.selectedOccurrence}\ncursor=${model.playback.value.positionMs}\nqueue=${model.playback.value.queue}\n")
            assertTrue(returned.contains("Reorder Fixture 1"))
            assertEquals(1L, release.count)
            assertTrue("Returned row's OWN bounded View pixels paint with repeat responses held", returnedPaint.magenta > 100)
            assertEquals("Already-painted same-rendition Queue source must not refetch", before, after)
            unchanged(model, paused)
        } catch (error: Throwable) {
            primary = error
            runCatching {
                output("queue-warm-failure", "dialogRoots=${compose.onAllNodes(isDialog()).fetchSemanticsNodes().size}\ndialogScrollOwners=${compose.onAllNodes(hasScrollAction() and dialog).fetchSemanticsNodes().size}\n")
                captureListeningStage("queue-warm-failure")
            }.exceptionOrNull()?.let(error::addSuppressed)
            throw error
        }
        finally {
            release.countDown()
            val cleanup = runCatching {
                ProductTransportFixture.server.dispatcher = original
                compose.runOnIdle { app.graph.session.retire() }
            }.exceptionOrNull()
            if (cleanup != null) { if (primary != null) primary.addSuppressed(cleanup) else throw cleanup }
        }
    }
}
