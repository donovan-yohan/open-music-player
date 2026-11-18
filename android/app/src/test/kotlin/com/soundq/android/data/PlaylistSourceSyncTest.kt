package com.soundq.android.data

import com.soundq.android.data.playlists.*
import com.soundq.android.data.acquisition.IntakeReceipts
import com.soundq.android.data.deviceaudio.*
import com.soundq.android.playback.nativeengine.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Wire resources are actual authenticated Go/SQL pipeline responses, not hand-authored DTOs. */
class PlaylistSourceSyncTest {
    private fun vector(name:String)=javaClass.getResourceAsStream("/playlist-sync/$name.json")!!.bufferedReader().use {it.readText()}
    private fun key()=Json.parseToJsonElement(vector("ack")).jsonObject.getValue("id").jsonPrimitive.content
    private fun id()=PlaylistId(Json.parseToJsonElement(vector("detail-before")).jsonObject.getValue("id").jsonPrimitive.long)
    private fun session(f:HttpsFixture)=AccountSession(f.endpoint,MemoryStore()).also {check(it.accept(it.beginIntent(),SecretTokens("sync-access","sync-refresh","sync-owner")))}
    private fun ready(f:HttpsFixture):Triple<SoundQApi,PlaylistDetailRepository,AccountSession> {
        val s=session(f);val api=SoundQApi(s,f.client);val detail=PlaylistDetailRepository(api)
        f.reply(vector("detail-before"));detail.open(id());assertNotNull(detail.state.value.detail)
        return Triple(api,detail,s)
    }
    @Test fun producerWireDispatchReceiptStatusAndAuthoritativeReadbackUseDistinctSyncRoute() {
        HttpsFixture().use {f->
            val (api,detail,_)=ready(f);val repo=PlaylistSourceSyncRepository(api,detail,newOperation=::key)
            f.reply(vector("eligible"));repo.enter(id())!!()
            val beforeMembership=detail.state.value.detail
            f.reply(vector("ack"),202);val action=repo.start()!!;action();action()
            assertFalse(repo.state.value.busy);assertEquals(key(),repo.state.value.observation!!.operation!!.id)
            assertFalse(repo.state.value.observation!!.operation!!.accepted);assertTrue(repo.state.value.observation!!.operation!!.active)
            assertSame("Resolving ACK is not accepted membership",beforeMembership,detail.state.value.detail)
            f.reply(vector("pending"));f.reply(vector("detail-pending"));repo.refresh()!!()
            assertTrue(repo.state.value.observation!!.operation!!.accepted);assertFalse(repo.state.value.readbackFailed)
            val expected=PlaylistJson.detail(Json.parseToJsonElement(vector("detail-pending")).jsonObject,id())
            assertEquals(expected,detail.state.value.detail)
            val requests=(0 until f.server.requestCount).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            assertEquals(1,requests.count {it.method=="POST"})
            val post=requests.single {it.method=="POST"};assertEquals("/api/v1/playlists/${id().value}/source-sync",post.url.encodedPath)
            val body=Json.parseToJsonElement(post.body!!.utf8()).jsonObject
            assertEquals(setOf("operationId","bindingId"),body.keys);assertEquals(key(),body.getValue("operationId").jsonPrimitive.content)
            assertTrue(requests.none {"auto-mix" in it.url.encodedPath})
            assertTrue(requests.any {it.url.queryParameter("operationId")==key()})
        }
    }
    @Test fun lostResponseRestoresExactDurableIntentWithoutAutomaticPostReplay() {
        val dir=Files.createTempDirectory("source-sync-receipt").toFile()
        try {HttpsFixture().use {f->
            val (api,detail,_)=ready(f);val file=File(dir,"journal.json")
            val first=PlaylistSourceSyncRepository(api,detail,IntakeReceipts(file),::key)
            f.reply(vector("eligible"));first.enter(id())!!()
            f.reply("{}",503);first.start()!!();assertTrue(first.state.value.uncertain)
            val before=f.server.requestCount
            val restored=PlaylistSourceSyncRepository(api,detail,IntakeReceipts(file),::key)
            f.reply(vector("pending"));f.reply(vector("detail-pending"));restored.enter(id())!!()
            assertTrue(restored.state.value.observation!!.operation!!.accepted);assertFalse(restored.state.value.uncertain)
            val requests=(0 until f.server.requestCount).map {f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            assertEquals(1,requests.count {it.method=="POST"});assertEquals(before+2,requests.size)
            assertEquals(key(),requests[before].url.queryParameter("operationId"))
        }}finally{dir.deleteRecursively()}
    }
    @Test fun newUnknownIntentDoesNotDisplayOlderCompletionAsItsAcknowledgement() {
        HttpsFixture().use {f->
            val (api,detail,_)=ready(f);val repo=PlaylistSourceSyncRepository(api,detail)
            f.reply(vector("complete"));f.reply(vector("detail-after"));repo.enter(id())!!()
            assertEquals("complete",repo.state.value.observation!!.operation!!.status)
            val next=repo.start()!!;assertNull(repo.state.value.observation!!.operation)
            f.reply("{}",503);next()
            assertTrue(repo.state.value.uncertain);assertNull(repo.state.value.observation!!.operation)
        }
    }
    @Test fun readbackFailureRetainsAcceptedProgressAndExplicitReadRecoveryClearsBusy() {
        HttpsFixture().use {f->
            val (api,detail,_)=ready(f);val repo=PlaylistSourceSyncRepository(api,detail,newOperation=::key)
            f.reply(vector("eligible"));repo.enter(id())!!();f.reply(vector("ack"),202);repo.start()!!()
            f.reply(vector("pending"));f.reply("{}",503);repo.refresh()!!()
            assertTrue(repo.state.value.observation!!.operation!!.accepted);assertTrue(repo.state.value.readbackFailed);assertFalse(repo.state.value.busy)
            f.reply(vector("pending"));f.reply(vector("detail-pending"));repo.refresh()!!()
            assertFalse(repo.state.value.error);assertFalse(repo.state.value.readbackFailed);assertFalse(repo.state.value.busy)
        }
    }
    @Test fun queuedStaleActionAndOldVisitCleanupCannotDispatchOrRetireNewVisit() {
        HttpsFixture().use {f->
            val (api,detail,s)=ready(f);val repo=PlaylistSourceSyncRepository(api,detail,newOperation=::key)
            f.reply(vector("eligible"));repo.enter(id())!!();val oldVisit=repo.lifetime();val stale=repo.start()!!
            repo.retire();stale();assertEquals(2,f.server.requestCount)
            f.reply(vector("eligible"));repo.enter(id())!!();repo.leave(oldVisit);assertNotNull(repo.state.value.observation)
            val newer=repo.start()!!;s.accept(s.beginIntent(),SecretTokens("replacement-access","replacement-refresh","replacement-owner"));repo.retire();newer()
            assertEquals(3,f.server.requestCount);assertNull(repo.state.value.playlist)
        }
    }
    @Test fun heldOldAccountReadCannotPublishOrClearNewVisitState() {
        HttpsFixture().use {f->
            val (api,detail,s)=ready(f);val repo=PlaylistSourceSyncRepository(api,detail,newOperation=::key)
            f.reply(vector("eligible"));repo.enter(id())!!()
            val entered=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1)
            val count=java.util.concurrent.atomic.AtomicInteger()
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                if(request.url.encodedPath.endsWith("source-sync")&&count.incrementAndGet()==1){entered.countDown();check(release.await(5,TimeUnit.SECONDS));return mockwebserver3.MockResponse.Builder().body(vector("pending")).build()}
                return mockwebserver3.MockResponse.Builder().body(if(request.url.encodedPath.endsWith("source-sync"))vector("eligible")else vector("detail-before")).build()
            }}
            val pool=java.util.concurrent.Executors.newSingleThreadExecutor()
            try {
                val old=repo.refresh()!!;val future=pool.submit {old()};assertTrue(entered.await(3,TimeUnit.SECONDS))
                repo.retire();s.accept(s.beginIntent(),SecretTokens("new-access","new-refresh","new-owner"));detail.open(id());repo.enter(id())!!()
                val fresh=repo.state.value;assertNotNull(fresh.observation)
                release.countDown();future.get(5,TimeUnit.SECONDS)
                assertSame(fresh,repo.state.value);assertFalse(repo.state.value.busy)
            }finally{release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(5,TimeUnit.SECONDS))}
        }
    }
    @Test fun obsoleteSyncPublicationRequiresGetOnlyRecoveryAfterActualRenameReadback() {
        HttpsFixture().use {f->
            val (api,detail,s)=ready(f)
            val receipts=IntakeReceipts();val scope=s.capture()!!
            val terminal=Json.parseToJsonElement(vector("recovery-complete")).jsonObject.getValue("operation").jsonObject.getValue("id").jsonPrimitive.content
            receipts.begin(s.endpoint.identity,scope.accountId,"playlist-sync",job=terminal,playlistId=id().value,candidateId="1")
            val repo=PlaylistSourceSyncRepository(api,detail,receipts)
            val management=PlaylistManagementRepository(api,detail);val route=management.enter()!!
            val target=management.capture(route)!!
            val renameName=PlaylistJson.summary(Json.parseToJsonElement(vector("rename-ack")).jsonObject).name
            val renameEntered=java.util.concurrent.CountDownLatch(1);val releaseRename=java.util.concurrent.CountDownLatch(1)
            val syncEntered=java.util.concurrent.CountDownLatch(1);val releaseSync=java.util.concurrent.CountDownLatch(1)
            val detailReads=java.util.concurrent.atomic.AtomicInteger()
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                val body=when {
                    request.method=="PUT"->vector("rename-ack")
                    request.url.encodedPath.endsWith("source-sync")->vector("recovery-complete")
                    detailReads.incrementAndGet()==1->{renameEntered.countDown();check(releaseRename.await(5,TimeUnit.SECONDS));vector("rename-before")}
                    else->{syncEntered.countDown();check(releaseSync.await(5,TimeUnit.SECONDS));vector("recovery-detail-after")}
                };return mockwebserver3.MockResponse.Builder().body(body).build()
            }}
            val pool=java.util.concurrent.Executors.newFixedThreadPool(2)
            try {
                val rename=management.rename(target,renameName)!!;val renamed=pool.submit{rename()};assertTrue(renameEntered.await(3,TimeUnit.SECONDS))
                val sync=repo.enter(id())!!;val syncing=pool.submit{sync()};assertTrue(syncEntered.await(3,TimeUnit.SECONDS))
                releaseRename.countDown();renamed.get(5,TimeUnit.SECONDS)
                assertEquals(MutationOutcome.Confirmed,management.state.value.outcome)
                val authored=detail.state.value.detail!!;assertEquals(renameName,authored.playlist.name)
                releaseSync.countDown();syncing.get(5,TimeUnit.SECONDS)
                assertSame("Obsolete source read must not overwrite the newer rename",authored,detail.state.value.detail)
                assertTrue("Refused publication was reported as readback success",repo.state.value.readbackFailed)
                assertFalse(repo.state.value.busy)
                assertEquals("pending",receipts.entries(s.endpoint.identity,scope.accountId).last().phase)
                // Re-read against the now-current owner; no rename/source POST replay.
                repo.refresh()!!();assertFalse(repo.state.value.readbackFailed)
                assertEquals(PlaylistJson.detail(Json.parseToJsonElement(vector("recovery-detail-after")).jsonObject,id()),detail.state.value.detail)
                assertEquals("accepted",receipts.entries(s.endpoint.identity,scope.accountId).last().phase)
                val requests=(0 until f.server.requestCount).map{f.server.takeRequest(2,TimeUnit.SECONDS)!!}
                assertEquals(1,requests.count{it.method=="PUT"});assertEquals(0,requests.count{it.method=="POST"})
            }finally{releaseRename.countDown();releaseSync.countDown();pool.shutdown();assertTrue(pool.awaitTermination(5,TimeUnit.SECONDS))}
        }
    }
    @Test fun completedManagement404RevokesCapturedBrowseButNotListening() {
        val dir=Files.createTempDirectory("sync-404-listening").toFile()
        try {HttpsFixture().use {f->
            val (api,detail,s)=ready(f);val capture=detail.capturePlayback()!!;val scope=s.capture()!!
            DeviceListeningStore(File(dir,"domain.json")).use {store->
                val account=ServerAccount(s.endpoint.identity,scope.accountId);val access=store.unlock(account)
                val source=store.bindServerContent(access,HistoryKey.Server(account,ServerAudioId(capture.detail.tracks.first().id.value)),ContentRevision("a".repeat(64),1000),700000)!!
                val binding=NativeListeningBinding(store,source,UUID.randomUUID(),77,0,0,700000,current={s.current(scope)})
                fun deck(position:Long,end:NativeNaturalEndReceipt?=null)=NativeCallbackDeck(77,77,position,700000,48000,33600000,true,false,end==null,if(end==null)0 else 1,0,rate=1.0,traversalRevision=1,naturalEnd=end)
                binding.observe(deck(1000),1000);binding.observe(deck(8000),2000);val stamp=binding.stamp()
                val repo=PlaylistSourceSyncRepository(api,detail,newOperation=::key)
                f.reply(vector("pending"));f.reply("{}",404);repo.enter(id())!!()
                assertNull("Completed management 404 left a deleted browse detail live",detail.state.value.detail)
                assertNull(detail.state.value.id);assertFalse(detail.ownsPlayback(capture));assertFalse(repo.canStart())
                assertEquals(stamp,binding.stamp());binding.observe(deck(14000),3000);assertEquals(14000L,store.bookmark(source)!!.positionMs)
                binding.observe(deck(700000,NativeNaturalEndReceipt(1,77,77,1)),4000)
                assertNull(store.bookmark(source));assertEquals(1L,binding.consumedCount())
                assertEquals(3,f.server.requestCount)
            }
        }}finally{dir.deleteRecursively()}
    }
    @Test fun acceptedStatusWithoutSnapshotRequestCannotRetireLoadingDetail() {
        HttpsFixture().use {f->
            val (api,detail,_)=ready(f);detail.select(id())
            val repo=PlaylistSourceSyncRepository(api,detail,newOperation=::key)
            f.reply(vector("pending"));repo.enter(id())!!()
            assertEquals(id(),detail.state.value.id);assertTrue(detail.state.value.loading)
            assertTrue(repo.state.value.readbackFailed);assertEquals(2,f.server.requestCount)
        }
    }
    @Test fun held404CannotRevokeAReplacementDetailReference() {
        HttpsFixture().use {f->
            val (api,detail,_)=ready(f);val repo=PlaylistSourceSyncRepository(api,detail,newOperation=::key)
            val entered=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1);val reads=java.util.concurrent.atomic.AtomicInteger()
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                if(request.url.encodedPath.endsWith("source-sync"))return mockwebserver3.MockResponse.Builder().body(vector("pending")).build()
                if(reads.incrementAndGet()==1){entered.countDown();check(release.await(5,TimeUnit.SECONDS));return mockwebserver3.MockResponse.Builder().code(404).body("{}").build()}
                return mockwebserver3.MockResponse.Builder().body(vector("detail-before")).build()
            }}
            val pool=java.util.concurrent.Executors.newSingleThreadExecutor()
            try {
                val work=repo.enter(id())!!;val future=pool.submit{work()};assertTrue(entered.await(3,TimeUnit.SECONDS))
                detail.open(id());val fresh=detail.state.value.detail!!
                release.countDown();future.get(5,TimeUnit.SECONDS)
                assertSame(fresh,detail.state.value.detail);assertTrue(repo.state.value.readbackFailed);assertFalse(repo.state.value.busy)
            }finally{release.countDown();pool.shutdown();assertTrue(pool.awaitTermination(5,TimeUnit.SECONDS))}
        }
    }
    @Test fun retryAfterZeroCannotAutomaticallyRedispatchOneSyncAttempt() {
        val dir=Files.createTempDirectory("sync-wire-attempt").toFile()
        try {HttpsFixture().use {f->
            val (api,detail,s)=ready(f);val file=File(dir,"journal.json");val repo=PlaylistSourceSyncRepository(api,detail,IntakeReceipts(file),::key)
            f.reply(vector("eligible"));repo.enter(id())!!()
            val posts=java.util.concurrent.atomic.AtomicInteger()
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                check(request.method=="POST")
                return if(posts.incrementAndGet()==1)mockwebserver3.MockResponse.Builder().code(503).addHeader("Retry-After","0").body("{}").build()
                else mockwebserver3.MockResponse.Builder().code(202).body(vector("ack")).build()
            }}
            repo.start()!!()
            assertEquals("One explicit sync attempt dispatched more than once",1,posts.get())
            assertTrue(repo.state.value.uncertain)
            val saved=IntakeReceipts(file).entries(s.endpoint.identity,s.capture()!!.accountId).single()
            assertEquals(key(),saved.job);assertEquals("1",saved.candidateId);assertTrue(saved.phase in setOf("pending","uncertain"))
            repo.start()!!();assertEquals(2,posts.get());assertFalse(repo.state.value.uncertain)
            val requests=(0 until f.server.requestCount).map{f.server.takeRequest(2,TimeUnit.SECONDS)!!}.filter{it.method=="POST"}
            assertEquals(2,requests.size);val bodies=requests.map{Json.parseToJsonElement(it.body!!.utf8()).jsonObject}
            assertEquals(bodies[0],bodies[1]);assertEquals(key(),bodies[0].getValue("operationId").jsonPrimitive.content)
        }}finally{dir.deleteRecursively()}
    }
    @Test fun acceptedImportingRetryPublishesMembershipBeforeAnotherWrite() {
        HttpsFixture().use {f->
            val (api,detail,_)=ready(f);val repo=PlaylistSourceSyncRepository(api,detail,newOperation=::key)
            f.reply(vector("eligible"));repo.enter(id())!!();f.reply("{}",503);repo.start()!!()
            f.reply(Json.parseToJsonElement(vector("pending")).jsonObject.getValue("operation").toString(),202);f.reply(vector("detail-pending"));repo.start()!!()
            assertEquals("Accepted importing ACK skipped authoritative membership",PlaylistJson.detail(Json.parseToJsonElement(vector("detail-pending")).jsonObject,id()),detail.state.value.detail)
            assertTrue(repo.state.value.observation!!.operation!!.active);assertFalse(repo.state.value.readbackFailed);assertTrue(repo.canStart())
            f.reply(vector("pending"));f.reply(vector("detail-pending"));repo.refresh()!!()
            assertTrue(repo.state.value.observation!!.operation!!.active);assertFalse(repo.state.value.busy)
        }
    }
    @Test fun legacyExactRetryKeepsOriginalBindingThenRefreshesBindingForFreshIntent() {
        val dir=Files.createTempDirectory("sync-legacy-binding").toFile()
        try {HttpsFixture().use {f->
            val (api,detail,s)=ready(f);var operation=key();val file=File(dir,"journal.json")
            val repo=PlaylistSourceSyncRepository(api,detail,IntakeReceipts(file),newOperation={operation})
            f.reply(JsonObject(Json.parseToJsonElement(vector("eligible")).jsonObject+("bindingId" to JsonPrimitive(0))).toString());repo.enter(id())!!()
            val posts=java.util.concurrent.atomic.AtomicInteger()
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                if(request.method=="POST")return when(posts.incrementAndGet()) {
                    1->mockwebserver3.MockResponse.Builder().code(503).body("{}").build()
                    2->mockwebserver3.MockResponse.Builder().code(202).body(Json.parseToJsonElement(terminalObservation()).jsonObject.getValue("operation").toString()).build()
                    else->mockwebserver3.MockResponse.Builder().code(202).body(vector("ack").replace(key(),operation)).build()
                }
                val body=if(request.url.encodedPath.endsWith("source-sync"))JsonObject(Json.parseToJsonElement(terminalObservation()).jsonObject+("bindingId" to JsonPrimitive(7))).toString() else vector("detail-after")
                return mockwebserver3.MockResponse.Builder().body(body).build()
            }}
            repo.start()!!();assertTrue(repo.state.value.uncertain)
            assertEquals("0",IntakeReceipts(file).entries(s.endpoint.identity,s.capture()!!.accountId).single().candidateId)
            repo.start()!!()
            assertEquals("Terminal recovery left the old legacy request binding actionable",7L,repo.state.value.observation!!.binding)
            val original=IntakeReceipts(file).entries(s.endpoint.identity,s.capture()!!.accountId).single()
            assertEquals("accepted",original.phase);assertEquals(key(),original.job);assertEquals("0",original.candidateId)
            assertFalse(repo.state.value.readbackFailed);operation=UUID.randomUUID().toString();repo.start()!!()
            val requests=(0 until f.server.requestCount).map{f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            val bodies=requests.filter{it.method=="POST"}.map{Json.parseToJsonElement(it.body!!.utf8()).jsonObject}
            assertEquals(listOf(0L,0L,7L),bodies.map{it.getValue("bindingId").jsonPrimitive.long})
            assertEquals(listOf(key(),key(),operation),bodies.map{it.getValue("operationId").jsonPrimitive.content})
            assertTrue(requests.any{it.method=="GET"&&it.url.queryParameter("operationId")==key()})
            val saved=IntakeReceipts(file).entries(s.endpoint.identity,s.capture()!!.accountId)
            assertEquals(original,saved.first());assertEquals("7",saved.last().candidateId)
        }}finally{dir.deleteRecursively()}
    }
    @Test fun refusedExactRetryCannotSettleOriginalUncertainOperation() {
        val dir=Files.createTempDirectory("sync-retry-refused").toFile()
        try {HttpsFixture().use {f->
            val (api,detail,s)=ready(f);val file=File(dir,"journal.json");val repo=PlaylistSourceSyncRepository(api,detail,IntakeReceipts(file),::key)
            f.reply(vector("eligible"));repo.enter(id())!!();f.reply("{}",503);repo.start()!!()
            val original=IntakeReceipts(file).entries(s.endpoint.identity,s.capture()!!.accountId).single()
            f.reply("{}",401);repo.start()!!()
            assertTrue("Rejected retry discarded possibly committed original",repo.state.value.uncertain)
            val retained=IntakeReceipts(file).entries(s.endpoint.identity,s.capture()!!.accountId).single()
            assertEquals(original,retained);assertTrue(repo.state.value.error)
            val recovered=PlaylistSourceSyncRepository(api,detail,IntakeReceipts(file),::key)
            f.reply(vector("pending"));f.reply(vector("detail-pending"));recovered.enter(id())!!()
            assertFalse(recovered.state.value.uncertain)
            val requests=(0 until f.server.requestCount).map{f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            assertEquals(2,requests.count{it.method=="POST"});assertEquals(key(),requests[requests.lastIndex-1].url.queryParameter("operationId"))
        }}finally{dir.deleteRecursively()}
    }
    @Test fun definitiveFreshRefusalMaySettleOnlyItsFreshReceipt() {
        HttpsFixture().use {f->
            val (api,detail,s)=ready(f);val journal=IntakeReceipts();val repo=PlaylistSourceSyncRepository(api,detail,journal,::key)
            f.reply(vector("eligible"));repo.enter(id())!!();f.reply("{}",401);repo.start()!!()
            assertFalse(repo.state.value.uncertain);assertTrue(repo.state.value.error)
            assertEquals("refused",journal.entries(s.endpoint.identity,s.capture()!!.accountId).single().phase)
            f.reply(vector("eligible"));repo.refresh()!!()
            val requests=(0 until f.server.requestCount).map{f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            assertNull(requests.last().url.queryParameter("operationId"));assertEquals(1,requests.count{it.method=="POST"})
        }
    }
    /** Only the filesystem boundary fails once; the real journal and atomic move still run. */
    private class JournalFile(path:String):File(path) {
        var failNextSave=false
        private var parentReads=0
        override fun getParentFile():File? {
            parentReads++
            if(parentReads%2==0) {
                if(failNextSave){failNextSave=false;return File(path)}
            }
            return super.getParentFile()
        }
    }
    private fun terminalObservation():String {
        val body=Json.parseToJsonElement(vector("complete")).jsonObject
        return JsonObject(body+("operation" to JsonObject(body.getValue("operation").jsonObject+("id" to JsonPrimitive(key()))))).toString()
    }
    @Test fun acceptedLegacyAckSurvivesFailedStatusRecoveryWithoutPost() { legacyReadbackFailure(false,false) }
    @Test fun legacyBindingFailureStillPublishesIndependentManagement() { legacyReadbackFailure(false,true) }
    @Test fun legacyBindingFailureStillRetiresMatchingManagement404() { legacyReadbackFailure(true,true) }
    private fun legacyReadbackFailure(missing:Boolean,membershipFirst:Boolean) {
        val dir=Files.createTempDirectory("legacy-independent-readback").toFile()
        try {HttpsFixture().use {f->
            val (api,detail,s)=ready(f);val file=File(dir,"journal.json");var operation=key()
            val repo=PlaylistSourceSyncRepository(api,detail,IntakeReceipts(file),newOperation={operation})
            f.reply(JsonObject(Json.parseToJsonElement(vector("eligible")).jsonObject+("bindingId" to JsonPrimitive(0))).toString());repo.enter(id())!!()
            f.reply("{}",503);repo.start()!!()
            val original=IntakeReceipts(file).entries(s.endpoint.identity,s.capture()!!.accountId).single()
            val resolved=java.util.concurrent.atomic.AtomicBoolean(false);val acceptedBeforeRead=java.util.concurrent.atomic.AtomicBoolean(false)
            val management=java.util.concurrent.atomic.AtomicInteger();val posts=java.util.concurrent.atomic.AtomicInteger()
            f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                if(request.method=="POST") {
                    posts.incrementAndGet()
                    return mockwebserver3.MockResponse.Builder().code(202).body(if(operation==key())Json.parseToJsonElement(terminalObservation()).jsonObject.getValue("operation").toString() else vector("ack").replace(key(),operation)).build()
                }
                if(request.url.encodedPath.endsWith("source-sync")) {
                    acceptedBeforeRead.set(repo.state.value.observation?.operation?.accepted==true&&repo.state.value.readbackFailed)
                    return if(resolved.get())mockwebserver3.MockResponse.Builder().body(JsonObject(Json.parseToJsonElement(terminalObservation()).jsonObject+("bindingId" to JsonPrimitive(7))).toString()).build()
                    else mockwebserver3.MockResponse.Builder().code(503).body("{}").build()
                }
                management.incrementAndGet()
                return mockwebserver3.MockResponse.Builder().code(if(missing)404 else 200).body(if(missing)"{}"else vector("detail-after")).build()
            }}
            repo.start()!!()
            if(membershipFirst)assertEquals("Binding failure suppressed independent management GET",1,management.get())
            assertTrue("Accepted ACK was not recorded before fallible binding IO",acceptedBeforeRead.get())
            assertTrue(repo.state.value.observation!!.operation!!.accepted);assertTrue(repo.state.value.readbackFailed)
            assertNull("Accepted recovery offered POST replay",repo.start())
            if(missing) {assertNull(detail.state.value.id);assertNull(detail.state.value.detail)} else {
                assertEquals(PlaylistJson.detail(Json.parseToJsonElement(vector("detail-after")).jsonObject,id()),detail.state.value.detail)
                repo.refresh()!!();assertTrue(repo.state.value.readbackFailed);assertTrue(repo.state.value.observation!!.operation!!.accepted)
                assertNull("Failed status read cleared accepted recovery",repo.start());assertEquals(2,management.get())
                assertEquals(original,IntakeReceipts(file).entries(s.endpoint.identity,s.capture()!!.accountId).single())
                resolved.set(true);repo.refresh()!!();assertFalse(repo.state.value.readbackFailed);assertEquals(7L,repo.state.value.observation!!.binding)
                operation=UUID.randomUUID().toString();repo.start()!!();assertEquals(2,posts.get())
                val requests=(0 until f.server.requestCount).map{f.server.takeRequest(2,TimeUnit.SECONDS)!!}
                val bodies=requests.filter{it.method=="POST"}.map{Json.parseToJsonElement(it.body!!.utf8()).jsonObject}
                assertEquals(listOf(0L,0L,7L),bodies.map{it.getValue("bindingId").jsonPrimitive.long})
                assertEquals(listOf(key(),key(),operation),bodies.map{it.getValue("operationId").jsonPrimitive.content})
            }
        }}finally{dir.deleteRecursively()}
    }
    @Test fun freshBeginFailureCannotRewritePreviousReceiptOrOfferUnsentExactRetry() {
        val dir=Files.createTempDirectory("sync-begin-failure").toFile()
        try {HttpsFixture().use {f->
            val (api,detail,s)=ready(f);val file=JournalFile(File(dir,"journal.json").path);val journal=IntakeReceipts(file)
            var operation=key();val repo=PlaylistSourceSyncRepository(api,detail,journal,{operation})
            f.reply(vector("eligible"));repo.enter(id())!!();f.reply(vector("ack"),202);repo.start()!!()
            f.reply(vector("pending"));f.reply(vector("detail-pending"));repo.refresh()!!()
            val before=file.readBytes();val original=journal.entries(s.endpoint.identity,s.capture()!!.accountId).single()
            operation=UUID.randomUUID().toString();file.failNextSave=true
            val requests=f.server.requestCount;repo.start()!!()
            assertArrayEquals("Fresh begin failure rewrote A with the unsent B identity",before,file.readBytes())
            assertEquals(original,IntakeReceipts(File(file.path)).entries(s.endpoint.identity,s.capture()!!.accountId).single())
            assertEquals(requests,f.server.requestCount);assertTrue(repo.state.value.error)
            assertFalse("No durable B exists to retry",repo.state.value.uncertain)
            assertEquals(key(),repo.state.value.observation!!.operation!!.id)
            f.reply(vector("ack").replace(key(),operation),202);repo.start()!!()
            val saved=IntakeReceipts(File(file.path)).entries(s.endpoint.identity,s.capture()!!.accountId)
            assertEquals(original,saved.first());assertEquals(operation,saved.last().job);assertEquals("1",saved.last().candidateId)
            assertEquals(requests+1,f.server.requestCount)
        }}finally{dir.deleteRecursively()}
    }
    @Test fun retirementAfterDurableBeginBeforeDispatchKeepsExactPendingRecovery() {
        val dir=Files.createTempDirectory("sync-before-dispatch").toFile()
        try {HttpsFixture().use {f->
            val (_,detail,s)=ready(f);val file=File(dir,"journal.json");val journal=IntakeReceipts(file)
            lateinit var repo:PlaylistSourceSyncRepository
            val intercepted=java.util.concurrent.atomic.AtomicBoolean(false)
            val client=f.client.newBuilder().addNetworkInterceptor {chain->
                if(chain.request().method=="POST") {
                    // Actual begin has returned and its atomic file is readable;
                    // the canonical API WireGuard has not dispatched the POST.
                    val saved=IntakeReceipts(file).entries(s.endpoint.identity,s.capture()!!.accountId).single()
                    assertEquals("pending",saved.phase);assertEquals(key(),saved.job)
                    intercepted.set(true)
                    repo.retire()
                }
                chain.proceed(chain.request())
            }.build()
            repo=PlaylistSourceSyncRepository(SoundQApi(s,client),detail,journal,::key)
            f.reply(vector("eligible"));repo.enter(id())!!()
            repo.start()!!()
            assertTrue("Post-begin/pre-dispatch boundary was not reached",intercepted.get())
            assertEquals(2,f.server.requestCount)
            val receipt=IntakeReceipts(File(file.path)).entries(s.endpoint.identity,s.capture()!!.accountId).single()
            assertEquals(key(),receipt.job);assertEquals("pending",receipt.phase);assertEquals("1",receipt.candidateId)
            f.reply(vector("pending"));f.reply(vector("detail-pending"));repo.enter(id())!!()
            val requests=(0 until f.server.requestCount).map{f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            assertEquals(0,requests.count{it.method=="POST"});assertEquals(key(),requests[2].url.queryParameter("operationId"))
        }}finally{dir.deleteRecursively()}
    }
    @Test fun terminalExactRetryMustPublishAuthoritativeMembershipBeforeCompletion() {
        HttpsFixture().use {f->
            val (api,detail,_)=ready(f);val repo=PlaylistSourceSyncRepository(api,detail,newOperation=::key)
            f.reply(vector("eligible"));repo.enter(id())!!();f.reply("{}",503);repo.start()!!()
            assertTrue(repo.state.value.uncertain)
            val terminal=Json.parseToJsonElement(terminalObservation()).jsonObject.getValue("operation").toString()
            f.reply(terminal,202);f.reply(vector("detail-after"));repo.start()!!()
            assertEquals("Terminal retry ACK did not read the playlist",PlaylistJson.detail(Json.parseToJsonElement(vector("detail-after")).jsonObject,id()),detail.state.value.detail)
            assertFalse(repo.state.value.uncertain);assertFalse(repo.state.value.readbackFailed);assertFalse(repo.state.value.busy)
            val requests=(0 until f.server.requestCount).map{f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            assertEquals(2,requests.count{it.method=="POST"})
            assertTrue(requests.filter{it.method=="POST"}.all{Json.parseToJsonElement(it.body!!.utf8()).jsonObject.getValue("operationId").jsonPrimitive.content==key()})
        }
    }
    @Test fun terminalRetryReadbackFailureRetainsDurableGetRecovery() {
        val dir=Files.createTempDirectory("sync-terminal-recovery").toFile()
        try {HttpsFixture().use {f->
            val (api,detail,s)=ready(f);val file=File(dir,"journal.json");val journal=IntakeReceipts(file)
            val repo=PlaylistSourceSyncRepository(api,detail,journal,::key)
            f.reply(vector("eligible"));repo.enter(id())!!();f.reply("{}",503);repo.start()!!()
            val before=detail.state.value.detail
            f.reply(Json.parseToJsonElement(terminalObservation()).jsonObject.getValue("operation").toString(),202);f.reply("{}",503);repo.start()!!()
            assertTrue("Terminal ACK without membership is not reconciled",repo.state.value.readbackFailed)
            assertTrue(repo.state.value.uncertain);assertSame(before,detail.state.value.detail);assertFalse(repo.state.value.busy)
            assertTrue(journal.entries(s.endpoint.identity,s.capture()!!.accountId).single().phase in setOf("pending","uncertain"))
            val recovered=PlaylistSourceSyncRepository(api,detail,IntakeReceipts(file),::key)
            f.reply(terminalObservation());f.reply(vector("detail-after"));recovered.enter(id())!!()
            assertFalse(recovered.state.value.readbackFailed);assertFalse(recovered.state.value.uncertain)
            val requests=(0 until f.server.requestCount).map{f.server.takeRequest(2,TimeUnit.SECONDS)!!}
            assertEquals(2,requests.count{it.method=="POST"});assertEquals(key(),requests[requests.lastIndex-1].url.queryParameter("operationId"))
        }}finally{dir.deleteRecursively()}
    }
    @Test fun retiredPostCannotDowngradeNewVisitAcceptedOrPendingJournal() {retiredPostJournal(true)}
    @Test fun retiredPostKeepsUnreconciledPendingIntentAvailable() {retiredPostJournal(false)}
    private fun retiredPostJournal(reconciled:Boolean) {
            val dir=Files.createTempDirectory("sync-old-post").toFile()
            try {HttpsFixture().use {f->
                val (api,detail,s)=ready(f);val file=File(dir,"journal.json");val journal=IntakeReceipts(file)
                val repo=PlaylistSourceSyncRepository(api,detail,journal,::key)
                f.reply(vector("eligible"));repo.enter(id())!!()
                val entered=java.util.concurrent.CountDownLatch(1);val release=java.util.concurrent.CountDownLatch(1)
                f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
                    if(request.method=="POST"){entered.countDown();check(release.await(5,TimeUnit.SECONDS));return mockwebserver3.MockResponse.Builder().code(202).body(vector("ack")).build()}
                    val body=if(request.url.encodedPath.endsWith("source-sync"))if(reconciled)terminalObservation()else vector("eligible") else vector("detail-after")
                    return mockwebserver3.MockResponse.Builder().body(body).build()
                }}
                val pool=java.util.concurrent.Executors.newSingleThreadExecutor()
                try {
                    val work=repo.start()!!;val old=pool.submit{work()};assertTrue(entered.await(3,TimeUnit.SECONDS))
                    repo.retire();repo.enter(id())!!()
                    val fresh=repo.state.value;val before=file.readBytes();val owner=s.capture()!!.accountId
                    assertEquals(if(reconciled)"accepted"else "pending",IntakeReceipts(file).entries(s.endpoint.identity,owner).single().phase)
                    release.countDown();old.get(5,TimeUnit.SECONDS)
                    assertArrayEquals("Retired POST rewrote the newer visit's journal",before,file.readBytes())
                    assertSame(fresh,repo.state.value)
                    val requests=(0 until f.server.requestCount).map{f.server.takeRequest(2,TimeUnit.SECONDS)!!}
                    assertEquals(1,requests.count{it.method=="POST"});assertEquals(key(),requests[3].url.queryParameter("operationId"))
                }finally{release.countDown();pool.shutdown();assertTrue(pool.awaitTermination(5,TimeUnit.SECONDS))}
            }}finally{dir.deleteRecursively()}
    }
    @Test fun sourceSyncJournalFailureIsAtomicIdentityQualifiedAndLeavesSiblingFinishUnchanged() {
        val dir=Files.createTempDirectory("sync-journal-cas").toFile()
        try {
            val file=File(dir,"journal.json");val journal=IntakeReceipts(file);val endpoint="https://fixture.invalid/api/v1";val account="fixture-owner"
            val pending=journal.begin(endpoint,account,"playlist-sync",job=key(),candidateId="1",playlistId=id().value)
            journal.failSourceSync(endpoint,account,pending,false)
            assertEquals("uncertain",IntakeReceipts(file).entries(endpoint,account).single().phase)
            journal.finish(endpoint,account,pending,"accepted",key());val accepted=file.readBytes()
            journal.failSourceSync(endpoint,account,pending,true);assertArrayEquals(accepted,file.readBytes())
            val next=journal.begin(endpoint,account,"playlist-sync",job=key(),candidateId="2",playlistId=id().value);val before=file.readBytes()
            journal.failSourceSync(endpoint,account,next.copy(candidateId="wrong"),true);assertArrayEquals(before,file.readBytes())
            journal.failSourceSync(endpoint,account,next,true);assertEquals("refused",IntakeReceipts(file).entries(endpoint,account).last().phase)
            val sibling=journal.begin(endpoint,account,"download",job=key());journal.finish(endpoint,account,sibling,"accepted",key());journal.finish(endpoint,account,sibling,"uncertain",key())
            assertEquals("uncertain",IntakeReceipts(file).entries(endpoint,account).last().phase)
        }finally{dir.deleteRecursively()}
    }
    @Test fun libraryRefinementRetiresItsOwnBrowseCaptureIndependentlyOfPlaylistSync() {
        HttpsFixture().use {f->
            val (api,_,s)=ready(f)
            val library=LibraryRepository(s,api::library,{_,_,_->error("No Library mutation authorized")})
            f.reply(vector("library-before"));library.refine(LibraryQuery())
            val capture=library.capturePlayback(library.state.value.rows,0)!!
            assertTrue(library.ownsPlayback(capture))
            f.reply(vector("library-pending"));library.refine(LibraryQuery())
            assertFalse("Library refinement retires its own query lifetime",library.ownsPlayback(capture))
        }
    }
    @Test fun browseReadbackRevokesBrowseCaptureButPreservesListeningSourceGenerationCheckpointAndNaturalEnd() {
        val dir=Files.createTempDirectory("source-sync-listening").toFile()
        try {HttpsFixture().use {f->
            val (api,detail,s)=ready(f);val browse=detail.capturePlayback()!!;val scope=s.capture()!!
            DeviceListeningStore(File(dir,"domain.json")).use {store->
                val account=ServerAccount(s.endpoint.identity,scope.accountId);val access=store.unlock(account)
                val source=store.bindServerContent(access,HistoryKey.Server(account,ServerAudioId(browse.detail.tracks.first().id.value)),ContentRevision("a".repeat(64),1000),700000)!!
                val owner=source.owner;val occurrence=UUID.randomUUID();val generation=77L
                val binding=NativeListeningBinding(store,source,occurrence,generation,0,0,700000,current={s.current(scope)})
                fun deck(position:Long,end:NativeNaturalEndReceipt?=null)=NativeCallbackDeck(generation,generation,position,700000,48000,33600000,true,false,end==null,if(end==null)0 else 1,0,rate=1.0,traversalRevision=1,naturalEnd=end)
                binding.observe(deck(1000),1000);binding.observe(deck(8000),2000)
                assertEquals(8000L,store.bookmark(source)!!.positionMs)
                val stamp=binding.stamp();val intent=binding.intentStamp()
                val repo=PlaylistSourceSyncRepository(api,detail,newOperation=::key)
                f.reply(vector("eligible"));repo.enter(id())!!();f.reply(vector("ack"),202);repo.start()!!()
                f.reply(vector("pending"));f.reply(vector("detail-pending"));repo.refresh()!!()
                assertFalse("Old detail browse captures must retire",detail.ownsPlayback(browse))
                assertTrue(s.current(scope));assertEquals(owner,source.owner);assertEquals(stamp,binding.stamp());assertEquals(intent,binding.intentStamp())
                binding.observe(deck(14000),3000);assertEquals(14000L,store.bookmark(source)!!.positionMs)
                binding.observe(deck(700000,NativeNaturalEndReceipt(1,generation,generation,1)),4000)
                assertNull("Same source still owns qualified natural completion",store.bookmark(source))
                assertEquals(1L,binding.consumedCount())
            }
        }}finally{dir.deleteRecursively()}
    }
}
