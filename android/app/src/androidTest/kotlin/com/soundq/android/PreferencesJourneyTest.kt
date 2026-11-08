package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.*
import com.soundq.android.data.preferences.StoragePreferences
import com.soundq.android.product.ProductViewModel
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Compiled ordinary-scale route and owner journey. OS authentication itself is a separate device gate. */
class PreferencesJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun settingsPersistCacheClearConfirmsAndLocalGateHidesPrivatePlayerWithoutAutoplay() {
        val graph=(InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication).graph
        compose.waitUntil(10000){compose.onAllNodesWithContentDescription("Email").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Email").performTextInput("preferences@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        compose.waitUntil(10000){graph.library.state.value.rows.size>=3&&graph.storagePreferences.state.value.ready}
        val model=compose.runOnIdle {ViewModelProvider(compose.activity)[ProductViewModel::class.java]}
        compose.onNodeWithContentDescription("Account and settings").performClick()
        compose.onNodeWithText("Settings").performClick()
        compose.onNodeWithText("Temporary audio").performScrollTo().performClick()
        compose.waitUntil(10000){!graph.storagePreferences.state.value.temporaryAudioEnabled}
        val restored=StoragePreferences(graph.directory.resolve("storage-preferences.v1.json"));restored.load();assertFalse(restored.state.value.temporaryAudioEnabled)
        compose.onNodeWithText("Clear temporary audio").performScrollTo().performClick()
        compose.onNodeWithText("Cancel").performClick()
        compose.onNodeWithText("Clear temporary audio").performClick()
        compose.onNodeWithText("Clear").performClick()
        compose.waitUntil(10000){compose.onAllNodesWithText("Temporary audio cleared").fetchSemanticsNodes().isNotEmpty()}
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
        compose.runOnIdle {model.play(0,graph.library.state.value.rows)}
        compose.waitUntil(15000){model.playback.value.isPlaying}
        val selected=model.playback.value.selectedOccurrence
        compose.runOnIdle {graph.session.lockLocal()}
        compose.waitUntil(10000){!model.playback.value.isPlaying}
        compose.onNodeWithText("SoundQ is locked").assertIsDisplayed()
        compose.onNodeWithContentDescription("Account and settings").assertDoesNotExist()
        compose.onNodeWithText("Unlock with device").assertIsDisplayed()
        assertEquals(selected,model.playback.value.selectedOccurrence)
        // Explicitly inject only a successful OS callback at the existing native session boundary.
        compose.runOnIdle {assertTrue(graph.session.completeLocalUnlock(graph.session.localUnlockTicket()!!))}
        compose.waitUntil(10000){
            graph.session.state.value is AuthState.SignedIn&&model.playback.value.accountEpoch==graph.session.version()&&
                graph.library.state.value.rows.firstOrNull()?.let(graph.library::captureTrack)!=null
        }
        assertFalse(model.playback.value.isPlaying);assertEquals(selected,model.playback.value.selectedOccurrence)
        val priorScope=graph.session.capture()!!
        val priorRow=graph.library.captureTrack(graph.library.state.value.rows.first())!!
        // Equal terminal SignedIn state must not hide an entire epoch change.
        // No main-loop drain occurs between lock and successful OS callback.
        compose.runOnIdle {
            assertTrue(graph.session.lockLocal());assertFalse(graph.session.remoteCurrent(priorScope))
            assertTrue(graph.session.completeLocalUnlock(graph.session.localUnlockTicket()!!))
            assertFalse(graph.session.current(priorScope))
        }
        compose.waitUntil(10000){
            val scope=graph.session.capture()
            val row=graph.library.state.value.rows.firstOrNull()?.let(graph.library::captureTrack)
            scope!=null&&row!=null&&row.scope.epoch==scope.epoch&&model.playback.value.accountEpoch==scope.epoch
        }
        assertFalse(graph.library.owns(priorRow))
        assertFalse(model.playback.value.isPlaying);assertEquals(selected,model.playback.value.selectedOccurrence)
        compose.runOnIdle {model.logout()}
    }
}
