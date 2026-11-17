package com.soundq.designsystem

import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Real production compact bar and Compose pointer dispatch. Not device/service/audio proof. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[34],qualifiers="w400dp-h800dp")
class CompactPlayerSwipeTest {
    @get:Rule val compose=createComposeRule()
    private var next=0
    private var previous=0
    private var expanded=0
    private var primary=0
    private var queue=0
    private var density=1f
    private val owner=mutableStateOf<Any>("selection-A:1")
    private val canNext=mutableStateOf(true)
    private val canPrevious=mutableStateOf(true)
    private val mounted=mutableStateOf(true)
    private val enabled=mutableStateOf(true)
    private val elapsed=mutableStateOf(1000L)
    private val playing=mutableStateOf(false)
    private val fontScale=mutableStateOf(1f)
    private fun mount() {
        compose.setContent {SoundQTheme {
            density=LocalDensity.current.density
            CompositionLocalProvider(LocalDensity provides Density(density,fontScale.value)) {
                Box(Modifier.requiredWidth(360.dp).testTag("compact-host")) {
                    if(mounted.value)SoundQCompactPlayer("Song","Artist",playing.value,true,false,
                        {expanded++},{primary++},{queue++},
                        timing=CompactSongTiming(elapsedMs=elapsed.value,totalMs=120000,selected=true),
                        swipe=if(enabled.value)CompactPlayerSwipe(owner.value,canNext.value,canPrevious.value,{next++},{previous++})else null)
                }
            }
        }}
    }
    private fun bar()=compose.onNodeWithTag("compact-host")
    private fun point(x:Float,y:Float=36f)=Offset(x*density,y*density)
    private fun left() {bar().performTouchInput {swipe(point(220f),point(40f),300)}}
    private fun right() {bar().performTouchInput {swipe(point(40f),point(220f),300)}}
    private fun counts(n:Int=0,p:Int=0,e:Int=0,b:Int=0,q:Int=0) {
        compose.runOnIdle {assertEquals(n,next);assertEquals(p,previous);assertEquals(e,expanded);assertEquals(b,primary);assertEquals(q,queue)}
    }

    @Test fun leftDispatchesNextAndRightDispatchesPreviousOnceWithoutClicks() {
        mount()
        left();counts(n=1)
        right();counts(n=1,p=1)
    }

    @Test fun swipesStartingOnEitherButtonNeverInvokeItsClick() {
        mount()
        bar().performTouchInput {swipe(point(288f),point(100f),300)}
        counts(n=1)
        bar().performTouchInput {swipe(point(336f),point(140f),300)}
        counts(n=2)
        bar().performTouchInput {swipe(point(288f),point(350f),300)}
        counts(n=2,p=1)
    }

    @Test fun normalBodyArtworkClockAndButtonTapsRetainTheirOwnActions() {
        mount()
        bar().performTouchInput {click(point(120f))};counts(e=1)
        bar().performTouchInput {click(point(36f))};counts(e=2)
        compose.onNodeWithContentDescription("Elapsed 0:01, Duration 2:00",useUnmergedTree=true).performTouchInput {click()}
        counts(e=3)
        compose.onNodeWithContentDescription("Play").performTouchInput {click()};counts(e=3,b=1)
        compose.runOnIdle {playing.value=true}
        compose.onNodeWithContentDescription("Pause").performTouchInput {click()};counts(e=3,b=2)
        compose.onNodeWithContentDescription("Open listening queue").performTouchInput {click()};counts(e=3,b=2,q=1)
        // Existing full 48dp action columns and 72dp bar geometry have not moved.
        compose.onNodeWithContentDescription("Pause").assertWidthIsEqualTo(48.dp).assertHeightIsEqualTo(72.dp)
        compose.onNodeWithContentDescription("Open listening queue").assertWidthIsEqualTo(48.dp).assertHeightIsEqualTo(72.dp)
    }

    @Test fun shortAndVerticalDragsDoNotDispatchOrClickAndFreshSwipeRecovers() {
        mount()
        bar().performTouchInput {swipe(point(200f),point(170f),300)};counts()
        bar().performTouchInput {swipe(point(170f,8f),point(170f,64f),300)};counts()
        bar().performTouchInput {
            down(point(100f,8f));moveTo(point(100f,54f));moveTo(point(220f,54f));up()
        };counts()
        left();counts(n=1)
    }

    @Test fun dispatchOccursOnlyAtReleaseAndNeverTwiceDuringOneContact() {
        mount()
        bar().performTouchInput {down(point(220f));moveTo(point(100f));moveTo(point(210f));moveTo(point(40f))}
        counts()
        bar().performTouchInput {up()};counts(n=1)
        right();counts(n=1,p=1)
    }

    @Test fun unavailableDirectionIsNotDispatchedButOtherDirectionWorks() {
        canNext.value=false
        mount()
        left();counts()
        right();counts(p=1)
        compose.runOnIdle {canNext.value=true;canPrevious.value=false}
        right();counts(p=1)
        left();counts(n=1,p=1)
    }

