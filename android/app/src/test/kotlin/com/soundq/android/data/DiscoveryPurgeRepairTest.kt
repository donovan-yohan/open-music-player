package com.soundq.android.data

import com.soundq.android.data.discovery.*
import com.soundq.android.data.imports.*
import org.junit.Assert.*
import org.junit.Test

class DiscoveryPurgeRepairTest {
    @Test fun knownDecisionSurvivesOmittedPurgedSessionAndRetainsOriginalCorrelation() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
            val api=SoundQApi(session,f.client);val library=LibraryRepository(session,api::library,api::like)
            val imports=ImportRepository(session,api,library);val discovery=DiscoveryRepository(session,api)
            val route=discovery.open()!!;val view=imports.open()!!
            discovery.edit(route,"海 & music");f.reply(DiscoveryBoundaryTest.search());discovery.search(route,discovery.state.value.draft)
            val choice=discovery.inspect(route,discovery.state.value.results!!.rows.single())!!
            f.reply(DiscoveryOwnershipTest.decision(),201);f.reply("{}",500);imports.submit(imports.claimSource(view,choice)!!)
            f.reply(purged());f.reply(DiscoveryPublicationRepairTest.job());imports.recoverSource(view,imports.state.value.sourceReceipt!!)
            assertEquals("exact acknowledged decision remains readable after canonical session purge",SourceImportPhase.Accepted,imports.state.value.sourceReceipt!!.phase)
            assertEquals("123e4567-e89b-12d3-a456-426614174010",imports.state.value.sourceReceipt!!.decision!!.sessionId)
            assertEquals(5,f.server.requestCount)
        }
    }
    @Test fun knownReadRejectsWrongDecisionCandidateActionAndConflictingPresentSession() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))};val api=SoundQApi(session,f.client)
            val known=SourceDecision("123e4567-e89b-12d3-a456-426614174020","123e4567-e89b-12d3-a456-426614174010","candidate-1",null)
            for(body in listOf(purged().replace("174020","174021"),purged().replace("candidate-1","candidate-2"),purged().replace("\"selected\"","\"rejected\""),DiscoveryOwnershipTest.decision().replace("174010","174011"))) {
                f.reply(body);assertEquals(SafeFailure.Reason.InvalidResponse,(runCatching {api.sourceDecision(session.capture()!!,known){true}}.exceptionOrNull() as SafeFailure).reason)
            }
            assertEquals(4,f.server.requestCount)
        }
    }
    @Test fun unknownDecisionCannotCorrelatePurgedSessionAndCreateStillRequiresSession() {
        HttpsFixture().use {f ->
            val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))};val api=SoundQApi(session,f.client)
            val repository=DiscoveryRepository(session,api);val route=repository.open()!!
            repository.edit(route,"海 & music");f.reply(DiscoveryBoundaryTest.search());repository.search(route,repository.state.value.draft)
            val choice=repository.inspect(route,repository.state.value.results!!.rows.single())!!
            f.reply("""{"items":[${purged()}],"limit":100,"offset":0}""")
            assertNull(api.findSourceDecision(session.capture()!!,choice){true})
            f.reply(purged(),201)
            assertEquals(SafeFailure.Reason.InvalidResponse,(runCatching {api.createSourceDecision(session.capture()!!,choice,{true},{true})}.exceptionOrNull() as SafeFailure).reason)
            assertEquals(3,f.server.requestCount)
        }
    }
    companion object {fun purged()=DiscoveryOwnershipTest.decision(",\"downloadJobId\":\"123e4567-e89b-12d3-a456-426614174071\"").replace("\"sessionId\":\"123e4567-e89b-12d3-a456-426614174010\",","")}
}
