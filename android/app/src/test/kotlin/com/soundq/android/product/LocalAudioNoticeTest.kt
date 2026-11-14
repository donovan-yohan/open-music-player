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
    /** [storage] is all files access (Environment.isExternalStorageManager()). */
    private fun phone(storage:Boolean,grants:List<ScanGrant> = emptyList(),files:List<DeviceAudio> = emptyList(),refreshing:Boolean=false,ready:Boolean=true,scan:PhoneScanObservation?=null)=
        PhoneAudioState(ready,DeviceListeningSnapshot(1,files,grants,emptyList()),refreshing,storage,scan=scan)
    private val fullScan=PhoneScanObservation(indexed=true,complete=true,storage=true)
    private val offScan=PhoneScanObservation(indexed=false,complete=true,storage=false)

    @Test fun serverSourceNeverExplainsEmptinessWithPhoneAccessScanOrNoFiles() {
        for(state in listOf(phone(false),phone(true,refreshing=true),phone(true,scan=fullScan),PhoneAudioState()))
            for(empty in listOf(true,false))assertNull(localAudioNotice(state,LibraryQuery(),LibrarySource.Server,empty))
    }

    @Test fun fileAccessOffIsExplainedForLocalFilesAndForEmptyResults() {
        val off=phone(false,listOf(grant(GrantKind.INDEXED,AccessState.REVOKED)))
        assertEquals(LocalAudioNotice.AccessOff,localAudioNotice(off,LibraryQuery(),source=LibrarySource.Local,rowsEmpty=true))
        // Device downloads or earlier index rows can populate Local files; file access is still off.
        assertEquals(LocalAudioNotice.AccessOff,localAudioNotice(off,LibraryQuery(),source=LibrarySource.Local,rowsEmpty=false))
        assertEquals(LocalAudioNotice.AccessOff,localAudioNotice(phone(false,listOf(grant(GrantKind.INDEXED,AccessState.REVOKED)),listOf(file(false))),LibraryQuery(),source=LibrarySource.Local,rowsEmpty=false))
        // A search with no rows while phone files would have been included.
        assertEquals(LocalAudioNotice.AccessOff,localAudioNotice(off,LibraryQuery(text="nothing"),source=LibrarySource.All,rowsEmpty=true))
        // Ordinary populated All tracks stays quiet.
        assertNull(localAudioNotice(off,LibraryQuery(),source=LibrarySource.All,rowsEmpty=false))
    }

    @Test fun refinementsThatNeverIncludePhoneFilesStayQuiet() {
        for(query in listOf(LibraryQuery(liked=true),LibraryQuery(verified=true),LibraryQuery(genre="House")))
            assertNull(localAudioNotice(phone(false),query,source=LibrarySource.Local,rowsEmpty=true))
    }

    @Test fun grantedAccessDistinguishesScanningFromGenuinelyNoAudio() {
        val indexed=listOf(grant(GrantKind.INDEXED))
        assertEquals(LocalAudioNotice.Finding,localAudioNotice(phone(true,indexed,refreshing=true),LibraryQuery(),source=LibrarySource.Local,rowsEmpty=true))
        assertEquals(LocalAudioNotice.NoneFound,localAudioNotice(phone(true,indexed,scan=fullScan),LibraryQuery(),source=LibrarySource.Local,rowsEmpty=true))
        // Unavailable rows are not audio that can be listed.
        assertEquals(LocalAudioNotice.NoneFound,localAudioNotice(phone(true,indexed,listOf(file(false)),scan=fullScan),LibraryQuery(),source=LibrarySource.Local,rowsEmpty=true))
        // Files exist but the search excluded them: the generic no-match state owns this.
        assertNull(localAudioNotice(phone(true,indexed,listOf(file()),scan=fullScan),LibraryQuery(text="zzz"),source=LibrarySource.Local,rowsEmpty=true))
        // Never claim none were found before a whole all-files scan finished.
        assertNull(localAudioNotice(phone(true,indexed),LibraryQuery(),source=LibrarySource.Local,rowsEmpty=true))
        assertNull(localAudioNotice(phone(true,indexed,scan=PhoneScanObservation(true,true,storage=false)),LibraryQuery(),source=LibrarySource.Local,rowsEmpty=true))
        assertNull(localAudioNotice(phone(true,indexed,scan=PhoneScanObservation(true,false,storage=true)),LibraryQuery(),source=LibrarySource.Local,rowsEmpty=true))
        // Rows visible: nothing to explain.
        assertNull(localAudioNotice(phone(true,indexed,listOf(file()),refreshing=true),LibraryQuery(),source=LibrarySource.Local,rowsEmpty=false))
    }

    @Test fun unavailableOwnerStateMakesNoClaim() {
        assertNull(localAudioNotice(PhoneAudioState(),LibraryQuery(),source=LibrarySource.Local,rowsEmpty=true))
        assertNull(localAudioNotice(phone(false,ready=false),LibraryQuery(),source=LibrarySource.Local,rowsEmpty=true))
    }

    @Test fun resumeRefreshOnlyFollowsAnActualAccessChange() {
        // All files access granted in system Settings; the last finished scan ran without it, or none finished.
        assertTrue(localAudioAccessChanged(phone(false,scan=offScan),storageAllowed=true))
        assertTrue(localAudioAccessChanged(phone(false),storageAllowed=true))
        // A journal publication already re-read access, but no scan has observed it.
        assertTrue(localAudioAccessChanged(phone(true,scan=offScan),storageAllowed=true))
        // Revoked outside the app.
        assertTrue(localAudioAccessChanged(phone(true,scan=fullScan),storageAllowed=false))
        // Ordinary resume: nothing changed, no exact-byte rescan (including partially proved scans).
        assertFalse(localAudioAccessChanged(phone(true,scan=fullScan),storageAllowed=true))
        assertFalse(localAudioAccessChanged(phone(true,scan=PhoneScanObservation(true,false,true)),storageAllowed=true))
        assertFalse(localAudioAccessChanged(phone(false,scan=offScan),storageAllowed=false))
        assertFalse(localAudioAccessChanged(phone(false),storageAllowed=false))
        // A running refresh admitted with the current access owns the scan; one admitted before the change does not.
        assertFalse(localAudioAccessChanged(phone(true,refreshing=true),storageAllowed=true))
        assertTrue(localAudioAccessChanged(phone(false,refreshing=true),storageAllowed=true))
        assertFalse(localAudioAccessChanged(phone(false,refreshing=true),storageAllowed=false))
        // Before the owner publishes, its startup refresh owns the first scan.
        assertFalse(localAudioAccessChanged(PhoneAudioState(),storageAllowed=true))
        assertFalse(localAudioAccessChanged(phone(false,ready=false),storageAllowed=true))
    }

    @Test fun noticeCellPrecedesRowsInScrollIndex() {
        assertEquals(3,libraryRowScrollIndex(2,false,false,notice=true))
        assertEquals(4,libraryRowScrollIndex(2,true,false,notice=true))
    }
}
