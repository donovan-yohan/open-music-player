package com.soundq.android.product.preferences

import com.soundq.android.data.AuthState
import com.soundq.android.data.device.PhoneAudioState
import com.soundq.android.data.deviceaudio.DeviceListeningSnapshot
import com.soundq.android.data.preferences.*
import org.junit.Assert.*
import org.junit.Test

class SettingsRouteTest {
    private val root=listOf(SettingsRoute.Root)

    @Test fun backPopsExactlyOneRouteAndEmptyMeansClosed() {
        val stack=root.push(SettingsRoute.Storage).push(SettingsRoute.StorageDetails)
        assertEquals(listOf(SettingsRoute.Root,SettingsRoute.Storage),stack.pop())
        assertEquals(root,stack.pop().pop())
        assertTrue(stack.pop().pop().pop().isEmpty())
    }

    @Test fun saveableNamesRoundTripAndUnknownNamesAreDropped() {
        val stack=root.push(SettingsRoute.MusicTools)
        assertEquals(stack,SettingsRoute.decode(stack.encode()))
        assertEquals(root,SettingsRoute.decode(listOf("Root","RetiredPanel")))
    }

    @Test fun accountEntryOpensTheFormOnlyWhenNoSessionExists() {
        assertEquals(listOf(SettingsRoute.Account,SettingsRoute.SignIn),accountEntry(AuthState.SignedOut()))
        assertEquals(listOf(SettingsRoute.Account),accountEntry(AuthState.SignedIn("account")))
        assertEquals(listOf(SettingsRoute.Account),accountEntry(AuthState.DeviceOnly("account")))
    }

    @Test fun authFormRoutesRetireOnceASessionExists() {
        val form=root.push(SettingsRoute.Account).push(SettingsRoute.SignIn)
        assertEquals(root.push(SettingsRoute.Account),form.settled(AuthState.SignedIn("account")))
        assertEquals(form,form.settled(AuthState.SignedOut()))
        val create=root.push(SettingsRoute.Account).push(SettingsRoute.CreateAccount)
        assertEquals(root.push(SettingsRoute.Account),create.settled(AuthState.DeviceOnly("account")))
    }

    @Test fun accountStatusUsesLiteralStateLabels() {
        assertEquals("Signed in",accountStatus(AuthState.SignedIn("account")))
        assertEquals("Signed out",accountStatus(AuthState.SignedOut()))
        assertEquals("Offline",accountStatus(AuthState.DeviceOnly("account")))
    }

    @Test fun crossfadeChoicesCoverTheSameZeroToTwelveRangeAsTheOldControls() {
        assertEquals((0..12).toList(),crossfadeChoices)
        assertEquals("Off",crossfadeLabel(0))
        assertEquals("1 second",crossfadeLabel(1))
        assertEquals("12 seconds",crossfadeLabel(12))
    }

    @Test fun summariesShowAcceptedStateOrAPlaceholderNeverADefault() {
        assertEquals("Loading…",summary(false,endOfQueueLabel(EndOfQueue.Off)))
        assertEquals("Shuffle library",summary(true,endOfQueueLabel(EndOfQueue.ShuffleLibrary)))
        assertEquals("Play next",swipeQueueLabel(SwipeQueue.PlayNext))
        assertEquals("Add to queue",swipeQueueLabel(SwipeQueue.AddToQueue))
        assertEquals("Camelot",keyNotationLabel(KeyNotation.Camelot))
        assertEquals("Musical key",keyNotationLabel(KeyNotation.Musical))
        assertEquals(listOf("System","Light","Dark"),Appearance.entries.map(::appearanceLabel))
    }

    @Test fun localAudioSummaryReflectsOwnerStateWithoutReportingUnknownAsZero() {
        assertEquals("Loading…",localAudioSummary(PhoneAudioState()))
        assertEquals("Access off",localAudioSummary(PhoneAudioState(ready=true,permission=false)))
        assertEquals("Scanning…",localAudioSummary(PhoneAudioState(ready=true,permission=true,refreshing=true)))
        assertNull(localAudioSummary(PhoneAudioState(ready=true,permission=true)))
        assertEquals("No audio found",localAudioSummary(PhoneAudioState(ready=true,permission=true,snapshot=DeviceListeningSnapshot(1,emptyList(),emptyList(),emptyList()))))
    }

    @Test fun musicToolsKeepTheOldAccountHubOrder() {
        assertEquals(listOf("Catalog","Mixes","Connected devices","Jam","Imports","Server import jobs and research"),MusicTool.entries.map {it.label})
    }

    /** Every control from the old Account hub and Settings sheet has a mapped destination (INVENTORY.md). */
    @Test fun everyInventoryItemHasADestination() {
        val routes=SettingsRoute.entries.map {it.title}.toSet()
        for(page in listOf("Account","Sign in","Create account","Local audio","Storage","Storage details","Theme","End of queue","Swipe to queue","Crossfade","Key notation","Music tools","About","Open-source notices"))
            assertTrue("Missing route $page",page in routes)
    }
}
