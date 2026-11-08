package com.soundq.designsystem

import android.graphics.Bitmap
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import soundq.design.generated.SoundQAppearance

/** Geometry and pixels from the mounted controls, not a second presentation model. */
class FlushRowActionsTest {
    @get:Rule val compose=createComposeRule()
    @Test fun lightRowsKeepTouchingSquareActionsAndCompleteBackgrounds()=exercise(SoundQAppearance.Light)
    @Test fun darkRowsKeepTouchingSquareActionsAndCompleteBackgrounds()=exercise(SoundQAppearance.Dark)
    @Test fun singleActionRemainsOneRowHeightSquareThroughoutOverSwipe() {
        val state=RowRevealState(RowRevealOwner())
        var queued=0
        compose.setContent {SoundQTheme {
            SoundQRevealMediaRow("Single","Artist",true,state,true,null,false,{}, {queued++},{},{},Modifier.width(360.dp).testTag("single-owner"))
        }}
        val owner=compose.onNodeWithTag("single-owner",useUnmergedTree=true)
        val queue=compose.onNodeWithContentDescription("Add Single to listening queue",useUnmergedTree=true)
        owner.performTouchInput {down(Offset(width-1f,center.y));moveBy(Offset(-70.dp.toPx(),0f),delayMillis=300);up()}
        compose.waitForIdle()
        val row=owner.fetchSemanticsNode().boundsInRoot
        val cell=queue.fetchSemanticsNode().boundsInRoot
        assertEquals(row.height,cell.width,1f);assertEquals(row.height,cell.height,1f)
        assertEquals(row.right,cell.right,1f);assertEquals(row.top,cell.top,1f)
        var held=false
        var primary:Throwable?=null
        try {
            compose.mainClock.autoAdvance=false
            held=true
            owner.performTouchInput {down(Offset(width*.5f,center.y));moveBy(Offset(-80.dp.toPx(),0f),delayMillis=300)}
            repeat(3){compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
            queue.assertIsSelected()
            assertEquals(cell,queue.fetchSemanticsNode().boundsInRoot)
            assertEquals(0,queued)
            held=false;owner.performTouchInput {cancel()}
        } catch(error:Throwable) {primary=error;throw error}
        finally {
            try {if(held)owner.performTouchInput {cancel()}}
            catch(error:Throwable) {primary?.addSuppressed(error) ?: throw error}
            finally {compose.mainClock.autoAdvance=true}
        }
    }

    private fun exercise(appearance:SoundQAppearance) {
        val states=List(2){RowRevealState(RowRevealOwner())}
        var density=Density(1f)
        var activeColor=Color.Unspecified
        val backgrounds=mutableListOf<Color>()
        var queues=0
        compose.setContent {SoundQTheme(appearance=appearance) {
            density=LocalDensity.current
            activeColor=SoundQ.colors.primary
            backgrounds.clear();backgrounds.add(SoundQ.colors.background);backgrounds.add(SoundQ.colors.surface)
            Column(Modifier.width(360.dp)) {
                for(index in 0..1)SoundQRevealMediaRow("Square $index","Artist",index==1,states[index],true,index==1,true,{}, {queues++},{},{},Modifier.testTag("square-$index"))
                SoundQOccurrenceQueue(listOf(QueueRowVisual("normal","Normal grip","Artist",false),QueueRowVisual("current","Current grip","Artist",true)),{},{_,_->},{},
                    Modifier.height(144.dp).testTag("flush-grips"),bounded=true)
            }
        }}
        fun pump() {compose.mainClock.advanceTimeByFrame();compose.waitForIdle()}
        fun save(node:SemanticsNodeInteraction,name:String):Bitmap {
            val bitmap=node.captureToImage().asAndroidBitmap()
            File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir,"flush-${appearance.name.lowercase()}-$name.png").outputStream().use {
                assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG,100,it))
            }
            return bitmap
        }
        fun near(expected:Float,actual:Float) {assertEquals(expected,actual,1f)}
        var held:SemanticsNodeInteraction?=null
        var primary:Throwable?=null
        try {
            for(index in 0..1) {
                val owner=compose.onNodeWithTag("square-$index",useUnmergedTree=true)
                val like=compose.onNodeWithContentDescription(if(index==1)"Unlike Square $index" else "Like Square $index",useUnmergedTree=true)
                val queue=compose.onNodeWithContentDescription("Add Square $index to listening queue",useUnmergedTree=true)
                val row=owner.fetchSemanticsNode().boundsInRoot
                // The same ordinary pointer reveal is valid on predecessor and successor.
                owner.performTouchInput {down(Offset(width-1f,center.y));moveBy(Offset(-145.dp.toPx(),0f),delayMillis=300);up()}
                compose.waitForIdle()
                like.assertIsEnabled();queue.assertIsEnabled()
                val l=like.fetchSemanticsNode().boundsInRoot
                val q=queue.fetchSemanticsNode().boundsInRoot
                for(cell in listOf(l,q)) {
                    near(row.height,cell.width);near(row.height,cell.height)
                    near(row.top,cell.top);near(row.bottom,cell.bottom)
                }
                near(l.right,q.left);near(q.right,row.right)
                val resting=save(owner,"$index-revealed")
                val sample=with(density){8.dp.toPx()}.toInt()
                val likeX=(l.left-row.left).toInt()+sample
                val queueX=(q.left-row.left).toInt()+sample
                assertEquals("Like must use the complete row surface",backgrounds[index].toArgb(),resting.getPixel(likeX,sample))
                assertEquals("Unarmed Queue must use the complete row surface",backgrounds[index].toArgb(),resting.getPixel(queueX,sample))
                compose.mainClock.autoAdvance=false
                held=owner
                owner.performTouchInput {down(Offset(width*.35f,center.y));moveBy(Offset(-row.height*.75f,0f),delayMillis=300)}
                repeat(3){pump()}
                owner.assert(hasStateDescription("Release to queue"));queue.assertIsSelected()
                fun fixed() {
                    val currentLike=like.fetchSemanticsNode().boundsInRoot
                    val currentQueue=queue.fetchSemanticsNode().boundsInRoot
                    assertEquals("Like bounds must not move or grow during over-swipe",l,currentLike)
                    assertEquals("Queue bounds must not move or grow during over-swipe",q,currentQueue)
                }
                fixed()
                val overswipe=save(owner,"$index-overswipe")
                val gapX=(l.left-row.left-with(density){8.dp.toPx()}).toInt()
                val frontX=(row.width-row.height*2.75f-with(density){8.dp.toPx()}).toInt()
                assertEquals("Dragging must not leave a darker tap ripple on only the sliding front",backgrounds[index].toArgb(),overswipe.getPixel(frontX,sample))
                for(y in listOf(sample,overswipe.height/2,overswipe.height-sample)) {
                    assertEquals("Exposed overtravel must match the current row from top to bottom",backgrounds[index].toArgb(),overswipe.getPixel(gapX,y))
                }
                assertEquals("Like remains flush against the row surface while Queue arms",backgrounds[index].toArgb(),overswipe.getPixel(likeX,sample))
                owner.performTouchInput {moveBy(Offset(-row.height*.25f,0f),delayMillis=100)}
                repeat(3){pump()};fixed()
                compose.mainClock.advanceTimeBy(300);compose.waitForIdle();fixed()
                val active=save(owner,"$index-maximum")
                val edge=with(density){2.dp.toPx()}.toInt()
                for(x in listOf((q.left-row.left).toInt()+edge,(q.right-row.left).toInt()-edge)) {
                    for(y in listOf(edge,active.height-edge))assertEquals("Active Queue fills its complete square without a scaled inset",activeColor.toArgb(),active.getPixel(x,y))
                }
                held=null;owner.performTouchInput {cancel()}
                compose.mainClock.autoAdvance=true;compose.waitForIdle()
                assertEquals(0,queues)
            }
            val list=compose.onNodeWithTag("flush-grips")
            val image=save(list,"grips")
            val listBounds=list.fetchSemanticsNode().boundsInRoot
            for((index,title)in listOf("Normal grip","Current grip").withIndex()) {
                val grip=compose.onNodeWithContentDescription("Reorder $title")
                val bounds=grip.fetchSemanticsNode().boundsInRoot
                near(with(density){72.dp.toPx()},bounds.height);near(bounds.height,bounds.width)
                near(listBounds.right,bounds.right)
                val inset=with(density){8.dp.toPx()}.toInt()
                val x=(bounds.left-listBounds.left).toInt()+inset
                val top=(bounds.top-listBounds.top).toInt()
                for(y in listOf(top+inset,top+bounds.height.toInt()-inset)) {
                    assertEquals("The reorder grip must share the complete row surface",backgrounds[index].toArgb(),image.getPixel(x,y))
                }
            }
        } catch(error:Throwable) {primary=error;throw error}
        finally {
            try {held?.performTouchInput {cancel()}}
            catch(error:Throwable) {primary?.addSuppressed(error) ?: throw error}
            finally {compose.mainClock.autoAdvance=true}
        }
    }
}
