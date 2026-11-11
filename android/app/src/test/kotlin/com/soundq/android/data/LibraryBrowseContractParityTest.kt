package com.soundq.android.data

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

/** Actual TLS/API/repository consuming path. Server fixtures are synthetic and account scoped. */
class LibraryBrowseContractParityTest {
    private fun page(offset:Int)= """{"tracks":[${(offset+1..minOf(offset+20,42)).joinToString(",") {id->"""{"id":$id,"title":"Song $id","artist":"Artist","is_liked":true,"duration_ms":12000}"""}}],"total":42,"limit":20,"offset":$offset}"""
    @Test fun fullServerRefinementKeepsEncodedQueryAndExactLaterPageRecoverySelection() {
        HttpsFixture().use {f->
            val s=AccountSession(f.endpoint,MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("a","r","A"))}
            val api=SoundQApi(s,f.client);var mutations=0
            val repo=LibraryRepository(s,api::library){_,_,_->mutations++}
            val query=LibraryQuery(text="100%_ + & 夜",sort=LibrarySort.Artist,ascending=true,liked=true,verified=false,genre="R&B + Soul")
            f.reply(page(0));repo.refine(query)
            f.reply("{}",503);repo.loadMore()
            val failed=repo.state.value;assertEquals(20,failed.rows.size);assertTrue(failed.failedAppend)
            f.reply(page(20));repo.executeNextPage(repo.claimPageRetry(failed){true}!!)
            val state=repo.state.value;assertEquals(query,state.query);assertEquals((1L..40L).toList(),state.rows.map {it.id.value})
            var selected=-1
            repo.playAction(state.rows,37){tracks,index->assertSame(state.rows,tracks);assertEquals(38L,tracks[index].id.value);selected=index}()
            assertEquals(37,selected)
            val requests=(1..3).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            assertEquals(listOf("0","20","20"),requests.map {it.url.queryParameter("offset")})
            for(request in requests) {
                assertEquals("GET",request.method);assertEquals("Bearer a",request.headers["Authorization"])
                assertEquals(query.text,request.url.queryParameter("q"));assertEquals("artist",request.url.queryParameter("sort"))
                assertEquals("asc",request.url.queryParameter("order"));assertEquals("true",request.url.queryParameter("liked"))
                assertEquals("false",request.url.queryParameter("mb_verified"));assertEquals(query.genre,request.url.queryParameter("genre"))
            }
            assertEquals(0,mutations);assertEquals(3,f.server.requestCount)
        }
    }
}