    @Test fun selectionAccountAndServiceIncarnationsRetireHeldContactsIncludingABA() {
        mount()
        // Every accepted source change is applied before the held contact's UP.
        for(replacement in listOf("selection-B:2","selection-A:3","account-B:4","account-A:5","service-B:6")) {
            bar().performTouchInput {down(point(220f));moveTo(point(100f))}
            compose.runOnIdle {owner.value=replacement}
            compose.waitForIdle()
            bar().performTouchInput {moveTo(point(40f));up()}
            counts()
        }
        left();counts(n=1)
    }

    @Test fun capabilityLossAndRestorationCannotReviveHeldContact() {
        mount()
        bar().performTouchInput {down(point(220f));moveTo(point(100f))}
        compose.runOnIdle {canNext.value=false};compose.waitForIdle()
        compose.runOnIdle {canNext.value=true};compose.waitForIdle()
        bar().performTouchInput {moveTo(point(40f));up()};counts()
        left();counts(n=1)
        bar().performTouchInput {down(point(40f));moveTo(point(120f))}
        compose.runOnIdle {canPrevious.value=false};compose.waitForIdle()
        bar().performTouchInput {moveTo(point(220f));up()};counts(n=1)
        compose.runOnIdle {canPrevious.value=true}
        right();counts(n=1,p=1)
    }

    @Test fun sourceRetirementBeforeSlopDoesNotBecomeAnExpandOrButtonClick() {
        mount()
        for(x in listOf(120f,288f,336f)) {
            bar().performTouchInput {down(point(x))}
            compose.runOnIdle {owner.value=Any()};compose.waitForIdle()
            bar().performTouchInput {up()};counts()
        }
        bar().performTouchInput {click(point(120f))};counts(e=1)
    }

    @Test fun progressAndPlayingPublicationsDoNotRestartHeldGesture() {
        mount()
        bar().performTouchInput {down(point(220f));moveTo(point(120f))}
        compose.runOnIdle {elapsed.value=45000;playing.value=true};compose.waitForIdle()
        compose.onNodeWithContentDescription("Elapsed 0:45, Duration 2:00",useUnmergedTree=true).assertExists()
        bar().performTouchInput {moveTo(point(40f));up()};counts(n=1)
    }

    @Test fun pointerCancelBeforeAndAfterCaptureNeverDispatchesAndSameIdRecovers() {
        mount()
        bar().performTouchInput {down(point(220f));cancel()};counts()
        bar().performTouchInput {down(point(220f));moveTo(point(40f));cancel()};counts()
        left();counts(n=1)
        bar().performTouchInput {click(point(120f))};counts(n=1,e=1)
    }

    @Test fun secondContactOnBodyOrQueueCancelsUntilAllPointersLift() {
        mount()
        for(secondX in listOf(160f,336f)) {
            bar().performTouchInput {
                down(0,point(220f));moveTo(0,point(120f));down(1,point(secondX))
                moveTo(0,point(40f));up(0);up(1)
            };counts()
        }
        right();counts(p=1)
    }

    @Test fun footerClockStillExpandsAndOwnsSwipesWithoutClockOrProgressLoss() {
        fontScale.value=1.4f
        mount()
        val clock=compose.onNodeWithContentDescription("Elapsed 0:01, Duration 2:00",useUnmergedTree=true)
        clock.performTouchInput {click()};counts(e=1)
        clock.performTouchInput {swipe(Offset(width*0.8f,centerY),Offset(width*0.2f,centerY),300)}
        counts(n=1,e=1)
        compose.onNode(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.ProgressBarRangeInfo,
            androidx.compose.ui.semantics.ProgressBarRangeInfo(1000f/120000f,0f..1f)),useUnmergedTree=true).assertExists()
        clock.assertExists()
    }

    @Test fun ownerReplacementAndReturnDuringOneContactCannotReviveIt() {
        mount()
        val original=owner.value
        bar().performTouchInput {down(point(220f));moveTo(point(120f))}
        compose.runOnIdle {owner.value="other-owner"};compose.waitForIdle()
        compose.runOnIdle {owner.value=original};compose.waitForIdle()
        bar().performTouchInput {moveTo(point(40f));up()};counts()
        left();counts(n=1)
    }

    @Test fun optOutFromStartLeavesUnrelatedHostsWithoutSwipeCommands() {
        enabled.value=false
        mount()
        // The non-opted-in predecessor treats an in-bounds drag as an ordinary body click.
        // Preserve that existing host policy; only the dock opts into swipe interception.
        left();right();counts(e=2)
        bar().performTouchInput {click(point(120f))};counts(e=3)
        compose.onNodeWithContentDescription("Play").performTouchInput {click()};counts(e=3,b=1)
        compose.onNodeWithContentDescription("Open listening queue").performTouchInput {click()};counts(e=3,b=1,q=1)
    }

    @Test fun removalOrOptOutRetiresHeldContactAndFreshMountWorks() {
        mount()
        bar().performTouchInput {down(point(220f));moveTo(point(100f))}
        compose.runOnIdle {mounted.value=false};compose.waitForIdle()
        bar().performTouchInput {up()};counts()
        compose.runOnIdle {mounted.value=true}
        left();counts(n=1)
        bar().performTouchInput {down(point(220f));moveTo(point(100f))}
        compose.runOnIdle {enabled.value=false};compose.waitForIdle()
        bar().performTouchInput {moveTo(point(40f));up()};counts(n=1)
        compose.runOnIdle {enabled.value=true}
        right();counts(n=1,p=1)
    }
}
