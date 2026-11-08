package com.soundq.android

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import com.soundq.android.product.ProductViewModel
import com.soundq.android.data.timeline.globalEndMs
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Ordinary Activity -> Queue -> loaded waveforms. Parent runs on its exclusively owned device. */
class WaveformViewportJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun bodyPanAndCrossLanePinchChangeViewportNotDocumentOrPausedTransport() {
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("waveform-gestures@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.waitUntil(15000){model.library.value.rows.size==3}
        compose.onNode(hasClickAction() and hasAnyDescendant(hasText("Fixture 1")) and hasAnyDescendant(hasContentDescription("More for Fixture 1")),useUnmergedTree=true).performClick()
        compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.positionMs>300}
        compose.runOnIdle {model.controller.pause()}
        compose.waitUntil(10000){!model.playback.value.isPlaying&&!model.playback.value.preparing}
        compose.onNodeWithContentDescription("Open listening queue").performClick()
        compose.onNodeWithText("Waveforms").performClick()
        val ids=compose.runOnIdle {model.playback.value.queue.take(2).map {it.occurrenceId}}
        val first=compose.onNodeWithContentDescription("Waveform ${ids[0]}")
        val second=compose.onNodeWithContentDescription("Waveform ${ids[1]}")
        compose.waitUntil(15000){listOf(first,second).all {it.fetchSemanticsNode().config.getOrNull(SemanticsProperties.StateDescription)?.startsWith("Loaded")==true}}
        val stack=compose.onNodeWithContentDescription("Waveform timeline")
        val authored=compose.runOnIdle {model.timeline.value.document}
        val paused=compose.runOnIdle {model.playback.value}
        fun camera():Pair<Float,Float> {
            val axis=stack.fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange]
            return axis.value() to (authored.clips.maxOf {it.globalEndMs}.toFloat()-axis.maxValue())
        }
        // Zoom away from the fitted overview before testing pan boundaries.
        repeat(2){compose.onNodeWithContentDescription("Zoom in").performClick()}
        val initial=camera()
        first.performTouchInput {swipe(Offset(width*.65f,height*.8f),Offset(width*.25f,height*.8f),300)}
        val later=camera()
        assertTrue("Loaded waveform must pan later",later.first>initial.first)
        assertEquals("Pan must not change span",initial.second,later.second,1f)
        first.performTouchInput {swipe(Offset(width*.25f,height*.8f),Offset(width*.65f,height*.8f),300)}
        assertTrue("Reverse pan must move earlier",camera().first<later.first)
        val a=first.fetchSemanticsNode().boundsInRoot
        val b=second.fetchSemanticsNode().boundsInRoot
        val origin=stack.fetchSemanticsNode().boundsInRoot.topLeft
        val beforePinch=camera()
        stack.performTouchInput {
            val y1=a.bottom-a.height*.2f-origin.y;val y2=b.bottom-b.height*.2f-origin.y
            down(0,Offset(width*.35f,y1));down(1,Offset(width*.65f,y2))
            repeat(8){step->
                moveTo(0,Offset(width*(.35f-.02f*(step+1)),y1),delayMillis=16)
                moveTo(1,Offset(width*(.65f+.02f*(step+1)),y2),delayMillis=16)
            }
            up(0);up(1)
        }
        assertTrue("Cross-lane two-pointer zoom must reduce visible span",camera().second<beforePinch.second)
        first.performTouchInput {swipe(Offset(width*.5f,height*.8f),Offset(width*.5f,height*.8f+500f),350)}
        compose.onNodeWithContentDescription("Close Queue").assertIsDisplayed()
        compose.runOnIdle {
            assertEquals(authored,model.timeline.value.document)
            val now=model.playback.value
            assertEquals(paused.queue,now.queue);assertEquals(paused.selectedOccurrence,now.selectedOccurrence)
            assertEquals(paused.positionMs,now.positionMs);assertEquals(paused.isPlaying,now.isPlaying)
            assertEquals(paused.source,now.source);assertEquals(paused.arrangement,now.arrangement)
        }
        compose.onNodeWithContentDescription("Drag to close Queue").performTouchInput {swipe(center,Offset(centerX,centerY+120.dp.toPx()),400)}
        compose.onNodeWithContentDescription("Close Queue").assertDoesNotExist()
        compose.onNodeWithContentDescription("Open listening queue").assertIsDisplayed()
    }
}
