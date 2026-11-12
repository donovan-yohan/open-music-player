package com.soundq.android.product

import com.soundq.android.data.*
import com.soundq.android.data.device.PhoneAudioState
import com.soundq.android.data.device.PhoneScanObservation
import com.soundq.android.data.deviceaudio.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class LocalAudioNoticeTest {
    private fun grant(kind:GrantKind,state:AccessState=AccessState.AVAILABLE)=ScanGrant(ScanGrantId(UUID.randomUUID()),kind,kind.name,ProviderLocator("fixture",kind.name),kind!=GrantKind.INDEXED,state)
    private fun file(available:Boolean=true)=DeviceAudio(DeviceFileId(UUID(0,1)),ProviderObjectId("fixture","1"),ContentRevision("a".repeat(64),40),1,
        OriginalMetadata("1.wav","Song","Artist","Album"),1000,listOf(LocatorAccess(ScanGrantId(UUID(1,1)),ProviderLocator("fixture","1"),if(available)AccessState.AVAILABLE else AccessState.REVOKED)))
    private fun phone(permission:Boolean,grants:List<ScanGrant> = emptyList(),files:List<DeviceAudio> = emptyList(),refreshing:Boolean=false,ready:Boolean=true,scan:PhoneScanObservation?=null)=
        PhoneAudioState(ready,DeviceListeningSnapshot(1,files,grants,emptyList()),refreshing,permission,scan=scan)
    private val indexedScan=PhoneScanObservation(indexed=true,complete=true)
    private val revokedScan=PhoneScanObservation(indexed=false,complete=true)

    @Test fun accessOffIsExplainedForLocalFilesAndForEmptyResults() {
        val off=phone(false,listOf(grant(GrantKind.INDEXED,AccessState.REVOKED)))
        assertEquals(LocalAudioNotice.AccessOff,localAudioNotice(off,LibraryQuery(),localFiles=true,rowsEmpty=true))
        // Device downloads can populate Local files; access is still off for phone audio.
        assertEquals(LocalAudioNotice.AccessOff,localAudioNotice(off,LibraryQuery(),localFiles=true,rowsEmpty=false))
        // A search with no rows while phone files would have been included.
        assertEquals(LocalAudioNotice.AccessOff,localAudioNotice(off,LibraryQuery(text="nothing"),localFiles=false,rowsEmpty=true))
        // Ordinary populated All tracks stays quiet.
        assertNull(localAudioNotice(off,LibraryQuery(),localFiles=false,rowsEmpty=false))
    }

    @Test fun refinementsThatNeverIncludePhoneFilesStayQuiet() {
        val off=phone(false)
        for(query in listOf(LibraryQuery(liked=true),LibraryQuery(verified=true),LibraryQuery(genre="House")))
            assertNull(localAudioNotice(off,query,localFiles=true,rowsEmpty=true))
    }

    @Test fun addedLocationsWithoutIndexedAccessArePartialNotOff() {
        val partial=phone(false,listOf(grant(GrantKind.INDEXED,AccessState.REVOKED),grant(GrantKind.FOLDER)),listOf(file()))
        assertEquals(LocalAudioNotice.AddedOnly,localAudioNotice(partial,LibraryQuery(),localFiles=true,rowsEmpty=false))
        // A lost added location is not partial access.
        val lost=phone(false,listOf(grant(GrantKind.FOLDER,AccessState.REVOKED)))
        assertEquals(LocalAudioNotice.AccessOff,localAudioNotice(lost,LibraryQuery(),localFiles=true,rowsEmpty=true))
    }

    @Test fun grantedAccessDistinguishesScanningFromGenuinelyNoAudio() {
        val indexed=listOf(grant(GrantKind.INDEXED))
        assertEquals(LocalAudioNotice.Finding,localAudioNotice(phone(true,indexed,refreshing=true),LibraryQuery(),localFiles=true,rowsEmpty=true))
        assertEquals(LocalAudioNotice.NoneFound,localAudioNotice(phone(true,indexed,scan=indexedScan),LibraryQuery(),localFiles=true,rowsEmpty=true))
        // Unavailable rows are not audio that can be listed.
        assertEquals(LocalAudioNotice.NoneFound,localAudioNotice(phone(true,indexed,listOf(file(false)),scan=indexedScan),LibraryQuery(),localFiles=true,rowsEmpty=true))
        // Files exist but the search excluded them: the generic no-match state owns this.
        assertNull(localAudioNotice(phone(true,indexed,listOf(file()),scan=indexedScan),LibraryQuery(text="zzz"),localFiles=true,rowsEmpty=true))
        // Never claim none were found before a scan finished: an AVAILABLE grant is persisted before scanning,
        // so a cancelled scan leaves it without any proved files.
        assertNull(localAudioNotice(phone(true,indexed),LibraryQuery(),localFiles=true,rowsEmpty=true))
        assertNull(localAudioNotice(phone(true),LibraryQuery(),localFiles=true,rowsEmpty=true))
        // Partially proved index: some audio exists that could not be proved.
        assertNull(localAudioNotice(phone(true,indexed,scan=PhoneScanObservation(true,false)),LibraryQuery(),localFiles=true,rowsEmpty=true))
        // Rows visible: nothing to explain.
        assertNull(localAudioNotice(phone(true,indexed,listOf(file()),refreshing=true),LibraryQuery(),localFiles=true,rowsEmpty=false))
    }

    @Test fun unavailableOwnerStateMakesNoClaim() {
        assertNull(localAudioNotice(PhoneAudioState(),LibraryQuery(),localFiles=true,rowsEmpty=true))
        assertNull(localAudioNotice(phone(false,ready=false),LibraryQuery(),localFiles=true,rowsEmpty=true))
    }

    @Test fun resumeRefreshOnlyFollowsAnActualAccessChange() {
        // Granted outside the app; the last finished scan saw access off, or none finished in this scope.
        assertTrue(localAudioAccessChanged(phone(false,scan=revokedScan),indexedAllowed=true))
        assertTrue(localAudioAccessChanged(phone(false),indexedAllowed=true))
        // A journal publication already re-read permission=true, but no scan has observed it.
        assertTrue(localAudioAccessChanged(phone(true,scan=revokedScan),indexedAllowed=true))
        // A scan was cancelled after persisting an AVAILABLE indexed grant: still unobserved.
        assertTrue(localAudioAccessChanged(phone(true,listOf(grant(GrantKind.INDEXED))),indexedAllowed=true))
        // Revoked outside the app.
        assertTrue(localAudioAccessChanged(phone(true,scan=indexedScan),indexedAllowed=false))
        // Ordinary resume: nothing changed, no exact-byte rescan (including partially proved indexes).
        assertFalse(localAudioAccessChanged(phone(true,scan=indexedScan),indexedAllowed=true))
        assertFalse(localAudioAccessChanged(phone(true,scan=PhoneScanObservation(true,false)),indexedAllowed=true))
        assertFalse(localAudioAccessChanged(phone(false,scan=revokedScan),indexedAllowed=false))
        assertFalse(localAudioAccessChanged(phone(false),indexedAllowed=false))
        // A running refresh admitted with the current access owns the scan; one admitted before the change does not.
        assertFalse(localAudioAccessChanged(phone(true,refreshing=true),indexedAllowed=true))
        assertTrue(localAudioAccessChanged(phone(false,refreshing=true),indexedAllowed=true))
        // Before the owner publishes, its startup refresh owns the first scan.
        assertFalse(localAudioAccessChanged(PhoneAudioState(),indexedAllowed=true))
        assertFalse(localAudioAccessChanged(phone(false,ready=false),indexedAllowed=true))
    }

    @Test fun noticeCellPrecedesRowsInScrollIndex() {
        assertEquals(3,libraryRowScrollIndex(2,false,false,notice=true))
        assertEquals(4,libraryRowScrollIndex(2,true,false,notice=true))
    }
}
