package com.soundq.android.data

import com.soundq.android.data.discovery.*
import com.soundq.android.data.imports.*
import org.junit.Assert.*
import org.junit.Test

class SourceImportSessionReadinessTest {
    @Test fun acceptedSelectionCannotOpenAnotherDeadConfirmation()=terminalSelectionNeedsFreshSearch(true)
    @Test fun refusedSelectionCannotOpenAnotherDeadConfirmation()=terminalSelectionNeedsFreshSearch(false)

    private fun terminalSelectionNeedsFreshSearch(accepted:Boolean) {
        HttpsFixture().use {fixture->
            val session=AccountSession(fixture.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
            val api=SoundQApi(session,fixture.client)
            val imports=ImportRepository(session,api,LibraryRepository(session,api::library,api::like))
            val discovery=DiscoveryRepository(session,api)
            val route=discovery.open()!!
            discovery.edit(route,"海 & music")
            fixture.reply(DiscoveryBoundaryTest.search())
            discovery.search(route,discovery.state.value.draft)
            val first=discovery.inspect(route,discovery.state.value.results!!.rows.single())!!
            val view=imports.open()!!
            val submission=imports.claimSource(view,first)!!
            if(accepted) {
                fixture.reply(DiscoveryOwnershipTest.decision(),201)
                fixture.reply("""{"queue":{"items":[]},"downloadJobId":"123e4567-e89b-12d3-a456-426614174071","idempotent":false}""",202)
            } else fixture.reply("""{"code":"VALIDATION_ERROR","message":"Synthetic refusal"}""",400)
            imports.submit(submission)
            assertEquals(if(accepted)SourceImportPhase.Accepted else SourceImportPhase.DecisionRefused,imports.state.value.sourceReceipt?.phase)
            discovery.dismiss(route,first)
            val sameSession=discovery.inspect(route,discovery.state.value.results!!.rows.single())!!
            assertNotSame(first,sameSession)
            assertFalse(sameSession.consumed)
            imports.another(view)
            val before=fixture.server.requestCount
            assertFalse("A consumed search must refuse before showing confirmation",imports.prepareSource(view,sameSession))
            assertNull(imports.state.value.sourcePlan)
            assertNull(imports.claimSource(view,sameSession))
            assertEquals(before,fixture.server.requestCount)
            val freshSession="123e4567-e89b-12d3-a456-426614174099"
            discovery.dismiss(route,sameSession)
            fixture.reply(DiscoveryBoundaryTest.search().replace("123e4567-e89b-12d3-a456-426614174010",freshSession))
            discovery.search(route,discovery.state.value.draft)
            val fresh=discovery.inspect(route,discovery.state.value.results!!.rows.single())!!
            assertEquals(freshSession,fresh.selection.id)
            assertTrue(imports.prepareSource(view,fresh))
            assertNotNull(imports.claimPlannedSource(view,imports.state.value.sourcePlan!!))
            assertNull(imports.claimSource(view,fresh))
        }
    }
}
