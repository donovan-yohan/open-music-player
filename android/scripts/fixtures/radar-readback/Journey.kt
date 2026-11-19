package com.soundq.android.data

import com.soundq.android.data.discovery.*
import com.soundq.android.data.imports.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import java.io.File
import java.time.Instant
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

private class MemoryStore:SessionStore {override fun load(endpoint:ApiEndpoint):SecretTokens?=null;override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){};override fun clear(){}}
private val fixtures=mutableListOf<Fixture>()
private class Fixture(radarAdmitted:Boolean=true,dispatcher:kotlinx.coroutines.CoroutineDispatcher=kotlinx.coroutines.Dispatchers.Unconfined):AutoCloseable {
 init {fixtures+=this}
 val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),MemoryStore()).apply {accept(beginIntent(),SecretTokens("synthetic-access","synthetic-refresh","A"))}
 val calls=mutableListOf<String>();val payloads=mutableListOf<String>();val replies=ArrayDeque<()->Pair<Int,String>>()
 val client=OkHttpClient.Builder().addInterceptor {chain->
  val request=chain.request()
  // Execute the real WireGuard closure at the synthetic network boundary.
  val guardClass=Class.forName("com.soundq.android.data.SoundQApi\$WireGuard")
  val guard=request.tag(guardClass)!!;val getter=guardClass.getDeclaredMethod("getValid").apply {isAccessible=true}
  @Suppress("UNCHECKED_CAST") val admitted=getter.invoke(guard) as ()->Boolean
  if(!admitted())throw SafeFailure(SafeFailure.Reason.Retired)
  val action=synchronized(this){calls+=request.url.encodedPath;val buffer=okio.Buffer();request.body?.writeTo(buffer);payloads+=buffer.readUtf8();check(request.url.host=="fixture.invalid");check(replies.isNotEmpty()){ "unexpected request ${request.url}" };replies.removeFirst()}
  val (status,body)=action()
  val provider=request.url.queryParameter("providers")
  val sent=if(provider=="soundcloud") """{"query":${JsonPrimitive(request.url.queryParameter("q")!!)},"results":[],"providers":[{"provider":"soundcloud","status":"ok"}]}""" else body
  Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(status).message("synthetic").body(sent.toResponseBody("application/json".toMediaType())).build()
 }.build()
 val directory=java.nio.file.Files.createTempDirectory("radar-readback").toFile()
 val graph=ReadbackGraph(session,client,directory,radarFixtureAdmission=radarAdmitted,dispatcher=dispatcher)
 val api=graph.api
 override fun close(){graph.close();directory.deleteRecursively()}
 fun reply(body:String,status:Int=200){synchronized(this){replies.addLast {status to body}}}
 fun held(entered:CountDownLatch,release:CountDownLatch,body:String){synchronized(this){replies.addLast {entered.countDown();check(release.await(5,TimeUnit.SECONDS));200 to body}}}
}
private fun source(query:String,expires:String="2030-01-01T00:00:00Z")="""{"query":"$query","results":[{"candidateId":"fixture-candidate","provider":"youtube","sourceUrl":"https://www.youtube.com/watch?v=synthetic","title":"Synthetic source","artist":"Synthetic listened artist","downloadable":true,"playable":false}],"providers":[{"provider":"youtube","status":"ok"}],"selectionSessionId":"123e4567-e89b-12d3-a456-426614174010","selectionExpiresAt":"$expires"}"""
private fun await(latch:CountDownLatch){check(latch.await(5,TimeUnit.SECONDS))}
fun main(args:Array<String>){
 val wire=File(args[0]).readText()
 try {
 run {
  val f=Fixture();val r=f.graph.discovery;val view=r.open()!!.also {r.showRadar(it){true}}
  val read=r.claimRadar(view)!!;check(r.claimRadar(view)==null);f.reply(wire);r.loadRadar(read)
  val page=r.radar.value.page!!;val song=page.songs.single();val blank=r.state.value.draft
  check(f.calls==listOf("/api/v1/me/discovery/releases"));check(r.radarCurrent(view,page,song,blank))
  val find=r.claimFindSources(view,page,song,blank)!!;check(r.claimFindSources(view,page,song,blank)==null)
  f.reply("""{"recordingMbid":"${song.recording.value}","inLibrary":false}""");val search=r.findSources(find)!!
  check(search.draft.text=="Synthetic newest song Synthetic listened artist");check(r.state.value.phase==DiscoveryPhase.Loading)
  repeat(2){f.reply(source(search.draft.text))};kotlinx.coroutines.runBlocking {r.search(search)}
  check(f.calls.last()=="/api/v1/discovery/search");val results=r.state.value.results!!;val choice=r.inspect(view,results.rows.single())!!
  var preview:String?=null;check(r.preview(view,choice){preview=it});check(preview=="https://www.youtube.com/watch?v=synthetic");check(r.state.value.results===results)
  // Preserve the real source import/playlist owner. Radar creates no decision.
  val intake=ImportRepository(f.session,f.api,LibraryRepository());val intakeView=intake.open()!!
  check(intake.prepareSource(intakeView,choice));val plan=intake.state.value.sourcePlan!!
  f.reply("""{"data":[{"id":7,"name":"Synthetic private playlist","isPublic":false,"trackCount":0,"durationMs":0}],"total":1,"limit":20,"offset":0}""")
  intake.loadSourcePlaylists(intakeView,plan);check(intake.chooseSourcePlaylist(intakeView,plan,intake.state.value.playlistChoices.single()))
  val submission=intake.claimPlannedSource(intakeView,plan)!!;check(intake.claimPlannedSource(intakeView,plan)==null)
  val candidate=Json.parseToJsonElement(source(search.draft.text)).jsonObject.getValue("results").jsonArray.single()
  val decisionId="123e4567-e89b-12d3-a456-426614174011";val jobId="123e4567-e89b-12d3-a456-426614174012"
  val decision="""{"id":"$decisionId","sessionId":"${choice.selection.id}","selectedCandidateId":"${choice.candidate.id}","action":"selected","selectedCandidate":$candidate}"""
  f.reply(decision,201);f.reply("{}",503);intake.submit(submission)
  check(intake.state.value.sourceReceipt!!.phase==SourceImportPhase.QueueUncertain)
  check(Json.parseToJsonElement(f.payloads.last()).jsonObject.getValue("playlistId").jsonPrimitive.long==7L)
  val uncertain=intake.state.value.sourceReceipt!!
  f.reply(decision)
  intake.recoverSource(intakeView,uncertain)
  check(intake.state.value.sourceReceipt!!.phase==SourceImportPhase.QueueRefused)
  // Explicit publication retry reuses the original decision and captured target.
  f.reply("""{"queue":{},"idempotent":true,"downloadJobId":"$jobId"}""")
  intake.retrySource(intakeView,intake.state.value.sourceReceipt!!)
  check(intake.state.value.sourceReceipt!!.phase==SourceImportPhase.Accepted)
  check(intake.state.value.acknowledgement!!.id.value==jobId)
  check(!r.radar.value.stale){"job/source ACK alone is not Library ownership"}
  check(f.calls.count {it=="/api/v1/source-selections"}==1&&f.calls.count {it=="/api/v1/queue/items"}==2)
  val receipt=f.api.intakeReceipts.entries(f.session.endpoint.identity,"A").single();check(receipt.playlistId==7L)
  f.reply("""{"job_id":"$jobId","status":"complete","progress":100,"track_id":7,"source_type":"youtube","created_at":"2026-11-14T12:00:00Z"}""")
  f.reply("""{"tracks":[{"id":7,"title":"Imported synthetic source","artist":"Synthetic listened artist","has_metadata_override":false,"mb_verified":true,"mb_recording_id":"${song.recording.value}"}],"total":1,"limit":100,"offset":0}""")
  f.reply("""{"id":7,"name":"Synthetic private playlist","isPublic":false,"trackCount":1,"durationMs":0,"tracks":[{"id":7,"title":"Imported synthetic source"}]}""")
  intake.check(intakeView)
  check(intake.state.value.playlistConfirmation!!.phase==ImportPlaylistPhase.Confirmed)
  check(f.calls.count {it=="/api/v1/queue/items"}==2&&f.calls.none {it.endsWith("/tracks")})
  check(r.back(view));check(r.radar.value.page===page);check(r.state.value.draft===blank);check(!choice.valid())
  if(args.getOrNull(1)=="readback-control") {
   println("OBSERVED after completed owned Library/playlist readback: phase="+r.radar.value.phase+" stale="+r.radar.value.stale+" sameSongActionable="+r.radarCurrent(view,page,song,blank))
   check(r.radar.value.stale||!r.radarCurrent(view,page,song,blank)){"newly owned recording remained fresh/actionable after actual ownership readback"}
  }

  r.edit(view,"artist search");check(!r.radarCurrent(view,page,song,blank));r.edit(view,"");check(!r.radarCurrent(view,page,song,blank));check(r.claimFindSources(view,page,song,blank)==null)
  f.reply(wire);r.loadRadar(r.claimRadar(view,true)!!)
  val refreshed=r.radar.value.page!!;val refreshedSong=refreshed.songs.single()
  val freshBlank=r.state.value.draft;val owned=r.claimFindSources(view,refreshed,refreshedSong,freshBlank)!!
  f.reply("""{"recordingMbid":"${song.recording.value}","inLibrary":true}""");check(r.findSources(owned)==null);check(r.radar.value.stale)
  check(r.claimFindSources(view,refreshed,refreshedSong,freshBlank)==null)
  println("producer -> API/wire/parser -> owner -> membership -> fresh source search -> inspect -> external preview -> captured playlist/import -> uncertain recovery/explicit same-decision retry -> completed library/playlist readback -> back/clear: PASS")
 }
 run {
  val f=Fixture();val r=f.graph.discovery;val view=r.open()!!.also {r.showRadar(it){true}};val read=r.claimRadar(view)!!
  val entered=CountDownLatch(1);val release=CountDownLatch(1);f.held(entered,release,wire)
  val failure=AtomicReference<Throwable?>();val thread=Thread {try{r.loadRadar(read)}catch(t:Throwable){failure.set(t)}};thread.start();await(entered)
  r.edit(view,"typed while loading");release.countDown();thread.join(5000);check(!thread.isAlive);failure.get()?.let {throw it};check(r.radar.value.page==null);check(r.state.value.draft.text=="typed while loading")
  r.edit(view,"");f.reply(wire);r.loadRadar(r.claimRadar(view)!!);val page=r.radar.value.page!!;val song=page.songs.single();val draft=r.state.value.draft
  val action=r.claimFindSources(view,page,song,draft)!!;val actionEntered=CountDownLatch(1);val actionRelease=CountDownLatch(1);f.held(actionEntered,actionRelease,"""{"recordingMbid":"${song.recording.value}","inLibrary":false}""")
  val result=AtomicReference<DiscoverySearchRequest?>();val worker=Thread {result.set(r.findSources(action))};worker.start();await(actionEntered);r.edit(view,"other");r.edit(view,"");actionRelease.countDown();worker.join(5000);check(!worker.isAlive&&result.get()==null)
  check(r.claimFindSources(view,page,song,draft)==null)
  val latest=r.claimRadar(view,true)!!;val routeEntered=CountDownLatch(1);val routeRelease=CountDownLatch(1);f.held(routeEntered,routeRelease,wire)
  val loading=Thread {r.loadRadar(latest)};loading.start();await(routeEntered);r.close(view);val successor=r.open()!!.also {r.showRadar(it){true}};routeRelease.countDown();loading.join(5000);check(!loading.isAlive);check(r.radar.value.page===page)
  check(r.claimRadar(view)==null);check(r.claimFindSources(view,page,song,draft)==null)
  f.session.accept(f.session.beginIntent(),SecretTokens("replacement","replacement","B"));check(r.claimRadar(successor)==null);r.open();check(r.radar.value.page==null)
  println("held read/action and query ABA/route/account retirement: PASS")
 }
 run {
  // Normal AppGraph is admitted. Preserve the historical no-network control on an explicitly unadmitted repository.
  val held=Fixture(false);val r=DiscoveryRepository(held.session,held.api);check(r.claimRadar(r.open()!!.also {r.showRadar(it){true}})==null);check(held.calls.isEmpty())
  val f=Fixture();val fresh=f.graph.discovery;val view=fresh.open()!!.also {fresh.showRadar(it){true}};f.reply(wire);fresh.loadRadar(fresh.claimRadar(view)!!);val page=fresh.radar.value.page!!;val song=page.songs.single()
  val action=fresh.claimFindSources(view,page,song,fresh.state.value.draft)!!;f.reply("{}",503);check(fresh.findSources(action)==null);check(fresh.state.value.draft.text.isBlank());check(fresh.radar.value.error!=null)
  fresh.libraryChanged();check(fresh.radar.value.stale);check(fresh.claimFindSources(view,page,song,fresh.state.value.draft)==null)
  fresh.edit(view,"source query");val draft=fresh.state.value.draft;repeat(2){f.reply(source(draft.text,"2000-01-01T00:00:00Z"))};kotlinx.coroutines.runBlocking {fresh.search(view,draft)};check(fresh.inspect(view,fresh.state.value.results!!.rows.single())==null);check(fresh.state.value.expired)
  println("production hold, membership unknown refusal, library invalidation, retained source expiry: PASS")
 }
 run {
  val f=Fixture();val r=f.graph.discovery;val view=r.open()!!.also {r.showRadar(it){true}}
  f.reply(wire);r.loadRadar(r.claimRadar(view)!!);val page=r.radar.value.page!!
  check(r.selectType(view,DiscoveryResultType.Artist)==null);r.edit(view,"ordinary artist query")
  val grouped=Json.parseToJsonElement(source("ordinary artist query")).jsonObject
  val sections=Json.parseToJsonElement("""[{"kind":"artists","items":[{"kind":"artist","id":"11111111-1111-4111-8111-111111111111","title":"Exact Artist","subtitle":"Group"}]},{"kind":"albums","items":[{"kind":"album","id":"22222222-2222-4222-8222-222222222222","title":"Exact Album","subtitle":"Artist"}]}]""")
  f.reply(JsonObject(grouped+mapOf("sections" to sections)).toString());kotlinx.coroutines.runBlocking {r.search(view,r.state.value.draft)};val accepted=r.state.value.results!!
  check(r.details(view,accepted.entities.first())!=null)
  val refined=r.refine(view,accepted.entities.first())!!;check(refined.text=="Exact Artist")
  f.reply(source(refined.text));kotlinx.coroutines.runBlocking {r.search(view,refined)};check(r.back(view));check(r.state.value.results===accepted)
  r.selectType(view,DiscoveryResultType.Album);check(r.details(view,accepted.entities.last())!=null)
  r.edit(view,"https://youtu.be/synthetic")
  val candidate=grouped.getValue("results").jsonArray.single()
  f.reply("""{"selectionRequired":true,"candidate":$candidate,"selectionSessionId":"123e4567-e89b-12d3-a456-426614174010","selectionExpiresAt":"2030-01-01T00:00:00Z"}""")
  kotlinx.coroutines.runBlocking {r.search(view,r.state.value.draft)};check(f.calls.last()=="/api/v1/discovery/resolve-url")
  val direct=r.inspect(view,r.state.value.results!!.rows.single())!!;check(r.preview(view,direct){})
  r.edit(view,"");check(r.radar.value.page===page);check(!direct.valid())
  check(r.state.value.recent.isNotEmpty());check(f.calls.none {it.contains("/queue/")||it.contains("source-selections")})
  println("Song/Artist/Album/refine/back/recent/URL/search-clear preservation: PASS")
 }
 if(args.getOrNull(1)=="matrix") readbackMatrix(wire)
 if(args.getOrNull(1)?.startsWith("case:")==true)readbackMatrix(wire,args[1].removePrefix("case:"))
 } finally {fixtures.asReversed().forEach {it.close()}}
}

