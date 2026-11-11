package com.soundq.designsystem

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.background
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class MediaRowRuleTest {
    @get:Rule val compose=createComposeRule()

    @Test fun reorderRulesStayOnListGridDuringLiftNeighborMotionSettleAndCancel() {
        var border=Color.Unspecified
        val moves=mutableListOf<Pair<String,Int>>()
        val rows=List(4){QueueRowVisual("occ-$it","Grid song $it","Artist",false)}
        compose.setContent {SoundQTheme {
            border=SoundQ.colors.border
            SoundQOccurrenceQueue(rows,{}, {id,to->moves.add(id to to)}, {},
                Modifier.width(360.dp).height(288.dp).testTag("stationary-grid"),bounded=true,
                artwork={Box(Modifier.fillMaxSize().background(Color.Magenta))})
        }}
        val root=compose.onNodeWithTag("stationary-grid")
        val first=compose.onNodeWithContentDescription("Reorder Grid song 0")
        val second=compose.onNodeWithContentDescription("Reorder Grid song 1")
        val origin=first.fetchSemanticsNode().boundsInRoot
        val next=second.fetchSemanticsNode().boundsInRoot
        val rowHeight=next.center.y-origin.center.y
        fun frame(name:String) {
            val bitmap=root.captureToImage().asAndroidBitmap()
            File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir,"grid-$name.png").outputStream().use {
                assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it))
            }
            for(index in rows.indices) {
                val y=((index+1)*rowHeight-2).toInt()
                for(x in 0 until bitmap.width)assertEquals("$name lost stationary slot $index rule at x=$x",border.toArgb(),bitmap.getPixel(x,y))
            }
            // No second full-width separator is allowed to travel with a lifted song.
            for(y in 0 until bitmap.height) {
                val nearSlot=(1..rows.size).any {boundary->kotlin.math.abs(y+1-boundary*rowHeight)<4}
                if(!nearSlot&&bitmap.getPixel(0,y)==border.toArgb()) {
                    assertFalse("$name has a moving separator at y=$y",(0 until bitmap.width).all {x->bitmap.getPixel(x,y)==border.toArgb()})
                }
            }
        }
        var held=false
        var primary:Throwable?=null
        try {
            compose.mainClock.autoAdvance=false
            frame("rest")
            held=true
            first.performTouchInput {down(center);moveBy(Offset(0f,rowHeight*1.25f))}
            repeat(3){compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
            first.assert(hasStateDescription("Moving to position 2"))
            assertTrue(first.fetchSemanticsNode().boundsInRoot.top>origin.top+rowHeight)
            assertTrue(moves.isEmpty())
            frame("lifted")
            repeat(4){compose.mainClock.advanceTimeByFrame();compose.waitForIdle();frame("held-$it")}
            held=false;first.performTouchInput {up()}
            compose.mainClock.advanceTimeByFrame();compose.waitForIdle()
            assertTrue(moves.isEmpty())
            frame("settling-start")
            repeat(3){compose.mainClock.advanceTimeByFrame();compose.waitForIdle();frame("settling-$it")}
            compose.mainClock.autoAdvance=true;compose.waitForIdle()
            assertEquals(listOf("occ-0" to 1),moves)
            frame("returned")
            compose.mainClock.autoAdvance=false
            held=true;first.performTouchInput {down(center);moveBy(Offset(0f,rowHeight*1.25f))}
            repeat(3){compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
            frame("before-cancel")
            held=false;first.performTouchInput {cancel()}
            compose.mainClock.autoAdvance=true;compose.waitForIdle()
            frame("cancelled")
            assertEquals(listOf("occ-0" to 1),moves)
        } catch(error:Throwable) {primary=error;throw error}
        finally {
            try {
                if(held)first.performTouchInput {cancel()}
            } catch(error:Throwable) {primary?.addSuppressed(error) ?: throw error}
            finally {compose.mainClock.autoAdvance=true}
        }
    }

    @Test fun bottomRuleSpansArtworkBodyAndReorderGrip() {
        compose.setContent {SoundQTheme {
            Column(Modifier.width(360.dp).testTag("row-rule-composition")) {
                SoundQMediaRow("Direct song","Artist",false,{},{},Modifier.testTag("direct-rule"))
                SoundQOccurrenceQueue(listOf(QueueRowVisual("first","First song","Artist",false),QueueRowVisual("second","Second song","Artist",false)),{},{_,_->},{},
                    Modifier.height(144.dp).testTag("queue-rules"),bounded=true)
            }
        }}
        val image=compose.onNodeWithTag("row-rule-composition").captureToImage()
        val bitmap=image.asAndroidBitmap()
        val output=File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir,"row-rule-composition.png")
        output.outputStream().use {bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)}

        val direct=compose.onNodeWithTag("direct-rule").fetchSemanticsNode().boundsInRoot
        val root=compose.onNodeWithTag("row-rule-composition").fetchSemanticsNode().boundsInRoot
        val y=(direct.bottom-root.top-2).toInt()
        // Compare the same rasterized subpixel row, not an unblended theme color.
        val expected=bitmap.getPixel(bitmap.width/2,y)
        assertNotEquals("Reference must contain a visible rule",bitmap.getPixel(bitmap.width/2,y-5),expected)
        for(row in 0..2) {
            val bottom=y+row*direct.height.toInt()
            // Every pixel includes the final edge beneath the trailing drag grip.
            for(x in 0 until bitmap.width)assertEquals("Row $row bottom rule missing at x=$x",expected,bitmap.getPixel(x,bottom))
        }
    }
}
