package com.soundq.designsystem

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Mounted Android Compose bounds and real text measurement, not physical-device proof. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[34],qualifiers="w393dp-h852dp")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SilentPlayerPreparationTest {
    @get:Rule val compose=createComposeRule()
    private fun geometry(scale:Float) {
        val preparing=mutableStateOf(false);val error=mutableStateOf<String?>(null)
        var primary=0
        compose.setContent {
            val actual=LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(actual.density,scale)) {SoundQTheme {
                Box(Modifier.requiredSize(393.dp,852.dp)) {
                    SoundQFullPlayerContent("Selected song","Artist",false,true,preparing.value,
                        3_600_000,12_372_000,"same",{},{primary++},{},{},onInfo={},error=error.value,
                        modifier=Modifier.fillMaxSize())
                }
            }}
        }
        fun bounds()=listOf(
            compose.onNodeWithTag("player-artwork",true).fetchSemanticsNode().boundsInRoot,
            compose.onNodeWithText("Selected song",true).fetchSemanticsNode().boundsInRoot,
            compose.onNodeWithContentDescription("Playback position").fetchSemanticsNode().boundsInRoot,
            compose.onNodeWithContentDescription("Previous track").fetchSemanticsNode().boundsInRoot,
            compose.onNodeWithContentDescription("Next track").fetchSemanticsNode().boundsInRoot,
            compose.onNodeWithContentDescription("Open listening queue").fetchSemanticsNode().boundsInRoot,
            compose.onNodeWithContentDescription("Song details").fetchSemanticsNode().boundsInRoot)
        val before=bounds()
        repeat(4) {index->
            compose.runOnIdle {preparing.value=index%2==0;error.value=if(index==2)"Audio failed" else null}
            assertEquals("Background state cannot move player controls",before,bounds())
            compose.onNodeWithText("Preparing audio").assertDoesNotExist()
            compose.onNodeWithText("Audio failed").assertDoesNotExist()
        }
        compose.runOnIdle {preparing.value=true}
        compose.onNodeWithContentDescription("Pause").assertIsEnabled().performClick()
        compose.runOnIdle {assertEquals(1,primary)}
        val clock=compose.onNodeWithText("01:00:00 / 03:26:12",useUnmergedTree=true)
        clock.assertIsDisplayed()
        val layouts=mutableListOf<TextLayoutResult>()
        clock.performSemanticsAction(SemanticsActions.GetTextLayoutResult){it(layouts)}
        val layout=layouts.single()
        assertFalse("Whole hour clock must fit or wrap: size=${layout.size}, constraints=${layout.layoutInput.constraints}, width=${layout.didOverflowWidth}, height=${layout.didOverflowHeight}, lines=${layout.lineCount}, right=${layout.getLineRight(0)}, scale=${layout.layoutInput.density.fontScale}",layout.hasVisualOverflow)
        for (index in layout.layoutInput.text.indices) {
            val glyph=layout.getBoundingBox(index)
            assertTrue(glyph.left>=0f && glyph.right<=layout.size.width.toFloat())
        }
    }
    @Test fun normalPlayerKeepsArtworkSeekTransportAndUtilitiesStationary()=geometry(1f)
    @Test @Config(fontScale=1.5f) fun enlargedPlayerKeepsArtworkSeekTransportAndUtilitiesStationary()=geometry(1.5f)

    @Test fun compactPreparationKeepsIdentityAndSilentSemanticsWithPauseCommand() {
        val preparing=mutableStateOf(false);var pauses=0
        compose.setContent {SoundQTheme {Box(Modifier.requiredWidth(393.dp)) {
            SoundQCompactPlayer("Nothing playing","",false,true,preparing.value,{},{pauses++},{})
        }}}
        val before=compose.onNodeWithText("Nothing playing",true).fetchSemanticsNode().boundsInRoot
        compose.runOnIdle {preparing.value=true}
        compose.onNodeWithText("Preparing audio",true).assertDoesNotExist()
        compose.onNodeWithContentDescription("Pause preparation").assertDoesNotExist()
        assertEquals(before,compose.onNodeWithText("Nothing playing",true).fetchSemanticsNode().boundsInRoot)
        compose.onNodeWithContentDescription("Pause").performClick()
        compose.runOnIdle {assertEquals(1,pauses)}
    }

    @Test @Config(fontScale=1.5f) fun compactLongClockReflowsAtNarrowEnlargedWidthWithoutClippedDigits() {
        val preparing=mutableStateOf(false)
        val timing=CompactSongTiming(elapsedMs=3_600_000,totalMs=Long.MAX_VALUE,selected=true)
        compose.setContent {
            val actual=LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(actual.density,1.5f)) {SoundQTheme {
                Box(Modifier.requiredWidth(280.dp)) {
                    SoundQCompactPlayer("Selected song","Artist",false,true,preparing.value,{},{},{},timing=timing)
                }
            }}
        }
        val clock=compose.onNodeWithContentDescription(timing.clockDescription,useUnmergedTree=true)
        clock.assertIsDisplayed()
        val before=clock.fetchSemanticsNode().boundsInRoot
        val layouts=mutableListOf<TextLayoutResult>()
        clock.performSemanticsAction(SemanticsActions.GetTextLayoutResult){it(layouts)}
        val layout=layouts.single()
        assertFalse(layout.hasVisualOverflow)
        for (index in layout.layoutInput.text.indices) {
            val glyph=layout.getBoundingBox(index)
            assertTrue(glyph.left>=0f&&glyph.right<=layout.size.width.toFloat())
        }
        compose.runOnIdle {preparing.value=true}
        assertEquals(before,clock.fetchSemanticsNode().boundsInRoot)
        compose.onNodeWithText("Preparing audio").assertDoesNotExist()
    }
}
