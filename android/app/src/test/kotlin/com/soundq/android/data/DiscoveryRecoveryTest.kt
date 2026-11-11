package com.soundq.android.data

import com.soundq.android.data.discovery.*
import com.soundq.android.data.imports.*
import mockwebserver3.*
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.util.concurrent.*

class DiscoveryRecoveryTest {
    private class Rig(val f:HttpsFixture) {
        val session=AccountSession(f.endpoint,MemoryStore()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
        val api=SoundQApi(session,f.client)
        val library=LibraryRepository(session,api::library,api::like)
        val imports=ImportRepository(session,api,library)
        var clock=Instant.parse("2026-10-29T00:00:00Z")
        val discover=DiscoveryRepository(session,api){clock}
        val route=discover.open()!!
        val view=imports.open()!!
        fun choice():SourceChoice {discover.edit(route,"海 & music");f.reply(DiscoveryBoundaryTest.search());discover.search(route,discover.state.value.draft);return discover.inspect(route,discover.state.value.results!!.rows.single())!!}
    }
    @Test fun consumedSourceSessionCannotBecomeFreshIntentByReinspection() {
        HttpsFixture().use {f ->val r=Rig(f);val choice=r.choice();val post=r.imports.claimSource(r.view,choice)!!
            f.reply(DiscoveryOwnershipTest.decision(),201);f.reply("""{"queue":{"items":[]},"downloadJobId":"123e4567-e89b-12d3-a456-426614174071","idempotent":false}""",202);r.imports.submit(post)
            r.imports.another(r.view)
            val recaptured=r.discover.inspect(r.route,choice.candidate)
            assertTrue("an already consumed server session needs a fresh search, not a new wrapper",recaptured==null || r.imports.claimSource(r.view,recaptured)==null)
            assertEquals(3,f.server.requestCount)
        }
    }
    @Test fun queueAcknowledgementRejectsUnexpectedSuccessStatusWithoutReplayingDecision() {
        HttpsFixture().use {f ->val r=Rig(f);val post=r.imports.claimSource(r.view,r.choice())!!
            f.reply(DiscoveryOwnershipTest.decision(),201);f.reply("""{"queue":{"items":[]},"downloadJobId":"123e4567-e89b-12d3-a456-426614174071","idempotent":false}""",201);r.imports.submit(post)
            assertNull("only contracted 200 or 202 may acknowledge a queued decision",r.imports.state.value.acknowledgement)
            assertEquals(SourceImportPhase.QueueUncertain,r.imports.state.value.sourceReceipt!!.phase)
            assertEquals(3,f.server.requestCount)
        }
    }
    @Test fun heldDecisionCannotAdoptNewAccountAndOldReceiptCannotAuthorizeRecovery() {
        HttpsFixture().use {f ->val r=Rig(f);val post=r.imports.claimSource(r.view,r.choice())!!
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().code(201).body(DiscoveryOwnershipTest.decision()).build()}}
            try {val work=pool.submit {r.imports.submit(post)};assertTrue(entered.await(3,TimeUnit.SECONDS))
                val old=r.imports.state.value.sourceReceipt!!
                r.session.accept(r.session.beginIntent(),SecretTokens("b","br","B"));val replacement=r.imports.open()!!
                release.countDown();work.get(5,TimeUnit.SECONDS);r.imports.recoverSource(replacement,old);r.imports.retrySource(replacement,old)
                assertNull(r.imports.state.value.sourceReceipt);assertNull(r.imports.state.value.acknowledgement);assertFalse(r.imports.state.value.pending);assertEquals(2,f.server.requestCount)
            }finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun malformedAcknowledgedDecisionNeverDispatchesQueueAndRemainsReadOnlyRecoverable() {
        HttpsFixture().use {f ->val r=Rig(f);val post=r.imports.claimSource(r.view,r.choice())!!
            f.reply(DiscoveryOwnershipTest.decision().replace("\"action\":\"selected\"","\"action\":true"),201);r.imports.submit(post)
            assertEquals(SourceImportPhase.DecisionUncertain,r.imports.state.value.sourceReceipt!!.phase);assertNull(r.imports.state.value.acknowledgement);assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun emptyAndUnavailableProviderResultsRemainDifferentFromRequestFailure() {
        HttpsFixture().use {f ->val r=Rig(f)
            r.discover.edit(r.route,"empty");f.reply("""{"query":"empty","results":[],"providers":[{"provider":"youtube","status":"disabled"}],"selectionRequired":false}""");r.discover.search(r.route,r.discover.state.value.draft)
            assertEquals(DiscoveryPhase.Ready,r.discover.state.value.phase);assertTrue(r.discover.state.value.results!!.rows.isEmpty());assertNull(r.discover.state.value.results!!.selection)
            r.discover.edit(r.route,"failed");f.reply("{}",503);r.discover.search(r.route,r.discover.state.value.draft)
            assertEquals(DiscoveryPhase.Failed,r.discover.state.value.phase);assertNotNull(r.discover.state.value.error)
        }
    }
    @Test fun recoveringOriginalSourceReplacesSelectedSiblingJobBeforeStatusContinuation() {
        HttpsFixture().use {f ->val r=Rig(f);val post=r.imports.claimSource(r.view,r.choice())!!
            f.reply(DiscoveryOwnershipTest.decision(),201);f.reply("{}",503);r.imports.submit(post)
            f.reply("""{"jobs":[{"job_id":"123e4567-e89b-12d3-a456-426614174099","status":"complete","progress":100,"track_id":99,"source_type":"youtube","created_at":"2026-10-29T00:00:00Z"}]}""")
            r.imports.recent(r.view);r.imports.select(r.view,r.imports.state.value.recent.single())
            f.reply(DiscoveryOwnershipTest.decision(",\"downloadJobId\":\"123e4567-e89b-12d3-a456-426614174071\""));f.reply(DiscoveryPublicationRepairTest.job());r.imports.recoverSource(r.view,r.imports.state.value.sourceReceipt!!)
            assertNull("original-source recovery must not let sibling selected job own its status button",r.imports.state.value.selected)
            assertEquals("123e4567-e89b-12d3-a456-426614174071",r.imports.state.value.acknowledgement?.id?.value)
        }
    }
    @Test fun expiryFeedbackAndDismissDoNotRecaptureRetiredInspection() {
        HttpsFixture().use {f ->val r=Rig(f);val first=r.choice();r.discover.dismiss(r.route,first)
            assertFalse(first.valid());assertNull(r.imports.claimSource(r.view,first))
            val second=r.discover.inspect(r.route,first.candidate)!!
            r.clock=Instant.parse("2031-01-01T00:00:00Z");r.discover.reportExpired(r.route,second)
            assertNull(r.discover.state.value.inspected);assertTrue(r.discover.state.value.expired);assertEquals(1,f.server.requestCount)
        }
    }
    @Test fun emptyAndOversizedDraftAreLocalCorrectionNotNetworkSearch() {
        HttpsFixture().use {f ->val r=Rig(f)
            for(text in listOf(" ","海".repeat(200))) {r.discover.edit(r.route,text);r.discover.search(r.route,r.discover.state.value.draft);assertTrue(r.discover.state.value.invalidQuery)}
            assertEquals(0,f.server.requestCount)
        }
    }
    @Test fun newSearchRetiresChoicesBeforeBackgroundDispatchAndRefusesQueuedDuplicate() {
        HttpsFixture().use {f ->val r=Rig(f);val choice=r.choice();val draft=r.discover.state.value.draft
            assertNotNull("Search admission must happen before scheduling work",r.discover.claimSearch(r.route,draft))
            assertNull(r.discover.claimSearch(r.route,draft));assertFalse(choice.valid());assertNull(r.imports.claimSource(r.view,choice));assertNull(r.discover.state.value.inspected)
            assertEquals(1,f.server.requestCount)
        }
    }
    @Test fun closeSettlesClaimedButUnenteredSourceBeforeCanceledCallerCanStrandPending() {
        HttpsFixture().use {f ->val r=Rig(f);val post=r.imports.claimSource(r.view,r.choice())!!
            r.discover.close(r.route);r.imports.close(r.view)
            assertFalse("closed unentered source admission cannot strand account pending",r.imports.state.value.pending)
            assertEquals(SourceImportPhase.DecisionRefused,r.imports.state.value.sourceReceipt!!.phase)
            r.imports.open();r.imports.submit(post);assertEquals(1,f.server.requestCount)
        }
    }
    @Test fun uncertainDecisionReadbackCorrelatesOriginalSelectionAndNeverReplaysPost() {
        HttpsFixture().use {f ->val r=Rig(f);val choice=r.choice();val post=r.imports.claimSource(r.view,choice)!!
            f.reply("{}",503);r.imports.submit(post);r.imports.submit(post)
            assertEquals(SourceImportPhase.DecisionUncertain,r.imports.state.value.sourceReceipt!!.phase)
            r.imports.another(r.view);assertTrue(r.imports.state.value.consumed)
            r.discover.edit(r.route,"new query")
            f.reply("""{"items":[],"limit":100,"offset":0}""");r.imports.recoverSource(r.view,r.imports.state.value.sourceReceipt!!)
            assertEquals(SourceImportPhase.DecisionUncertain,r.imports.state.value.sourceReceipt!!.phase)
            f.reply("{}",500);r.imports.recoverSource(r.view,r.imports.state.value.sourceReceipt!!)
            assertEquals(SourceImportPhase.ReadbackFailed,r.imports.state.value.sourceReceipt!!.phase)
            f.reply("""{"items":[${DiscoveryOwnershipTest.decision(",\"downloadJobId\":\"123e4567-e89b-12d3-a456-426614174071\"")}],"limit":100,"offset":0}""")
            f.reply(DiscoveryPublicationRepairTest.job())
            r.imports.recoverSource(r.view,r.imports.state.value.sourceReceipt!!)
            assertEquals(SourceImportPhase.Accepted,r.imports.state.value.sourceReceipt!!.phase)
            assertEquals("123e4567-e89b-12d3-a456-426614174071",r.imports.state.value.acknowledgement?.id?.value)
            assertEquals(6,f.server.requestCount);assertTrue(r.library.state.value.rows.isEmpty())
        }
    }
    @Test fun savedDecisionRetryReusesIdentityAfterOriginalSelectionExpiresAndReceiptCannotReplay() {
        HttpsFixture().use {f ->val r=Rig(f);val choice=r.choice();val post=r.imports.claimSource(r.view,choice)!!
            f.reply(DiscoveryOwnershipTest.decision(),201);f.reply("{}",503);r.imports.submit(post)
            val receipt=r.imports.state.value.sourceReceipt!!
            assertEquals(SourceImportPhase.QueueUncertain,receipt.phase)
            r.clock=Instant.parse("2031-01-01T00:00:00Z");r.discover.close(r.route)
            val reopened=r.imports.open()!!
            f.reply("""{"queue":{"items":[]},"downloadJobId":"123e4567-e89b-12d3-a456-426614174071","idempotent":true}""",200)
            r.imports.retrySource(reopened,receipt);r.imports.retrySource(reopened,receipt);r.imports.submit(post)
            assertEquals(SourceImportPhase.Accepted,r.imports.state.value.sourceReceipt!!.phase)
            assertEquals(4,f.server.requestCount)
            val requests=(1..4).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            assertEquals(1,requests.count {it.method=="POST"&&it.url.encodedPath=="/api/v1/source-selections"})
            assertEquals(2,requests.count {it.method=="POST"&&it.url.encodedPath=="/api/v1/queue/items"})
        }
    }
    @Test fun retiredQueryRouteAccountAndExpiredSelectionCannotGrantNewImportAuthority() {
        HttpsFixture().use {f ->val r=Rig(f);val old=r.choice()
            r.discover.edit(r.route,"changed");assertNull(r.imports.claimSource(r.view,old))
            val expired=r.choice();r.clock=Instant.parse("2031-01-01T00:00:00Z");assertNull(r.imports.claimSource(r.view,expired))
            assertNull(r.discover.inspect(r.route,expired.candidate));assertTrue(r.discover.state.value.expired)
            r.clock=Instant.parse("2026-10-29T00:00:00Z");val closed=r.choice();r.discover.close(r.route);assertNull(r.imports.claimSource(r.view,closed))
            val freshRoute=r.discover.open()!!;r.discover.edit(freshRoute,"海 & music");f.reply(DiscoveryBoundaryTest.search());r.discover.search(freshRoute,r.discover.state.value.draft)
            val replaced=r.discover.inspect(freshRoute,r.discover.state.value.results!!.rows.single())!!
            r.session.accept(r.session.beginIntent(),SecretTokens("b","br","B"));assertNull(r.imports.claimSource(r.view,replaced))
            assertEquals(4,f.server.requestCount)
        }
    }
    @Test fun closeBeforeSendRefusesAndCloseDuringDecisionRetainsReceiptWithoutFollowingWithQueuePost() {
        HttpsFixture().use {f ->val r=Rig(f);val first=r.choice();val unsent=r.imports.claimSource(r.view,first)!!
            r.discover.close(r.route);r.imports.submit(unsent)
            assertEquals(SourceImportPhase.DecisionRefused,r.imports.state.value.sourceReceipt!!.phase);assertEquals(1,f.server.requestCount)
            r.imports.another(r.view)
            val route=r.discover.open()!!;r.discover.edit(route,"海 & music");f.reply(DiscoveryBoundaryTest.search().replace("174010","174011"));r.discover.search(route,r.discover.state.value.draft)
            val choice=r.discover.inspect(route,r.discover.state.value.results!!.rows.single())!!;val post=r.imports.claimSource(r.view,choice)!!
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().code(201).body(DiscoveryOwnershipTest.decision().replace("174010","174011")).build()}}
            try {val work=pool.submit {r.imports.submit(post)};assertTrue(entered.await(3,TimeUnit.SECONDS));r.discover.close(route);r.imports.close(r.view);release.countDown();work.get(5,TimeUnit.SECONDS)
                assertNotNull(r.imports.state.value.sourceReceipt!!.decision);assertEquals(SourceImportPhase.QueueRefused,r.imports.state.value.sourceReceipt!!.phase);assertEquals(3,f.server.requestCount)
            }finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun heldOldSearchCannotPublishAfterDraftEditOrReopen() {
        HttpsFixture().use {f ->val r=Rig(f);r.discover.edit(r.route,"海 & music")
            val entered=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            f.server.dispatcher=object:Dispatcher(){override fun dispatch(request:RecordedRequest):MockResponse {entered.countDown();check(release.await(5,TimeUnit.SECONDS));return MockResponse.Builder().body(DiscoveryBoundaryTest.search()).build()}}
            try {val work=pool.submit {r.discover.search(r.route,r.discover.state.value.draft)};assertTrue(entered.await(3,TimeUnit.SECONDS));r.discover.edit(r.route,"new");r.discover.close(r.route);r.discover.open();release.countDown();work.get(5,TimeUnit.SECONDS)
                assertNull(r.discover.state.value.results);assertEquals("new",r.discover.state.value.draft.text);assertEquals(DiscoveryPhase.Idle,r.discover.state.value.phase)
            }finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun malformedSearchAndMutationResponsesNeverInventJobAndMutationUnauthorizedNeverRefreshes() {
        HttpsFixture().use {f ->val r=Rig(f)
            for(body in listOf(DiscoveryBoundaryTest.search().replace("\"downloadable\":true","\"downloadable\":\"true\""),DiscoveryBoundaryTest.search().replace("123e4567-e89b-12d3-a456-426614174010","1-1-1-1-1"),DiscoveryBoundaryTest.search().replace("2030-01-01T00:00:00Z","invalid"),DiscoveryBoundaryTest.search().replace("\"durationMs\":12000","\"durationMs\":\"12000\""),DiscoveryBoundaryTest.search().replace("https://youtu.be/fixture","https://evil.test/fixture"))) {
                f.reply(body);assertEquals(SafeFailure.Reason.InvalidResponse,(runCatching {r.api.discoverySearch(r.session.capture()!!,"海 & music")}.exceptionOrNull() as SafeFailure).reason)
            }
            val choice=r.choice();val post=r.imports.claimSource(r.view,choice)!!;f.reply("{}",401);r.imports.submit(post);r.imports.submit(post)
            assertEquals(SourceImportPhase.DecisionRefused,r.imports.state.value.sourceReceipt!!.phase);assertNull(r.imports.state.value.acknowledgement);assertEquals(7,f.server.requestCount)
        }
    }
}
