package com.soundq.android.data

import com.soundq.android.data.discovery.*
import com.soundq.android.data.imports.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*

/** The generated harness compiles verbatim ProductApp root action bodies, not a manual close. */
class DiscoveryRootAdmissionRepairTest {
    @Test fun rootNavigationRefusesFirstPostBeforeChildDisposal()=firstPost(false)
    @Test fun rootOpenImportsRefusesFirstPostBeforeChildDisposal()=firstPost(true)
    @Test fun rootNavigationRetainsEnteredDecisionButRefusesSecondPostBeforeChildDisposal()=secondPost(false)
    @Test fun rootOpenImportsRetainsEnteredDecisionButRefusesSecondPostBeforeChildDisposal()=secondPost(true)
    private fun firstPost(openImports:Boolean) {
        HttpsFixture().use {f ->
            val r=Rig(f);val post=r.imports.claimSource(r.view,r.choice)!!
            val mounted=ExtractedDiscoveryRootActions(r.discovery,r.route,r.imports,r.view)
            f.reply(DiscoveryOwnershipTest.decision(),201)
            f.reply("""{"queue":{"items":[]},"downloadJobId":"123e4567-e89b-12d3-a456-426614174071","idempotent":false}""",202)
            if(openImports)mounted.openImports() else mounted.navigate("Library")
            // No child disposal has run; the old callback and request are deliberately retained.
            r.imports.submit(post)
            assertEquals("accepted root exit must revoke first POST synchronously",1,f.server.requestCount)
            assertFalse(r.choice.valid());assertFalse(r.imports.state.value.pending)
            assertEquals(SourceImportPhase.DecisionRefused,r.imports.state.value.sourceReceipt!!.phase)
            mounted.disposeChild();assertFalse(r.choice.valid())
            if(openImports)assertTrue(r.imports.current(mounted.importView!!))
        }
    }
    private fun secondPost(openImports:Boolean) {
        HttpsFixture().use {f ->
            val r=Rig(f);val post=r.imports.claimSource(r.view,r.choice)!!
            val mounted=ExtractedDiscoveryRootActions(r.discovery,r.route,r.imports,r.view)
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {
                if(request.url.encodedPath=="/api/v1/source-selections") {entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().code(201).body(DiscoveryOwnershipTest.decision()).build()}
                return MockResponse.Builder().code(202).body("""{"queue":{"items":[]},"downloadJobId":"123e4567-e89b-12d3-a456-426614174071","idempotent":false}""").build()
            }}
            try {
                val work=pool.submit {r.imports.submit(post)};assertTrue(entered.await(3,TimeUnit.SECONDS))
                if(openImports)mounted.openImports() else mounted.navigate("Library")
                release.countDown();work.get(5,TimeUnit.SECONDS)
                assertEquals("entered decision evidence survives, but root exit cannot grant a new queue POST",2,f.server.requestCount)
                assertEquals("123e4567-e89b-12d3-a456-426614174020",r.imports.state.value.sourceReceipt!!.decision!!.id)
                assertEquals(SourceImportPhase.QueueRefused,r.imports.state.value.sourceReceipt!!.phase)
                assertNull(r.imports.state.value.acknowledgement);mounted.disposeChild()
            }finally {release.countDown();pool.shutdownNow()}
        }
    }
    private class Rig(val f:HttpsFixture) {
        val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
        val api=SoundQApi(session,f.client);val library=LibraryRepository(session,api::library,api::like)
        val imports=ImportRepository(session,api,library);val discovery=DiscoveryRepository(session,api)
        val route=discovery.open()!!;val view=imports.open()!!
        val choice:SourceChoice
        init {discovery.edit(route,"海 & music");f.reply(DiscoveryBoundaryTest.search());discovery.search(route,discovery.state.value.draft);choice=discovery.inspect(route,discovery.state.value.results!!.rows.single())!!}
    }
}
