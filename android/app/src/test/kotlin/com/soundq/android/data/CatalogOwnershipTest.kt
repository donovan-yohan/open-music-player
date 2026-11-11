package com.soundq.android.data

import com.soundq.android.data.catalog.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*

class CatalogOwnershipTest {
    private fun signed(f:HttpsFixture)=AccountSession(f.endpoint,MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("synthetic-a","synthetic-r","catalog"))}
    @Test fun queuedReadsAndRetainedRowsAreRevokedBeforeDispatch() {
        HttpsFixture().use {f ->
            val session=signed(f);val repo=CatalogRepository(SoundQApi(session,f.client));val view=repo.open()!!
            repo.edit(view,"first");val queued=repo.search(view)!!;repo.close(view);repo.load(queued)
            assertEquals(0,f.server.requestCount);assertFalse(repo.state.value.loading)
            val fresh=repo.open()!!;repo.edit(fresh,"new");f.reply(CatalogContractTest.search());repo.load(repo.search(fresh)!!)
            val acknowledged=repo.state.value;val row=acknowledged.search!!.rows.single()
            repo.edit(fresh,"changed");assertNull(repo.artist(fresh,acknowledged,row))
            assertNull(repo.search(view));assertEquals(1,f.server.requestCount)
        }
    }
    @Test fun heldOldQueryDetailSameIdBackLogoutAndEndpointCannotPublishOrStrandLoading() {
        for(mode in listOf("query","detail","same-id","back","logout","endpoint","close-reopen")) HttpsFixture().use {f ->
            val session=signed(f);val repo=CatalogRepository(SoundQApi(session,f.client));val view=repo.open()!!
            repo.edit(view,"old");f.reply(CatalogContractTest.search());repo.load(repo.search(view)!!)
            f.server.takeRequest(2,TimeUnit.SECONDS)!!
            val accepted=repo.state.value
            val request=if(mode=="query")repo.search(view)!! else repo.artist(view,accepted,accepted.search!!.rows.single())!!
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(r:RecordedRequest):MockResponse {
                entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().body(if(r.url.encodedPath.endsWith("/search/artists"))CatalogContractTest.search() else CatalogContractTest.artist()).build()
            }}
            try {
                val old=pool.submit {repo.load(request)};assertTrue(mode,entered.await(3,TimeUnit.SECONDS))
                when(mode){
                    "query"->repo.edit(view,"replacement")
                    "detail","back"->repo.back(view)
                    "same-id"->{repo.back(view);val now=repo.state.value;repo.artist(view,now,now.search!!.rows.single())}
                    "logout"->session.revoke()
                    "endpoint"->{val foreign=AccountSession(ApiEndpoint.parse("https://different.invalid/api/v1"),MemoryStore());foreign.accept(foreign.beginIntent(),SecretTokens("a","r","catalog"));assertFailsRetired {SoundQApi(foreign,f.client).catalogArtist(view.scope,ArtistMbid(CatalogContractTest.A)){true}};repo.close(view)}
                    "close-reopen"->{repo.close(view);repo.open()}
                }
                release.countDown();old.get(5,TimeUnit.SECONDS)
                assertNull(mode,repo.state.value.artist)
                if(mode=="same-id") {assertTrue(repo.state.value.loading);repo.back(view)}
                assertFalse(mode,repo.state.value.loading)
                // Fresh same-account reopen remains useful after every retirement schedule.
                if(session.capture()==null)session.accept(session.beginIntent(),SecretTokens("b","r2","catalog"))
                val fresh=repo.open()!!;repo.edit(fresh,"fresh");repo.load(repo.search(fresh)!!)
                assertNotNull(mode,repo.state.value.search)
                assertFalse(mode,repo.state.value.loading)
            } finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun missingMalformedRefusedAndSuccessAreSeparateTerminalStates() {
        HttpsFixture().use {f ->
            val repo=CatalogRepository(SoundQApi(signed(f),f.client));val view=repo.open()!!
            for((body,code) in listOf("{}" to 404,"{bad" to 200,"{\"message\":\"must not echo\"}" to 503,CatalogContractTest.search() to 200)) {
                repo.edit(view,"artist");f.reply(body,code);repo.load(repo.search(view)!!)
                assertFalse(repo.state.value.loading)
                when(code){404->{assertTrue(repo.state.value.missing);assertNull(repo.state.value.error)}
                    503->assertEquals(SafeFailure.Reason.Refused,repo.state.value.error)
                    else->if(body=="{bad")assertEquals(SafeFailure.Reason.InvalidResponse,repo.state.value.error) else assertNotNull(repo.state.value.search)}
            }
        }
    }
    private fun assertFailsRetired(block:()->Unit) {assertEquals(SafeFailure.Reason.Retired,(runCatching(block).exceptionOrNull() as SafeFailure).reason)}
}
