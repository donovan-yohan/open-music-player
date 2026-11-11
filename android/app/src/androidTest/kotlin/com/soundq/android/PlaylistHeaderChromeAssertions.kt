package com.soundq.android

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.ComposeTestRule
import org.junit.Assert.*
import kotlin.math.*

/** Inspect the mounted header's own View, not a design reference or a different root. */
internal fun ComposeTestRule.assertFlatPlaylistHeader() {
    val search = onNodeWithContentDescription("Find harmonic matches").assertIsDisplayed().fetchSemanticsNode()
    val more = onNodeWithContentDescription("Playlist actions").assertIsDisplayed().fetchSemanticsNode()
    assertSame("Adjacent actions share the actual header root", search.root, more.root)
    val left = search.boundsInRoot
    val right = more.boundsInRoot
    assertEquals("No gap hides a doubled edge", left.right, right.left, .5f)
    val density = (more.root as ViewRootForTest).view.resources.displayMetrics.density
    val maxSingleRule = ceil(density.toDouble()).toInt()
    val widest = runOnIdle {
        val view = (more.root as ViewRootForTest).view
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        try {
            view.draw(Canvas(bitmap))
            val background = bitmap.getPixel((right.right - 8 * density).roundToInt(), (right.top + 4 * density).roundToInt())
            val seam = right.left.roundToInt()
            var maximum = 0
            for (y in ceil(max(left.top, right.top) + 6 * density).toInt() until floor(min(left.bottom, right.bottom) - 6 * density).toInt()) {
                var run = 0
                for (x in floor(seam - 2 * density).toInt() until ceil(seam + 2 * density).toInt()) {
                    run = if (bitmap.getPixel(x, y) != background) run + 1 else 0
                    maximum = max(maximum, run)
                }
            }
            maximum
        } finally { bitmap.recycle() }
    }
    assertTrue("Search/More seam must not contain two full borders: widest=$widest px, single-rule limit=$maxSingleRule px", widest <= maxSingleRule)
    val title = onNodeWithText("Evening listening").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
    val count = onNodeWithText("3 tracks").assertIsDisplayed().fetchSemanticsNode().boundsInRoot
    assertEquals("Facts share the title's content edge", title.left, count.left, .5f)
    assertTrue("Track count is grouped beneath the title inside the header", count.top >= title.bottom - .5f && count.bottom <= right.bottom + .5f)
    for (label in listOf("Back to playlists", "Find harmonic matches", "Playlist actions", "Play playlist", "Plain listening", "Mixed listening", "Generate Blend", "Shuffle")) {
        val bounds = onNodeWithContentDescription(label).assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        assertTrue("$label retains a 48dp target: $bounds", bounds.width + .5f >= 48 * density && bounds.height + .5f >= 48 * density)
    }
}