private class ReadbackScenario(wire:String) {
 val f=Fixture()
 val r=f.graph.discovery
 var view=r.open()!!.also {r.showRadar(it){true}}
 val page:RadarPage
 val job="123e4567-e89b-12d3-a456-426614174012"
 val imports:ImportRepository
 var intake:ImportView
 init {
  f.reply(wire);r.loadRadar(r.claimRadar(view)!!);page=r.radar.value.page!!
  val saved=f.api.intakeReceipts.begin(f.session.endpoint.identity,"A","source",sessionId="123e4567-e89b-12d3-a456-426614174010",candidateId="fixture-candidate",decisionId="123e4567-e89b-12d3-a456-426614174011",job=job,playlistId=7)
  f.api.intakeReceipts.finish(f.session.endpoint.identity,"A",saved,"accepted",job)
  imports=ImportRepository(f.session,f.api,f.graph.library);intake=imports.open()!!
 }
 fun jobBody(status:String="complete")="""{"job_id":"$job","status":"$status","progress":${if(status=="complete")100 else 0},"track_id":${if(status=="complete")"7" else "null"},"source_type":"youtube","created_at":"2026-11-14T12:00:00Z"}"""
 fun row(recording:String=page.songs.single().recording.value)="""{"tracks":[{"id":7,"title":"Synthetic newest song","artist":"Synthetic listened artist","has_metadata_override":false,"mb_verified":true,"mb_recording_id":"$recording"}],"total":1,"limit":100,"offset":0}"""
 fun playlist()="""{"id":7,"name":"Synthetic private playlist","isPublic":false,"trackCount":1,"durationMs":0,"tracks":[{"id":7,"title":"Synthetic newest song"}]}"""
 fun perform(recovery:Boolean=false){if(recovery)imports.recoverDurable(intake,imports.state.value.durableReceipt!!)else imports.check(intake)}
 fun fresh()=r.radarCurrent(view,r.radar.value.page!!,r.radar.value.page!!.songs.single(),r.state.value.draft)
 fun assertInvalidated(){check(r.radar.value.stale&&!fresh()){"confirmed Library ownership did not invalidate radar"}}
 fun refetch(wire:String){f.reply(wire);r.loadRadar(r.claimRadar(view)!!)}
}
private fun readbackMatrix(wire:String,only:String?=null) {
 fun case(name:String,body:()->Unit){if(only==null||only==name){body();println("CASE $name: PASS")}}
 for(recovery in listOf(false,true)) {
  val mode=if(recovery)"durable-recovery" else "check"
  case("$mode-confirmed-ownership-without-opening-Library") {
   val s=ReadbackScenario(wire);s.f.reply(s.jobBody());s.f.reply(s.row());s.f.reply(s.playlist());s.perform(recovery)
   check(s.imports.state.value.playlistConfirmation?.phase==ImportPlaylistPhase.Confirmed)
   check(s.f.graph.library.state.value.pageRevision==0L);s.assertInvalidated()
   val json=Json.parseToJsonElement(wire).jsonObject
   val coverage=JsonObject(json.getValue("coverage").jsonObject+mapOf("ownedExcluded" to JsonPrimitive(1),"returned" to JsonPrimitive(0)))
   s.refetch(JsonObject(json+mapOf("items" to JsonArray(emptyList()),"coverage" to coverage)).toString())
   check(!s.r.radar.value.stale&&s.r.radar.value.page!!.songs.isEmpty())
   check(s.f.calls.none {it.contains("queue")||it.contains("source-selections")})
  }
  case("$mode-ownership-precedes-playlist-failure") {
   val s=ReadbackScenario(wire);s.f.reply(s.jobBody());s.f.reply(s.row());s.f.reply("{}",503);s.perform(recovery)
   check(s.imports.state.value.error!=null&&!s.imports.state.value.loading);s.assertInvalidated()
   check(s.f.api.intakeReceipts.entries(s.f.session.endpoint.identity,"A").single().job==s.job)
  }
  for(kind in listOf("missing","refused","failed","malformed"))case("$mode-$kind-Library-is-not-ownership") {
   val s=ReadbackScenario(wire);s.f.reply(s.jobBody())
   when(kind) {
    "missing"->s.f.reply("""{"tracks":[],"total":0,"limit":100,"offset":0}""")
    "refused"->s.f.reply("{}",403)
    "failed"->s.f.reply("{}",503)
    else->s.f.reply(s.row().replace("\"id\":7","\"id\":\"7\""))
   }
   s.perform(recovery);check(s.fresh()&&!s.r.radar.value.stale);check(s.f.calls.size==3)
   if(kind=="missing")check(s.imports.state.value.playlistConfirmation?.phase==ImportPlaylistPhase.AwaitingLibrary)else check(s.imports.state.value.error!=null)
  }
  case("$mode-job-ACK-only-does-not-invalidate") {
   val s=ReadbackScenario(wire);s.f.reply(s.jobBody("queued"));s.perform(recovery)
   check(s.fresh()&&!s.r.radar.value.stale);check(s.f.calls.size==2)
  }
 }
 case("different-recording-same-title-source-never-suppresses-original") {
  val s=ReadbackScenario(wire);s.f.reply(s.jobBody());s.f.reply(s.row("44444444-4444-4444-8444-444444444444"));s.f.reply(s.playlist());s.perform()
  s.assertInvalidated();s.refetch(wire);check(s.fresh());check(s.r.radar.value.page!!.songs.single().recording==s.page.songs.single().recording)
  val p=s.r.radar.value.page!!;val song=p.songs.single();val find=s.r.claimFindSources(s.view,p,song,s.r.state.value.draft)!!
  s.f.reply("""{"recordingMbid":"${song.recording.value}","inLibrary":false}""")
  check(s.r.findSources(find)!=null);check(s.f.calls.none {it.contains("queue")||it.contains("source-selections")})
 }
 for(recovery in listOf(false,true))for(action in listOf("close-reopen","another","select","account-B","account-A-B-A","discover-return"))case("held-${if(recovery)"durable-recovery" else "check"}-$action") {
  val s=ReadbackScenario(wire)
  if(action=="select") {s.f.reply("""{"jobs":[${s.jobBody()},${s.jobBody().replace(s.job,"123e4567-e89b-12d3-a456-426614174099")}]}""");s.imports.recent(s.intake)}
  s.f.reply(s.jobBody());val entered=CountDownLatch(1);val release=CountDownLatch(1);s.f.held(entered,release,s.row())
  if(action=="discover-return")s.f.reply(s.playlist())
  val failure=AtomicReference<Throwable?>();val thread=Thread {try{s.perform(recovery)}catch(t:Throwable){failure.set(t)}};thread.start()
  try {
   await(entered)
   when(action) {
    "close-reopen"->{s.imports.close(s.intake);s.intake=s.imports.open()!!}
    "another"->s.imports.another(s.intake)
    "select"->s.imports.select(s.intake,s.imports.state.value.recent.last())
    "discover-return"->{s.r.close(s.view);s.view=s.r.open()!!.also {s.r.showRadar(it){true}}}
    else->{
     s.f.session.accept(s.f.session.beginIntent(),SecretTokens("b","b","B"));s.r.open()
     if(action=="account-A-B-A")s.f.session.accept(s.f.session.beginIntent(),SecretTokens("new-a","new-a","A"))
     s.view=s.r.open()!!.also {s.r.showRadar(it){true}};s.f.reply(wire);s.r.loadRadar(s.r.claimRadar(s.view)!!)
    }
   }
   release.countDown();thread.join(5000);check(!thread.isAlive);failure.get()?.let {throw it}
   if(action=="discover-return")s.assertInvalidated()else check(s.fresh()&&!s.r.radar.value.stale)
   check(s.f.api.intakeReceipts.entries(s.f.session.endpoint.identity,"A").single().job==s.job)
   check(s.f.calls.none {it.contains("queue")||it.contains("source-selections")})
  }finally{release.countDown();thread.join(5000);check(!thread.isAlive)}
 }
 case("ordinary-Library-revision-production-observer") {
  val s=ReadbackScenario(wire);s.f.graph.library.publish(s.f.session.capture()!!);s.assertInvalidated();check(s.f.calls.size==1)
 }
 case("fast-Library-revision-before-collector-start-is-not-dropped") {
  val queued=object:kotlinx.coroutines.CoroutineDispatcher(){
   val work=ArrayDeque<Runnable>()
   override fun dispatch(context:kotlin.coroutines.CoroutineContext,block:Runnable){work.addLast(block)}
   fun drain(){while(work.isNotEmpty())work.removeFirst().run()}
  }
  val f=Fixture(dispatcher=queued);val r=f.graph.discovery;val view=r.open()!!.also {r.showRadar(it){true}}
  f.reply(wire);r.loadRadar(r.claimRadar(view)!!);val p=r.radar.value.page!!
  f.graph.library.publish(f.session.capture()!!);queued.drain()
  check(r.radar.value.stale&&!r.radarCurrent(view,p,p.songs.single(),r.state.value.draft)){"fast Library revision lost before collector start"}
  f.close();queued.drain()
 }
 case("obsolete-Library-revision-does-not-invalidate-replacement-account") {
  val s=ReadbackScenario(wire);val old=s.f.session.capture()!!
  s.f.session.accept(s.f.session.beginIntent(),SecretTokens("b","b","B"));s.view=s.r.open()!!.also {s.r.showRadar(it){true}};s.f.reply(wire);s.r.loadRadar(s.r.claimRadar(s.view)!!)
  s.f.graph.library.publish(old);check(s.fresh()&&!s.r.radar.value.stale)
 }
 case("ownership-retires-held-radar-response") {
  val s=ReadbackScenario(wire);val request=s.r.claimRadar(s.view,true)!!;val entered=CountDownLatch(1);val release=CountDownLatch(1)
  s.f.held(entered,release,wire);val thread=Thread {s.r.loadRadar(request)};thread.start()
  try {
   await(entered);s.f.reply(s.jobBody());s.f.reply(s.row());s.f.reply(s.playlist());s.perform();s.assertInvalidated()
   release.countDown();thread.join(5000);check(!thread.isAlive);check(s.r.radar.value.page===s.page);s.assertInvalidated()
  }finally{release.countDown();thread.join(5000);check(!thread.isAlive)}
 }
 case("default-held-and-no-network-invalidation-control") {
  val f=Fixture(false);val r=DiscoveryRepository(f.session,f.api);check(r.claimRadar(r.open()!!.also {r.showRadar(it){true}})==null);f.graph.library.publish(f.session.capture()!!)
  check(r.radar.value.phase==RadarPhase.Held&&r.radar.value.page==null&&f.calls.isEmpty())
 }
}
