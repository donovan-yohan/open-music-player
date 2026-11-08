package com.soundq.android.data

import com.soundq.android.data.discovery.*
import org.junit.Assert.*
import org.junit.Test

class DiscoveryOwnershipTest {
    @Test fun explicitCapturedImportSavesOneDecisionQueuesOneJobAndUsesExistingReadbackOwner() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val library=LibraryRepository(session,api::library,api::like)
            val imports=com.soundq.android.data.imports.ImportRepository(session,api,library)
            val repository=DiscoveryRepository(session,api);val route=repository.open()!!
            repository.edit(route,"海 & music");f.reply(DiscoveryBoundaryTest.search());repository.search(route,repository.state.value.draft)
            val choice=repository.inspect(route,repository.state.value.results!!.rows.single())!!
            val view=imports.open()!!;val submit=imports.claimSource(view,choice)
            assertNotNull("explicit import must claim captured server selection in existing intake owner",submit)
            f.reply(decision(),201);f.reply("""{"queue":{"items":[]},"downloadJobId":"123e4567-e89b-12d3-a456-426614174071","idempotent":false}""",202)
            imports.submit(submit!!);imports.submit(submit)
            assertEquals("123e4567-e89b-12d3-a456-426614174071",imports.state.value.acknowledgement?.id?.value)
            assertNull(imports.claimSource(view,choice));assertTrue(library.state.value.rows.isEmpty())
            val requests=(1..3).map {f.server.takeRequest(2,java.util.concurrent.TimeUnit.SECONDS)!!}
            assertEquals(listOf("/api/v1/discovery/search","/api/v1/source-selections","/api/v1/queue/items"),requests.map {it.url.encodedPath})
            val payload=kotlinx.serialization.json.Json.parseToJsonElement(requests[1].body!!.utf8()).toString()
            assertTrue(payload.contains("candidate-1"));assertFalse(payload.contains("sourceUrl"));assertEquals(3,f.server.requestCount)
            f.reply("""{"job_id":"123e4567-e89b-12d3-a456-426614174071","status":"complete","progress":100,"track_id":71,"source_type":"youtube","created_at":"2026-10-29T00:00:00Z"}""")
            imports.check(view);assertEquals(TrackId(71),imports.state.value.selected?.track)
            f.reply("""{"tracks":[{"id":71,"title":"Acknowledged source Library row","is_liked":false}],"total":1,"limit":20,"offset":0}""")
            assertTrue(imports.openLibrary(view));assertEquals(TrackId(71),library.state.value.rows.single().id)
            assertEquals(5,f.server.requestCount)
        }
    }
    companion object {
        fun decision(job:String="")="""{"id":"123e4567-e89b-12d3-a456-426614174020","sessionId":"123e4567-e89b-12d3-a456-426614174010","selectedCandidateId":"candidate-1","action":"selected","origin":"discovery_search","selectedCandidate":${DiscoveryBoundaryTest.candidate()}$job}"""
    }
    @Test fun editingDoesNotSearchAndExplicitSearchCapturesOnlyAcknowledgedResult() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val repository=DiscoveryRepository(session,SoundQApi(session,f.client));val view=repository.open()!!
            repository.edit(view,"海 & music");assertEquals(0,f.server.requestCount)
            f.reply(DiscoveryBoundaryTest.search());repository.search(view,repository.state.value.draft)
            assertEquals("explicit Search must publish acknowledged source rows",DiscoveryPhase.Ready,repository.state.value.phase)
            val row=repository.state.value.results!!.rows.single();val captured=repository.inspect(view,row)
            assertNotNull(captured);assertSame(row,captured!!.candidate)
            assertEquals(1,f.server.requestCount)
        }
    }
}
