package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test

class BoundedLibraryCorpusTest {
    private class Store:SessionStore {override fun load(endpoint:ApiEndpoint):SecretTokens?=null;override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){};override fun clear(){}}
    private fun session()=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store()).also {it.accept(it.beginIntent(),SecretTokens("fixture","fixture","owner"))}
    @Test fun globallyOrderedProjectionReadsEveryPageAndRejectsRepeatedRawMembership() {
        val s=session();val scope=s.capture()!!;val calls=mutableListOf<Int>()
        val result=readBoundedLibraryCorpus(scope,LibraryQuery(),{_,_,offset->calls+=offset;LibraryPage(listOf(Track(TrackId(offset+1L),if(offset==0)"Zebra"else "Alpha")),2,1,offset)}) {s.current(scope)}
        assertEquals(listOf(0,1),calls);assertEquals(2,result.tracks.size)
        assertTrue(runCatching {readBoundedLibraryCorpus(scope,LibraryQuery(),{_,_,offset->LibraryPage(listOf(Track(TrackId(1),"Repeat")),2,1,offset)}) {true}}.isFailure)
        assertTrue(runCatching {readBoundedLibraryCorpus(scope,LibraryQuery(),{_,_,offset->LibraryPage(emptyList(),2,1,offset)}) {true}}.isFailure)
    }
    @Test fun ordinaryAcknowledgedRefreshRetiresCompleteCorpusReceiptBeforeRepaging() {
        val s=session();val repository=LibraryRepository(s,{_,_,offset->LibraryPage(listOf(Track(TrackId(offset+1L),"Row $offset")),2,1,offset)},{_,_,_->})
        repository.refine(LibraryQuery());repository.completeProjection(repository.state.value)
        val complete=repository.state.value;assertTrue(complete.completeProjection);assertEquals(2,complete.rows.size)
        repository.refreshObserved(s.capture()!!,complete)
        val prefix=repository.state.value;assertEquals(1,prefix.rows.size)
        assertFalse("A refreshed prefix cannot retain complete-corpus authority",prefix.completeProjection)
        repository.completeProjection(prefix);assertTrue(repository.state.value.completeProjection);assertEquals(2,repository.state.value.rows.size)
    }
    @Test fun mixedProjectionCannotRelabelOldRowsWithReplacementAccount() {
        val s=session();val repository=LibraryRepository(s,{_,_,offset->LibraryPage(listOf(Track(TrackId(1),"Old account")),1,1,offset)},{_,_,_->})
        repository.refine(LibraryQuery());val displayed=repository.state.value
        assertNotNull(repository.projectionScope(displayed))
        s.accept(s.beginIntent(),SecretTokens("new","new","new-owner"))
        assertNull(repository.projectionScope(displayed))
        assertNull(repository.captureTrack(displayed.rows.single()))
    }
    @Test fun unparsedRawServerMemberCannotBeLabeledCompleteCoverage() {
        val s=session();val scope=s.capture()!!
        assertTrue("Parsed prefix is not a complete server corpus",runCatching {
            readBoundedLibraryCorpus(scope,LibraryQuery(),{_,_,offset->LibraryPage(emptyList(),1,1,offset,scannedIds=listOf(1))}) {s.current(scope)}
        }.isFailure)
    }
    @Test fun retiredOwnerCannotPublishHeldPageEvenAtEqualQuery() {
        val s=session();val scope=s.capture()!!
        assertTrue(runCatching {readBoundedLibraryCorpus(scope,LibraryQuery(),{_,_,offset->s.retire();LibraryPage(listOf(Track(TrackId(1),"Old")),1,1,offset)}) {s.current(scope)}}.isFailure)
    }
}
