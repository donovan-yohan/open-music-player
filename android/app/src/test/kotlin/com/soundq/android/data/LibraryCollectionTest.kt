package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test

class LibraryCollectionTest {
    private fun session(account:String="A")=AccountSession(ApiEndpoint.parse("https://fixture.test/api/v1"),MemoryStore()).also {
        it.accept(it.beginIntent(),SecretTokens("a","r",account))
    }
    private val artist="""  A%_ + & / ? # \\"東京"""
    private val album="""  100%_+ [Live] & / ? # \\"  """
    private fun corpus()=(1L..643L).map {id->Track(TrackId(id),"Same title",if(id<41)"Other" else artist,if(id%3==0L)album else "Other",liked=id%2==0L)}
    private fun fetch(rows:List<Track>,offsets:MutableList<Int> = mutableListOf()):(AccountScope,LibraryQuery,Int)->LibraryPage = {_,query,offset->
        assertNull("Exact metadata must never be turned into fuzzy/SQL search",query.collection)
        offsets+=offset
        LibraryPage(rows.drop(offset).take(20),rows.size,20,offset)
    }
    @Test fun literalArtistAndAlbumUseEntireCorpusBeforeMembershipAndKeepDistinctRecordings() {
        val offsets=mutableListOf<Int>();val rows=corpus()
        val repo=LibraryRepository(session(),fetch(rows,offsets),{_,_,_->})
        repo.refine(LibraryQuery(collection=LibraryCollection(artist,album)))
        val expected=rows.filter {it.artist==artist&&it.album==album}
        assertEquals(expected,repo.state.value.rows)
        assertEquals(expected.size,repo.state.value.total)
        assertTrue(repo.state.value.endReached)
        assertEquals((0..640 step 20).toList(),offsets)
        assertEquals(642L,repo.state.value.rows.last().id.value)
        assertTrue(repo.state.value.rows.size>20)
        repo.loadMore();assertEquals(33,offsets.size)
        assertEquals(album,repo.state.value.query.collection?.album)
    }
    @Test fun artistOnlyAndAlbumOnlyAreLiteralNotNormalizedOrFirstPageSets() {
        val rows=corpus();val repo=LibraryRepository(session(),fetch(rows),{_,_,_->})
        for(collection in listOf(LibraryCollection(artist=artist),LibraryCollection(album=album),LibraryCollection(artist=artist.trim()),LibraryCollection(album=album.lowercase()))) {
            repo.refine(LibraryQuery(collection=collection))
            assertEquals(rows.filter(collection::contains),repo.state.value.rows)
        }
    }
    @Test fun likedPlayAndShuffleReadAllPagesAndUseExactSelectedIdNotTitleArtist() {
        val rows=corpus();val offsets=mutableListOf<Int>();val repo=LibraryRepository(session(),fetch(rows,offsets),{_,_,_->})
        repo.refine(LibraryQuery(liked=true));val shown=repo.state.value.rows
        for(shuffle in listOf(false,true)) {
            val request=repo.claimCollectionPlay(repo.state.value,shuffle=shuffle){true}!!
            assertNull(repo.claimCollectionPlay(repo.state.value){true})
            repo.readCollection(request)
            var calls=0
            repo.startCollection(request){tracks,index->
                calls++;assertEquals(0,index)
                assertEquals(rows.filter {it.liked==true}.map {it.id}.toSet(),tracks.map {it.id}.toSet())
                assertEquals(321,tracks.size)
                if(!shuffle)assertEquals(rows.filter {it.liked==true},tracks)
                null
            }
            assertEquals(1,calls);assertSame(shown,repo.state.value.rows)
            assertNull(repo.state.value.collectionError)
        }
        val request=repo.claimCollectionPlay(repo.state.value,selected=TrackId(18)){true}!!
        repo.readCollection(request)
        repo.startCollection(request){tracks,index->assertEquals(TrackId(18),tracks[index].id);assertEquals(8,index);null}
    }
    @Test fun largeEligibleSetIsDeliveredUntrimmedAndCapacityRefusalIsVisible() {
        val rows=(1L..643).map {Track(TrackId(it),"Same",artist,album,liked=true)}
        val repo=LibraryRepository(session(),fetch(rows),{_,_,_->});repo.refine(LibraryQuery(liked=true))
        val request=repo.claimCollectionPlay(repo.state.value){true}!!;repo.readCollection(request)
        repo.startCollection(request){tracks,_->assertEquals(rows,tracks);"Capacity refused. Nothing started."}
        assertEquals("Capacity refused. Nothing started.",repo.state.value.collectionError)
        assertFalse(repo.state.value.collectionLoading)
    }
    @Test fun failedLaterReadNeverStartsPartialAndRetryRetainsQueryAndRows() {
        val rows=corpus();var fail=false;val reader=fetch(rows)
        val repo=LibraryRepository(session(),{scope,query,offset->if(fail&&offset==40)throw SafeFailure(SafeFailure.Reason.Network);reader(scope,query,offset)},{_,_,_->})
        repo.refine(LibraryQuery(liked=true));val shown=repo.state.value.rows;fail=true
        val request=repo.claimCollectionPlay(repo.state.value){true}!!;repo.readCollection(request)
        repo.startCollection(request){_,_->fail("Partial selection started");null}
        assertNotNull(repo.state.value.collectionError);assertSame(shown,repo.state.value.rows)
        fail=false;val retry=repo.claimCollectionPlay(repo.state.value){true}!!;repo.readCollection(retry)
        var count=0;repo.startCollection(retry){tracks,_->count=tracks.size;null};assertEquals(321,count)
    }
    @Test fun exactBrowseFailureDoesNotPublishFirstPageOrFalseTotal() {
        val rows=corpus();val reader=fetch(rows)
        val repo=LibraryRepository(session(),{scope,query,offset->if(offset==40)throw SafeFailure(SafeFailure.Reason.Network);reader(scope,query,offset)},{_,_,_->})
        repo.refine(LibraryQuery(collection=LibraryCollection(album=album)))
        assertTrue(repo.state.value.rows.isEmpty());assertNull(repo.state.value.total)
        assertEquals(SafeFailure.Reason.Network,repo.state.value.error)
    }
    @Test fun queryRefreshRouteRetirementAndReplacementAccountRefuseCollectedStart() {
        for(retirement in 0..2) {
            val s=session();val repo=LibraryRepository(s,fetch(corpus()),{_,_,_->});repo.refine(LibraryQuery(liked=true))
            var route=true
            val request=repo.claimCollectionPlay(repo.state.value){route}!!;repo.readCollection(request)
            when(retirement){0->repo.refine(repo.state.value.query);1->route=false;else->s.accept(s.beginIntent(),SecretTokens("b","r","A"))}
            repo.startCollection(request){_,_->fail("Retired start accepted");null}
            repo.abandonCollection(request);assertFalse(repo.state.value.collectionLoading)
        }
    }
    @Test fun cancellationBetweenRawPagesStopsWithoutSelection() {
        var route=true;var reads=0;val reader=fetch(corpus())
        val repo=LibraryRepository(session(),{scope,query,offset->reads++;reader(scope,query,offset).also {if(reads==3)route=false}},{_,_,_->})
        repo.refine(LibraryQuery(liked=true));val request=repo.claimCollectionPlay(repo.state.value){route}!!
        repo.readCollection(request);repo.startCollection(request){_,_->fail("Retired scan started");null};repo.abandonCollection(request)
        assertEquals(3,reads);assertFalse(repo.state.value.collectionLoading)
    }
    @Test fun malformedProgressOrChangingTotalIsNotCompleteMembership() {
        for(changing in listOf(false,true)) {
            val reader=fetch(corpus())
            val repo=LibraryRepository(session(),{scope,query,offset->reader(scope,query,offset).let {if(offset==20)if(changing)it.copy(total=it.total+1)else it.copy(tracks=emptyList(),scannedIds=emptyList())else it}},{_,_,_->})
            repo.refine(LibraryQuery(collection=LibraryCollection(artist=artist)))
            assertEquals(SafeFailure.Reason.InvalidResponse,repo.state.value.error);assertNull(repo.state.value.total)
        }
    }
    // Each bad scan still has four raw rows and an unchanged total. An omitted raw
    // row models SoundQApi filtering an ineligible row before constructing tracks.
    private fun completenessReader(withinPage:Boolean,kind:Int,bad:()->Boolean,offsets:MutableList<Int>):(AccountScope,LibraryQuery,Int)->LibraryPage = {_,query,offset->
        assertNull(query.collection);offsets+=offset
        val raw=if(bad())if(withinPage)listOf(1L,1L,3L,4L)else listOf(1L,2L,2L,4L)else listOf(1L,2L,3L,4L)
        val repeated=if(withinPage)1L else 2L
        val ids=raw.drop(offset).take(2)
        val tracks=ids.filter {kind!=2||it!=repeated}.map {id->
            val eligible=kind==0||id!=repeated
            Track(TrackId(id),"Track $id",if(eligible)artist else "Other",album,liked=eligible)
        }
        LibraryPage(tracks,4,2,offset,scannedIds=ids)
    }
    private fun repeatedRawBrowse(withinPage:Boolean,kind:Int) {
        var bad=true;val offsets=mutableListOf<Int>()
        val repo=LibraryRepository(session(),completenessReader(withinPage,kind,{bad},offsets),{_,_,_->})
        val query=LibraryQuery(collection=LibraryCollection(artist=artist))
        repo.refine(query)
        assertEquals(SafeFailure.Reason.InvalidResponse,repo.state.value.error)
        assertTrue(repo.state.value.rows.isEmpty());assertNull(repo.state.value.total)
        assertFalse(repo.state.value.loading);assertFalse(repo.state.value.endReached)
        assertEquals(if(withinPage)listOf(0)else listOf(0,2),offsets)
        // Recovery is explicit and starts at zero; there is no automatic retry loop.
        bad=false;offsets.clear();repo.refine(repo.state.value.query)
        val omitted=if(kind==0)null else if(withinPage)1L else 2L
        assertEquals((1L..4L).filter {it!=omitted},repo.state.value.rows.map {it.id.value})
        assertEquals(repo.state.value.rows.size,repo.state.value.total)
        assertEquals(query,repo.state.value.query);assertTrue(repo.state.value.endReached)
        assertFalse(repo.state.value.loading);assertNull(repo.state.value.error)
        assertEquals(listOf(0,2),offsets)
    }
    private fun repeatedRawStart(withinPage:Boolean,kind:Int) {
        for(exact in listOf(false,true))for(shuffle in listOf(false,true)) {
            var bad=false;val offsets=mutableListOf<Int>()
            val repo=LibraryRepository(session(),completenessReader(withinPage,kind,{bad},offsets),{_,_,_->})
            val query=if(exact)LibraryQuery(collection=LibraryCollection(artist=artist))else LibraryQuery(liked=true)
            repo.refine(query);val shown=repo.state.value.rows;val total=repo.state.value.total
            bad=true;offsets.clear()
            val request=repo.claimCollectionPlay(repo.state.value,shuffle=shuffle){true}!!
            repo.readCollection(request)
            var starts=0;repo.startCollection(request){_,_->starts++;null}
            assertEquals("No partial Play/Shuffle transport",0,starts)
            assertEquals(SafeFailure.Reason.InvalidResponse.message,repo.state.value.collectionError)
            assertFalse(repo.state.value.collectionLoading);assertSame(shown,repo.state.value.rows)
            assertEquals(total,repo.state.value.total);assertEquals(query,repo.state.value.query)
            assertEquals(if(withinPage)listOf(0)else listOf(0,2),offsets)
            bad=false;offsets.clear()
            val retry=repo.claimCollectionPlay(repo.state.value,shuffle=shuffle){true}!!
            repo.readCollection(retry)
            val omitted=if(kind==0)null else if(withinPage)1L else 2L
            val expected=(1L..4L).filter {it!=omitted}
            repo.startCollection(retry){tracks,index->
                starts++;assertEquals(0,index)
                assertEquals(expected.toSet(),tracks.map {it.id.value}.toSet());assertEquals(expected.size,tracks.size)
                if(!shuffle)assertEquals(expected,tracks.map {it.id.value})
                null
            }
            assertEquals(1,starts);assertNull(repo.state.value.collectionError)
            assertFalse(repo.state.value.collectionLoading);assertEquals(listOf(0,2),offsets)
        }
    }
    @Test fun repeatedEligibleRawAcrossPagesRejectsBrowseAndExplicitRetryRecovers()=repeatedRawBrowse(false,0)
    @Test fun repeatedEligibleRawWithinPageRejectsBrowseAndExplicitRetryRecovers()=repeatedRawBrowse(true,0)
    @Test fun repeatedLocallyIneligibleRawAcrossPagesRejectsBrowseAndExplicitRetryRecovers()=repeatedRawBrowse(false,1)
    @Test fun repeatedLocallyIneligibleRawWithinPageRejectsBrowseAndExplicitRetryRecovers()=repeatedRawBrowse(true,1)
    @Test fun repeatedParserExcludedRawAcrossPagesRejectsBrowseAndExplicitRetryRecovers()=repeatedRawBrowse(false,2)
    @Test fun repeatedParserExcludedRawWithinPageRejectsBrowseAndExplicitRetryRecovers()=repeatedRawBrowse(true,2)
    @Test fun repeatedEligibleRawAcrossPagesRefusesPlayShuffleAndRetryRecovers()=repeatedRawStart(false,0)
    @Test fun repeatedEligibleRawWithinPageRefusesPlayShuffleAndRetryRecovers()=repeatedRawStart(true,0)
    @Test fun repeatedLocallyIneligibleRawAcrossPagesRefusesPlayShuffleAndRetryRecovers()=repeatedRawStart(false,1)
    @Test fun repeatedLocallyIneligibleRawWithinPageRefusesPlayShuffleAndRetryRecovers()=repeatedRawStart(true,1)
    @Test fun repeatedParserExcludedRawAcrossPagesRefusesPlayShuffleAndRetryRecovers()=repeatedRawStart(false,2)
    @Test fun repeatedParserExcludedRawWithinPageRefusesPlayShuffleAndRetryRecovers()=repeatedRawStart(true,2)
    @Test fun uniqueMixedEligibleAndIneligibleRawPagesPublishAndStartCompleteMembership() {
        val offsets=mutableListOf<Int>()
        val eligible=listOf(1L,4L).map {Track(TrackId(it),"Track $it",artist,album,liked=true)}
        val excluded=Track(TrackId(2),"Other","Other",album,liked=false)
        val repo=LibraryRepository(session(),{_,_,offset->
            offsets+=offset
            if(offset==0)LibraryPage(listOf(eligible[0],excluded),4,2,0,scannedIds=listOf(1,2))
            else LibraryPage(listOf(eligible[1]),4,2,2,scannedIds=listOf(3,4))
        },{_,_,_->})
        repo.refine(LibraryQuery(collection=LibraryCollection(artist=artist)))
        assertEquals(eligible,repo.state.value.rows);assertEquals(2,repo.state.value.total)
        assertTrue(repo.state.value.endReached);assertFalse(repo.state.value.loading);assertNull(repo.state.value.error)
        for(shuffle in listOf(false,true)) {
            val request=repo.claimCollectionPlay(repo.state.value,shuffle=shuffle){true}!!;repo.readCollection(request)
            var calls=0;repo.startCollection(request){tracks,index->calls++;assertEquals(eligible.toSet(),tracks.toSet());assertEquals(2,tracks.size);assertEquals(0,index);null}
            assertEquals(1,calls);assertFalse(repo.state.value.collectionLoading);assertNull(repo.state.value.collectionError)
        }
        assertEquals(listOf(0,2,0,2,0,2),offsets)
    }
    @Test fun queuedRefinementCannotBorrowLaterAccountOrOverrideNewerIntent() {
        val s=session();var reads=0;val repo=LibraryRepository(s,{_,_,offset->reads++;LibraryPage(emptyList(),0,20,offset)},{_,_,_->})
        val old=repo.claimRefinement(LibraryQuery(text="old"))!!
        val newer=repo.claimRefinement(LibraryQuery(text="new"))!!
        repo.executeRefinement(old);assertEquals(0,reads)
        repo.executeRefinement(newer);assertEquals("new",repo.state.value.query.text)
        val retired=repo.claimRefinement(LibraryQuery(text="retired"))!!
        s.accept(s.beginIntent(),SecretTokens("b","r","B"));repo.executeRefinement(retired);assertEquals(1,reads)
    }
}
