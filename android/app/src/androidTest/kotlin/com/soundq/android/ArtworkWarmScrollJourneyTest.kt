package com.soundq.android

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.compose.ui.platform.ViewRootForTest
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

    private fun visibleTitles(): List<String> = compose.onAllNodes(
        SemanticsMatcher.keyIsDefined(SemanticsProperties.Text), useUnmergedTree = true
    ).fetchSemanticsNodes().flatMap { node ->
        node.config[SemanticsProperties.Text].map { it.text }.filter { it.matches(Regex("Warm [0-9]+")) }
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
            compose.waitUntil(10000) { compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithContentDescription("Email").performTextInput("warm-artwork@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(10000) { app.graph.library.state.value.let { !it.loading && it.rows.size == 40 } }
            compose.onNode(row("Warm 1"), useUnmergedTree = true).assertIsDisplayed()
            compose.waitUntil(10000) { images.get() > 0 && pixels("Warm 1") > 100 }
            val initial = visibleTitles()
            val before = images.get()
            captureListeningStage("artwork-cold-loaded")
            holdAdditional.set(true)
            val list = compose.onNode(hasContentDescription("Library, 40 tracks") and hasScrollAction())
            repeat(4) { list.performTouchInput { swipeUp(durationMillis = 250) } }
            compose.onAllNodes(row("Warm 1"), useUnmergedTree = true).assertCountEquals(0)
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
