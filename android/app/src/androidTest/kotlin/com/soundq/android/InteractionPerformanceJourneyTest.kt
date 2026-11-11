package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.product.ProductViewModel
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Real root, populated service queue, touch scrolling and transport. No fixture FPS or thresholds. */
class InteractionPerformanceJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun populatedQueueScrollAndAudioControlsRetainBoundedWindowMetrics() {
        val graph=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as SoundQApplication).graph
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("synthetic@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        compose.waitUntil(10000){graph.library.state.value.rows.size==3}
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        val rows=graph.library.state.value.rows
        compose.runOnIdle {graph.rememberTracks(rows);model.controller.playContext(List(120){rows[it%rows.size]},0)}
        compose.waitUntil(15000){model.playback.value.queue.size==120 && model.playback.value.isPlaying}
        compose.onNodeWithContentDescription("Open listening queue").performClick()
        compose.runOnIdle {compose.activity.beginInteractionTrace()}
        try {
            repeat(4){compose.onAllNodes(hasScrollAction()).onFirst().performTouchInput {swipeUp(durationMillis=300)}}
            compose.onNodeWithContentDescription("Pause").performClick()
            compose.waitUntil(10000){!model.playback.value.isPlaying}
            compose.onNodeWithContentDescription("Play").performClick()
            compose.waitUntil(10000){model.playback.value.isPlaying}
        } finally {
            compose.runOnIdle {
                val file=File(compose.activity.filesDir,"interaction-queue.json")
                compose.activity.endInteractionTrace(file)
                val result=JSONObject(file.readText())
                assertTrue(result.getJSONArray("frames").length()>0)
                assertTrue(result.getJSONArray("inputs").length()>0)
                assertTrue(result.getJSONArray("frames").length()<=600)
                model.controller.pause()
            }
        }
    }
}
