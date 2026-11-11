package com.soundq.android.data

import com.soundq.android.data.discovery.*
import com.soundq.android.data.catalog.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class DiscoverCatalogContinuationTest {
    @Test fun qualifiedArtistToExplicitEditionAndRecordingReturnsToSameDiscoverPage() {
        HttpsFixture().use { f ->
            val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r",CatalogContractTest.A))}
            val api=SoundQApi(session,f.client);val discovery=DiscoveryRepository(session,api);val view=discovery.open()!!
            f.reply(grouped());discovery.edit(view,"seed");discovery.search(view,discovery.state.value.draft)
            val page=discovery.state.value.results!!;val draft=discovery.state.value.draft
            val details=discovery.details(view,page.entities.first())!!
            val catalog=CatalogRepository(api);val actions=CatalogActions(catalog){it()}
            f.reply(CatalogContractTest.artist());assertTrue(actions.discover(details))
            val artist=catalog.state.value
            actions.group(artist,artist.artist!!.releases.single())
            assertEquals(CatalogContractTest.G,catalog.state.value.group!!.id.value)
            assertEquals(2,f.server.requestCount) // group IDs never enter /albums
            f.reply(CatalogContractTest.releases());actions.groupEditions(catalog.state.value)
            assertNull(catalog.state.value.group)
            val editions=catalog.state.value
            f.reply(CatalogContractTest.album());actions.album(editions,editions.albums!!.rows.first())
            val album=catalog.state.value
            f.reply("""{"recordingMbid":"${CatalogContractTest.T}","userId":"${CatalogContractTest.A}","status":"missing","candidates":[],"limit":20,"truncated":false}""")
            actions.recording(album,album.album!!.tracks.single(),0)
            assertEquals("missing",catalog.state.value.inspection!!.result!!.status)
            actions.dismissRecording(catalog.state.value.inspection!!)
            assertTrue(actions.back());assertSame(editions.albums,catalog.state.value.albums)
            assertTrue(actions.back());assertEquals(CatalogContractTest.G,catalog.state.value.group!!.id.value)
            actions.close()
            assertSame(page,discovery.state.value.results);assertSame(draft,discovery.state.value.draft)
            assertTrue(details.valid())
            val requests=(1..5).map {f.server.takeRequest()}
            assertEquals(listOf("/api/v1/discovery/search","/api/v1/artists/${CatalogContractTest.A}","/api/v1/search/releases","/api/v1/albums/${CatalogContractTest.R}","/api/v1/catalog/recordings/${CatalogContractTest.T}/resolution"),requests.map {it.url.encodedPath})
            assertTrue(requests.all {it.method=="GET"})
            discovery.edit(view,"replacement")
            assertFalse(details.valid())
            val fresh=CatalogActions(catalog){it()};assertFalse(fresh.discover(details));fresh.close()
            assertEquals(5,f.server.requestCount)
        }
    }
    @Test fun groupedAlbumIsAReleaseGroupAndMalformedIdentityOnlyAllowsRefinement() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
            val api=SoundQApi(session,f.client);val discovery=DiscoveryRepository(session,api);val view=discovery.open()!!
            f.reply(grouped());discovery.edit(view,"seed");discovery.search(view,discovery.state.value.draft)
            val entity=discovery.state.value.results!!.entities.last();val details=discovery.details(view,entity)!!
            val catalog=CatalogRepository(api);val actions=CatalogActions(catalog){it()}
            assertTrue(actions.discover(details));assertEquals(CatalogContractTest.G,catalog.state.value.group!!.id.value)
            assertNull(catalog.state.value.album);assertEquals(1,f.server.requestCount)
            actions.close()
            discovery.refine(view,entity);assertFalse(details.valid())
            assertTrue(discovery.back(view));assertFalse("Returning to the same page must not revive a retired Details capability",details.valid())
            discovery.edit(view,"seed");f.reply(DiscoveryGroupedJourneyTest.grouped());discovery.search(view,discovery.state.value.draft)
            val malformed=discovery.state.value.results!!.entities.first()
            assertNull(discovery.details(view,malformed));assertEquals("Exact Artist",discovery.refine(view,malformed)!!.text)
        }
    }
    @Test fun queuedCatalogReadCannotOutliveOriginatingPageAndFreshDetailsStillWork() {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
            val api=SoundQApi(session,f.client);val discovery=DiscoveryRepository(session,api);val view=discovery.open()!!
            f.reply(grouped());discovery.edit(view,"seed");discovery.search(view,discovery.state.value.draft)
            val entity=discovery.state.value.results!!.entities.first();val details=discovery.details(view,entity)!!
            val catalog=CatalogRepository(api);val jobs=mutableListOf<()->Unit>();val actions=CatalogActions(catalog){jobs.add(it)}
            assertTrue(actions.discover(details));assertEquals(1,jobs.size)
            discovery.refine(view,entity);jobs.removeAt(0)()
            assertEquals(1,f.server.requestCount);assertNull(catalog.state.value.artist)
            assertTrue(discovery.back(view));assertFalse(details.valid())
            actions.close()
            val fresh=CatalogActions(catalog){jobs.add(it)}
            val renewed=discovery.details(view,entity)!!
            f.reply(CatalogContractTest.artist());assertTrue(fresh.discover(renewed));jobs.removeAt(0)()
            assertEquals(CatalogContractTest.A,catalog.state.value.artist!!.row.id.value)
            assertEquals(2,f.server.requestCount);fresh.close()
        }
    }
    @Test fun recentSubmittedQueriesAreBoundedDeduplicatedAndScopedNotDraftKeystrokes() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
            val repo=DiscoveryRepository(session,SoundQApi(session,f.client));val view=repo.open()!!
            repo.edit(view,"not submitted");assertTrue(repo.state.value.recent.isEmpty())
            for(q in listOf(" seed ","Other","SEED")) {
                repo.edit(view,q);f.reply(DiscoveryBoundaryTest.search(q.trim()));repo.search(view,repo.state.value.draft)
            }
            assertEquals(listOf("SEED","Other"),repo.state.value.recent)
            repo.edit(view,"");repo.close(view)
            val reopened=repo.open()!!;assertEquals(listOf("SEED","Other"),repo.state.value.recent)
            val recent=repo.recent(reopened,"Other")!!;assertEquals("Other",recent.text)
            repo.clearRecent(reopened);assertTrue(repo.state.value.recent.isEmpty())
            assertNull(repo.recent(reopened,"Other"));repo.clearRecent(view)
            session.accept(session.beginIntent(),SecretTokens("b","rr","B"));repo.open()
            assertTrue(repo.state.value.recent.isEmpty());assertEquals(3,f.server.requestCount)
        }
    }
    companion object {
        fun grouped()=DiscoveryGroupedJourneyTest.grouped().replace("artist-mbid",CatalogContractTest.A).replace("album-mbid",CatalogContractTest.G)
    }
}
