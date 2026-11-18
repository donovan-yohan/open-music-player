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
            f.reply(vector("ack"),202);val action=repo.start()!!;action();action()
            assertFalse(repo.state.value.busy);assertEquals(key(),repo.state.value.observation!!.operation!!.id)
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
    @Test fun browseReadbackRevokesBrowseCaptureButPreservesListeningSourceGenerationCheckpointAndNaturalEnd() {
        val dir=Files.createTempDirectory("source-sync-listening").toFile()
        try {HttpsFixture().use {f->
            val (api,detail,s)=ready(f);val browse=detail.capturePlayback()!!;val scope=s.capture()!!
            val library=LibraryRepository(s,api::library,{_,_,_->error("No Library mutation authorized")})
            f.reply(vector("library-before"));library.refine(LibraryQuery())
            val libraryBrowse=library.capturePlayback(library.state.value.rows,0)!!
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
                f.reply(vector("library-pending"));library.refine(LibraryQuery())
                assertFalse("Old Library browse authority must retire",library.ownsPlayback(libraryBrowse))
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
