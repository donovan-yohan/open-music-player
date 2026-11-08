package com.soundq.android

import androidx.compose.foundation.layout.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.playlists.PlaylistMemberOrderList
import com.soundq.designsystem.*
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class PlaylistRowRuleTest {
    @get:Rule val compose=createComposeRule()
    @Test fun playlistGridSurvivesSwipeLiftNeighborMotionAndSettle() {
        var border=Color.Unspecified
        var queued=0
        val moves=mutableListOf<Pair<String,Int>>()
        val rows=List(4){QueueRowVisual("occ-$it","Grid song $it","Artist",false)}
        compose.setContent {SoundQTheme {
            border=SoundQ.colors.border
            PlaylistMemberOrderList(rows,{}, {id,to->moves.add(id to to)}, {},
                Modifier.width(360.dp).height(288.dp).testTag("playlist-grid"),onQueue={queued++})
        }}
        val root=compose.onNodeWithTag("playlist-grid")
        val first=compose.onNodeWithContentDescription("Reorder Grid song 0")
        val origin=first.fetchSemanticsNode().boundsInRoot
        val second=compose.onNodeWithContentDescription("Reorder Grid song 1").fetchSemanticsNode().boundsInRoot
        val rowHeight=second.center.y-origin.center.y
        fun frame(name:String) {
            val bitmap=root.captureToImage().asAndroidBitmap()
            File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir,"playlist-grid-$name.png").outputStream().use {
                assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it))
            }
            for(index in rows.indices) {
                val y=((index+1)*rowHeight-2).toInt()
                for(x in 0 until bitmap.width)assertEquals("$name lost playlist grid rule $index at x=$x",border.toArgb(),bitmap.getPixel(x,y))
            }
        }
        val swipe=compose.onNode(SemanticsMatcher("first song swipe owner") {
            it.config.getOrNull(SemanticsActions.CustomActions)?.any {action->action.label=="Reveal actions for Grid song 0"}==true
        },useUnmergedTree=true)
        var held:SemanticsNodeInteraction?=null
        var primary:Throwable?=null
        try {
            compose.mainClock.autoAdvance=false
            frame("rest")
            held=swipe
            swipe.performTouchInput {down(Offset(width-1f,center.y));moveBy(Offset(-180.dp.toPx(),0f),delayMillis=300)}
            repeat(3){compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
            swipe.assert(hasStateDescription("Release to queue"))
            frame("swiped-armed")
            held=null;swipe.performTouchInput {up()}
            repeat(3){compose.mainClock.advanceTimeByFrame();compose.waitForIdle();frame("swipe-return-$it")}
            compose.mainClock.autoAdvance=true;compose.waitForIdle();assertEquals(1,queued)
            compose.mainClock.autoAdvance=false
            held=first
            first.performTouchInput {down(center);moveBy(Offset(0f,rowHeight*1.25f))}
            repeat(3){compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
            first.assert(hasStateDescription("Moving to position 2"))
            assertTrue(first.fetchSemanticsNode().boundsInRoot.top>origin.top+rowHeight)
            frame("lifted")
            repeat(4){compose.mainClock.advanceTimeByFrame();compose.waitForIdle();frame("held-$it")}
            held=null;first.performTouchInput {up()}
            compose.mainClock.advanceTimeByFrame();compose.waitForIdle();assertTrue(moves.isEmpty())
            repeat(3){compose.mainClock.advanceTimeByFrame();compose.waitForIdle();frame("settle-$it")}
            compose.mainClock.autoAdvance=true;compose.waitForIdle()
            frame("committed")
            assertEquals(listOf("occ-0" to 1),moves)
            assertEquals(1,queued)
        } catch(error:Throwable) {primary=error;throw error}
        finally {
            try {held?.performTouchInput {cancel()}}
            catch(error:Throwable) {primary?.addSuppressed(error) ?: throw error}
            finally {compose.mainClock.autoAdvance=true}
        }
    }

    @Test fun playlistGripSharesTheCompleteBottomRule() {
        compose.setContent {SoundQTheme {
            Column(Modifier.width(360.dp).testTag("playlist-rule-composition")) {
                SoundQMediaRow("Reference","Artist",false,{},{},Modifier.testTag("reference-rule"))
                PlaylistMemberOrderList(listOf(QueueRowVisual("a","First song","Artist",false),QueueRowVisual("b","Second song","Artist",false)),{},{_,_->},{},
                    Modifier.height(144.dp),onQueue={})
            }
        }}
        val root=compose.onNodeWithTag("playlist-rule-composition")
        val bitmap=root.captureToImage().asAndroidBitmap()
        File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir,"playlist-row-rules.png").outputStream().use {
            assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it))
        }
        val reference=compose.onNodeWithTag("reference-rule").fetchSemanticsNode().boundsInRoot
        val top=root.fetchSemanticsNode().boundsInRoot.top
        val y=(reference.bottom-top-2).toInt()
        val expected=bitmap.getPixel(bitmap.width/2,y)
        assertNotEquals(bitmap.getPixel(bitmap.width/2,y-5),expected)
        for(row in 0..2)for(x in 0 until bitmap.width)assertEquals("Playlist row $row missing rule at x=$x",expected,bitmap.getPixel(x,y+row*reference.height.toInt()))
        compose.onNodeWithContentDescription("Reorder First song").assertIsDisplayed()
        compose.onNodeWithContentDescription("Reorder Second song").assertIsDisplayed()
    }
}
