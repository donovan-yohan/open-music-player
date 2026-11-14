package com.soundq.designsystem

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Native layout regression, not proof of glyph fit from semantic existence alone. */
@org.junit.runner.RunWith(org.robolectric.RobolectricTestRunner::class)
@org.robolectric.annotation.Config(sdk=[34],qualifiers="w720dp-h1000dp")
@org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
class HistoryMediaRowFitTest {
    @get:Rule val compose = createComposeRule()

    private fun assertFits(text: String, complete: Boolean = false): TextLayoutResult {
        val layouts = mutableListOf<TextLayoutResult>()
        compose.onNodeWithText(text, useUnmergedTree = true)
            .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        assertTrue("Expected native text layout for $text", layouts.isNotEmpty())
        val layout = layouts.single()
        // didOverflowHeight also flags maxLines truncation from intentional horizontal ellipsis.
        assertTrue("Enlarged row clips text vertically: $text", layout.size.height.toFloat() >= layout.multiParagraph.height)
        if (complete) assertFalse("Essential event facts are hidden by row truncation: $text", layout.hasVisualOverflow)
        return layout
    }

    @Test fun enlargedHistoryRowDoesNotClipTextOrHideItsEventFacts() {
        val facts = "Listened · Oct 27, 2026 20:00"
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(2f, 2f)) {
                SoundQTheme {
                    Box(Modifier.requiredWidth(360.dp)) {
                        SoundQMediaRow("ÉCHO", "Beyoncé", false, {}, {}, supporting = facts, supportingMaxLines = 6)
                    }
                }
            }
        }
        assertFits("ÉCHO")
        assertFits("Beyoncé")
        assertTrue("History facts should wrap at enlarged type", assertFits(facts, complete = true).lineCount > 1)
    }

    @Test fun enlargedHistoryFactsKeepFullWidthAlongsideRealMetadataAndUnavailableContext() {
        val facts = "Skipped · Oct 27, 2026 20:00 · album · Not in your library"
        val metadata = "3:42 · A minor"
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(2f, 2f)) {
                SoundQTheme {
                    Box(Modifier.requiredWidth(360.dp)) {
                        SoundQMediaRow("ÉCHO", "Björk", false, {}, {}, Modifier.testTag("history-row"),
                            supporting = facts, supportingMaxLines = 6, enabled = false,
                            metadata = { Text(metadata, modifier = Modifier.fillMaxWidth(), style = SoundQ.typography.caption, maxLines = 1) })
                    }
                }
            }
        }
        assertFits("ÉCHO")
        assertFits("Björk")
        assertFits(metadata, complete = true)
        assertFits(facts, complete = true)
        val meta = compose.onNodeWithText(metadata, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        val supporting = compose.onNodeWithText(facts, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        assertEquals("Facts must use the whole metadata lane", meta.width, supporting.width, 1f)
        assertTrue("Facts have their own line below metadata", meta.bottom <= supporting.top + 1f)
        compose.onNodeWithTag("history-row").assertIsNotEnabled()
        compose.onNodeWithContentDescription("More for ÉCHO").assertWidthIsAtLeast(48.dp).assertHeightIsAtLeast(48.dp)
    }

    @Test fun normalHistoryRowsKeepBothRepeatedEventStatusesFullyVisibleAt72() {
        val listened = "Listened · Oct 27, 2026 20:00"
        val skipped = "Skipped · Oct 27, 2026 20:00"
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(2f, 1f)) {
                SoundQTheme {
                    Column(Modifier.requiredWidth(360.dp)) {
                        SoundQMediaRow("ÉCHO", "Björk", false, {}, {}, Modifier.testTag("listened"),
                            supporting = listened, supportingMaxLines = 6)
                        SoundQMediaRow("ÉCHO", "Björk", false, {}, {}, Modifier.testTag("skipped"),
                            supporting = skipped, supportingMaxLines = 6)
                    }
                }
            }
        }
        assertFits(listened, complete = true)
        assertFits(skipped, complete = true)
        compose.onNodeWithTag("listened").assertHeightIsEqualTo(72.dp)
        compose.onNodeWithTag("skipped").assertHeightIsEqualTo(72.dp)
    }

    @Test fun defaultDenseRowsStay72TouchingWithSquareLeadingArtworkAndHorizontalEllipsis() {
        val title = "Long title ÉCHO ".repeat(12)
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(2f, 1f)) {
                SoundQTheme {
                    Column(Modifier.requiredWidth(360.dp)) {
                        // Selected overflow now uses the separately tested native marquee.
                        SoundQMediaRow(title, "Artist", false, {}, {}, Modifier.testTag("first"),
                            artwork = { Box(Modifier.fillMaxSize().testTag("first-art")) },
                            supporting = "Like not confirmed. Reload", metadata = { Text("3:42 · 128 BPM · A minor", maxLines = 1, softWrap = false) })
                        SoundQMediaRow("Sibling", "Artist two", false, {}, {}, Modifier.testTag("second"),
                            artwork = { Box(Modifier.fillMaxSize().testTag("second-art")) })
                    }
                }
            }
        }
        compose.onNodeWithTag("first").assertHeightIsEqualTo(72.dp)
        compose.onNodeWithTag("second").assertHeightIsEqualTo(72.dp)
        listOf("first-art", "second-art").forEach {
            compose.onNodeWithTag(it, useUnmergedTree = true).assertWidthIsEqualTo(72.dp).assertHeightIsEqualTo(72.dp)
        }
        val first = compose.onNodeWithTag("first").fetchSemanticsNode().boundsInRoot
        val second = compose.onNodeWithTag("second").fetchSemanticsNode().boundsInRoot
        val art = compose.onNodeWithTag("first-art", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        assertEquals(first.bottom, second.top, 1f)
        assertEquals(first.left, art.left, 1f)
        assertEquals(first.top, art.top, 1f)
        val layout = assertFits(title)
        assertEquals(1, layout.lineCount)
        assertTrue(layout.isLineEllipsized(0))
        assertFits("Artist")
        assertFits("Like not confirmed. Reload")
        compose.onNodeWithContentDescription("More for $title").assertWidthIsEqualTo(48.dp).assertHeightIsEqualTo(72.dp)
    }
}
