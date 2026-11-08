package com.soundq.designsystem

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class SharedMediaRowTest {
    @get:Rule val compose=createComposeRule()
    @Test fun rowsKeepOneGeometryAcrossDirectSwipeAndOccurrenceListAndRetainArtworkIdentity() {
        compose.setContent {SoundQTheme {
            Column(Modifier.width(360.dp)) {
                SoundQMediaRow("Home title","Home artist",false,{},{},Modifier.testTag("home-row"),artwork={Box(Modifier.fillMaxSize().background(Color.Magenta).testTag("home-art"))},supporting="Listened")
                val reveal=remember {RowRevealState(RowRevealOwner())}
                SoundQRevealMediaRow("Library title","Library artist",false,reveal,true,null,false,{},{},{},{},Modifier.testTag("library-row"),artwork={Box(Modifier.fillMaxSize().background(Color.Magenta).testTag("library-art"))})
                Box(Modifier.height(144.dp)) {
                    SoundQOccurrenceQueue(listOf(QueueRowVisual("a","Duplicate","Artist",false),QueueRowVisual("b","Duplicate","Artist",true)),{},{_,_->},{},bounded=true,
                        artwork={id->Box(Modifier.fillMaxSize().background(if(id=="a")Color.Magenta else Color.Cyan).testTag("queue-art-$id"))})
                }
            }
        }}
        compose.onNodeWithTag("home-row").assertHeightIsEqualTo(72.dp)
        compose.onNodeWithTag("library-row").assertHeightIsEqualTo(72.dp)
        listOf("home-art","library-art","queue-art-a","queue-art-b").forEach {tag->
            compose.onNodeWithTag(tag,useUnmergedTree=true).assertWidthIsEqualTo(72.dp).assertHeightIsEqualTo(72.dp)
        }
        val a=compose.onNodeWithTag("queue-art-a",useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
        val b=compose.onNodeWithTag("queue-art-b",useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
        assertEquals(a.bottom,b.top,.5f)
        val home=compose.onNodeWithTag("home-art",useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
        assertEquals("All song lists keep artwork on the same leading edge",home.left,a.left,.5f)
    }
    @Test fun disabledSongCannotActivateButItsContextRemainsAvailable() {
        var played=0;var more=0
        compose.setContent {SoundQTheme {SoundQMediaRow("Unavailable song","Artist",false,{played++},{more++},Modifier.testTag("disabled-song"),enabled=false)}}
        compose.onNodeWithTag("disabled-song").assertIsNotEnabled()
        compose.onNodeWithTag("disabled-song").performTouchInput {click(centerLeft+androidx.compose.ui.geometry.Offset(100f,0f))}
        compose.onNodeWithContentDescription("More for Unavailable song").performClick()
        compose.runOnIdle {assertEquals(0,played);assertEquals(1,more)}
    }
}
