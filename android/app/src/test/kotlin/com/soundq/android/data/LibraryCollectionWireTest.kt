package com.soundq.android.data

import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class LibraryCollectionWireTest {
    @Test fun exactMetadataNeverEntersFuzzyQueryAndLaterPagesAreParsedBeforeSelection() {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("a","r","A"))}
            val artist=""" A%_+ & ? # / \\"東京 """;val album="100%_+ [Live]"
            val api=SoundQApi(session,f.client);val repo=LibraryRepository(session,api::library,api::like)
            fun page(offset:Int)=buildJsonObject {
                put("total",45);put("limit",20);put("offset",offset)
                putJsonArray("tracks") {for(id in offset+1..minOf(offset+20,45))addJsonObject {
                    put("id",id);put("title","Same title");put("artist",if(id==1||id>=41)artist else "Other")
                    put("album",album);put("is_liked",true)
                }}
            }.toString()
            for(offset in listOf(0,20,40))f.reply(page(offset))
            repo.refine(LibraryQuery(sort=LibrarySort.Artist,ascending=true,collection=LibraryCollection(artist,album)))
            assertEquals(listOf(1L,41L,42L,43L,44L,45L),repo.state.value.rows.map {it.id.value})
            assertEquals(6,repo.state.value.total)
            for(offset in listOf(0,20,40)) {
                val request=f.server.takeRequest(2,TimeUnit.SECONDS)!!
                assertEquals("GET",request.method);assertEquals("Bearer a",request.headers["Authorization"])
                assertNull(request.url.queryParameter("q"));assertNull(request.url.queryParameter("artist"));assertNull(request.url.queryParameter("album"))
                assertEquals(offset.toString(),request.url.queryParameter("offset"));assertEquals("artist",request.url.queryParameter("sort"));assertEquals("asc",request.url.queryParameter("order"))
            }
            for(offset in listOf(0,20,40))f.reply(page(offset))
            val request=repo.claimCollectionPlay(repo.state.value,selected=TrackId(44)){true}!!;repo.readCollection(request)
            repo.startCollection(request){tracks,index->assertEquals(6,tracks.size);assertEquals(4,index);assertEquals(TrackId(44),tracks[index].id);null}
            assertEquals(6,f.server.requestCount)
        }
    }
}
