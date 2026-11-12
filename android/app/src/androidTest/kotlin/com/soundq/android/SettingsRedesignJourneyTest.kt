package com.soundq.android

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.soundq.android.data.AuthState
import com.soundq.android.data.preferences.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/** Ordinary product route: Library gear → full-screen Settings. Fixture backend; no OS authentication. */
class SettingsRedesignJourneyTest {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private val app get()=InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as FixtureApplication
    private val graph get()=app.graph

    private fun gear() {
        compose.waitUntil(15000){compose.onAllNodesWithContentDescription("Settings").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithContentDescription("Settings").assertIsDisplayed().performClick()
    }
    private fun heading(text:String)=compose.onNode(hasText(text) and isHeading())
    private fun row(text:String)=compose.onNode(hasText(text) and hasClickAction())
    // The app bar title is the first heading; a detail page may repeat it as its section label.
    private fun open(text:String){row(text).performScrollTo().performClick();compose.onAllNodes(hasText(text) and isHeading()).onFirst().assertIsDisplayed()}
    private fun back()=compose.onNodeWithContentDescription("Back").performClick()
    private fun systemBack(){InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK);compose.waitForIdle()}
    private fun signedOut(){compose.runOnIdle {if(graph.session.state.value !is AuthState.SignedOut)graph.session.retire()};compose.waitUntil(10000){graph.session.state.value is AuthState.SignedOut}}

    @Test fun gearOpensGroupedSettingsInOneTapAndBackReturnsToLibrary() {
        signedOut();gear()
        heading("Settings").assertIsDisplayed()
        // No sheet chrome, Account hub or bottom navigation over the full-screen page.
        compose.onNodeWithContentDescription("Close Settings").assertDoesNotExist()
        compose.onNodeWithText("Back to Library").assertDoesNotExist()
        compose.onNodeWithContentDescription("Library search query").assertDoesNotExist()
        for(section in listOf("Account","Library","Playback","Appearance","More"))heading(section).performScrollTo().assertIsDisplayed()
        compose.onNode(hasText("Account") and hasText("Signed out") and hasClickAction()).performScrollTo().assertIsDisplayed()
        back()
        compose.waitUntil(5000){compose.onAllNodesWithContentDescription("Library search query").fetchSemanticsNodes().isNotEmpty()}
        heading("Settings").assertDoesNotExist()
        gear();heading("Settings").assertIsDisplayed();systemBack()
        heading("Settings").assertDoesNotExist()
        compose.onNodeWithContentDescription("Library search query").assertExists()
        compose.onNodeWithContentDescription("Local files").performClick()
        compose.onNodeWithText("Offline Library",substring=true).assertDoesNotExist()
        compose.onNodeWithContentDescription("Local files").performClick()
    }

    @Test fun rowsTitlesAndSectionLabelsShareTheTwentyDpGutter() {
        signedOut();gear()
        val width=compose.onRoot().fetchSemanticsNode().boundsInRoot.width
        val density=compose.activity.resources.displayMetrics.density
        for(title in listOf("Downloads","Storage","Listening history","Keep queued songs","Theme","About")) {
            row(title).performScrollTo()
            compose.onNodeWithText(title,useUnmergedTree=true).assertLeftPositionInRootIsEqualTo(20.dp)
            val hit=row(title).fetchSemanticsNode().boundsInRoot
            assertEquals("$title row spans the full width",width,hit.width,1f)
        }
        heading("Playback").performScrollTo().assertLeftPositionInRootIsEqualTo(20.dp)
        // Navigation chevron ends at the right gutter: value text ends 12dp + 24dp before it.
        row("Account").performScrollTo()
        val value=compose.onNodeWithText("Signed out",useUnmergedTree=true).fetchSemanticsNode().boundsInRoot
        assertEquals(width/density-20f-24f-12f,value.right/density,1f)
    }

