package com.soundq.android.product

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule

import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.soundq.designsystem.SoundQTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class LibraryMetadataGeometryTest {
    @get:Rule val compose=createComposeRule()
    @Test fun narrowFactsEllipsizeOnOneLineButRetainEveryFullSpokenField() {
        var pixelsPerDp=1f
        val fields=listOf(LibraryMetadataField("123:45:56","Duration 123 hours 45 minutes 56 seconds"),
            LibraryMetadataField("128 BPM","Tempo 128 BPM"),LibraryMetadataField("A minor","Key A minor"))
        compose.setContent {
            val actual=LocalDensity.current
            pixelsPerDp=actual.density
            CompositionLocalProvider(LocalDensity provides Density(actual.density,2f)) {SoundQTheme {
                Box(Modifier.width(110.dp)) {LibraryMetadataContent(fields)}
            }}
        }
        val node=compose.onNodeWithContentDescription(fields.joinToString(", "){it.spoken},useUnmergedTree=true)
        node.assertExists().assertIsDisplayed()
        // Native clearAndSetSemantics intentionally removes text-layout actions. Check the
        // allocated single-line geometry separately from its complete spoken description.
        val bounds=compose.onNodeWithTag("library-row-metadata",useUnmergedTree=true)
            .assertWidthIsEqualTo(110.dp).fetchSemanticsNode().boundsInRoot
        assertTrue(bounds.height<=48*pixelsPerDp+1f)
    }
}
