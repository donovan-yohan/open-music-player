package com.soundq.android.data

import com.soundq.android.data.acquisition.*
import com.soundq.android.data.imports.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.util.concurrent.*

class AcquisitionLifecycleTest {
    private val id="123e4567-e89b-12d3-a456-426614174001"
    private val revision="123e4567-e89b-12d3-a456-426614174002"
    private fun research(status:String="degraded",degradation:String="model_disabled")="""{"job":{"id":"$id","status":"$status","retrySafe":true,"attempts":1,"maxAttempts":3,"latestRevision":1,"latestRevisionId":"$revision"},"revisions":[{"id":"$revision","jobId":"$id","number":1,"kind":"baseline","payload":{"schemaVersion":"omp.research.revision.v1","stage":"baseline","query":"fixture","candidates":[],"recommendations":[]}}],"latestDegradation":{"code":"$degradation","retryable":false}}"""
    private fun playlist(status:String="importing")="""{"id":"$id","playlistId":17,"status":"$status","totalItems":1,"importedItems":0,"queuedItems":1,"failedItems":0,"skippedItems":0,"items":[{"id":8,"title":"Fixture item","status":"queued","downloadJobId":"$revision"}]}"""
    @Test fun journalIsDurableEndpointAccountScopedAndRetainsUnknownWrites() {
        val directory=Files.createTempDirectory("acquisition-receipts").toFile()
        try {
            val file=java.io.File(directory,"journal.json");val journal=IntakeReceipts(file)
            val receipt=journal.begin("https://fixture.test/api/v1","A","download")
            journal.finish("https://fixture.test/api/v1","A",receipt,"accepted",id)
            assertEquals(id,IntakeReceipts(file).entries("https://fixture.test/api/v1","A").single().job)
            assertTrue(IntakeReceipts(file).entries("https://other.test/api/v1","A").isEmpty())
            assertTrue(IntakeReceipts(file).entries("https://fixture.test/api/v1","B").isEmpty())
            journal.begin("https://fixture.test/api/v1","A","playlist")
            assertEquals("pending",IntakeReceipts(file).entries("https://fixture.test/api/v1","A").last().phase)
            val before=file.readBytes();file.writeText("{broken");val corrupt=file.readBytes()
            assertTrue(runCatching {IntakeReceipts(file).begin("endpoint","A","download")}.isFailure)
            assertArrayEquals(corrupt,file.readBytes());assertTrue(before.isNotEmpty())
        }finally {directory.deleteRecursively()}
    }
    @Test fun shareDefersAcrossRecreationAndNeverBorrowsAnotherAccount() {
        val directory=Files.createTempDirectory("acquisition-share").toFile()
        try {
            val file=java.io.File(directory,"share");val shares=IncomingShares(file)
            assertTrue(shares.receive("Fixture title https://youtu.be/fixture",null))
            val restored=IncomingShares(file);assertNotNull(restored.visible("A"))
            assertFalse(restored.receive("https://youtu.be/one https://youtu.be/two",null))
            assertTrue(restored.receive("https://soundcloud.com/fixture/song","A"))
            assertNull(restored.visible("B"));assertNotNull(restored.visible("A"))
        }finally {directory.deleteRecursively()}
    }
    @Test fun playlistProgressUsesAcceptedIdentityAndRefreshIsGetOnly() {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val repo=AcquisitionRepository(session,api);val view=repo.open()!!
            f.reply(playlist(),202)
            val action=repo.startPlaylist(view,"https://music.youtube.com/playlist?list=PLfixture","Fixture",500)!!
            assertNull(repo.startPlaylist(view,"https://youtube.com/playlist?list=PLfixture","",500))
            action();action()
            assertEquals(17L,repo.state.value.playlist!!.playlistId)
            assertEquals(1,f.server.requestCount)
            val request=f.server.takeRequest(2,TimeUnit.SECONDS)!!;assertEquals("POST",request.method);assertEquals("/api/v1/playlist-imports",request.url.encodedPath)
            f.reply(playlist("complete"));repo.loadPlaylist(view,ImportJobId(id))!!()
            assertEquals("complete",repo.state.value.playlist!!.status)
            assertEquals("GET",f.server.takeRequest(2,TimeUnit.SECONDS)!!.method)
            assertEquals(id,api.intakeReceipts.entries(f.endpoint.identity,"A").single().job)
        }
    }
    @Test fun researchRequiresConsentShowsBudgetAndCancelSendsAnEmptyBody() {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val repo=AcquisitionRepository(session,api);val view=repo.open()!!
            assertNull(repo.startResearch(view,"fixture"));assertEquals(0,f.server.requestCount)
            repo.consent(view,true);f.reply(research("queued"),201);repo.startResearch(view,"fixture")!!()
            assertFalse(repo.state.value.consent)
            val create=f.server.takeRequest(2,TimeUnit.SECONDS)!!;assertNotNull(create.headers["Idempotency-Key"])
            f.reply(research("cancel_requested"));repo.mutateResearch(view,repo.state.value.research!!,"cancel")!!()
            val cancel=f.server.takeRequest(2,TimeUnit.SECONDS)!!;assertEquals("/api/v1/research-jobs/$id/cancel",cancel.url.encodedPath);assertEquals(0,cancel.body!!.size)
            f.reply(research(degradation="budget_exhausted"));repo.loadResearch(view,ImportJobId(id))!!()
            assertEquals("budget_exhausted",repo.state.value.research!!.degradation);assertFalse(repo.state.value.research!!.canRetry)
            assertEquals("GET",f.server.takeRequest(2,TimeUnit.SECONDS)!!.method)
        }
    }
    @Test fun queueMutationIsSingleUseAndRouteExitBeforeWorkerSendsNothing() {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val repo=AcquisitionRepository(session,api);val view=repo.open()!!
            val queue="""{"items":[{"queueItemId":"$id","position":0,"playbackState":"failed","progress":0,"canRetry":true,"canRemove":true,"downloadJobId":"$revision"}],"currentPosition":0,"updatedAt":"2026-10-29T00:00:00Z"}"""
            f.reply(queue);repo.loadQueue(view)!!();val snapshot=repo.state.value.queue!!
            val retry=repo.manageQueue(view,snapshot,"retry",snapshot.items.single())!!
            repo.close(view);retry();assertEquals(1,f.server.requestCount)
            val current=repo.open()!!;f.reply(queue)
            val action=repo.manageQueue(current,snapshot,"retry",snapshot.items.single())!!;action();action()
            assertEquals(2,f.server.requestCount)
            assertEquals("accepted",api.intakeReceipts.entries(f.endpoint.identity,"A").last().phase)
        }
    }
    @Test fun unknownPlaylistWriteRemainsFencedAcrossQueueRefreshAndRecreation() {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val repo=AcquisitionRepository(session,api);val view=repo.open()!!
            f.reply("{}",503);repo.startPlaylist(view,"https://youtube.com/playlist?list=PLfixture","",500)!!()
            assertTrue(repo.state.value.uncertain)
            val restored=AcquisitionRepository(session,api);val current=restored.open()!!
            assertTrue(restored.state.value.uncertain)
            f.reply("""{"items":[],"currentPosition":0,"updatedAt":"2026-10-29T00:00:00Z"}""")
            restored.loadQueue(current)!!()
            assertTrue("An unrelated GET cannot certify unknown playlist creation",restored.state.value.uncertain)
            assertNull(restored.startPlaylist(current,"https://youtube.com/playlist?list=PLfixture","",500))
            assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun researchReviewEventsAndExplicitImportUseOnlyAcknowledgedDecision() {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val repo=AcquisitionRepository(session,api);val view=repo.open()!!
            val candidate="""{"candidateId":"youtube:fixture","provider":"youtube","sourceUrl":"https://youtu.be/fixture","title":"Research fixture","downloadable":true,"playable":false}"""
            val snapshot=research().replace("\"candidates\":[],\"recommendations\":[]","\"candidates\":[$candidate],\"recommendations\":[{\"candidateId\":\"youtube:fixture\",\"rank\":1}]")
            f.reply(snapshot);repo.loadResearch(view,ImportJobId(id))!!()
            val progress=repo.state.value.research!!;val row=progress.candidates.single()
            assertNull(repo.review(view,progress,row,"overridden"))
            f.reply("""{"id":"$revision","selectedCandidateId":"youtube:fixture","action":"accepted","selectedCandidate":$candidate}""",201)
            repo.review(view,progress,row,"accepted")!!()
            assertNotNull(repo.state.value.review);assertNull(repo.review(view,progress,row,"accepted"))
            assertEquals(2,f.server.requestCount)
            f.reply("""{"events":[{"jobId":"$id","sequence":1,"kind":"reviewed","createdAt":"2026-10-29T00:00:00Z"}],"afterSequence":0,"limit":50}""")
            repo.loadEvents(view,progress)!!();assertEquals("reviewed",repo.state.value.events.single().kind)
            f.reply("""{"queue":{},"downloadJobId":"$id","idempotent":false}""",202)
            repo.importReviewed(view,repo.state.value.review!!)!!()
            val requests=(1..4).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            assertEquals(listOf("GET","POST","GET","POST"),requests.map {it.method})
            assertEquals("/api/v1/research-jobs/$id/reviews",requests[1].url.encodedPath)
            assertEquals("$revision",Json.parseToJsonElement(requests[3].body!!.utf8()).jsonObject.getValue("sourceDecisionId").jsonPrimitive.content)
            assertNotNull(repo.state.value.reviewedImport)
            assertEquals(revision,api.intakeReceipts.entries(f.endpoint.identity,"A").first {it.kind=="review"}.decisionId)
        }
    }
    @Test fun queueRemoveReorderAndClearUseServerContractAndReadback() {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val scope=session.capture()!!
            val empty="""{"items":[],"currentPosition":0,"updatedAt":"2026-10-29T00:00:00Z"}"""
            for(operation in listOf("remove","reorder","clear")) {
                f.reply(empty);assertTrue(api.manageServerImport(scope,operation,if(operation=="clear")null else id,0,{true},{true}).items.isEmpty())
            }
            val requests=(1..3).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            assertEquals(listOf("DELETE","PUT","DELETE"),requests.map {it.method})
            assertEquals(listOf("/api/v1/queue/items/$id","/api/v1/queue/reorder","/api/v1/queue"),requests.map {it.url.encodedPath})
            val reorder=Json.parseToJsonElement(requests[1].body!!.utf8()).jsonObject
            assertEquals(id,reorder.getValue("queueItemId").jsonPrimitive.content);assertEquals(0,reorder.getValue("toPosition").jsonPrimitive.int)
        }
    }
    @Test fun heldPlaylistAckSurvivesRouteExitButNeverPublishesIntoReplacementAccount() {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val repo=AcquisitionRepository(session,api);val view=repo.open()!!
            val entered=CountDownLatch(1);val release=CountDownLatch(1)
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(r:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {entered.countDown();release.await(5,TimeUnit.SECONDS);return mockwebserver3.MockResponse.Builder().code(202).body(playlist()).build()}}
            val work=repo.startPlaylist(view,"https://youtube.com/playlist?list=PLfixture","",500)!!
            val pool=Executors.newSingleThreadExecutor()
            try {
                val task=pool.submit {work()};assertTrue(entered.await(3,TimeUnit.SECONDS));repo.close(view)
                session.accept(session.beginIntent(),SecretTokens("b","r","B"));repo.retire();repo.open()
                release.countDown();task.get(5,TimeUnit.SECONDS)
                assertNull(repo.state.value.playlist);assertTrue(repo.state.value.receipts.isEmpty())
                assertEquals("pending",api.intakeReceipts.entries(f.endpoint.identity,"A").single().phase)
                assertEquals(1,f.server.requestCount)
            }finally {release.countDown();pool.shutdownNow()}
        }
    }
    @Test fun wrongJobAndScalarCoercionAreRejected() {
        assertEquals(SafeFailure.Reason.InvalidResponse,(runCatching {AcquisitionJson.playlist(Json.parseToJsonElement(playlist()).jsonObject,ImportJobId(revision))}.exceptionOrNull() as SafeFailure).reason)
        assertEquals(SafeFailure.Reason.InvalidResponse,(runCatching {AcquisitionJson.research(Json.parseToJsonElement(research().replace("\"attempts\":1","\"attempts\":\"1\"")).jsonObject)}.exceptionOrNull() as SafeFailure).reason)
    }
}
