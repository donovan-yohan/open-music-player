package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.FileQueuePreferencesStore
import com.soundq.android.data.QueueSettingsRepository
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Ordinary startup/login; actual controller/service consumes the persisted installation choice. */
class QueueSettingsJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun savedKeepQueuedChoiceChangesFutureReplacementWithoutChangingCurrentQueue() {
        val app=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
        val graph=app.graph
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("settings-fixture@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        compose.waitUntil(10000){graph.library.state.value.rows.size>=3&&!graph.queueSettings.state.value.loading}
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        try {
            val rows=graph.library.state.value.rows
            compose.runOnIdle {model.play(0,rows)}
            compose.waitUntil(15000){model.playback.value.isPlaying}
            compose.runOnIdle {model.enqueue(rows[2],true)}
            compose.waitUntil(10000){!model.playback.value.isPlaying&&model.playback.value.queue.any {it.manual}}
            compose.runOnIdle {model.controller.seek(0);model.controller.toggle()}
            compose.waitUntil(10000){model.playback.value.isPlaying&&model.playback.value.queue.any {it.manual}}
            val before=model.playback.value
            assertTrue(before.isPlaying)
            compose.onNodeWithContentDescription("Settings").performClick()
            if(graph.queueSettings.state.value.keepQueued)compose.onNode(hasText("Keep queued songs") and isToggleable()).performClick()
            compose.waitUntil(10000){!graph.queueSettings.state.value.keepQueued}
            assertEquals(before.queue,model.playback.value.queue)
            assertEquals(before.selectedOccurrence,model.playback.value.selectedOccurrence)
            assertEquals(before.isPlaying,model.playback.value.isPlaying)
            val reconstructed=QueueSettingsRepository(FileQueuePreferencesStore(graph.directory.resolve("queue-settings.v1.json")))
            reconstructed.load();assertFalse(reconstructed.state.value.keepQueued)
            InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
            compose.runOnIdle {model.play(1,rows)}
            compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.queue.none {it.manual}}
            assertEquals(rows.map {it.id.value},model.playback.value.queue.map {it.trackId})
            compose.runOnIdle {model.enqueue(rows[2],true)}
            compose.waitUntil(10000){!model.playback.value.isPlaying&&model.playback.value.queue.any {it.manual}}
            val manual=model.playback.value.queue.single {it.manual}.occurrenceId
            compose.runOnIdle {model.controller.seek(0);model.controller.toggle()}
            compose.waitUntil(10000){model.playback.value.isPlaying&&model.playback.value.queue.any {it.occurrenceId==manual}}
            val beforeKeep=model.playback.value
            assertTrue(beforeKeep.isPlaying)
            compose.onNodeWithContentDescription("Settings").performClick()
            compose.onNode(hasText("Keep queued songs") and isToggleable()).performClick()
            compose.waitUntil(10000){graph.queueSettings.state.value.keepQueued}
            assertEquals(beforeKeep.queue,model.playback.value.queue)
            assertEquals(beforeKeep.selectedOccurrence,model.playback.value.selectedOccurrence)
            assertTrue(model.playback.value.isPlaying)
            InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
            compose.runOnIdle {model.play(0,rows)}
            compose.waitUntil(15000){model.playback.value.isPlaying&&model.playback.value.queue.any {it.occurrenceId==manual}}
            assertSame(graph,app.graph)
        } finally {compose.runOnIdle {model.controller.pause()}}
    }
}
