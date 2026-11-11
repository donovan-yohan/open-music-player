package com.soundq.android

import android.view.Window
import android.view.WindowInsetsController
import android.view.WindowManager
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogWindowProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.soundq.designsystem.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import soundq.design.generated.SoundQAppearance

/** Exact shared seams only. Run/capture on the integration owner's exclusively owned device. */
@RunWith(AndroidJUnit4::class)
class SharedPresentationHotateTest {
    @get:Rule val compose=createComposeRule()

    private fun enlargedRow(scale:Float,project:Boolean) {
        val title="Long song identity ".repeat(6);val artist="Complete artist identity ".repeat(5)
        val full=if(project)"Download failed. Device storage unavailable; retry from Device copy." else "Failed"
        var activate=0;var more=0
        compose.setContent {
            val actual=LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(actual.density,scale)) {SoundQTheme {
                Column(Modifier.requiredWidth(393.dp)) {
                    SoundQMediaRow(title,artist,true,{activate++},{more++},Modifier.testTag("hotate-row"),
                        supporting=full,compactSupporting=if(project)"Failed" else full,
                        metadata={Text("—",style=SoundQ.typography.mono)})
                    SoundQMediaRow("Next song","Next artist",false,{},{},Modifier.testTag("hotate-next"))
                }
            }}
        }
        compose.onNodeWithText(full,useUnmergedTree=true).assertIsDisplayed()
        compose.onNodeWithText(artist,useUnmergedTree=true).assertIsDisplayed()
        compose.onNodeWithText("—",useUnmergedTree=true).assertIsDisplayed()
        val row=compose.onNodeWithTag("hotate-row")
        row.assertHeightIsEqualTo(106.dp)
        val spoken=row.fetchSemanticsNode().config[SemanticsProperties.Text].map {it.text}
        assertTrue(spoken.containsAll(listOf(title,artist,full)))
        val art=compose.onAllNodesWithTag("media-artwork",useUnmergedTree=true)[0]
        art.assertWidthIsEqualTo(106.dp).assertHeightIsEqualTo(106.dp)
        val a=row.fetchSemanticsNode().boundsInRoot
        val next=compose.onNodeWithTag("hotate-next").fetchSemanticsNode().boundsInRoot
        assertEquals(a.bottom,next.top,1f)
        val artistBounds=compose.onNodeWithText(artist,useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
        assertTrue(artistBounds.width>0f)
        compose.onNodeWithContentDescription("More for $title").assertWidthIsAtLeast(48.dp).assertHeightIsEqualTo(106.dp).performClick()
        row.performClick()
        compose.runOnIdle {assertEquals(1,activate);assertEquals(1,more)}
    }
    @Test fun supportingDefaultSurvivesAt130Percent()=enlargedRow(1.3f,false)
    @Test fun compactFactAt200PercentKeepsCompleteSpokenIdentity()=enlargedRow(2f,true)

    @Test fun unknownSeekRetainsElapsedAndCannotDispatchWhileKnownSeekStillWorks() {
        val duration=mutableLongStateOf(0);val seeks=mutableListOf<Long>()
        compose.setContent {SoundQTheme {Column {SoundQSeek(65000,duration.longValue,"same",{seeks.add(it)})}}}
        compose.onNodeWithText("1:05 / —").assertIsDisplayed()
        val slider=compose.onNodeWithContentDescription("Playback position")
        slider.assertIsNotEnabled().assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription,"Duration unavailable"))
        slider.assert(SemanticsMatcher.expectValue(SemanticsProperties.ProgressBarRangeInfo,ProgressBarRangeInfo.Indeterminate))
        slider.performTouchInput {click()}
        compose.runOnIdle {assertTrue(seeks.isEmpty());duration.longValue=120000}
        slider.assertIsEnabled().performSemanticsAction(SemanticsActions.SetProgress) {it(0.5f)}
        compose.runOnIdle {assertEquals(listOf(60000L),seeks)}
    }

    @Test fun fullPlayerOwnWindowUpdatesBothBarsInPlaceWithoutTransportOrSecurePolicyMutation() {
        val appearance=mutableStateOf(SoundQAppearance.Light);val open=mutableStateOf(true)
        var dialog:Window?=null;var transport=0
        compose.setContent {SoundQTheme(appearance=appearance.value) {
            if(open.value)SoundQFullPlayer("Song","Artist",false,true,false,65000,0,"same",
                {open.value=false},{transport++},{transport++},{},artwork={dialog=(LocalView.current.parent as DialogWindowProvider).window})
        }}
        compose.onNodeWithTag("player-window",useUnmergedTree=true).assertIsDisplayed()
        val original=checkNotNull(dialog)
        var secure=0
        compose.runOnIdle {secure=original.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE}
        @Suppress("DEPRECATION")
        fun checkBars(light:Boolean) {
            compose.runOnIdle {
                assertSame(original,dialog)
                assertEquals(secure,original.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE)
                if(android.os.Build.VERSION.SDK_INT>=30) {
                    val flags=original.insetsController!!.systemBarsAppearance
                    assertEquals(light,flags and WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS != 0)
                    assertEquals(light,flags and WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS != 0)
                } else {
                    val flags=original.decorView.systemUiVisibility
                    assertEquals(light,flags and android.view.View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR != 0)
                    assertEquals(light,flags and android.view.View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR != 0)
                }
            }
        }
        checkBars(true)
        compose.runOnIdle {appearance.value=SoundQAppearance.Dark}
        checkBars(false)
        compose.runOnIdle {appearance.value=SoundQAppearance.Light}
        checkBars(true)
        compose.onNodeWithContentDescription("Close Now playing").performClick()
        compose.onNodeWithTag("player-window",useUnmergedTree=true).assertDoesNotExist()
        compose.runOnIdle {assertEquals(0,transport)}
    }
}
