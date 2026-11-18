package com.soundq.android

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.assertIsNotEnabled
import com.soundq.android.data.playlists.*
import com.soundq.android.product.playlists.PlaylistSourceSyncControls
import com.soundq.designsystem.SoundQTheme
import org.junit.Rule
import org.junit.Test
import org.junit.Assert.assertEquals

/** Mounted semantic action gate; parent owns execution on its admitted AVD. */
class PlaylistSourceSyncControlsTest {
    @get:Rule val compose=createComposeRule()
    @Test fun manualSyncUsesDistinctSemanticAction() {
        var sync=0;var read=0
        compose.setContent {SoundQTheme {PlaylistSourceSyncControls(PlaylistSourceSyncState(playlist=PlaylistId(41),observation=SourceSyncObservation(true,1,null,null)),{sync++},{read++},writeReady=true)}}
        compose.onNodeWithText("Sync source").performClick()
        compose.runOnIdle {assertEquals(1,sync);assertEquals(0,read)}
    }
    @Test fun uncertaintyOffersExactRequestRetryAndSeparateReadback() {
        var sync=0;var read=0
        compose.setContent {SoundQTheme {PlaylistSourceSyncControls(PlaylistSourceSyncState(playlist=PlaylistId(41),observation=SourceSyncObservation(true,1,null,null),uncertain=true),{sync++},{read++},writeReady=true)}}
        compose.onNodeWithText("Read sync status").performClick()
        compose.runOnIdle {assertEquals(1,read);assertEquals(0,sync)}
        compose.onNodeWithText("Retry sync request").performClick()
        compose.runOnIdle {assertEquals(1,sync);assertEquals(1,read)}
    }
    private fun terminal(status:String)=SourceSyncOperation("00000000-0000-0000-0000-000000000001",PlaylistId(41),status,true,1,0,0,false,0,0,null)
    @Test fun unreadyDetailDisablesWriteButKeepsStatusRead() {
        var sync=0;var read=0
        compose.setContent {SoundQTheme {PlaylistSourceSyncControls(PlaylistSourceSyncState(playlist=PlaylistId(41),observation=SourceSyncObservation(true,1,null,null)),{sync++},{read++},writeReady=false)}}
        compose.onNodeWithText("Sync source").assertIsNotEnabled()
        compose.onNodeWithText("Read sync status").performClick()
        compose.runOnIdle {assertEquals(0,sync);assertEquals(1,read)}
    }
    @Test fun supersededIneligibleSourceHasReadOnlyCurrentStatusRecovery() {
        var sync=0;var read=0
        compose.setContent {SoundQTheme {PlaylistSourceSyncControls(PlaylistSourceSyncState(playlist=PlaylistId(41),observation=SourceSyncObservation(false,1,"relink_required",terminal("superseded"))),{sync++},{read++})}}
        compose.onNodeWithText("Read sync status").performClick()
        compose.onNodeWithText("Sync source").assertDoesNotExist()
        compose.runOnIdle {assertEquals(0,sync);assertEquals(1,read)}
    }
    @Test fun terminalPublicationFailureKeepsExplicitReadRecovery() {
        var sync=0;var read=0
        compose.setContent {SoundQTheme {PlaylistSourceSyncControls(PlaylistSourceSyncState(playlist=PlaylistId(41),observation=SourceSyncObservation(true,1,null,terminal("complete")),readbackFailed=true),{sync++},{read++})}}
        compose.onNodeWithText("Read sync status").performClick()
        compose.runOnIdle {assertEquals(0,sync);assertEquals(1,read)}
    }
}
