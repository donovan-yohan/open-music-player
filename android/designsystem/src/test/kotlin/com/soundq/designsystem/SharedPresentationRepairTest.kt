package com.soundq.designsystem

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Mounted host composition, not device pixels or TalkBack/system-UI acceptance. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[34])
class SharedPresentationRepairTest {
    @get:Rule val compose=createComposeRule()

    @Test fun enlargedRowKeepsEssentialSupportingBesideArtistAndIndependentMore() {
        val title="Long song identity ".repeat(6)
        val artist="Complete artist identity ".repeat(5)
        var activated=0;var more=0
        compose.setContent {
            val actual=LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(actual.density,1.3f)) {SoundQTheme {
                Box(Modifier.requiredWidth(393.dp)) {
                    SoundQMediaRow(title,artist,false,{activated++},{more++},Modifier.testTag("row"),
                        supporting="Failed",metadata={Text("—",style=SoundQ.typography.mono)})
                }
            }}
        }
        compose.onNodeWithText("Failed",useUnmergedTree=true).assertIsDisplayed()
        compose.onNodeWithText(artist,useUnmergedTree=true).assertIsDisplayed()
        compose.onNodeWithText("—",useUnmergedTree=true).assertIsDisplayed()
        compose.onNodeWithTag("row").assertHeightIsEqualTo(72.dp)
        compose.onNodeWithTag("media-artwork",useUnmergedTree=true).assertWidthIsEqualTo(72.dp).assertHeightIsEqualTo(72.dp)
        compose.onNodeWithContentDescription("More for $title").assertWidthIsAtLeast(48.dp).performClick()
        compose.onNodeWithTag("row").performClick()
        compose.runOnIdle {assertEquals(1,activated);assertEquals(1,more)}
    }

    @Test fun compactFactDoesNotReplaceSongIdentityWhenMetadataHasItsOwnDescription() {
        val full="Download failed. Device storage unavailable; retry from Device copy."
        compose.setContent {
            val actual=LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(actual.density,2f)) {SoundQTheme {
                Box(Modifier.requiredWidth(393.dp)) {
                    SoundQMediaRow("Complete song","Complete artist",false,{},{},Modifier.testTag("projected-row"),
                        supporting=full,compactSupporting="Failed",metadata={
                            Text("—",Modifier.semantics {contentDescription="Duration unavailable"},style=SoundQ.typography.mono)
                        })
                }
            }}
        }
        val node=compose.onNodeWithTag("projected-row").fetchSemanticsNode()
        assertTrue(node.config[SemanticsProperties.ContentDescription].contains("Complete song, Complete artist, $full"))
        assertTrue(node.config[SemanticsProperties.ContentDescription].contains("Duration unavailable"))
        assertTrue(node.config[SemanticsProperties.Text].map {it.text}.containsAll(listOf("Complete song","Complete artist",full)))
        compose.onNodeWithText(full,useUnmergedTree=true).assertIsDisplayed()
    }
}
