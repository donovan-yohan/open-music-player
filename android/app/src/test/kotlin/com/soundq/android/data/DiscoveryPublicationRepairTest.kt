package com.soundq.android.data

import com.soundq.android.data.discovery.*
import com.soundq.android.data.imports.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit

class DiscoveryPublicationRepairTest {
    @Test fun sqlAttachmentWithoutRedisJobRetainsSameDecisionPublicationRetry() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
            val api=SoundQApi(session,f.client);val library=LibraryRepository(session,api::library,api::like)
            val imports=ImportRepository(session,api,library);val discover=DiscoveryRepository(session,api)
            val route=discover.open()!!;val view=imports.open()!!
            discover.edit(route,"海 & music");f.reply(DiscoveryBoundaryTest.search());discover.search(route,discover.state.value.draft)
            val choice=discover.inspect(route,discover.state.value.results!!.rows.single())!!
            val post=imports.claimSource(view,choice)!!
            f.reply(DiscoveryOwnershipTest.decision(),201);f.reply("{}",500);imports.submit(post)
            assertEquals(SourceImportPhase.QueueUncertain,imports.state.value.sourceReceipt!!.phase)
            f.reply(DiscoveryOwnershipTest.decision(",\"downloadJobId\":\"123e4567-e89b-12d3-a456-426614174071\""));f.reply("{}",404)
            imports.recoverSource(view,imports.state.value.sourceReceipt!!)
            assertNull("SQL attachment is not published job acceptance",imports.state.value.acknowledgement)
            assertNotEquals(SourceImportPhase.Accepted,imports.state.value.sourceReceipt!!.phase)
            assertNotNull(imports.state.value.sourceReceipt!!.decision)
            imports.another(view);assertTrue(imports.state.value.consumed)
            assertEquals(5,f.server.requestCount)
            f.reply("""{"queue":{"items":[]},"downloadJobId":"123e4567-e89b-12d3-a456-426614174071","idempotent":true}""",200)
            imports.retrySource(view,imports.state.value.sourceReceipt!!);imports.submit(post)
            assertEquals(SourceImportPhase.Accepted,imports.state.value.sourceReceipt!!.phase)
            f.reply(job());imports.check(view)
            f.reply("""{"tracks":[{"id":71,"title":"Published source","is_liked":false}],"total":1,"limit":20,"offset":0}""")
            assertTrue(imports.openLibrary(view));assertEquals(TrackId(71),library.state.value.rows.single().id)
            val requests=(1..8).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            assertEquals(1,requests.count {it.method=="POST"&&it.url.encodedPath=="/api/v1/source-selections"})
            val queues=requests.filter {it.method=="POST"&&it.url.encodedPath=="/api/v1/queue/items"}
            assertEquals(2,queues.size)
            for(request in queues)assertEquals("123e4567-e89b-12d3-a456-426614174020",Json.parseToJsonElement(request.body!!.utf8()).jsonObject.getValue("sourceDecisionId").jsonPrimitive.content)
            assertEquals(8,f.server.requestCount)
        }
    }
    companion object {
        fun job()="""{"job_id":"123e4567-e89b-12d3-a456-426614174071","status":"complete","progress":100,"track_id":71,"source_type":"youtube","created_at":"2026-10-29T00:00:00Z"}"""
    }
}
