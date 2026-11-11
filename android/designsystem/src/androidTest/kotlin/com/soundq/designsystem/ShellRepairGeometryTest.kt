package com.soundq.designsystem

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Mounted geometry checks; run by the parent device owner, never a source-text oracle. */
class ShellRepairGeometryTest {
    @get:Rule val compose=createComposeRule()

    private fun navigation(width:Int) {
        var destination=""
        compose.setContent {SoundQTheme {
            Box(Modifier.requiredWidth(width.dp)) {SoundQBottomNavigation("Library",{destination=it})}
        }}
        val labels=listOf("Home","Discover","Library","Playlists")
        val bounds=labels.map {compose.onNodeWithText(it).fetchSemanticsNode().boundsInRoot}
        bounds.zipWithNext().forEach {(a,b)->
            assertEquals(a.width,b.width,1f)
            assertEquals(a.right,b.left,1f)
            assertEquals(a.top,b.top,1f)
            assertTrue(a.height>=48f)
        }
        compose.onNodeWithText("Library").assertIsSelected()
        compose.onNodeWithText("Home").assertIsNotSelected().performClick()
        compose.runOnIdle {assertEquals("Home",destination)}
    }
    @Test fun fourEqualTouchingDestinationsAt360()=navigation(360)
    @Test fun fourEqualTouchingDestinationsAt412()=navigation(412)

    @Test fun compactTitleIsClampedButIdentityDisclosesAndActionsStayInOneRow() {
        var expanded=0;var plays=0;var queues=0
        val title="A deliberately long title that cannot all fit in the compact identity cell"
        compose.setContent {SoundQTheme {
            Box(Modifier.requiredWidth(360.dp)) {SoundQCompactPlayer(title,"Artist",false,true,false,{expanded++},{plays++},{queues++})}
        }}
        val play=compose.onNodeWithContentDescription("Play")
        val queue=compose.onNodeWithContentDescription("Open listening queue")
        val a=play.fetchSemanticsNode().boundsInRoot
        val b=queue.fetchSemanticsNode().boundsInRoot
        assertEquals(a.top,b.top,1f);assertEquals(a.bottom,b.bottom,1f);assertEquals(a.right,b.left,1f)
        compose.onNodeWithContentDescription("$title, Artist").performClick()
        play.performClick();queue.performClick()
        compose.runOnIdle {assertEquals(1,expanded);assertEquals(1,plays);assertEquals(1,queues)}
    }

    @Test fun scaledCompactIdentityStaysFixedAndDisclosesFullSpokenText() {
        compose.setContent {
            val density=LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density,2f)) {SoundQTheme {
                Box(Modifier.requiredWidth(360.dp)) {SoundQCompactPlayer("Long identity stays one line at enlarged text","Artist",false,true,false,{},{},{})}
            }}
        }
        val identity=compose.onNodeWithContentDescription("Long identity stays one line at enlarged text, Artist").fetchSemanticsNode().boundsInRoot
        val play=compose.onNodeWithContentDescription("Play").fetchSemanticsNode().boundsInRoot
        assertTrue(identity.right<=play.left+1f)
        compose.onNodeWithContentDescription("Long identity stays one line at enlarged text, Artist").assertHeightIsEqualTo(72.dp)
        compose.onNodeWithText("Long identity stays one line at enlarged text",useUnmergedTree=true).assertIsDisplayed()
    }

    @Test fun mediaCellsTouchAndKeepArtworkMetadataAndCurrentDisclosure() {
        compose.setContent {SoundQTheme {Column(Modifier.requiredWidth(360.dp)) {
            SoundQMediaRow("First","Artist",true,{},{},Modifier.testTag("first row"),artwork={Text("Artwork")},supporting="Liked",metadata={Text("3:42 · 128 BPM")})
            SoundQMediaRow("Second","Artist",false,{},{},Modifier.testTag("second row"))
        }}}
        val first=compose.onNodeWithTag("first row").fetchSemanticsNode().boundsInRoot
        val second=compose.onNodeWithTag("second row").fetchSemanticsNode().boundsInRoot
        assertEquals(first.bottom,second.top,1f)
        assertEquals(first.left,second.left,1f);assertEquals(first.right,second.right,1f)
        compose.onNodeWithText("Artwork",useUnmergedTree=true).assertIsDisplayed()
        compose.onNodeWithText("3:42 · 128 BPM",useUnmergedTree=true).assertIsDisplayed()
        compose.onNodeWithText("Current",useUnmergedTree=true).assertDoesNotExist()
        compose.onNodeWithTag("first row").assertIsSelected()
        compose.onNodeWithContentDescription("More for First").assertHasClickAction()
    }

    @Test fun workspaceGivesContentBoundedRemainingHeightAndCloseWorks() {
        var closed=0
        compose.setContent {SoundQTheme {SoundQWorkspaceSheet("Queue",{closed++},actions={
            SoundQIconButton(SoundQIcon.More,"Queue options",{})
        }) {
            Box(Modifier.fillMaxWidth().height(48.dp).testTag("view switch"))
            Box(Modifier.weight(1f).fillMaxWidth().testTag("viewport"))
            Box(Modifier.fillMaxWidth().height(72.dp).testTag("transport"))
        }}}
        val switch=compose.onNodeWithTag("view switch").fetchSemanticsNode().boundsInRoot
        val viewport=compose.onNodeWithTag("viewport").fetchSemanticsNode().boundsInRoot
        val transport=compose.onNodeWithTag("transport").fetchSemanticsNode().boundsInRoot
        assertTrue(viewport.height>0f)
        assertEquals(switch.bottom,viewport.top,1f);assertEquals(viewport.bottom,transport.top,1f)
        assertEquals(switch.left,viewport.left,1f);assertEquals(viewport.right,transport.right,1f)
        compose.onNodeWithContentDescription("Close Queue").performClick()
        compose.runOnIdle {assertEquals(1,closed)}
    }
}