    @Test fun deviceLocalPreferencesWriteWithoutAnAccountAndSummariesFollowAcceptedState() {
        signedOut();gear()
        val dj=graph.djModePreferences.state.value.enabled
        compose.onNode(hasText("DJ mode") and isToggleable()).performScrollTo().performClick()
        compose.waitUntil(10000){graph.djModePreferences.state.value.enabled!=dj}
        DjModePreferences(java.io.File(graph.directory,"dj-mode.v1.json")).also {it.load();assertEquals(!dj,it.enabled())}
        compose.onNode(hasText("DJ mode") and isToggleable()).performClick()
        compose.waitUntil(10000){graph.djModePreferences.state.value.enabled==dj}

        compose.waitUntil(10000){graph.queueSettings.capture()!=null}
        val keep=graph.queueSettings.state.value.keepQueued
        compose.onNode(hasText("Keep queued songs") and isToggleable()).performScrollTo().assertIsEnabled().performClick()
        compose.waitUntil(10000){graph.queueSettings.state.value.keepQueued!=keep}
        com.soundq.android.data.QueueSettingsRepository(com.soundq.android.data.FileQueuePreferencesStore(graph.directory.resolve("queue-settings.v1.json"))).also {it.load();assertEquals(!keep,it.state.value.keepQueued)}
        compose.onNode(hasText("Keep queued songs") and isToggleable()).performClick()
        compose.waitUntil(10000){graph.queueSettings.state.value.keepQueued==keep}

        open("Storage")
        val temporary=graph.storagePreferences.state.value.temporaryAudioEnabled
        compose.onNode(hasText("Temporary audio") and isToggleable()).assertIsEnabled().performClick()
        compose.waitUntil(10000){graph.storagePreferences.state.value.temporaryAudioEnabled!=temporary}
        StoragePreferences(graph.directory.resolve("storage-preferences.v1.json")).also {it.load();assertEquals(!temporary,it.state.value.temporaryAudioEnabled)}
        compose.onNode(hasText("Temporary audio") and isToggleable()).performClick()
        compose.waitUntil(10000){graph.storagePreferences.state.value.temporaryAudioEnabled==temporary}
        back()

        val fade=graph.crossfadePreferences.state.value.seconds
        val target=if(fade==3)4 else 3
        open("Crossfade")
        compose.onNode(hasText("$target seconds") and isSelectable()).performScrollTo().performClick().assertIsSelected()
        compose.waitUntil(10000){graph.crossfadePreferences.state.value.seconds==target}
        back();row("Crossfade").performScrollTo().assert(hasText("$target seconds"))
        open("Crossfade");compose.onNode(hasText(crossfadeText(fade)) and isSelectable()).performScrollTo().performClick()
        compose.waitUntil(10000){graph.crossfadePreferences.state.value.seconds==fade};back()

        open("Theme")
        compose.onNode(hasText("Dark") and isSelectable()).performClick()
        compose.waitUntil(10000){graph.appearancePreferences.state.value.choice==Appearance.Dark}
        systemBack();row("Theme").performScrollTo().assert(hasText("Dark"))
        open("Theme");compose.onNode(hasText("System") and isSelectable()).performClick()
        compose.waitUntil(10000){graph.appearancePreferences.state.value.choice==Appearance.System};back()

        open("End of queue")
        for(label in listOf("Off","Shuffle library"))compose.onNode(hasText(label) and isSelectable()).assertIsDisplayed()
        back();open("Swipe to queue")
        for(label in listOf("Add to queue","Play next"))compose.onNode(hasText(label) and isSelectable()).assertIsDisplayed()
        back();open("Key notation")
        compose.onNode(hasText("Camelot") and hasText("8A, 11B") and isSelectable()).assertIsDisplayed()
        compose.onNode(hasText("Musical key") and hasText("Am, F# major") and isSelectable()).assertIsDisplayed()
        back()
    }
    private fun crossfadeText(seconds:Int)=when(seconds){0->"Off";1->"1 second";else->"$seconds seconds"}

    @Test fun everyRelocatedSettingAndActionIsReachable() {
        signedOut();gear()
        for(title in listOf("Account","Local audio","Downloads","Storage","Listening history","End of queue","Swipe to queue","Crossfade","Key notation","Theme","Music tools","About"))
            row(title).performScrollTo().assertIsDisplayed().assertIsEnabled()
        for(title in listOf("Keep queued songs","DJ mode"))compose.onNode(hasText(title) and isToggleable()).performScrollTo().assertIsDisplayed()
        open("Storage")
        compose.onNode(hasText("Temporary audio") and isToggleable()).assertIsDisplayed()
        compose.onNodeWithText("Used",useUnmergedTree=true).assertIsDisplayed()
        for(title in listOf("Clear temporary audio","Storage details","Refresh","Manage downloads"))row(title).performScrollTo().assertIsDisplayed()
        row("Clear temporary audio").performClick()
        compose.onNodeWithText("Clear temporary audio?").assertIsDisplayed()
        compose.onNodeWithText("Downloads and artwork stay on this device.").assertIsDisplayed()
        compose.onNodeWithText("Cancel").performClick()
        open("Storage details")
        compose.waitUntil(5000){compose.onAllNodesWithText("Tracked files").fetchSemanticsNodes().isNotEmpty()}
        for(title in listOf("Size","Tracked files","Awaiting clear","Active writes","Validation failures"))compose.onNodeWithText(title,useUnmergedTree=true).assertExists()
        back();back()
        open("Music tools")
        for(tool in listOf("Catalog","Mixes","Connected devices","Jam","Imports","Server import jobs and research"))row(tool).performScrollTo().assertIsDisplayed()
        back();open("About")
        for(title in listOf("Version","Build"))compose.onNodeWithText(title,useUnmergedTree=true).assertExists()
        for(title in listOf("Privacy policy","Terms of service"))row(title).assertIsDisplayed()
        open("Open-source notices")
        compose.waitUntil(5000){compose.onAllNodesWithText("SIL Open Font License",substring=true).fetchSemanticsNodes().isNotEmpty()}
        back();back()
        open("Local audio");back()
        open("Account")
        compose.onNode(hasText("Status") and hasText("Signed out")).assertIsDisplayed()
        compose.onNodeWithText("Server",useUnmergedTree=true).assertExists()
        for(title in listOf("Sign in","Create account"))row(title).assertIsDisplayed()
        open("Create account")
        for(field in listOf("Username","Email","Password","Confirm password"))compose.onNodeWithContentDescription(field).assertExists()
        back();back();back()
        heading("Settings").assertDoesNotExist()
    }

