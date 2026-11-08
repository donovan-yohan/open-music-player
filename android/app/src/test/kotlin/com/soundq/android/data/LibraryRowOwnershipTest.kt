package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test

/** Existing consumer gap. A retained enqueue callback cannot borrow the replacement account. */
class LibraryRowOwnershipTest {
    @Test fun acknowledgedRowCaptureRetiresBeforeCollectorClearsOldRows() {
        val session=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore())
        session.accept(session.beginIntent(),SecretTokens("a","r","A"))
        val row=Track(TrackId(1),"Same object",liked=false)
        val library=LibraryRepository(session,{_,_,_->LibraryPage(listOf(row),1,20,0)},{_,_,_->})
        library.refine(LibraryQuery());val capture=library.captureTrack(row)!!
        assertTrue(library.owns(capture))
        session.accept(session.beginIntent(),SecretTokens("b","r","B"))
        assertFalse(library.owns(capture));assertNull(library.captureTrack(row))
    }
}
