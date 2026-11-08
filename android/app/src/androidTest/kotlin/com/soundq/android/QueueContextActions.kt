package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.ComposeTestRule

/** Follow the production disclosure route. Downstream BPM/audio assertions stay in their owners. */
internal fun ComposeTestRule.openWaveformBpm(title:String) {
    waitUntil(10000) {onAllNodes(hasContentDescription("More for $title") and isEnabled()).fetchSemanticsNodes().isNotEmpty()}
    onNodeWithContentDescription("More for $title").performClick()
    onNode(hasText("Set BPM") and hasClickAction()).assertIsDisplayed().assertIsEnabled().performClick()
}

/** The chronological editor is not a source queue. Source commands require this explicit context. */
internal fun ComposeTestRule.showSourceListeningQueue() {
    if(onAllNodesWithText("Listening queue").fetchSemanticsNodes().isNotEmpty())return
    onNodeWithContentDescription("Queue actions").performClick()
    onNode(hasText("Listening queue") and hasClickAction()).performClick()
}
