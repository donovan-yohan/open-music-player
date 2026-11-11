package com.soundq.android.data

import com.soundq.android.data.acquisition.*
import com.soundq.android.data.imports.ImportJobId
import kotlinx.serialization.json.*
import kotlinx.coroutines.*
import kotlin.coroutines.CoroutineContext
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.*

class AcquisitionRepairTest {
    private val id="123e4567-e89b-12d3-a456-426614174001"
    private val revision="123e4567-e89b-12d3-a456-426614174002"
    private val other="123e4567-e89b-12d3-a456-426614174003"
    private fun research(job:String=id,status:String="queued")="""{"job":{"id":"$job","status":"$status","retrySafe":true,"attempts":1,"maxAttempts":3,"latestRevision":1,"latestRevisionId":"$revision"},"revisions":[{"id":"$revision","jobId":"$job","number":1,"payload":{"schemaVersion":"omp.research.revision.v1","stage":"baseline","candidates":[],"recommendations":[]}}],"latestDegradation":{"code":"transient","retryable":true}}"""

    // Exact bytes emitted by real Go buildPlaylistImportResponse + YTDLP Resolve.
    private fun producerPlaylist()=javaClass.getResource("/acquisition/playlist-omitted-title.json")!!.readText()
    @Test fun omittedProducerTitleKeepsCreateIdentityReceiptAndProgressGet() {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val repo=AcquisitionRepository(session,api);val view=repo.open()!!
            f.reply(producerPlaylist(),202);repo.startPlaylist(view,"https://youtube.com/playlist?list=PLfixture","",500)!!()
            assertNull(repo.state.value.error);assertFalse(repo.state.value.uncertain)
            val created=repo.state.value.playlist!!
            assertEquals(id,created.id.value);assertEquals(17L,created.playlistId);assertEquals(1,created.total);assertEquals(1,created.failed)
            assertEquals("Playlist item #8",created.items.single().title)
            assertEquals(id,api.intakeReceipts.entries(f.endpoint.identity,"A").single().job)
            assertEquals("accepted",api.intakeReceipts.entries(f.endpoint.identity,"A").single().phase)
            f.reply(producerPlaylist());repo.loadPlaylist(view,created.id)!!()
            assertNull(repo.state.value.error);assertEquals("Playlist item #8",repo.state.value.playlist!!.items.single().title)
            assertEquals(listOf("POST","GET"),(1..2).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!.method})
            assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun presentMalformedPlaylistTitleStillRefusesWithoutLosingStrictIdentityCountsOrStatus() {
        val original=Json.parseToJsonElement(producerPlaylist()).jsonObject
        val item=original.getValue("items").jsonArray.single().jsonObject
        for(value in listOf(JsonNull,JsonPrimitive(7),JsonPrimitive(true),buildJsonObject {},buildJsonArray {})) {
            val body=JsonObject(original+("items" to JsonArray(listOf(JsonObject(item+("title" to value))))))
            assertEquals(SafeFailure.Reason.InvalidResponse,(runCatching {AcquisitionJson.playlist(body)}.exceptionOrNull() as SafeFailure).reason)
        }
        for(body in listOf(JsonObject(original+("id" to JsonPrimitive(other))),JsonObject(original+("failedItems" to JsonPrimitive(2))),JsonObject(original+("status" to JsonPrimitive("invented"))))) {
            assertEquals(SafeFailure.Reason.InvalidResponse,(runCatching {AcquisitionJson.playlist(body,ImportJobId(id))}.exceptionOrNull() as SafeFailure).reason)
        }
    }
    @Test fun unknownResearchCreateAndReviewAreNeverReplayedOrCertifiedByJobReads() {
        for(review in listOf(false,true)) HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val repo=AcquisitionRepository(session,api);val view=repo.open()!!
            val candidate="""{"candidateId":"youtube:fixture","provider":"youtube","sourceUrl":"https://youtu.be/fixture","title":"Fixture","downloadable":true,"playable":false}"""
            if(review) {
                f.reply(research().replace("\"candidates\":[],\"recommendations\":[]","\"candidates\":[$candidate],\"recommendations\":[{\"candidateId\":\"youtube:fixture\",\"rank\":1}]"))
                repo.loadResearch(view,ImportJobId(id))!!()
            } else repo.consent(view,true)
            f.reply("{}",503)
            val work=if(review)repo.state.value.research!!.let {repo.review(view,it,it.candidates.single(),"accepted")} else repo.startResearch(view,"synthetic fixture")
            work!!();work()
            assertTrue(repo.state.value.uncertain)
            val receipt=api.intakeReceipts.entries(f.endpoint.identity,"A").single()
            assertEquals(if(review)id else null,receipt.job)
            assertEquals("uncertain",receipt.phase)
            val restored=AcquisitionRepository(session,api);val current=restored.open()!!
            f.reply(research());restored.loadResearch(current,ImportJobId(id))!!()
            assertTrue("Job GET cannot certify an unknown create or review decision",restored.state.value.uncertain)
            restored.consent(current,true);assertNull(restored.startResearch(current,"new fixture"))
            val count=if(review)3 else 2
            assertEquals(count,f.server.requestCount)
            assertEquals(1,(1..count).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}.count {it.method=="POST"})
        }
    }
    private class HeldDispatcher:CoroutineDispatcher() {
        private val tasks=java.util.ArrayDeque<Runnable>()
        override fun dispatch(context:CoroutineContext,block:Runnable){tasks.add(block)}
        fun drain(){while(tasks.isNotEmpty())tasks.removeFirst().run()}
    }
    @Test fun routeCloseReleasesClaimWithoutInvokingDroppedClosure() {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val repo=AcquisitionRepository(session,api);val view=repo.open()!!
            val dropped=repo.startPlaylist(view,"https://youtube.com/playlist?list=PLfixture","",500)!!
            assertTrue(repo.state.value.busy);repo.close(view)
            val next=repo.open()!!
            assertFalse("Closing an unentered claim must release busy without running it",repo.state.value.busy)
            assertTrue(api.intakeReceipts.entries(f.endpoint.identity,"A").isEmpty())
            assertNotNull(repo.loadQueue(next))
            dropped();assertEquals(0,f.server.requestCount)
            assertTrue("Old closure cannot release the newer claim",repo.state.value.busy)
            repo.close(next)
        }
    }
    @Test fun cancelledSchedulerReleasesItsUnstartedClaimWithoutRouteDisposal() {
        HttpsFixture().use {f->
            val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
            val api=SoundQApi(session,f.client);val repo=AcquisitionRepository(session,api);val view=repo.open()!!
            val dispatcher=HeldDispatcher();val owner=CoroutineScope(SupervisorJob()+dispatcher)
            val work=repo.startPlaylist(view,"https://youtube.com/playlist?list=PLfixture","",500)!!
            val job=repo.schedule(owner,work,dispatcher)!!
            owner.cancel();dispatcher.drain()
            assertTrue(job.isCompleted)
            assertFalse("A cancelled worker that never entered must release its own claim",repo.state.value.busy)
            assertEquals(0,f.server.requestCount)
            assertTrue(api.intakeReceipts.entries(f.endpoint.identity,"A").isEmpty())
            assertNotNull(repo.loadQueue(view));work()
            assertTrue(repo.state.value.busy);assertEquals(0,f.server.requestCount)
            repo.close(view)
        }
    }
    @Test fun startedWorkerRetiredBeforeWireRefusesReceiptAndCannotTouchNextClaim() {
        HttpsFixture().use {f->
            val reached=CountDownLatch(1);val release=CountDownLatch(1);val pool=Executors.newSingleThreadExecutor()
            try {
                val client=f.client.newBuilder().addInterceptor {chain->reached.countDown();check(release.await(5,TimeUnit.SECONDS));chain.proceed(chain.request())}.build()
                val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
                val api=SoundQApi(session,client);val repo=AcquisitionRepository(session,api);val view=repo.open()!!
                val task=pool.submit {repo.startPlaylist(view,"https://youtube.com/playlist?list=PLfixture","",500)!!()}
                assertTrue(reached.await(3,TimeUnit.SECONDS));repo.close(view)
                val next=repo.open()!!;assertFalse(repo.state.value.busy);assertFalse(repo.state.value.uncertain)
                assertEquals("refused",api.intakeReceipts.entries(f.endpoint.identity,"A").single().phase)
                assertNotNull(repo.loadQueue(next));release.countDown();task.get(5,TimeUnit.SECONDS)
                assertTrue(repo.state.value.busy);assertEquals(0,f.server.requestCount);repo.close(next)
            } finally {release.countDown();pool.shutdownNow();pool.awaitTermination(5,TimeUnit.SECONDS)}
        }
    }
    @Test fun enteredWriteSettlesForSameAccountAfterRouteAndSchedulingOwnerRetire() {
        HttpsFixture().use {f->
            val reached=CountDownLatch(1);val release=CountDownLatch(1)
            val dispatcher=Executors.newSingleThreadExecutor().asCoroutineDispatcher()
            val owner=CoroutineScope(SupervisorJob()+dispatcher)
            try {
                val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
                val api=SoundQApi(session,f.client);val repo=AcquisitionRepository(session,api);val view=repo.open()!!
                f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                    reached.countDown();check(release.await(5,TimeUnit.SECONDS));return mockwebserver3.MockResponse.Builder().code(201).body(research()).build()
                }}
                repo.consent(view,true)
                val job=repo.schedule(owner,repo.startResearch(view,"synthetic fixture"),dispatcher)!!
                assertTrue(reached.await(3,TimeUnit.SECONDS));owner.cancel();repo.close(view);repo.open()!!
                assertTrue("Entered write remains account-owned",repo.state.value.busy)
                release.countDown();runBlocking {withTimeout(5000){job.join()}}
                assertFalse(repo.state.value.busy);assertFalse(repo.state.value.uncertain)
                assertEquals(id,repo.state.value.research!!.id.value)
                assertEquals("accepted",api.intakeReceipts.entries(f.endpoint.identity,"A").single().phase)
                assertEquals(1,f.server.requestCount)
            } finally {release.countDown();owner.cancel();dispatcher.close()}
        }
    }
    @Test fun pendingKnownResearchMutationRecoversOnlyByExactGetAfterReconstruction() {
        for(operation in listOf("cancel","retry")) HttpsFixture().use {f->
            val directory=Files.createTempDirectory("acquisition-repair").toFile()
            val pool=Executors.newSingleThreadExecutor()
            val release=CountDownLatch(1)
            try {
                val file=File(directory,"journal.json")
                val session=AccountSession(f.endpoint,MemoryStore());session.accept(session.beginIntent(),SecretTokens("a","r","A"))
                val api=SoundQApi(session,f.client,IntakeReceipts(file));val repo=AcquisitionRepository(session,api);val view=repo.open()!!
                repo.consent(view,true);f.reply(research(status=if(operation=="cancel")"queued" else "degraded"),201)
                repo.startResearch(view,"synthetic fixture")!!()
                val create=f.server.takeRequest(2,TimeUnit.SECONDS)!!;assertEquals("POST",create.method)
                repo.consent(view,true)
                val entered=CountDownLatch(1)
                f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                    if(request.method=="POST") {entered.countDown();check(release.await(5,TimeUnit.SECONDS))}
                    val job=if(request.url.encodedPath.endsWith(other))other else id
                    return mockwebserver3.MockResponse.Builder().code(200).body(research(job)).build()
                }}
                val action=repo.mutateResearch(view,repo.state.value.research!!,operation)!!
                val task=pool.submit {action()}
                assertTrue(entered.await(3,TimeUnit.SECONDS))
                // Freeze actual pre-settlement disk bytes, not a hand-built pending receipt.
                val restart=File(directory,"restart.json");file.copyTo(restart)
                val saved=IntakeReceipts(restart).entries(f.endpoint.identity,"A")
                assertEquals("pending",saved.last().phase)
                assertEquals("Known target must be durable before POST $operation",id,saved.last().job)
                val restoredApi=SoundQApi(session,f.client,IntakeReceipts(restart))
                val restored=AcquisitionRepository(session,restoredApi);val current=restored.open()!!
                assertTrue(restored.state.value.uncertain)
                restored.loadResearch(current,ImportJobId(other))!!()
                assertTrue("A different job cannot settle this mutation",restored.state.value.uncertain)
                restored.loadResearch(current,ImportJobId(id))!!()
                assertFalse(restored.state.value.uncertain)
                assertEquals("accepted",IntakeReceipts(restart).entries(f.endpoint.identity,"A").last().phase)
                val next=restored.startPlaylist(current,"https://youtube.com/playlist?list=PLfixture","",500)
                assertNotNull("A new explicit claim is admitted after exact recovery",next)
                val requests=(1..3).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}
                assertEquals(listOf("POST","GET","GET"),requests.map {it.method})
                assertEquals("/api/v1/research-jobs/$id/$operation",requests[0].url.encodedPath)
                assertEquals(4,f.server.requestCount)
                release.countDown();task.get(5,TimeUnit.SECONDS)
            } finally {release.countDown();pool.shutdownNow();pool.awaitTermination(5,TimeUnit.SECONDS);directory.deleteRecursively()}
        }
    }
}
