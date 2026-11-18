package com.soundq.android.data

import com.soundq.android.data.playlists.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.*

/** Actual ProductApp callback bodies/control body, platform/render facades only. */
class PlaylistSyncLifecycleTest {
 private fun vector(name:String)=javaClass.getResourceAsStream("/playlist-sync/$name.json")!!.bufferedReader().use{it.readText()}
 private fun id()=PlaylistId(Json.parseToJsonElement(vector("detail-before")).jsonObject.getValue("id").jsonPrimitive.long)
 private fun key()=Json.parseToJsonElement(vector("ack")).jsonObject.getValue("id").jsonPrimitive.content
 private fun ready(f:HttpsFixture,operation:String=key()):Pair<PlaylistDetailRepository,PlaylistSourceSyncRepository>{
  val s=AccountSession(f.endpoint,MemoryStore());check(s.accept(s.beginIntent(),SecretTokens("fixture-access","fixture-refresh","fixture-owner")))
  val api=SoundQApi(s,f.client);val detail=PlaylistDetailRepository(api);f.reply(vector("detail-before"));detail.open(id())
  return detail to PlaylistSourceSyncRepository(api,detail,newOperation={operation})
 }
 @Test fun actualPauseAndDisposalRevokeQueuedPostBeforeCancellationOrResumeABA(){
  for(dispose in listOf(false,true))HttpsFixture().use{f->
   val (_,repo)=ready(f);val old=ProductSyncLifecycleProbe(repo);old.resume()
   f.reply(vector("eligible"));repo.enter(id())!!();val command=repo.start()!!;val keys=old.effectKeys()
   if(dispose)old.dispose()else{old.pause();old.resume()}
   f.reply(vector("ack"),202);command()
   assertEquals("A retired queued command reached POST",2,f.server.requestCount)
   assertNull(repo.state.value.playlist)
   if(!dispose)assertNotEquals("Foreground ABA did not renew the actual effect keys",keys,old.effectKeys())
   // A fresh admitted visit works; old callback/cleanup cannot retire it.
   if(dispose){val fresh=ProductSyncLifecycleProbe(repo);fresh.resume()}
   f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest)=mockwebserver3.MockResponse.Builder().code(if(request.method=="POST")202 else 200).body(vector(if(request.method=="POST")"ack" else "eligible")).build()}
   repo.enter(id())!!();val state=repo.state.value
   if(dispose)old.sync()
   assertSame(state,repo.state.value);repo.start()!!()
   assertEquals(4,f.server.requestCount)
  }
 }
 @Test fun queuedInitialVisitReadCannotAcquireAfterActualPause(){
  HttpsFixture().use{f->
   val (_,repo)=ready(f);val lifecycle=ProductSyncLifecycleProbe(repo);lifecycle.resume()
   val initial=repo.enter(id())!!;lifecycle.pause();f.reply(vector("eligible"));initial()
   assertEquals("Queued initial status acquired after pause",1,f.server.requestCount)
   lifecycle.resume();f.reply(vector("eligible"));repo.enter(id())!!();assertNotNull(repo.state.value.observation)
  }
 }
 @Test fun actualPauseRevokesHeldGetAndCannotPublishAcrossForegroundABA(){
  HttpsFixture().use{f->
   val (_,repo)=ready(f);val lifecycle=ProductSyncLifecycleProbe(repo);lifecycle.resume()
   f.reply(vector("eligible"));repo.enter(id())!!()
   val entered=CountDownLatch(1);val release=CountDownLatch(1);val reads=java.util.concurrent.atomic.AtomicInteger()
   f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse{
    if(!request.url.encodedPath.endsWith("source-sync"))return mockwebserver3.MockResponse.Builder().body(vector("detail-pending")).build()
    if(reads.incrementAndGet()==1){entered.countDown();check(release.await(5,TimeUnit.SECONDS));return mockwebserver3.MockResponse.Builder().body(vector("pending")).build()}
    return mockwebserver3.MockResponse.Builder().body(vector("eligible")).build()
   }}
   val pool=Executors.newSingleThreadExecutor()
   try{
    val work=repo.refresh()!!;val future=pool.submit{work()};assertTrue(entered.await(3,TimeUnit.SECONDS))
    lifecycle.pause();assertNull("ON_PAUSE must retire synchronously",repo.state.value.playlist)
    lifecycle.resume();repo.enter(id())!!();val freshWork=repo.refresh()!!;val fresh=repo.state.value
    release.countDown();future.get(5,TimeUnit.SECONDS)
    assertSame(fresh,repo.state.value);assertTrue("Old GET cleared the new admitted read",repo.state.value.busy)
    freshWork();assertFalse(repo.state.value.busy);assertEquals(3,reads.get())
   }finally{release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(5,TimeUnit.SECONDS))}
  }
 }
 @Test fun settingsReplacementRetiresSyncAndReturnAdmitsFreshVisit(){
  HttpsFixture().use{f->
   val (_,repo)=ready(f);val lifecycle=ProductSyncLifecycleProbe(repo);lifecycle.resume()
   f.reply(vector("eligible"));repo.enter(id())!!();val owner=repo.lifetime();val old=repo.start()!!
   lifecycle.settings(true);assertNull("Hidden detail kept its sync visit",repo.state.value.playlist)
   old();assertEquals(2,f.server.requestCount)
   lifecycle.settings(false);f.reply(vector("eligible"));repo.enter(id())!!()
   assertNotEquals(owner,repo.lifetime());f.reply(vector("ack"),202);repo.start()!!();assertEquals(4,f.server.requestCount)
  }
 }
 @Test fun oldPollCannotClaimNewVisitBeforeItsDurableRestoration(){
  HttpsFixture().use{f->
   val s=AccountSession(f.endpoint,MemoryStore());check(s.accept(s.beginIntent(),SecretTokens("fixture-access","fixture-refresh","fixture-owner")))
   val api=SoundQApi(s,f.client);val detail=PlaylistDetailRepository(api);f.reply(vector("detail-before"));detail.open(id())
   val receipts=com.soundq.android.data.acquisition.IntakeReceipts()
   receipts.begin(s.endpoint.identity,s.capture()!!.accountId,"playlist-sync",job=key(),playlistId=id().value,candidateId="1")
   val repo=PlaylistSourceSyncRepository(api,detail,receipts,::key);val lifecycle=ProductSyncLifecycleProbe(repo);lifecycle.resume()
   f.reply(vector("pending"));f.reply(vector("detail-pending"));repo.enter(id())!!();val owner=repo.lifetime()
   val delayed={lifecycle.poll(owner)};repo.retire();val initial=repo.enter(id())!!
   // Claim is the original race boundary, before executing any resulting IO.
   // A held response is not needed: queue the old poll behind the new enter.
   f.reply(vector("eligible"));delayed()
   assertFalse("Old poll claimed new-visit busy before receipt restoration",repo.state.value.busy)
   assertNull(repo.state.value.observation);assertEquals(3,f.server.requestCount)
   // The original acknowledged active receipt may not need recovery. Seed an
   // unresolved exact intent for the new visit's real restoration read.
   val pending=receipts.begin(s.endpoint.identity,s.capture()!!.accountId,"playlist-sync",job=key(),playlistId=id().value,candidateId="1")
   f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest)=mockwebserver3.MockResponse.Builder().body(vector(if(request.url.encodedPath.endsWith("source-sync"))"pending"else "detail-pending")).build()}
   initial();assertNotNull(repo.state.value.observation);assertFalse(repo.state.value.busy)
   val requests=(0 until f.server.requestCount).map{f.server.takeRequest(2,TimeUnit.SECONDS)!!}
   assertEquals(pending.job,requests[3].url.queryParameter("operationId"));assertEquals(0,requests.count{it.method=="POST"})
   lifecycle.poll(repo.lifetime());assertFalse(repo.state.value.busy)
  }
 }
 @Test fun writeReadinessDoesNotDisableIndependentRecoveryOrSwapCallbacks(){
  val state=PlaylistSourceSyncState(playlist=id(),observation=SourceSyncObservation(true,1,null,null),uncertain=true)
  var sync=0;var read=0
  val disabled=SourceSyncControlProbe();disabled.render(state,{sync++},{read++},writeReady=false)
  assertNull("Unready matching detail still offers a write",disabled.buttons["Retry sync request"])
  disabled.buttons.getValue("Read sync status")();assertEquals(1,read);assertEquals(0,sync)
  val ready=SourceSyncControlProbe();ready.render(state,{sync++},{read++},writeReady=true)
  ready.buttons.getValue("Read sync status")();assertEquals(2,read);assertEquals(0,sync)
  ready.buttons.getValue("Retry sync request")();assertEquals(2,read);assertEquals(1,sync)
 }
 @Test fun actualDetailReadinessGatesWriteButNotStatusRecovery(){
  HttpsFixture().use{f->
   val (detail,repo)=ready(f);f.reply(vector("eligible"));repo.enter(id())!!()
   fun checkReady(expected:Boolean) {
    assertEquals(expected,repo.canStart())
    val controls=SourceSyncControlProbe();controls.render(repo.state.value,{}, {},writeReady=repo.canStart())
    assertEquals(expected,controls.buttons.containsKey("Sync source"))
    if(!expected){assertNull(repo.start());assertNotNull(controls.buttons["Read sync status"])}
   }
   checkReady(true)
   val loading=detail.select(id())!!;checkReady(false)
   f.reply("{}",503);detail.load(loading);checkReady(false)
   val noManage=JsonObject(Json.parseToJsonElement(vector("detail-before")).jsonObject+("canManage" to JsonPrimitive(false))).toString()
   f.reply(noManage);detail.open(id());checkReady(false)
   f.reply(vector("detail-before"));detail.open(id());checkReady(true)
   detail.select(PlaylistId(id().value+1));checkReady(false)
  }
 }
 @Test fun supersededIneligibleSourceOffersActualReadOnlyLatestStatusControl(){
  HttpsFixture().use{f->
   val opKey=Json.parseToJsonElement(vector("recovery-ack")).jsonObject.getValue("id").jsonPrimitive.content
   val (_,repo)=ready(f,opKey);f.reply(vector("eligible"));repo.enter(id())!!();f.reply(vector("recovery-ack"),202);repo.start()!!()
   f.reply(vector("superseded"));f.reply(vector("recovery-detail-pending"));repo.refresh()!!()
   assertEquals("superseded",repo.state.value.observation!!.operation!!.status);assertFalse(repo.state.value.observation!!.eligible)
   val controls=SourceSyncControlProbe();controls.render(repo.state.value,{error("No new POST is a recovery read")},{repo.refresh()!!()})
   assertNotNull("Superseded instruction has no read action",controls.buttons["Read sync status"])
   assertNull(controls.buttons["Sync source"])
   f.reply(vector("current-ineligible"));f.reply(vector("recovery-detail-pending"));controls.buttons.getValue("Read sync status")()
   val requests=(0 until f.server.requestCount).map{f.server.takeRequest(2,TimeUnit.SECONDS)!!}
   assertEquals(1,requests.count{it.method=="POST"})
   val status=requests.filter{it.url.encodedPath.endsWith("source-sync")&&it.method=="GET"}
   assertEquals(opKey,status[status.lastIndex-1].url.queryParameter("operationId"))
   assertNull("Latest status still pinned the superseded UUID",status.last().url.queryParameter("operationId"))
   assertNotEquals(opKey,repo.state.value.observation!!.operation!!.id)
  }
 }
}
