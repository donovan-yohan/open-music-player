#!/usr/bin/env python3
"""Execute central ordinary Home fixture branches with the real reader over HTTPS.

Framework-free fixture extraction only, not instrumentation/native startup or Go
wire evidence. The dispatcher branches and corpus generator are exact source.
"""
import argparse,hashlib,json,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--classpath',required=True);p.add_argument('--friend',required=True);a=p.parse_args()
a.output.mkdir(parents=True,exist_ok=False)
root=Path(__file__).resolve().parents[2];native=root/'android/app/src/androidTest/kotlin/com/soundq/android'
fixture=(native/'ProductFixtureRunner.kt').read_text()
branches=fixture[fixture.index('            if(request.headers["Authorization"]!="Bearer synthetic-fixture-access")'):fixture.index('            if(path=="/api/v1/me/plays") {')]
helper=(native/'RecentContinuationFixture.kt').read_text();helper=helper[helper.index('internal val ordinaryRecentRevision='):]
code=r'''package com.soundq.android.fixtureconsumerprobe
import com.soundq.android.data.*
import com.soundq.android.data.home.*
import mockwebserver3.*
import java.util.concurrent.TimeUnit
HELPER
class OrdinaryDispatcher:Dispatcher() {
 private val radarWire=java.io.File(RADAR_ASSET_PATH).readText()
 override fun dispatch(request:RecordedRequest):MockResponse {
  val path=request.url.encodedPath
BRANCHES
  return reply("{}",404)
 }
 private fun reply(body:String,code:Int=200):MockResponse {val response=MockResponse.Builder().code(code).addHeader("Content-Type","application/json");if(code!=204)response.body(body);return response.build()}
}
fun main() {
 val passed=mutableListOf<String>()
 fun run(name:String,body:()->Unit){body();passed+=name;println("PASS $name")}
 run("ordinaryCentralFiveBufferedThenRealNetworkPage") {
  HttpsFixture().use {f->
   f.server.dispatcher=OrdinaryDispatcher()
   val s=AccountSession(f.endpoint,MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("synthetic-fixture-access","r","fixture"))}
   val api=SoundQApi(s,f.client);val repo=HomeFeedRepository(s,api);val route=HomeRouteLifetime().enter(HomeDestination.Home)
   repo.load(route,HomeSection.Recent);check(repo.recent.value.error==null)
   val rows=repo.recent.value.rows;check(rows.size==20&&repo.recent.value.visibleCount==5&&repo.recent.value.hasMore)
   for(n in listOf(10,15,20)) {repo.load(route,HomeSection.Recent,repo.recent.value,true);check(repo.recent.value.visibleCount==n&&repo.recent.value.rows===rows&&f.server.requestCount==1)}
   var context=emptyList<Track>();var index=-1
   val old=repo.playActionWithSource(route,HomeSection.Recent,rows,rows.first()){t,i,valid->check(valid());context=t;index=i}
   old();check(context.map {it.id.value}==(1L..20L).toList()&&index==0)
   repo.load(route,HomeSection.Recent,repo.recent.value,true)
   val state=repo.recent.value;check(state.rows.size==23&&state.visibleCount==23&&!state.hasMore&&f.server.requestCount==2)
   repo.playActionWithSource(route,HomeSection.Recent,state.rows,state.rows[20]){t,i,v->check(v());context=t;index=i}()
   check(context.map {it.id.value}==(1L..22L).toList()&&index==20)
   old();check(context.size==22&&index==20)
   repo.playActionWithSource(route,HomeSection.Recent,state.rows,state.rows.last()){_,_,_->error("unavailable")}()
   val first=f.server.takeRequest(2,TimeUnit.SECONDS)!!;val next=f.server.takeRequest(2,TimeUnit.SECONDS)!!
   check(first.url.queryParameter("offset")=="0"&&first.url.queryParameter("continuation")=="true")
   check(next.url.queryParameter("offset")=="20"&&next.url.queryParameter("revision")==ordinaryRecentRevision)
  }
 }
 run("ordinaryCentralWrongRevisionIsConflictNotExhaustion") {
  HttpsFixture().use {f->
   f.server.dispatcher=OrdinaryDispatcher()
   val s=AccountSession(f.endpoint,MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("synthetic-fixture-access","r","fixture"))}
   check(runCatching {SoundQApi(s,f.client).recentPage(s.capture()!!,20,"c".repeat(64))}.exceptionOrNull() is RecentChanged)
   check(f.server.requestCount==1)
  }
 }
 run("ordinaryCentralTopAndRawHistoryRemainIndependent") {
  HttpsFixture().use {f->
   f.server.dispatcher=OrdinaryDispatcher()
   val s=AccountSession(f.endpoint,MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("synthetic-fixture-access","r","fixture"))}
   val api=SoundQApi(s,f.client);check(api.top(s.capture()!!).isEmpty());check(api.history(s.capture()!!,0).isEmpty())
   check(f.server.takeRequest(2,TimeUnit.SECONDS)!!.url.queryParameter("days")=="30")
   check(f.server.takeRequest(2,TimeUnit.SECONDS)!!.url.queryParameter("limit")=="50")
  }
 }
 run("ordinaryCentralRequiresAuthentication") {
  HttpsFixture().use {f->
   f.server.dispatcher=OrdinaryDispatcher()
   val response=f.client.newCall(okhttp3.Request.Builder().url(f.server.url("/api/v1/me/plays/recent?continuation=true&limit=20&offset=0")).build()).execute()
   response.use {check(it.code==401)}
  }
 }
 run("ordinaryCentralRadarUsesActualGoProducerWire") {
  HttpsFixture().use {f->
   f.server.dispatcher=OrdinaryDispatcher()
   val s=AccountSession(f.endpoint,MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("synthetic-fixture-access","r","fixture"))}
   val api=SoundQApi(s,f.client);val page=api.releaseRadar(s.capture()!!){true}
   check(page.songs.size==20&&page.songs.first().title=="Radar fixture 01"&&page.songs.last().title=="Radar fixture 20")
   check(page.songs.zipWithNext().all {(a,b)->!a.firstRelease.start.isBefore(b.firstRelease.start)})
   check(f.server.takeRequest(2,TimeUnit.SECONDS)!!.url.encodedPath=="/api/v1/me/discovery/releases")
   check(f.server.requestCount==1)
  }
 }
 run("ordinaryCentralRadarRefusesUnauthenticatedAndQueryOverride") {
  HttpsFixture().use {f->
   f.server.dispatcher=OrdinaryDispatcher()
   for((suffix,auth,code) in listOf(Triple("",false,401),Triple("?userId=foreign",true,400))) {
    val request=okhttp3.Request.Builder().url(f.server.url("/api/v1/me/discovery/releases"+suffix))
    if(auth)request.header("Authorization","Bearer synthetic-fixture-access")
    f.client.newCall(request.build()).execute().use {check(it.code==code)}
   }
  }
 }
 println("RESULT "+passed.joinToString(","))
}
'''.replace('HELPER',helper).replace('BRANCHES',branches).replace('RADAR_ASSET_PATH',json.dumps(str(root/'android/app/src/androidTest/assets/ordinary-radar-wire.json')))
(a.output/'Probe.kt').write_text(code)
(a.output/'inputs.json').write_text(json.dumps({'branchesSha256':hashlib.sha256(branches.encode()).hexdigest(),'helperSha256':hashlib.sha256(helper.encode()).hexdigest(),'source':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [native/'ProductFixtureRunner.kt',native/'RecentContinuationFixture.kt']},'scope':'exact synthetic fixture branches over real HTTPS, not native startup or Go wire proof'},indent=2)+'\n')
subprocess.run(['kotlinc','-nowarn','-Xfriend-paths='+a.friend,'-cp',a.classpath,str(a.output/'Probe.kt'),'-d',str(a.output/'probe.jar')],check=True)
r=subprocess.run(['kotlin','-cp',str(a.output/'probe.jar')+':'+a.classpath,'com.soundq.android.fixtureconsumerprobe.ProbeKt'],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
(a.output/'result.log').write_text(r.stdout);print(r.stdout);raise SystemExit(r.returncode)
