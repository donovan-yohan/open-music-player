package com.soundq.android.data

import com.soundq.android.data.catalog.*
import org.junit.Assert.*
import org.junit.Test

class CatalogBrowseTest {
    @Test fun authenticatedTlsSearchArtistAndConcreteAlbumNeverAcquirePlayback() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("synthetic-a","synthetic-r","catalog"))
            val repo=CatalogRepository(SoundQApi(session,f.client));val view=repo.open()!!
            repo.edit(view,"海 & artist");f.reply(CatalogContractTest.search());repo.load(repo.search(view)!!)
            assertFalse(repo.state.value.loading)
            val search=repo.state.value
            val request=repo.artist(view,search,search.search!!.rows.single())!!
            f.reply(CatalogContractTest.artist());repo.load(request)
            assertEquals(CatalogContractTest.G,repo.state.value.artist!!.releases.single().id.value)
            repo.group(view,repo.state.value,repo.state.value.artist!!.releases.single())
            assertEquals(2,f.server.requestCount) // A release-group is NOT a concrete release.
            repo.back(view);repo.back(view)
            f.reply(CatalogContractTest.releases());repo.load(repo.releases(view)!!)
            val releases=repo.state.value
            assertNull(repo.album(view,releases,releases.albums!!.rows.last()))
            f.reply(CatalogContractTest.album());repo.load(repo.album(view,releases,releases.albums!!.rows.first())!!)
            assertEquals(CatalogContractTest.T,repo.state.value.album!!.tracks.single().id.value)
            assertFalse(repo.state.value.loading)
            val requests=(1..4).map {f.server.takeRequest(2,java.util.concurrent.TimeUnit.SECONDS)!!}
            assertEquals(listOf("/api/v1/musicbrainz/search/artists","/api/v1/artists/${CatalogContractTest.A}","/api/v1/search/releases","/api/v1/albums/${CatalogContractTest.R}"),requests.map {it.url.encodedPath})
            assertEquals("海 & artist",requests[0].url.queryParameter("q"))
            assertTrue(requests.all {it.method=="GET" && it.headers["Authorization"]!=null})
            repo.back(view);assertNull(repo.state.value.album);assertNotNull(repo.state.value.albums)
        }
    }
}
