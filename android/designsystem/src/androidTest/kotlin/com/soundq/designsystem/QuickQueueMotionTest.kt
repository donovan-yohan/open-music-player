package com.soundq.designsystem

import android.graphics.Bitmap
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

import soundq.design.generated.SoundQComposeTokens as T

/** Mounted regressions; compilation/execution belong to the parent runtime gate. */
class QuickQueueMotionTest {
    @get:Rule val compose=createComposeRule()
    private val title="Queue song"
    private var ruleColor=Color.Unspecified
    private var ruleInset=1f
    private fun owner()=compose.onNodeWithTag("swipe-owner",useUnmergedTree=true)
    private fun queue()=compose.onNodeWithContentDescription("Add $title to listening queue",useUnmergedTree=true)
    private fun like()=compose.onNodeWithContentDescription("Like $title",useUnmergedTree=true)
    private fun fill():Color {
        val pixels=queue().captureToImage().toPixelMap()
        // Inside the painted cell, away from the outline, glyph and pressed inset.
        return pixels[pixels.width/2,(pixels.height*.15f).toInt()]
    }
    private fun distance(a:Color,b:Color)=kotlin.math.abs(a.red-b.red)+kotlin.math.abs(a.green-b.green)+kotlin.math.abs(a.blue-b.blue)
    private fun frames(milliseconds:Long) {compose.mainClock.advanceTimeBy(milliseconds);compose.waitForIdle()}
    private fun frame(name:String) {
        val bitmap=owner().captureToImage().asAndroidBitmap()
        val y=(bitmap.height-ruleInset).toInt()
        for(x in 0 until bitmap.width)assertEquals("Stationary separator missing in $name at x=$x",ruleColor.toArgb(),bitmap.getPixel(x,y))
        val file=File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir,"swipe-$name.png")
        file.outputStream().use {assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG,100,it))}
    }

    @Test fun mountedTrayKeepsIdentityAndContinuousGeometryWhileArmAnimatesRetreatsAndRearms() {
        val state=RowRevealState(RowRevealOwner())
        var queues=0;var plays=0;var likes=0
        var replacementQueues=0
        var quickQueue by mutableStateOf<()->Unit>({queues++})
        val haptics=mutableListOf<Int>()
        var density=Density(1f)
        var activeFill=Color.Unspecified
        compose.setContent {SoundQTheme {
            density=androidx.compose.ui.platform.LocalDensity.current
            ruleColor=SoundQ.colors.border
            ruleInset=with(density){(SoundQ.sizes.border.toPx()/2).coerceAtLeast(1f)}
            activeFill=SoundQ.colors.primary
            val actualView=LocalView.current
            val context=actualView.context
            val feedback=remember {object:View(context) {
                override fun performHapticFeedback(feedbackConstant:Int):Boolean {haptics.add(feedbackConstant);return true}
            }}
            DisposableEffect(actualView,feedback) {
                // Ripple requires a real hierarchy when LocalView observes feedback.
                val parent=actualView.rootView.findViewById<android.view.ViewGroup>(android.R.id.content)
                parent.addView(feedback,android.view.ViewGroup.LayoutParams(0,0))
                onDispose {parent.removeView(feedback)}
            }
            // Observe the existing platform-feedback call; no gesture or reducer facade.
            CompositionLocalProvider(LocalView provides feedback) {
                SoundQRevealMediaRow(title,"Artist",false,state,true,false,true,{likes++},{queues++},{plays++},{},modifier=Modifier.testTag("swipe-owner"),onQuickQueue=quickQueue)
            }
        }}
        val bounds=owner().fetchSemanticsNode().boundsInRoot
        frame("closed")
        val (arm,maximum,step)=with(density) {
            val height=bounds.height.toDp()
            val geometry=swipeQueueGeometry(height,true)
            assertTrue(geometry.fits(bounds.width.toDp()))
            Triple(geometry.arm.toPx(),geometry.maximum.toPx(),2.dp.toPx())
        }
        var held=false
        var primary:Throwable?=null
        try {
            compose.mainClock.autoAdvance=false
            held=true
            owner().performTouchInput {down(Offset(width-1f,center.y));moveBy(Offset(-(arm-step*2),0f),delayMillis=300)}
            frames(16)
            queue().assertIsNotSelected().assertIsNotEnabled()
            like().assertIsNotEnabled()
            val queueId=queue().fetchSemanticsNode().id
            val likeId=like().fetchSemanticsNode().id
            val tray=checkNotNull(queue().fetchSemanticsNode().parent)
            val initialTrayWidth=tray.boundsInRoot.width
            val restingFill=fill()
            frame("outlined-reveal")
            fun stableActions() {
                frames(16)
                assertEquals(queueId,queue().fetchSemanticsNode().id)
                assertEquals(likeId,like().fetchSemanticsNode().id)
                assertEquals(tray.id,queue().fetchSemanticsNode().parent!!.id)
                assertEquals(tray.id,like().fetchSemanticsNode().parent!!.id)
                queue().assertIsNotEnabled();like().assertIsNotEnabled()
                compose.onNodeWithText("Release to queue",useUnmergedTree=true).assertDoesNotExist()
            }
            owner().performTouchInput {moveBy(Offset(-step,0f),delayMillis=100)}
            stableActions()
            val beforeArmWidth=queue().fetchSemanticsNode().parent!!.boundsInRoot.width
            assertEquals("Tray width stays fixed while the content keeps sliding",initialTrayWidth,beforeArmWidth,1f)
            owner().performTouchInput {moveBy(Offset(-step*2,0f),delayMillis=100)}
            stableActions()
            queue().assertIsSelected().assert(hasStateDescription("Release to queue"))
            owner().assert(hasStateDescription("Release to queue"))
            assertEquals("Arming must not resize or space the actions",beforeArmWidth,queue().fetchSemanticsNode().parent!!.boundsInRoot.width,1f)
            compose.runOnIdle {assertTrue(state.armed);assertEquals(listOf(HapticFeedbackConstants.CLOCK_TICK),haptics);assertEquals(0,queues+likes+plays)}
            // A held pointer has an actual intermediate painted fill, not a swapped control.
            compose.mainClock.advanceTimeByFrame()
            frames(T.MOTION_DURATION_QUICK.toLong()/2)
            val intermediate=fill()
            frame("halfway-arm")
            assertTrue("Armed fill must leave its outlined rest state",distance(restingFill,intermediate)>.03f)
            assertTrue("Armed fill must not snap to its terminal color",distance(activeFill,intermediate)>.03f)
            frames(T.MOTION_DURATION_QUICK.toLong())
            assertTrue(distance(activeFill,fill())<.03f)
            frame("filled-armed")
            owner().performTouchInput {moveBy(Offset(-(maximum-arm-step),0f),delayMillis=100)}
            stableActions()
            compose.runOnIdle {assertEquals(1,haptics.size);assertEquals(0,queues)}
            owner().performTouchInput {moveBy(Offset(maximum-arm+step,0f),delayMillis=100)}
            stableActions();queue().assertIsNotSelected()
            compose.runOnIdle {assertFalse(state.armed);assertEquals(1,haptics.size)}
            frames(T.MOTION_DURATION_QUICK.toLong()+32)
            assertTrue("Retreat restores the outlined fill",distance(restingFill,fill())<.03f)
            frame("retreat")
            owner().performTouchInput {moveBy(Offset(-step*2,0f),delayMillis=100)}
            stableActions();queue().assertIsSelected()
            compose.runOnIdle {assertEquals(listOf(HapticFeedbackConstants.CLOCK_TICK,HapticFeedbackConstants.CLOCK_TICK),haptics);assertEquals(0,queues)}
            // Recomposition cannot replace the callback captured at the original Down.
            compose.runOnIdle {quickQueue={replacementQueues++}}
            stableActions()
            held=false;owner().performTouchInput {up()}
            compose.mainClock.advanceTimeByFrame()
            frames(T.MOTION_DURATION_SETTLE.toLong()/2)
            frame("settling")
            compose.runOnIdle {assertEquals(RowRevealPhase.Settling,state.phase);assertEquals(1,queues);assertEquals(0,replacementQueues)}
            compose.mainClock.autoAdvance=true;compose.waitForIdle()
            compose.runOnIdle {assertEquals(1,queues);assertEquals(0,likes+plays);assertEquals(RowRevealPhase.Closed,state.phase)}
            // A second accepted, armed gesture is cancelled, never queued on settle.
            held=true
            owner().performTouchInput {down(Offset(width-1f,center.y));moveBy(Offset(-maximum,0f),delayMillis=300)}
            stableActions();queue().assertIsSelected()
            compose.runOnIdle {assertEquals(3,haptics.size);assertEquals(1,queues)}
            held=false;owner().performTouchInput {cancel()}
            compose.waitForIdle()
            compose.runOnIdle {assertFalse(state.armed);assertEquals(RowRevealPhase.Closed,state.phase);assertEquals(1,queues);assertEquals(0,likes+plays+replacementQueues)}
            compose.onAllNodes(hasContentDescription("Add $title to listening queue") and isEnabled()).assertCountEquals(0)
            compose.onAllNodes(hasContentDescription("Like $title") and isEnabled()).assertCountEquals(0)
            // Mounted actions become usable only after the normal reveal settles.
            val revealAction=owner().fetchSemanticsNode().config[SemanticsActions.CustomActions].single {it.label=="Reveal actions for $title"}
            compose.runOnIdle {assertTrue(revealAction.action())}
            compose.waitForIdle()
            assertEquals(queueId,queue().fetchSemanticsNode().id)
            assertEquals(likeId,like().fetchSemanticsNode().id)
            queue().assertIsNotSelected().assertIsEnabled().performClick()
            compose.waitForIdle()
            compose.runOnIdle {assertEquals(2,queues);assertEquals(0,likes+plays+replacementQueues)}
        } catch(error:Throwable) {primary=error;throw error}
        finally {
            try {
                compose.mainClock.autoAdvance=true
                if(held)owner().performTouchInput {cancel()}
            } catch(error:Throwable) {primary?.addSuppressed(error) ?: throw error}
        }
    }

    @Test fun reducedMotionArmsAndRetreatsWithoutTimedFillOrActionReplacement() {
        val state=RowRevealState(RowRevealOwner());var queues=0
        var activeFill=Color.Unspecified
        var density=Density(1f)
        compose.setContent {SoundQTheme(reducedMotion=true) {
            activeFill=SoundQ.colors.primary
            density=androidx.compose.ui.platform.LocalDensity.current
            SoundQRevealMediaRow(title,"Artist",false,state,true,false,true,{}, {queues++},{},{},modifier=Modifier.testTag("swipe-owner"))
        }}
        val bounds=owner().fetchSemanticsNode().boundsInRoot
        val (arm,maximum,step)=with(density) {
            val height=bounds.height.toDp()
            val geometry=swipeQueueGeometry(height,true)
            Triple(geometry.arm.toPx(),geometry.maximum.toPx(),2.dp.toPx())
        }
        try {
            compose.mainClock.autoAdvance=false
            compose.runOnIdle {state.begin(0f,arm);state.follow(-(arm-step),maximum)}
            val id=queue().fetchSemanticsNode().id
            val restingFill=fill()
            compose.runOnIdle {state.follow(-(arm+step),maximum)}
            frames(32)
            assertEquals(id,queue().fetchSemanticsNode().id)
            queue().assertIsSelected().assertIsNotEnabled()
            assertTrue(distance(activeFill,fill())<.03f)
            compose.runOnIdle {state.follow(-(arm-step),maximum)}
            frames(32)
            queue().assertIsNotSelected()
            assertTrue(distance(restingFill,fill())<.03f)
            compose.runOnIdle {state.end(with(density){swipeQueueGeometry(bounds.height.toDp(),true).reveal.toPx()},T.MOTION_ROW_COMMIT_PROGRESS,0f,1f,cancel=true)}
            frames(32)
            compose.runOnIdle {assertEquals(0,queues);assertEquals(RowRevealPhase.Closed,state.phase)}
        } finally {compose.mainClock.autoAdvance=true}
    }
}
