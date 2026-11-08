package com.soundq.android.data

import com.soundq.android.data.acquisition.*
import com.soundq.android.data.imports.ImportJobId
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

/** Existing D06 capabilities qualified through the actual authenticated transport, not reimplemented. */
class ImportControlsContractTest {
    private val id="123e4567-e89b-12d3-a456-426614174001"
    private fun queue()="""{"items":[{"queueItemId":"$id","position":0,"playbackState":"failed","progress":0,"canRetry":true,"canRemove":true},{"queueItemId":"second","position":1,"playbackState":"queued","progress":0,"canRetry":false,"canRemove":true}],"currentPosition":0,"updatedAt":"2026-10-29T00:00:00Z"}"""
    @Test fun retryReorderRemoveAndClearUseOnlyServerImportContractsAndRejectRetiredSnapshots() {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
            val api=SoundQApi(session,f.client);val repo=AcquisitionRepository(session,api);val view=repo.open()!!
            f.reply(queue());repo.loadQueue(view)!!()
            val stale=repo.state.value.queue!!
            for(operation in listOf("retry","reorder","remove","clear")) {
                val snapshot=repo.state.value.queue!!
                f.reply(queue())
                val work=repo.manageQueue(view,snapshot,operation,if(operation=="clear")null else snapshot.items.first(),if(operation=="reorder")1 else null)!!
                work();work()
                assertNull(repo.state.value.error)
                assertNull(repo.manageQueue(view,stale,"retry",stale.items.first()))
            }
            val requests=(1..5).map {f.server.takeRequest(3,TimeUnit.SECONDS)!!}
            assertEquals(listOf("GET","POST","PUT","DELETE","DELETE"),requests.map {it.method})
            assertEquals(listOf("/api/v1/queue","/api/v1/queue/items/$id/retry","/api/v1/queue/reorder","/api/v1/queue/items/$id","/api/v1/queue"),requests.map {it.url.encodedPath})
            val reorder=Json.parseToJsonElement(requests[2].body!!.utf8()).jsonObject
            assertEquals(id,reorder["queueItemId"]?.jsonPrimitive?.content)
            assertEquals(1,reorder["toPosition"]?.jsonPrimitive?.int)
            assertFalse(repo.state.value.uncertain)
            assertEquals(5,f.server.requestCount)
        }
    }
    @Test fun playlistDescriptionChosenLimitPartialCountsAndExplicitOpenKeepTheirExactIdentity() {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
            val api=SoundQApi(session,f.client);val repo=AcquisitionRepository(session,api);val view=repo.open()!!
            // Extend the retained real-producer response with the other declared item states.
            val original=Json.parseToJsonElement(javaClass.getResource("/acquisition/playlist-omitted-title.json")!!.readText()).jsonObject
            val failed=original.getValue("items").jsonArray.single().jsonObject
            val imported=JsonObject(failed+mapOf("id" to JsonPrimitive(9),"status" to JsonPrimitive("imported"),"trackId" to JsonPrimitive(71)))
            val skipped=JsonObject(failed+mapOf("id" to JsonPrimitive(10),"status" to JsonPrimitive("skipped_duplicate")))
            val body=JsonObject(original+mapOf("playlistId" to JsonPrimitive(41),"maxItems" to JsonPrimitive(37),"totalItems" to JsonPrimitive(3),"importedItems" to JsonPrimitive(1),"failedItems" to JsonPrimitive(1),"skippedItems" to JsonPrimitive(1),"items" to JsonArray(listOf(imported,failed,skipped))))
            f.reply(body.toString(),202)
            repo.startPlaylist(view,"https://youtube.com/playlist?list=PLfixture","Selected name",37,"海辺の曲\nSecond line")!!()
            val request=f.server.takeRequest(3,TimeUnit.SECONDS)!!
            val payload=Json.parseToJsonElement(request.body!!.utf8()).jsonObject
            assertEquals(37,payload["maxItems"]?.jsonPrimitive?.int)
            assertEquals("海辺の曲\nSecond line",payload["description"]?.jsonPrimitive?.content)
            assertEquals("Selected name",payload["name"]?.jsonPrimitive?.content)
            val snapshot=repo.state.value.playlist!!
            assertEquals("partial_failure",snapshot.status)
            assertEquals(listOf(1,1,1),listOf(snapshot.imported,snapshot.failed,snapshot.skipped))
            var opened:Long?=null
            assertTrue(repo.openPlaylist(view,snapshot){opened=it});assertEquals(41L,opened)
            repo.close(view)
            assertFalse(repo.openPlaylist(view,snapshot){error("stale playlist navigation")})
            assertEquals(1,f.server.requestCount)
        }
    }
}
