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
 private fun listPage(created:Boolean=false)="""{"data":[{"id":${id().value},"name":"Source","isPublic":false,"trackCount":0,"durationMs":0},{"id":99,"name":"Other","isPublic":false,"trackCount":0,"durationMs":0}${if(created)",{\"id\":88,\"name\":\"Created\",\"isPublic\":false,\"trackCount\":0,\"durationMs\":0}"else ""}],"total":${if(created)3 else 2},"limit":20,"offset":0}"""
 private fun graph(f:HttpsFixture,dir:java.io.File,client:okhttp3.OkHttpClient=f.client):SourceSyncAppGraphProbe {
  val s=AccountSession(f.endpoint,MemoryStore());check(s.accept(s.beginIntent(),SecretTokens("fixture-access","fixture-refresh","fixture-owner")))
  val graph=SourceSyncAppGraphProbe(SoundQApi(s,client),dir)
  f.reply(vector("detail-before"));graph.playlistDetail.open(id())
  f.reply(listPage());graph.playlists.requestRead(graph.playlists.captureList()!!,PlaylistQuery("source",PlaylistSort.Name,true))!!()
  return graph
 }
 @Test fun changedQuery404AutomaticallyReplacesHeldAndQueuedReads(){for(queued in listOf(false,true))changedQueryReadback(queued,false,false)}
 @Test fun changedQueryAutomaticReplacementFailureIsTruthful(){changedQueryReadback(true,true,false)}
 @Test fun changedQueryReplacementCannotOverwriteNewerQuery(){changedQueryReadback(false,false,true)}
 private fun changedQueryReadback(queued:Boolean,fail:Boolean,replace:Boolean){
  val dir=java.nio.file.Files.createTempDirectory("sync-changed-query").toFile()
  try{HttpsFixture().use{f->
   val owner=java.util.concurrent.atomic.AtomicReference<SourceSyncAppGraphProbe>()
   val locked=java.util.concurrent.atomic.AtomicBoolean(false)
   val client=f.client.newBuilder().addNetworkInterceptor{chain->
    owner.get()?.let {g->if(Thread.holdsLock(g.playlists)||Thread.holdsLock(g.playlistSync))locked.set(true)}
    chain.proceed(chain.request())
   }.build()
   val g=graph(f,dir,client);owner.set(g)
   val query=PlaylistQuery("Other",PlaylistSort.Tracks,false)
   val jobs=mutableListOf<()->Unit>();val actions=PlaylistActions(g.playlists){jobs.add(it)}
   val entered=CountDownLatch(1);val release=CountDownLatch(1);val autoEntered=CountDownLatch(1);val autoRelease=CountDownLatch(1)
   val reads=java.util.concurrent.atomic.AtomicInteger()
   val oldPage=Json.parseToJsonElement(listPage()).jsonObject
   val remaining=oldPage.getValue("data").jsonArray.filter{it.jsonObject.getValue("id").jsonPrimitive.long!=id().value}
   val page=JsonObject(oldPage+("data" to JsonArray(remaining))+("total" to JsonPrimitive(1))).toString()
   val freshRow=JsonObject(remaining.single().jsonObject+("id" to JsonPrimitive(100))+("name" to JsonPrimitive("New")))
   val freshPage=JsonObject(oldPage+("data" to JsonArray(listOf(freshRow)))+("total" to JsonPrimitive(1))).toString()
   f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
    if(request.url.encodedPath=="/api/v1/playlists"){
     if(request.url.queryParameter("q")=="New")return mockwebserver3.MockResponse.Builder().body(freshPage).build()
     if(reads.incrementAndGet()==1&&!queued){entered.countDown();check(release.await(5,TimeUnit.SECONDS));return mockwebserver3.MockResponse.Builder().body(listPage()).build()}
     autoEntered.countDown()
     if(replace)check(autoRelease.await(5,TimeUnit.SECONDS))
     return mockwebserver3.MockResponse.Builder().code(if(fail)503 else 200).body(if(fail)"{}"else page).build()
    }
    return if(request.url.encodedPath.endsWith("source-sync"))mockwebserver3.MockResponse.Builder().body(vector("pending")).build()else mockwebserver3.MockResponse.Builder().code(404).body("{}").build()
   }}
   val pool=Executors.newFixedThreadPool(2)
   try{
    actions.refine(query);assertTrue(g.playlists.state.value.rows.isEmpty());assertTrue(g.playlists.state.value.loading)
    val old=jobs.removeAt(0);val held=if(queued)null else pool.submit{old()}
    if(!queued)assertTrue(entered.await(3,TimeUnit.SECONDS))
    val work=g.playlistSync.enter(id())!!
    var replacement:PlaylistState?=null
    if(replace){
     val syncing=pool.submit{work()};assertTrue("No automatic query replacement was dispatched",autoEntered.await(3,TimeUnit.SECONDS))
     actions.refine(PlaylistQuery("New",PlaylistSort.Name,true));jobs.removeAt(0)();replacement=g.playlists.state.value
     autoRelease.countDown();syncing.get(5,TimeUnit.SECONDS)
     assertSame(replacement,g.playlists.state.value)
    }else{
     work()
     assertTrue("Confirmed absence left changed query empty/idle without replacement",autoEntered.count==0L)
     assertEquals(query,g.playlists.state.value.query);assertFalse(g.playlists.state.value.loading)
     if(fail){assertNotNull(g.playlists.state.value.error);assertTrue(g.playlists.state.value.rows.isEmpty())}
     else{assertEquals(listOf(99L),g.playlists.state.value.rows.map{it.id.value});assertEquals(1,g.playlists.state.value.total);assertNull(g.playlists.state.value.error)}
    }
    val accepted=g.playlists.state.value
    release.countDown();if(queued)old()else held!!.get(5,TimeUnit.SECONDS)
    assertSame(accepted,g.playlists.state.value);if(replace)assertEquals(listOf(100L),g.playlists.state.value.rows.map{it.id.value})
    assertFalse("Automatic query network IO ran under publication lock",locked.get())
    val requests=(0 until f.server.requestCount).map{f.server.takeRequest(2,TimeUnit.SECONDS)!!}
    val requested=requests.filter{it.url.encodedPath=="/api/v1/playlists"&&it.url.queryParameter("q")==query.text}
    assertEquals(if(queued)1 else 2,requested.size)
    assertTrue(requested.all{it.method=="GET"&&it.url.queryParameter("sort")=="track_count"&&it.url.queryParameter("order")=="desc"})
   }finally{release.countDown();autoRelease.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(5,TimeUnit.SECONDS))}
  }}finally{dir.deleteRecursively()}
 }
 @Test fun actualAppGraphMissingReadbackRemovesRowAndFencesDelayedListAndCreateReads(){
  for(create in listOf(false,true)){
   val dir=java.nio.file.Files.createTempDirectory("sync-list-owner").toFile()
   try{HttpsFixture().use{f->
    val graph=graph(f,dir);val entered=CountDownLatch(1);val release=CountDownLatch(1)
    val query=graph.playlists.state.value.query
    f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
     if(request.url.encodedPath=="/api/v1/playlists"){
      if(request.method=="POST")return mockwebserver3.MockResponse.Builder().code(201).body("""{"id":88,"name":"Created","description":"","coverUrl":"","isPublic":false,"trackCount":0,"durationMs":0}""").build()
      entered.countDown();check(release.await(5,TimeUnit.SECONDS));return mockwebserver3.MockResponse.Builder().body(listPage(create)).build()
     }
     return if(request.url.encodedPath.endsWith("source-sync"))mockwebserver3.MockResponse.Builder().body(vector("pending")).build()else mockwebserver3.MockResponse.Builder().code(404).body("{}").build()
    }}
    val pool=Executors.newSingleThreadExecutor()
    try{
     val capture=graph.playlists.captureList()!!
     val old=if(create)pool.submit{graph.playlists.create(capture,PlaylistDraft("Created"))}else pool.submit{graph.playlists.reload(capture)}
     assertTrue(entered.await(3,TimeUnit.SECONDS));val mutation=graph.playlists.state.value.mutation
     graph.playlistSync.enter(id())!!()
     assertNull(graph.playlistDetail.state.value.id)
     assertEquals("Successful matching404 did not notify the actual AppGraph list owner",listOf(99L),graph.playlists.state.value.rows.map{it.id.value})
     assertEquals(query,graph.playlists.state.value.query);assertEquals(1,graph.playlists.state.value.total)
     assertEquals(mutation,graph.playlists.state.value.mutation)
     release.countDown();old.get(5,TimeUnit.SECONDS)
     assertEquals("Delayed list publication resurrected confirmed deletion",listOf(99L),graph.playlists.state.value.rows.map{it.id.value})
     assertFalse(graph.playlists.state.value.loading)
     if(create){assertEquals(88L,graph.playlists.state.value.created!!.id.value);assertEquals(MutationOutcome.ReadbackFailed,graph.playlists.state.value.mutation!!.outcome)}
    }finally{release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(5,TimeUnit.SECONDS))}
   }}finally{dir.deleteRecursively()}
  }
 }
 @Test fun losing404CannotDamageReplacementDetailListOrAccount(){
  for(replaceAccount in listOf(false,true)){
   val dir=java.nio.file.Files.createTempDirectory("sync-list-losing").toFile()
   try{HttpsFixture().use{f->
    val graph=graph(f,dir);val entered=CountDownLatch(1);val release=CountDownLatch(1);val reads=java.util.concurrent.atomic.AtomicInteger()
    f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
     if(request.url.encodedPath.endsWith("source-sync"))return mockwebserver3.MockResponse.Builder().body(vector("pending")).build()
     if(request.url.encodedPath=="/api/v1/playlists")return mockwebserver3.MockResponse.Builder().body(listPage()).build()
     if(reads.incrementAndGet()==1){entered.countDown();check(release.await(5,TimeUnit.SECONDS));return mockwebserver3.MockResponse.Builder().code(404).body("{}").build()}
     return mockwebserver3.MockResponse.Builder().body(vector("detail-before")).build()
    }}
    val pool=Executors.newSingleThreadExecutor()
    try{
     val work=graph.playlistSync.enter(id())!!;val old=pool.submit{work()};assertTrue(entered.await(3,TimeUnit.SECONDS))
     if(replaceAccount){val s=graph.api.session;check(s.accept(s.beginIntent(),SecretTokens("replacement","replacement-refresh","replacement-owner")));graph.playlists.retire()}
     graph.playlistDetail.open(id());graph.playlists.reload();val detail=graph.playlistDetail.state.value;val list=graph.playlists.state.value
     release.countDown();old.get(5,TimeUnit.SECONDS)
     assertSame(detail,graph.playlistDetail.state.value);assertSame(list,graph.playlists.state.value)
    }finally{release.countDown();pool.shutdownNow();assertTrue(pool.awaitTermination(5,TimeUnit.SECONDS))}
   }}finally{dir.deleteRecursively()}
  }
 }
 @Test fun actualGraphLegacyBindingFailureStillRemovesConfirmedMissingListRow(){
  val dir=java.nio.file.Files.createTempDirectory("sync-list-legacy").toFile()
  try{HttpsFixture().use{f->
   val graph=graph(f,dir)
   f.reply(JsonObject(Json.parseToJsonElement(vector("eligible")).jsonObject+("bindingId" to JsonPrimitive(0))).toString());graph.playlistSync.enter(id())!!()
   f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest):mockwebserver3.MockResponse {
    if(request.method=="POST"){
     val operation=Json.parseToJsonElement(request.body!!.utf8()).jsonObject.getValue("operationId")
     val ack=Json.parseToJsonElement(vector("pending")).jsonObject.getValue("operation").jsonObject
     return mockwebserver3.MockResponse.Builder().code(202).body(JsonObject(ack+("id" to operation)).toString()).build()
    }
    return mockwebserver3.MockResponse.Builder().code(if(request.url.encodedPath.endsWith("source-sync"))503 else 404).body("{}").build()
   }}
   graph.playlistSync.start()!!();assertNull(graph.playlistDetail.state.value.id)
   assertEquals(listOf(99L),graph.playlists.state.value.rows.map{it.id.value});assertNull(graph.playlistSync.start())
  }}finally{dir.deleteRecursively()}
 }
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
   val delayed={lifecycle.pollAfterDispatch(owner)};repo.retire();val initial=repo.enter(id())!!
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
   val beforePoll=f.server.requestCount
   lifecycle.poll(repo.lifetime());assertFalse(repo.state.value.busy)
   val polled=(beforePoll until f.server.requestCount).map{f.server.takeRequest(2,TimeUnit.SECONDS)!!}
   assertEquals(2,polled.size)
   val status=polled.filter{it.url.encodedPath.endsWith("source-sync")}
   assertEquals(1,status.size);assertEquals("GET",status.single().method)
   assertEquals(pending.job,status.single().url.queryParameter("operationId"));assertTrue(polled.none{it.method=="POST"})
  }
 }
 @Test fun actualPollGuardSkipsInactiveAndReadsExactlyOnceWhileImporting(){
  HttpsFixture().use{f->
   val s=AccountSession(f.endpoint,MemoryStore());check(s.accept(s.beginIntent(),SecretTokens("fixture-access","fixture-refresh","fixture-owner")))
   val api=SoundQApi(s,f.client);val detail=PlaylistDetailRepository(api);f.reply(vector("detail-before"));detail.open(id())
   val receipts=com.soundq.android.data.acquisition.IntakeReceipts();receipts.begin(s.endpoint.identity,s.capture()!!.accountId,"playlist-sync",job=key(),playlistId=id().value,candidateId="1")
   val repo=PlaylistSourceSyncRepository(api,detail,receipts,::key);val lifecycle=ProductSyncLifecycleProbe(repo);lifecycle.resume()
   var response=vector("eligible")
   f.server.dispatcher=object:mockwebserver3.Dispatcher(){override fun dispatch(request:mockwebserver3.RecordedRequest)=mockwebserver3.MockResponse.Builder().body(if(request.url.encodedPath.endsWith("source-sync"))response else vector("detail-pending")).build()}
   repo.enter(id())!!();val owner=repo.lifetime();val inactive=f.server.requestCount
   lifecycle.poll(owner);assertEquals("Inactive visit polled contrary to ProductApp",inactive,f.server.requestCount)
   response=JsonObject(Json.parseToJsonElement(vector("eligible")).jsonObject+("operation" to Json.parseToJsonElement(vector("ack")))).toString()
   repo.refresh()!!();val beforeResolving=f.server.requestCount;val unchanged=detail.state.value.detail
   (0 until beforeResolving).forEach{assertNotNull(f.server.takeRequest(2,TimeUnit.SECONDS))}
   lifecycle.poll(owner)
   assertEquals(beforeResolving+1,f.server.requestCount);val resolving=f.server.takeRequest(2,TimeUnit.SECONDS)!!
   assertEquals("GET",resolving.method);assertEquals(key(),resolving.url.queryParameter("operationId"))
   assertSame("Unaccepted resolving poll published membership",unchanged,detail.state.value.detail)
   response=vector("pending");repo.refresh()!!();val before=f.server.requestCount
   (beforeResolving+1 until before).forEach{assertNotNull(f.server.takeRequest(2,TimeUnit.SECONDS))}
   lifecycle.poll(owner);val requests=(before until f.server.requestCount).map{f.server.takeRequest(2,TimeUnit.SECONDS)!!}
   val status=requests.filter{it.url.encodedPath.endsWith("source-sync")}
   assertEquals(1,status.size);assertEquals("GET",status.single().method);assertEquals(key(),status.single().url.queryParameter("operationId"))
   assertEquals(2,requests.size);assertTrue(requests.none{it.method=="POST"})
   val terminal=Json.parseToJsonElement(vector("complete")).jsonObject
   response=JsonObject(terminal+("operation" to JsonObject(terminal.getValue("operation").jsonObject+("id" to JsonPrimitive(key()))))).toString()
   repo.refresh()!!();val complete=f.server.requestCount;lifecycle.poll(owner);assertEquals(complete,f.server.requestCount)
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
 @Test fun latestFailureKeepsItsOwnStatusWhileAnEarlierReadIsOwed(){
  val failed=SourceSyncOperation(key(),id(),"failed",false,2,0,0,false,0,0,null)
  val state=PlaylistSourceSyncState(playlist=id(),observation=SourceSyncObservation(true,1,null,failed),error=true,readbackFailed=true)
  var reads=0
  val controls=SourceSyncControlProbe();controls.render(state,{error("Unexpected write")},{reads++},writeReady=false)
  assertTrue(controls.labels.any {it.startsWith("Source could not be synchronized.")})
  assertTrue(controls.labels.any {it.startsWith("Could not refresh the playlist.")})
  assertFalse(controls.labels.any {it.contains("accepted",ignoreCase=true)})
  assertEquals(setOf("Read sync status"),controls.buttons.keys)
  controls.buttons.getValue("Read sync status")();assertEquals(1,reads)
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
