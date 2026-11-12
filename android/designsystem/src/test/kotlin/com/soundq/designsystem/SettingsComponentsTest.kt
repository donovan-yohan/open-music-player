package com.soundq.designsystem

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.*
import androidx.compose.ui.state.ToggleableState
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

/** Mounted host composition of the settings list primitives. Not device pixels or TalkBack acceptance. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[34],qualifiers="w412dp-h915dp")
class SettingsComponentsTest {
    @get:Rule val compose=createComposeRule()

    private fun host(width:Int=412,scale:Float=1f,content:@Composable ()->Unit) {
        compose.setContent {
            val actual=LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(actual.density,scale)) {SoundQTheme {
                Box(Modifier.fillMaxSize()) {Column(Modifier.width(width.dp)) {content()}}
            }}
        }
    }

    @Test fun rowsAndLabelsShareOneTwentyDpGutterOnBothEdges() {
        host {
            SoundQSettingsSectionLabel("Library",first=true)
            SoundQSettingsRow("Local audio",value="Access off",onClick={})
            SoundQSettingsRow("Songs",value="248")
            SoundQSettingsRow("Downloads",onClick={})
        }
        compose.onNodeWithText("Library").assertLeftPositionInRootIsEqualTo(20.dp).assertTopPositionInRootIsEqualTo(16.dp)
        compose.onNodeWithText("Local audio",useUnmergedTree=true).assertLeftPositionInRootIsEqualTo(20.dp)
        compose.onNodeWithText("Downloads",useUnmergedTree=true).assertLeftPositionInRootIsEqualTo(20.dp)
        // Navigation value ends before the 12dp gap and 24dp chevron; read-only value ends at the gutter.
        val nav=compose.onNodeWithText("Access off",useUnmergedTree=true).getBoundsInRoot()
        assertEquals(412f-20f-24f-12f,nav.right.value,0.5f)
        val readOnly=compose.onNodeWithText("248",useUnmergedTree=true).getBoundsInRoot()
        assertEquals(392f,readOnly.right.value,0.5f)
        // The hit row spans the whole width including its internal gutter.
        compose.onNode(hasText("Local audio") and hasClickAction()).assertLeftPositionInRootIsEqualTo(0.dp).assertWidthIsEqualTo(412.dp)
    }

    @Test fun rowHeightsFollowOneLineAndSupportingMinimums() {
        host(360) {
            SoundQSettingsRow("Downloads",onClick={})
            SoundQSettingsSwitchRow("Keep queued songs",true,{},supporting="Keep your queue when starting another list")
        }
        // Host text metrics are synthetic, so only the floors are asserted here: 56dp one-line / 80dp
        // supporting minimum plus the row's own 1dp rule. Native heights are measured on the emulator.
        assertTrue(compose.onNode(hasText("Downloads") and hasClickAction()).getBoundsInRoot().let {it.bottom-it.top}.value>=57f)
        assertTrue(compose.onNode(hasText("Keep queued songs")).getBoundsInRoot().let {it.bottom-it.top}.value>=81f)
    }

    @Test fun navigationActionAndReadOnlyRowsExposeTheRightSemantics() {
        var opened=0
        host {
            SoundQSettingsRow("Storage",value="128 MB",onClick={opened++})
            SoundQSettingsRow("Status",value="Signed in")
            SoundQSettingsRow("Sign out",onClick={opened+=10},trailing={})
        }
        compose.onNode(hasText("Storage") and hasText("128 MB")).assertHasClickAction().performClick()
        compose.onNode(hasText("Sign out")).assertHasClickAction().performClick()
        assertEquals(11,opened)
        compose.onNode(hasText("Status") and hasText("Signed in")).assertHasNoClickAction()
    }

    @Test fun switchRowIsOneToggleNodeAndWritesThroughItsOwner() {
        var checked by mutableStateOf(false)
        host {SoundQSettingsSwitchRow("DJ mode",checked,{checked=it},supporting="Harmonic matching in playlists")}
        val row=compose.onNode(hasText("DJ mode") and SemanticsMatcher.expectValue(SemanticsProperties.Role,Role.Switch))
        row.assertIsOff().performClick()
        assertTrue(checked)
        row.assertIsOn()
        assertEquals(1,compose.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsProperties.ToggleableState)).fetchSemanticsNodes().size)
        compose.onNodeWithText("DJ mode",useUnmergedTree=true).assertLeftPositionInRootIsEqualTo(20.dp)
    }

    @Test fun disabledSwitchRowRefusesWrites() {
        var changes=0
        host {SoundQSettingsSwitchRow("Device unlock",false,{changes++},supporting="Set up a screen lock",enabled=false)}
        compose.onNode(hasText("Device unlock")).assertIsNotEnabled().performClick()
        assertEquals(0,changes)
    }

    @Test fun choiceRowsAreSingleSelectRadioOptions() {
        var choice by mutableStateOf("System")
        host {
            Column(Modifier.selectableGroup()) {
                for(option in listOf("System","Light","Dark"))SoundQSettingsChoiceRow(option,choice==option,{choice=option})
            }
        }
        compose.onNode(hasText("System")).assertIsSelected()
        compose.onNode(hasText("Dark")).assertIsNotSelected().performClick()
        assertEquals("Dark",choice)
        compose.onNode(hasText("Dark")).assertIsSelected()
        compose.onNode(hasText("System")).assertIsNotSelected()
        assertEquals(3,compose.onAllNodes(SemanticsMatcher.expectValue(SemanticsProperties.Role,Role.RadioButton)).fetchSemanticsNodes().size)
    }

    @Test fun scaffoldPinsBackAndTitleToTheSpecifiedEdges() {
        var back=0
        compose.setContent {SoundQTheme {Box(Modifier.width(412.dp).height(800.dp)) {
            SoundQSettingsScaffold("Settings",{back++}) {SoundQSettingsRow("Account",value="Signed in",onClick={})}
        }}}
        compose.onNodeWithContentDescription("Back").assertLeftPositionInRootIsEqualTo(8.dp).assertWidthIsEqualTo(48.dp).assertHeightIsAtLeast(48.dp).performClick()
        assertEquals(1,back)
        compose.onNode(hasText("Settings") and SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading)).assertLeftPositionInRootIsEqualTo(68.dp)
        compose.onNodeWithText("Account",useUnmergedTree=true).assertLeftPositionInRootIsEqualTo(20.dp)
    }

    @Test fun enlargedTextMovesValueUnderTitleWithoutLosingIt() {
        host(360,2f) {SoundQSettingsRow("Server import jobs and research",value="Shuffle library",onClick={})}
        val title=compose.onNodeWithText("Server import jobs and research",useUnmergedTree=true).getBoundsInRoot()
        val value=compose.onNodeWithText("Shuffle library",useUnmergedTree=true).getBoundsInRoot()
        assertEquals(20f,value.left.value,0.5f)
        assertTrue("value stacks below title",value.top>=title.bottom)
        assertTrue(compose.onNode(hasText("Server import jobs and research") and hasClickAction()).getBoundsInRoot().let {it.bottom-it.top}.value>=80f)
    }
}
