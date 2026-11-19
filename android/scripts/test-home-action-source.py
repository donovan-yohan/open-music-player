#!/usr/bin/env python3
"""Real Home/API -> extracted VM/controller -> actual context ticket admission.
Framework-free command/scheduler facades; not native playback acceptance.
Run with the frozen host cohort's classpath and friend paths. No SDK/Gradle.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
p.add_argument('--classpath', required=True)
p.add_argument('--friend', required=True)
p.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[2])
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
main = a.source / 'android/app/src/main/kotlin/com/soundq/android'
vm = (main / 'product/ProductViewModel.kt').read_text()
binding = vm[vm.index('    fun homePlay('):vm.index('    override fun onCleared()')]
controller = (main / 'playback/ControllerProjection.kt').read_text()
body = controller[controller.index('    fun playContext('):controller.index('    fun playDevice(')]
# Extract exact enclosing spans, never a substitute validity callback.
assert 'fun homePlay(' in binding and 'controller.playContext(' in binding
assert 'private fun startLargeContext(' in body and 'sendCustomCommand(' in body
code = r'''package com.soundq.android.homeactionprobe
import com.soundq.android.data.*
import com.soundq.android.data.home.*
import com.soundq.android.playback.*
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
class ProductViewModel(val graph:Graph,val controller:ControllerProjection) {
 val home=graph.home
BINDING
}
class Graph(val session:AccountSession,val home:HomeFeedRepository,directory:File) {
 val endpoint=session.endpoint
 val io=Scheduler()
 internal val contextStarts=ContextStartAdmission(directory)
 fun rememberTracks(tracks:List<Track>){}
}
class Scheduler {
 val tasks=mutableListOf<()->Unit>()
 fun launch(block:()->Unit){tasks+=block}
 fun drain(){while(tasks.isNotEmpty())tasks.removeAt(0)()}
}
class Handler {
 val tasks=mutableListOf<()->Unit>()
 fun post(block:()->Unit){tasks+=block}
 fun post(block:Runnable){tasks+={block.run()}}
 fun drain(){while(tasks.isNotEmpty())tasks.removeAt(0)()}
}
class Bundle {
 private val values=mutableMapOf<String,Any>()
 fun putBoolean(k:String,v:Boolean){values[k]=v}
 fun putString(k:String,v:String){values[k]=v}
 fun getString(k:String)=values[k] as? String
 companion object {val EMPTY=Bundle()}
}
class SessionCommand(val action:String,b:Bundle)
object SoundQLibraryService {const val START_CONTEXT="start"}
object SessionResult {const val RESULT_SUCCESS=0}
class Result {val resultCode=0;fun get()=this;fun addListener(f:()->Unit,e:Executor){e.execute(f)}}
class Connection {fun accepts(c:MediaController)=true}
class MediaController(val graph:Graph) {
 var sent=0;var starts=0;var playing=false;var selected=-1
 var accepted=emptyList<Long>();var holdClaim=false
 val service=Scheduler()
 fun isSessionCommandAvailable(c:SessionCommand)=true
 fun sendCustomCommand(c:SessionCommand,b:Bundle):Result {
  check(c.action==SoundQLibraryService.START_CONTEXT);sent++
  val consume={
   val capture=graph.contextStarts.claim(requireNotNull(b.getString("ticket")))
   if(capture!=null) {
    val saved=requireNotNull(graph.contextStarts.read(capture))
    accepted=saved.items.map {it.track};selected=saved.selected;starts++;playing=true
    graph.contextStarts.finish(capture)
   }
  }
  if(holdClaim)service.launch(consume) else consume()
  return Result()
 }
 fun setMediaItems(t:List<MediaItem>,index:Int,start:Int){accepted=t.map {it.id.toLong()};selected=index}
 fun prepare(){}
 fun play(){starts++;playing=true}
}
class MediaItem(val id:String) {
 class Builder {private var id="";fun setMediaId(id:String)=apply {this.id=id};fun setRequestMetadata(m:Any)=this;fun build()=MediaItem(id)}
 class RequestMetadata {class Builder {fun setExtras(b:Bundle)=this;fun build()=Any()}}
}
class ControllerProjection(val appContext:com.soundq.android.SoundQApplication) {
 val controller:MediaController?=MediaController(appContext.graph)
 val connection=Connection();val handler=Handler()
 var contextIntent=0L;var selectionIncarnation=0L;var contextError:String?=null;var closed=false
 fun refuseContext(s:String){contextError=s}
BODY
}
fun main(args:Array<String>) {
 val results=mutableListOf<Map<String,Any>>()
 fun run(name:String,section:HomeSection=HomeSection.Recent,n:Int=501,phase:String="stage",mutation:String="route") {
  HttpsFixture().use {f->
   val s=AccountSession(f.endpoint,MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("a","r","fixture"))}
   val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val life=HomeRouteLifetime()
   val route=life.enter(if(section==HomeSection.History)HomeDestination.History else HomeDestination.Home)
   fun page(offset:Int):String {
    val end=minOf(offset+20,n)
    return """{"tracks":[${(offset+1..end).joinToString(","){"""{"id":$it,"title":"Track","inLibrary":true}"""}}],"limit":20,"offset":$offset,"revision":"${"a".repeat(64)}","hasMore":${end<n}}"""
   }
   if(section==HomeSection.Recent) {
    f.reply(page(0));repo.load(route,section)
    while(repo.recent.value.rows.size<n) {
     val state=repo.recent.value
     if(state.visibleCount==state.rows.size&&state.serverHasMore)f.reply(page(state.nextOffset))
     repo.load(route,section,state,true)
    }
   } else if(section==HomeSection.Top) {
    f.reply("""{"tracks":[${(1..n).joinToString(","){"""{"id":$it,"title":"Top","inLibrary":true}"""}}]}""");repo.load(route,section)
   } else {
    f.reply("""{"plays":[{"id":41,"track":{"id":7,"title":"History","inLibrary":true},"playedAt":"2026-10-28T00:00:00Z","skipped":false}],"limit":50,"offset":0}""");repo.load(route,section)
   }
   val rows:Any=when(section){HomeSection.Recent->repo.recent.value.rows;HomeSection.Top->repo.top.value.rows;HomeSection.History->repo.history.value.rows}
   val entry=when(section){HomeSection.Recent->repo.recent.value.rows.last();HomeSection.Top->repo.top.value.rows.last();HomeSection.History->repo.history.value.rows.single().entry}
   val directory=File(args[0],name).also {it.mkdirs()}
   try {
    val graph=Graph(s,repo,directory);val projection=ControllerProjection(com.soundq.android.SoundQApplication(graph));val media=projection.controller!!
    val model=ProductViewModel(graph,projection)
    // Binding retained display rows during refresh captures the new read owner;
    // acceptance below replaces only that owner's list, not the owner itself.
    val replacement=if(mutation=="listReplacement")repo.claimRecent(route,repo.recent.value)!! else null
    val action=model.homePlay(route,section,rows,entry,if(section==HomeSection.History)41 else null)
    action()
    val large=section!=HomeSection.History&&n>500
    check(if(large)graph.io.tasks.size==1&&media.starts==0 else media.starts==1){"$name: start branch not reached"}
    if(large&&phase!="stage") {graph.io.drain();check(projection.handler.tasks.isNotEmpty()){"$name: staging failed: ${projection.contextError}"}}
    if(large&&phase=="claim") {media.holdClaim=true;projection.handler.drain();check(media.sent==1&&media.service.tasks.size==1)}
    when(mutation) {
     "route"->life.enter(HomeDestination.Library)
     "routeAba"->{life.enter(HomeDestination.Library);life.enter(route.destination)}
     "replacement"->{f.reply(page(0));repo.load(route,section,repo.recent.value)}
     "listReplacement"->{f.reply(page(0));repo.executeRecent(requireNotNull(replacement))}
     "claimReplacement"->{check(repo.claimRecent(route,repo.recent.value)!=null)}
     "accountAba"->{s.revoke();s.accept(s.beginIntent(),SecretTokens("b","rb","other"));s.revoke();s.accept(s.beginIntent(),SecretTokens("a2","ra2","fixture"))}
     "sameAccount"->{s.accept(s.beginIntent(),SecretTokens("a2","ra2","fixture"))}
     "source"->repo.retire()
     "buffer"->{val before=repo.recent.value;check(before.visibleCount<before.rows.size);repo.load(route,section,before,true);check(repo.recent.value.rows===rows)}
     "none"->Unit
     else->error(mutation)
    }
    val validSource=mutation in listOf("none","buffer")
    if(large) {
     graph.io.drain();projection.handler.drain();media.service.drain();graph.io.drain()
     check(media.starts==(if(validSource)1 else 0)){"$name: stale pending START_CONTEXT committed ${media.starts} times"}
     check(media.sent==(if(validSource||phase=="claim")1 else 0)){"$name: stale controller command sent ${media.sent} times"}
    } else {check(media.starts==1&&media.playing){"$name: accepted playback stopped by navigation"}}
    if(validSource||!large) {
     val expected=if(section==HomeSection.History)listOf(7L) else (1..n).map {it.toLong()}
     check(media.accepted==expected&&media.selected==expected.lastIndex){"$name: context/index truncated or changed"}
    }
    val pending=graph.io.tasks.size
    if(!validSource) {action();check(graph.io.tasks.size==pending&&media.starts==(if(large)0 else 1)){"$name: retired callback revived"}}
    if(validSource&&large) {life.enter(HomeDestination.Library);check(media.playing&&media.starts==1){"$name: accepted playback stopped"}}
    results+=mapOf("name" to name,"passed" to true,"sent" to media.sent,"starts" to media.starts,"accepted" to media.accepted.size)
    println("PASS $name sent=${media.sent} starts=${media.starts} accepted=${media.accepted.size}")
   } finally {check(directory.deleteRecursively());life.close()}
  }
 }
 val cases=listOf("route","replacement","listReplacement","routeAba","accountAba","sameAccount","source","claimReplacement","none","buffer")
 val failures=mutableListOf<String>()
 fun record(name:String,block:()->Unit) {try {block()}catch(e:Throwable){failures+="$name: $e";println("FAIL $name: $e")}}
 for(m in cases)record("large-$m"){run("large-$m",n=if(m=="buffer")519 else 501,mutation=m)}
 for(m in listOf("route","replacement","none"))for(phase in listOf("dispatch","claim"))record("$phase-$m"){run("$phase-$m",phase=phase,mutation=m)}
 record("direct500-navigation"){run("direct500-navigation",n=500)}
 record("top-current"){run("top-current",HomeSection.Top,20,mutation="none")}
 record("top-navigation"){run("top-navigation",HomeSection.Top,20)}
 record("history-current"){run("history-current",HomeSection.History,1,mutation="none")}
 record("history-navigation"){run("history-navigation",HomeSection.History,1)}
 File(args[1]).writeText(kotlinx.serialization.json.buildJsonObject {
  put("passed",kotlinx.serialization.json.JsonPrimitive(results.size));put("failures",kotlinx.serialization.json.buildJsonArray {failures.forEach {add(kotlinx.serialization.json.JsonPrimitive(it))}})
  put("identities",kotlinx.serialization.json.buildJsonArray {results.forEach {add(kotlinx.serialization.json.JsonPrimitive(it.getValue("name").toString()))}})
 }.toString())
 check(failures.isEmpty()){failures.joinToString("\n")}
}
'''.replace('BINDING', binding).replace('BODY', body)
(a.output / 'ActionProbe.kt').write_text(code)
(a.output / 'AppFacade.kt').write_text('package com.soundq.android\nclass SoundQApplication(val graph:com.soundq.android.homeactionprobe.Graph)\n')
# Compile changed repository and unchanged plain admission/storage source ahead of
# baseline collaborators. The actual VM/controller bodies above are not rewritten.
sources = [main / path for path in [
    Path('data') / 'home' / 'HomeFeedRepository.kt', Path('data') / 'home' / 'HomeRoute.kt',
    'playback/ContextStartAdmission.kt', 'playback/QueueSnapshotStore.kt',
    'playback/QueueSnapshot.kt', 'playback/QueuePolicy.kt',
]]
(a.output / 'source-bodies.json').write_text(json.dumps({
    'homePlay': hashlib.sha256(binding.encode()).hexdigest(),
    'playContext_and_startLargeContext': hashlib.sha256(body.encode()).hexdigest(),
    'inputs': {str(path.relative_to(a.source)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources},
}, indent=2))
jar = a.output / 'action-probe.jar'
commands = [
    ['kotlinc', '-nowarn', '-Xfriend-paths=' + a.friend, '-cp', a.classpath,
     *map(str, sources), str(a.output / 'ActionProbe.kt'), str(a.output / 'AppFacade.kt'), '-d', str(jar)],
    ['kotlin', '-cp', str(jar) + ':' + a.classpath, 'com.soundq.android.homeactionprobe.ActionProbeKt',
     str(a.output / 'staging'), str(a.output / 'results.json')],
]
with (a.output / 'action-probe.log').open('w') as log:
    for command in commands:
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log.write(result.stdout + '\nexit=' + str(result.returncode) + '\n')
        print(result.stdout, end='')
        if result.returncode:
            raise SystemExit(result.returncode)