    @Test fun signedOutToolOpensSignInThenAccountReflectsSessionAndSignOutConfirms() {
        signedOut();gear()
        open("Music tools");row("Catalog").performClick()
        heading("Sign in").assertIsDisplayed()
        compose.onNodeWithContentDescription("Email").performTextInput("settings-redesign@example.test")
        compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
        compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
        compose.waitUntil(15000){graph.session.state.value is AuthState.SignedIn}
        // The retained tool target runs once the session exists; Back returns to Settings.
        compose.waitUntil(15000){compose.onAllNodes(hasText("Settings") and isHeading()).fetchSemanticsNodes().isEmpty()}
        systemBack()
        compose.waitUntil(10000){compose.onAllNodes(hasText("Settings") and isHeading()).fetchSemanticsNodes().isNotEmpty()||compose.onAllNodes(hasText("Music tools") and isHeading()).fetchSemanticsNodes().isNotEmpty()}
        while(compose.onAllNodes(hasText("Settings") and isHeading()).fetchSemanticsNodes().isEmpty())back()
        compose.onNode(hasText("Account") and hasText("Signed in") and hasClickAction()).performScrollTo().assertIsDisplayed()
        open("Account")
        compose.onNode(hasText("Status") and hasText("Signed in")).assertIsDisplayed()
        compose.onNode(hasText("Device unlock") and isToggleable()).assertIsDisplayed()
        row("Sign out").performClick()
        compose.onNodeWithText("Sign out?").assertIsDisplayed()
        compose.onNodeWithText("Downloads stay on this device.").assertIsDisplayed()
        compose.onNodeWithText("Clear temporary playback audio").assertIsDisplayed()
        compose.onNodeWithText("Cancel").performClick()
        assertTrue(graph.session.state.value is AuthState.SignedIn)
        row("Sign out").performClick()
        compose.onAllNodesWithText("Sign out").filterToOne(hasAnyAncestor(isDialog())).performClick()
        compose.waitUntil(15000){graph.session.state.value is AuthState.SignedOut}
        compose.waitUntil(10000){compose.onAllNodes(hasText("Account") and hasText("Signed out") and hasClickAction()).fetchSemanticsNodes().isNotEmpty()}
        heading("Settings").assertIsDisplayed()
    }

    /** OS-frame captures for review, only when the runner passes captureLabel. Not an acceptance assertion. */
    @Test fun capturesSettingsPagesForReview() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("captureLabel")!=null)
        val dark=InstrumentationRegistry.getArguments().getString("captureDark")=="true"
        signedOut()
        if(InstrumentationRegistry.getArguments().getString("captureSignedIn")=="true") {
            gear();open("Account");open("Sign in")
            compose.onNodeWithContentDescription("Email").performTextInput("settings-capture@example.test")
            compose.onNodeWithContentDescription("Password").performTextInput("test-only-password")
            compose.onAllNodesWithText("Sign in").filterToOne(hasClickAction()).performClick()
            compose.waitUntil(15000){graph.session.state.value is AuthState.SignedIn&&graph.appearancePreferences.state.value.ready}
            back();back()
            compose.waitUntil(5000){compose.onAllNodes(hasText("Settings") and isHeading()).fetchSemanticsNodes().isEmpty()}
        }
        compose.runOnIdle {graph.appearancePreferences.capture()?.let {graph.appearancePreferences.setChoice(it,if(dark)Appearance.Dark else Appearance.Light){true}}}
        try {
            captureListeningStage("library")
            compose.onNodeWithContentDescription("Local files").performClick();compose.waitForIdle();Thread.sleep(500)
            captureListeningStage("library-local-files")
            compose.onNodeWithContentDescription("Local files").performClick();compose.waitForIdle()
            gear();compose.waitForIdle();Thread.sleep(500);captureListeningStage("settings-top")
            row("About").performScrollTo();compose.waitForIdle();Thread.sleep(500);captureListeningStage("settings-bottom")
            compose.onNode(hasScrollAction()).performTouchInput {swipeDown()};compose.waitForIdle()
            row("Account").performScrollTo();open("Account");captureListeningStage("account")
            back();open("Local audio");captureListeningStage("local-audio")
            back();open("Storage");captureListeningStage("storage")
            back();open("Crossfade");captureListeningStage("crossfade")
            back();open("Theme");captureListeningStage("theme")
            back();open("Music tools");captureListeningStage("music-tools")
            back();open("About");captureListeningStage("about")
            back();back()
        } finally {
            compose.runOnIdle {graph.appearancePreferences.capture()?.let {graph.appearancePreferences.setChoice(it,Appearance.System){true}}}
        }
    }
}
