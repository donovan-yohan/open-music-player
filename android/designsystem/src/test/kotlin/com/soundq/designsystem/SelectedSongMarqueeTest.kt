package com.soundq.designsystem

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.MotionDurationScale
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.WindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import kotlin.math.ceil
import kotlin.math.roundToInt
import kotlinx.coroutines.launch
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Real foundation marquee drawing under controlled Compose time. No synthesized offset oracle.
 * Host native raster/semantics tests; not phone/TalkBack or physical pacing qualification. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[34],qualifiers="w720dp-h1000dp")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class SelectedSongMarqueeTest {
    private class Scale:MotionDurationScale {
        var factor by mutableStateOf(1f)
        override val scaleFactor:Float get()=factor
    }
    private val scale=Scale()
    @get:Rule val compose=createComposeRule(effectContext=scale)
    private val title="Beginning — a long song with the very last title characters"
    private val artist="First artist, second artist, third artist, final credited artist"
    private val selected=mutableStateOf(true)
    private val reduced=mutableStateOf(false)
    private val focused=mutableStateOf(true)
    private val identity=mutableStateOf<Any>("source-A")
    private val font=mutableStateOf(1f)
    private val width=mutableStateOf(320)
    private val rowTitle=mutableStateOf(title)
    private val rowArtist=mutableStateOf(artist)
    private var density=1f
    private var activated=0
    private var more=0

    @Composable private fun Host(content:@Composable ()->Unit) {
        val actual=LocalDensity.current
        val window=LocalWindowInfo.current
        val focus=remember(window) {object:WindowInfo by window {
            override val isWindowFocused:Boolean get()=focused.value
        }}
        density=actual.density
        CompositionLocalProvider(LocalDensity provides Density(actual.density,font.value),
            LocalWindowInfo provides focus,LocalMediaMarqueeIdentity provides identity.value) {
            SoundQTheme(reducedMotion=reduced.value) {Box(Modifier.requiredWidth(width.value.dp)) {content()}}
        }
    }
    private fun row(shortTitle:Boolean=false,shortArtist:Boolean=false) {
        if(shortTitle)rowTitle.value="Song"
        if(shortArtist)rowArtist.value="Artist"
        compose.mainClock.autoAdvance=false
        compose.setContent {Host {
            SoundQMediaRow(rowTitle.value,rowArtist.value,selected.value,{activated++},{more++},
                Modifier.testTag("row"),supporting="3:25",metadata={
                    // Match the production compact metadata slot: duration occupies the first
                    // 34dp line alongside artist, analysis belongs on the second line.
                    if(LocalMediaRowCompactMetadata.current)Column {
                        Spacer(Modifier.height(34.dp))
                        Text("120 BPM",Modifier.testTag("facts"))
                    } else Text("120 BPM",Modifier.testTag("facts"))
                })
        }}
        settle()
    }
    private fun settle() {
        // Android measure/placement is outside the manual Compose clock. Interleave the same
        // 64ms with native idle so onGloballyPositioned's visibility write can recompose and
        // attach the native marquee before a leading-edge/static reference is captured.
        repeat(4) {
            compose.mainClock.advanceTimeByFrame()
            compose.waitForIdle()
        }
        // Positively admit the applied content/font and native measurement mode; neither a
        // stale ellipsized row nor old text is a valid motion/static pixel reference.
        listOf("media-title" to rowTitle.value,"media-artist" to rowArtist.value).forEach {(tag,text)->
            compose.onAllNodesWithTag(tag,useUnmergedTree=true).fetchSemanticsNodes()
                // Lazy prefetch can retain semantics with a fully clipped, zero-sized rect.
                // Those are deliberately offscreen, not a reference frame for pixel assertions.
                .filter {it.boundsInRoot.width>0f&&it.boundsInRoot.height>0f}.forEach {node->
                val layouts=mutableListOf<TextLayoutResult>()
                node.config[androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult].action!!(layouts)
                val layout=layouts.single()
                assertEquals("$tag applied text",text,layout.layoutInput.text.text)
                assertEquals("$tag applied font scale",font.value,layout.layoutInput.density.fontScale,0f)
                assertTrue("$tag has native allocation",node.boundsInRoot.width>0f&&node.boundsInRoot.height>0f)
                val current=generateSequence(node) {it.parent}.first {it.config.contains(SemanticsProperties.Selected)}
                    .config[SemanticsProperties.Selected]
                val marquee=current&&!reduced.value&&focused.value&&scale.factor>0f
                assertEquals("$tag native marquee measure is applied",marquee,
                    layout.layoutInput.constraints.maxWidth==androidx.compose.ui.unit.Constraints.Infinity)
            }
        }
    }
    private fun advance(ms:Long) {compose.mainClock.advanceTimeBy(ms);compose.waitForIdle()}
    private fun pixels(tag:String):List<Int> {
        val bitmap=compose.onNodeWithTag(tag,useUnmergedTree=true).captureToImage().asAndroidBitmap()
        val values=IntArray(bitmap.width*bitmap.height)
        bitmap.getPixels(values,0,bitmap.width,0,0,bitmap.width,bitmap.height)
        return values.toList()
    }
    private fun assertMoving(tag:String) {
        val start=pixels(tag)
        advance(3000)
        assertNotEquals("$tag must move after its dwell",start,pixels(tag))
    }

    @Test fun titleOnlyOverflowMovesAfterDwellWhileArtistAndFactsStayStill() {
        row(shortArtist=true)
        val first=pixels("media-title");val artistStart=pixels("media-artist");val facts=pixels("facts")
        advance(1500)
        assertEquals(first,pixels("media-title"))
        advance(1500)
        assertNotEquals(first,pixels("media-title"))
        assertEquals(artistStart,pixels("media-artist"));assertEquals(facts,pixels("facts"))
        compose.onNodeWithTag("row").assertHeightIsEqualTo(72.dp).performClick()
        compose.onNodeWithContentDescription("More for $title").assertWidthIsAtLeast(48.dp).performClick()
        compose.runOnIdle {assertEquals(1,activated);assertEquals(1,more)}
    }
    @Test fun artistOnlyOverflowMovesWhileTitleStaysStill() {
        row(shortTitle=true)
        val titleStart=pixels("media-title")
        assertMoving("media-artist")
        assertEquals(titleStart,pixels("media-title"))
    }
    @Test fun fittingAndUnselectedLongFieldsStayStatic() {
        selected.value=false
        row()
        val a=pixels("media-title");val b=pixels("media-artist")
        advance(30000)
        assertEquals(a,pixels("media-title"));assertEquals(b,pixels("media-artist"))
        compose.runOnIdle {selected.value=true;rowTitle.value="Song";rowArtist.value="Artist"}
        settle()
        val shortA=pixels("media-title");val shortB=pixels("media-artist")
        advance(30000)
        assertEquals(shortA,pixels("media-title"));assertEquals(shortB,pixels("media-artist"))
    }
    @Test fun selectedRowMovesWithoutAnimatingItsUnselectedNeighbor() {
        compose.mainClock.autoAdvance=false
        compose.setContent {Host {Column {
            SoundQMediaRow(title,artist,true,{},{})
            SoundQMediaRow(title,artist,false,{},{})
        }}}
        settle()
        val selectedTitle=pixels("media-title",0);val selectedArtist=pixels("media-artist",0)
        val neighborTitle=pixels("media-title",1);val neighborArtist=pixels("media-artist",1)
        advance(3000)
        assertNotEquals(selectedTitle,pixels("media-title",0));assertNotEquals(selectedArtist,pixels("media-artist",0))
        assertEquals(neighborTitle,pixels("media-title",1));assertEquals(neighborArtist,pixels("media-artist",1))
    }
    @Test fun sourceAndContentChangesRestartAtBeginningAndLoseSelectionImmediately() {
        row()
        val start=pixels("media-title")
        assertMoving("media-title")
        compose.runOnIdle {identity.value="source-B"} // same title, different source/occurrence
        settle()
        assertEquals(start,pixels("media-title"))
        advance(1500)
        assertEquals(start,pixels("media-title"))
        advance(1500)
        assertNotEquals(start,pixels("media-title"))
        compose.runOnIdle {rowTitle.value=title.replace("Beginning","Following")}
        settle()
        compose.runOnIdle {rowTitle.value=title}
        settle()
        assertEquals(start,pixels("media-title"))
        compose.runOnIdle {selected.value=false}
        settle()
        val static=pixels("media-title")
        advance(30000)
        assertEquals(static,pixels("media-title"))
    }
    @Test fun reducedMotionAndPlatformZeroCancelAnUnderwayLoopAndResetBeforeReentry() {
        reduced.value=true
        row()
        val static=pixels("media-title")
        advance(5000);assertEquals(static,pixels("media-title"))
        compose.runOnIdle {reduced.value=false};settle()
        val start=pixels("media-title")
        assertMoving("media-title")
        compose.runOnIdle {reduced.value=true};settle()
        assertEquals(static,pixels("media-title"))
        advance(5000);assertEquals(static,pixels("media-title"))
        compose.runOnIdle {reduced.value=false;scale.factor=0f};settle()
        assertEquals(static,pixels("media-title"))
        advance(5000);assertEquals(static,pixels("media-title"))
        compose.runOnIdle {scale.factor=1f};settle()
        assertEquals(start,pixels("media-title"))
        assertMoving("media-title")
        compose.runOnIdle {scale.factor=0f};settle()
        assertEquals(static,pixels("media-title"))
    }
    @Test fun backgroundWindowStopsMotionAndForegroundRestartsItsDwell() {
        row()
        val start=pixels("media-title")
        assertMoving("media-title")
        compose.runOnIdle {focused.value=false};settle()
        val stopped=pixels("media-title")
        advance(5000);assertEquals(stopped,pixels("media-title"))
        compose.runOnIdle {focused.value=true};settle()
        assertEquals(start,pixels("media-title"))
        advance(1500);assertEquals(start,pixels("media-title"))
    }
    @Test fun enlargedArtistBranchAndChangedWidthKeepGeometryAndReassessOverflow() {
        font.value=1.3f
        row()
        compose.onNodeWithTag("row").assertHeightIsEqualTo(106.dp)
        val factsBounds=compose.onNodeWithTag("facts",useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
        val artistBounds=compose.onNodeWithTag("media-artist",useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
        assertTrue("analysis fixture occupies its own line",factsBounds.top>=artistBounds.bottom)
        val facts=pixels("facts")
        assertMoving("media-artist")
        assertEquals(factsBounds,compose.onNodeWithTag("facts",useUnmergedTree=true).fetchSemanticsNode().boundsInRoot)
        assertEquals(facts,pixels("facts"))
        compose.runOnIdle {font.value=1f;rowTitle.value="A moderately long song";width.value=640};settle()
        val fits=pixels("media-title")
        advance(5000);assertEquals(fits,pixels("media-title"))
        compose.runOnIdle {width.value=240};settle()
        assertMoving("media-title")
        compose.onNodeWithTag("row").assertHeightIsEqualTo(72.dp)
    }
    @Test fun twoNativeArtistCyclesHaveRepeatDwellAndOneCompleteSemanticIdentity() {
        row()
        val start=pixels("media-artist")
        val initialTime=compose.mainClock.currentTime
        val results=mutableListOf<TextLayoutResult>()
        compose.onNodeWithTag("media-artist",useUnmergedTree=true).performSemanticsAction(
            androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) {it(results)}
        val field=compose.onNodeWithTag("media-artist",useUnmergedTree=true).fetchSemanticsNode().boundsInRoot.width
        val content=results.single().size.width
        val cycle=2000L+ceil((content+(field/3f).roundToInt())/(24f*density)*1000).toLong()
        repeat(2) {pass->
            val end=initialTime+(pass+1)*cycle+300
            advance(end-compose.mainClock.currentTime)
            assertEquals("native repeat dwell $pass",start,pixels("media-artist"))
            advance(700)
            assertEquals(start,pixels("media-artist"))
            advance(2000)
            assertNotEquals(start,pixels("media-artist"))
        }
        val config=compose.onNodeWithTag("row").fetchSemanticsNode().config
        assertEquals(1,config[SemanticsProperties.Text].count {it.text==title})
        assertEquals(1,config[SemanticsProperties.Text].count {it.text==artist})
        assertTrue(config[SemanticsProperties.ContentDescription].contains("$title, $artist, 3:25"))
        assertEquals("Current track",config[SemanticsProperties.StateDescription])
        assertTrue(config[SemanticsProperties.Selected])
        assertFalse(config.contains(SemanticsProperties.LiveRegion))
    }
    @Test fun pausedCompactPlayerAnimatesBothFieldsButClockTicksDoNotRestartThem() {
        val elapsed=mutableStateOf(0L)
        val song=CompactSongIdentity(1,"session","queue",1,"occurrence",CompactSongSource.Server(7))
        compose.mainClock.autoAdvance=false
        compose.setContent {Host {
            SoundQCompactPlayer(title,artist,false,true,false,{},{},{},
                timing=CompactSongTiming(song,elapsed.value,100000,CompactPlaybackState.Paused))
        }}
        settle()
        val firstTitle=pixels("compact-title");val firstArtist=pixels("compact-artist")
        repeat(8) {
            advance(500)
            compose.runOnIdle {elapsed.value+=500}
        }
        settle()
        assertNotEquals(firstTitle,pixels("compact-title"));assertNotEquals(firstArtist,pixels("compact-artist"))
        val node=compose.onNodeWithContentDescription("$title, $artist").fetchSemanticsNode()
        assertEquals("Paused",node.config[SemanticsProperties.StateDescription])
        assertEquals(1,node.config[SemanticsProperties.Text].count {it.text==title})
        assertEquals(1,node.config[SemanticsProperties.Text].count {it.text==artist})
        compose.onNodeWithContentDescription("Open listening queue").assertWidthIsAtLeast(48.dp)
    }
    @Test fun compactPreparationWithoutSelectionDoesNotMove() {
        compose.mainClock.autoAdvance=false
        compose.setContent {Host {SoundQCompactPlayer(title,artist,false,false,true,{},{},{})}}
        settle()
        compose.onNodeWithText("Preparing audio",useUnmergedTree=true).assertDoesNotExist()
        compose.onNodeWithText(title,useUnmergedTree=true).assertExists()
        val a=pixels("compact-title");val b=pixels("compact-artist")
        advance(30000)
        assertEquals(a,pixels("compact-title"));assertEquals(b,pixels("compact-artist"))
    }
    @Test fun lazyRowReturningAfterOffscreenPlacementStartsAgainAtItsLeadingEdge() {
        var scroll:(()->Unit)?=null
        var restore:(()->Unit)?=null
        compose.mainClock.autoAdvance=false
        compose.setContent {Host {
            val state=rememberLazyListState()
            val scope=rememberCoroutineScope()
            scroll={scope.launchScroll(state,20)}
            restore={scope.launchScroll(state,0)}
            LazyColumn(Modifier.height(150.dp),state=state) {
                items(30,key={it}) {index->SoundQMediaRow(title,artist,index==0,{},{},Modifier.testTag("lazy-$index"))}
            }
        }}
        settle()
        val start=pixels("media-title",0)
        advance(3000)
        assertNotEquals(start,pixels("media-title",0))
        compose.runOnIdle {scroll!!()};settle()
        advance(5000)
        compose.runOnIdle {restore!!()};settle()
        assertEquals(start,pixels("media-title",0))
        advance(1500);assertEquals(start,pixels("media-title",0))
    }
    private fun kotlinx.coroutines.CoroutineScope.launchScroll(state:androidx.compose.foundation.lazy.LazyListState,index:Int) {
        launch {state.scrollToItem(index)}
    }
    private fun pixels(tag:String,index:Int):List<Int> {
        val bitmap=compose.onAllNodesWithTag(tag,useUnmergedTree=true)[index].captureToImage().asAndroidBitmap()
        val values=IntArray(bitmap.width*bitmap.height)
        bitmap.getPixels(values,0,bitmap.width,0,0,bitmap.width,bitmap.height)
        return values.toList()
    }
}
