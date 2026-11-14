package com.soundq.designsystem

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

/** Real composition/geometry. The integration owner runs this on the shared device lane. */
class PlayerCompositionTest {
    @get:Rule val compose=createComposeRule()
    private var density=1f
    private fun bounds(tag:String)=compose.onNodeWithTag(tag,useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
    private fun near(expected:Float,actual:Float)=assertEquals(expected,actual,1.1f)
    private fun dp(value:Int)=value*density

    private fun rows(width:Int) {
        val title="Long title 音楽 ".repeat(12)
        compose.setContent {SoundQTheme {
            density=LocalDensity.current.density
            Column(Modifier.requiredWidth(width.dp)) {
                SoundQMediaRow(title,"Artist ".repeat(16),true,{},{},Modifier.testTag("first"),
                    artwork={Box(Modifier.fillMaxSize().testTag("decoded art"))},supporting="Like not confirmed. Reload",
                    metadata={Text("3:42 · 128 BPM · A minor",maxLines=1,softWrap=false)})
                SoundQMediaRow("Missing","Artist",false,{},{},Modifier.testTag("second"))
            }
        }}
        val first=bounds("first");val second=bounds("second");val art=bounds("decoded art")
        near(dp(72),first.height);near(dp(72),second.height);near(first.bottom,second.top)
        near(first.left,art.left);near(first.top,art.top);near(dp(72),art.width);near(art.width,art.height)
        val titleNode=compose.onNodeWithText(title,useUnmergedTree=true)
        near(first.left+dp(80),titleNode.fetchSemanticsNode().boundsInRoot.left)
        val layouts=mutableListOf<TextLayoutResult>()
        titleNode.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult){it(layouts)}
        assertEquals(1,layouts.single().lineCount);assertTrue(layouts.single().isLineEllipsized(0))
        compose.onNodeWithText("Current",useUnmergedTree=true).assertDoesNotExist()
        compose.onNodeWithTag("first").assertIsSelected().assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription,"Current track"))
        compose.onNodeWithContentDescription("More for $title").assertWidthIsAtLeast(48.dp).assertHeightIsEqualTo(72.dp)
    }
    @Test fun rowsAt393HaveFlush72SquareArtworkAndOneLineIdentity()=rows(393)
    @Test fun rowsAt280KeepTheSameGeometryAndFullSpokenIdentity()=rows(280)

    @Test fun artworkMissingAndDecodedPixelsKeepTheSameSquareCropSlot() {
        val decoded=mutableStateOf(false)
        compose.setContent {SoundQTheme {SoundQArtworkSlot(Modifier.testTag("art slot"),size=72.dp,
            image=if(decoded.value)androidx.compose.ui.graphics.ImageBitmap(144,72) else null)}}
        val before=bounds("art slot")
        compose.onNodeWithTag("art slot",useUnmergedTree=true).assertWidthIsEqualTo(72.dp).assertHeightIsEqualTo(72.dp)
        compose.runOnIdle {decoded.value=true}
        val after=bounds("art slot")
        assertEquals(before,after)
        compose.runOnIdle {decoded.value=false}
        assertEquals(before,bounds("art slot"))
    }

    @Test fun compactArtworkIdentityAndIndependentActionCellsRemain72AtEnlargedType() {
        val playing=mutableStateOf(false);var expands=0;var primary=0;var queue=0
        val title="Long compact identity ".repeat(10)
        compose.setContent {
            val actual=LocalDensity.current
            density=actual.density
            CompositionLocalProvider(LocalDensity provides Density(actual.density,2f)) {SoundQTheme {
                Box(Modifier.requiredWidth(280.dp)) {SoundQCompactPlayer(title,"Complete artist",playing.value,true,false,
                    {expands++},{primary++},{queue++},artwork={Box(Modifier.fillMaxSize().testTag("compact decoded art"))})}
            }}
        }
        val art=bounds("compact decoded art")
        val play=compose.onNodeWithContentDescription("Play").fetchSemanticsNode().boundsInRoot
        val queueBounds=compose.onNodeWithContentDescription("Open listening queue").fetchSemanticsNode().boundsInRoot
        near(dp(72),art.height);near(dp(72),art.width);near(dp(72),play.height);near(dp(48),play.width)
        near(play.right,queueBounds.left);near(play.top,queueBounds.top)
        val identity=compose.onNodeWithContentDescription("$title, Complete artist")
        near(art.left,identity.fetchSemanticsNode().boundsInRoot.left)
        assertTrue(identity.fetchSemanticsNode().boundsInRoot.right<=play.left+1f)
        identity.performClick();compose.onNodeWithContentDescription("Play").performClick()
        compose.onNodeWithContentDescription("Open listening queue").performClick()
        compose.runOnIdle {playing.value=true;assertEquals(1,expands);assertEquals(1,primary);assertEquals(1,queue)}
        val pause=compose.onNodeWithContentDescription("Pause").fetchSemanticsNode().boundsInRoot
        near(play.left,pause.left);near(play.height,pause.height)
    }

    @Test fun transportAt280HasFiveCenteredTargetsAndModesUseExistingCallbacks() {
        val calls=mutableListOf<String>()
        compose.setContent {SoundQTheme {
            density=LocalDensity.current.density
            Box(Modifier.requiredWidth(280.dp).testTag("transport host")) {
                SoundQTransport(false,true,false,{calls.add("primary")},{calls.add("previous")},{calls.add("next")},true,true,
                    shuffle=true,repeat=1,onShuffle={calls.add("shuffle")},onRepeat={calls.add("repeat")})
            }
        }}
        val labels=listOf("Shuffle on","Previous track","Play","Next track","Repeat one")
        val controls=labels.map {compose.onNodeWithContentDescription(it).fetchSemanticsNode().boundsInRoot}
        controls.zipWithNext().forEach {(a,b)->assertTrue(a.right<=b.left+1f);near(a.center.y,b.center.y)}
        near(bounds("transport host").center.x,(controls.first().left+controls.last().right)/2f)
        controls.forEach {assertTrue(it.width>=dp(48)-1f);assertTrue(it.height>=dp(48)-1f)}
        compose.onNodeWithContentDescription("Repeat one").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription,"Repeat one"))
        labels.forEach {compose.onNodeWithContentDescription(it).performClick()}
        compose.runOnIdle {assertEquals(listOf("shuffle","previous","primary","next","repeat"),calls)}
    }

    @Test fun unavailableTransportRefusesEveryActionButPreparationCanStillBePaused() {
        var calls=0;val available=mutableStateOf(false)
        compose.setContent {SoundQTheme {SoundQTransport(false,available.value,true,{calls++},{calls++},{calls++},false,false,
            onShuffle={calls++},onRepeat={calls++})}}
        listOf("Shuffle off","Previous track","Pause","Next track","Repeat off").forEach {
            compose.onNodeWithContentDescription(it).assertIsNotEnabled().performTouchInput {click()}
        }
        compose.runOnIdle {assertEquals(0,calls);available.value=true}
        compose.onNodeWithContentDescription("Previous track").assertIsNotEnabled()
        compose.onNodeWithContentDescription("Next track").assertIsNotEnabled()
        compose.onNodeWithContentDescription("Pause").assertIsEnabled().performClick()
        compose.runOnIdle {assertEquals(1,calls)}
    }

    @Test fun utilityPermissionsReflowOneTouchingRowWithoutInventingControls() {
        var queues=0;var infos=0
        compose.setContent {SoundQTheme {Box(Modifier.requiredWidth(280.dp)) {SoundQPlayerUtilities({queues++},onInfo={infos++})}}}
        val queue=compose.onNodeWithContentDescription("Open listening queue")
        val info=compose.onNodeWithContentDescription("Song details")
        val a=queue.fetchSemanticsNode().boundsInRoot;val b=info.fetchSemanticsNode().boundsInRoot
        near(a.right,b.left);near(a.width,b.width);near(a.top,b.top)
        queue.assertHeightIsAtLeast(56.dp).performClick();info.performClick()
        compose.onNodeWithContentDescription("Connected devices").assertDoesNotExist()
        compose.runOnIdle {assertEquals(1,queues);assertEquals(1,infos)}
    }

    private fun fullPlayer(width:Int,height:Int) {
        var dismisses=0;var primary=0
        compose.setContent {SoundQTheme {
            val actual=LocalDensity.current
            BoxWithConstraints(Modifier.fillMaxSize()) {
                // Fit a deterministic dp viewport inside the device without clipping a landscape
                // fixture off the portrait test activity. These are logical dp layout assertions.
                val scale=minOf(maxWidth/width.dp,maxHeight/height.dp,1f)
                density=actual.density*scale
                CompositionLocalProvider(LocalDensity provides Density(density,1f)) {
                    Box(Modifier.requiredSize(width.dp,height.dp)) {SoundQFullPlayerContent(
                        "Track","Artist",false,true,false,12000,180000,"occurrence-a",{dismisses++},{primary++},{},{},
                        onDevices={},onInfo={},modifier=Modifier.fillMaxSize())}
                }
            }
        }}
        val art=bounds("player-artwork");near(art.width,art.height)
        assertTrue(art.width<=dp(320)+1f)
        if(width<560)near(bounds("player-body").center.x,art.center.x)
        else assertTrue(art.width<=dp(280)+1f)
        val previous=compose.onNodeWithContentDescription("Previous track").fetchSemanticsNode().boundsInRoot
        val next=compose.onNodeWithContentDescription("Next track").fetchSemanticsNode().boundsInRoot
        near(previous.center.y,next.center.y)
        val utilities=listOf("Open listening queue","Connected devices","Song details").map {
            compose.onNodeWithContentDescription(it).assertIsDisplayed().fetchSemanticsNode().boundsInRoot
        }
        utilities.zipWithNext().forEach {(a,b)->near(a.right,b.left);near(a.top,b.top);near(a.width,b.width)}
        compose.onNodeWithContentDescription("Play").performClick()
        compose.onNodeWithContentDescription("Close Now playing").performClick()
        compose.runOnIdle {assertEquals(1,primary);assertEquals(1,dismisses)}
    }
    @Test fun portraitPlayerUsesCenteredSquareArtwork()=fullPlayer(393,852)
    @Test fun shortPortraitReducesArtworkBeforeControls()=fullPlayer(393,640)
    @Test fun landscapePlayerKeepsInlineTransportAndUtilities()=fullPlayer(852,393)

    @Test fun fullWindowDialogLeavesFailureFeedbackToProductAndCloseDoesNotInvokeTransport() {
        var closes=0;var primary=0
        var dialogView:android.view.View?=null
        compose.setContent {SoundQTheme {SoundQFullPlayer("Track","Artist",false,true,false,0,1000,"a",
            {closes++},{primary++},{},{},error="Source refused",onInfo={},artwork={dialogView=LocalView.current})}}
        compose.onNodeWithTag("player-window",useUnmergedTree=true).assertExists()
        compose.onNode(isDialog()).assertExists()
        val window=bounds("player-window")
        compose.runOnIdle {
            near(dialogView!!.rootView.width.toFloat(),window.width)
            near(dialogView!!.rootView.height.toFloat(),window.height)
        }
        compose.onNodeWithText("Source refused").assertDoesNotExist()
        compose.onNodeWithContentDescription("Close Now playing").performClick()
        compose.runOnIdle {assertEquals(1,closes);assertEquals(0,primary)}
    }

    @Test fun seekDraftSurvivesPositionUpdatesButResetsOnOccurrenceChange() {
        val position=mutableLongStateOf(10000L);val occurrence=mutableStateOf("a");val seeks=mutableListOf<Long>()
        compose.setContent {SoundQTheme {Column {SoundQSeek(position.longValue,100000L,occurrence.value,{seeks.add(it)})}}}
        val slider=compose.onNodeWithContentDescription("Playback position")
        slider.performTouchInput {down(center);moveTo(androidx.compose.ui.geometry.Offset(width*0.75f,center.y))}
        compose.runOnIdle {position.longValue=20000L}
        // Live observations cannot replace the held draft.
        val progress=slider.fetchSemanticsNode().config[SemanticsProperties.ProgressBarRangeInfo].current
        assertTrue(progress>0.6f)
        compose.runOnIdle {occurrence.value="b"}
        val replacement=slider.fetchSemanticsNode().config[SemanticsProperties.ProgressBarRangeInfo].current
        assertEquals(0.2f,replacement,0.01f)
        slider.performTouchInput {cancel()}
        compose.runOnIdle {assertTrue(seeks.isEmpty())}
    }

    @Test fun closingDialogReturnsFocusToTheExpandTriggerWithoutPausing() {
        val open=mutableStateOf(false);val focus=FocusRequester();var primary=0
        compose.setContent {SoundQTheme {
            Box(Modifier.size(72.dp).testTag("expand trigger").focusRequester(focus).focusable()
                .clickable {open.value=true}) {Text("Open player")}
            if(open.value)SoundQFullPlayer("Track","Artist",true,true,false,0,1000,"a",
                {open.value=false},{primary++},{},{},returnFocus=focus)
        }}
        compose.onNodeWithTag("expand trigger").performClick()
        compose.onNodeWithContentDescription("Pause").assertIsDisplayed()
        compose.onNodeWithContentDescription("Close Now playing").performClick()
        compose.onNodeWithTag("expand trigger").assertIsFocused()
        compose.runOnIdle {assertEquals(0,primary)}
    }
}
