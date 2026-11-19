#!/usr/bin/env python3
"""Exact repository/VM/lifecycle/effect bodies, keyed host facades; NOT native/TLS proof."""
import ast
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1])
a = parser.parse_args()
root = a.source.resolve()
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=False)
# Reuse only declaration facades; never execute or edit the frozen predecessor helper.
helper = Path(__file__).with_name('test-radar-native-policy.py')
text = helper.read_text()
base = root / 'app/src/main/kotlin/com/soundq/android'
inputs = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__).resolve(), helper]}
def source(p):
    f = base / p
    inputs[p] = hashlib.sha256(f.read_bytes()).hexdigest()
    return f.read_text()
def emit(name, value):
    (out / name).write_text(value)
def block(value, anchor):
    start = value.index(anchor)
    opening = value.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (value[end] == '{') - (value[end] == '}')
        end += 1
    return value[start:end]
for p in ['data/AccountSession.kt', 'data/Contracts.kt', 'data/catalog/Catalog.kt',
          'data/discovery/Discovery.kt', 'data/discovery/DiscoveryRepository.kt', 'data/imports/Imports.kt']:
    emit(Path(p).name, source(p).replace('import kotlinx.serialization.json.*\n', ''))
radar = source('data/discovery/ReleaseRadar.kt')
emit('ReleaseRadar.kt', radar[:radar.index('/** Strict Go wire projection.')].replace('import kotlinx.serialization.json.*\n', ''))
vm = source('product/ProductViewModel.kt')
emit('ProductViewModel.kt', '''package com.soundq.android.product
import kotlinx.coroutines.*
import com.soundq.android.data.discovery.*
class Graph(val discovery:DiscoveryRepository)
object Dispatchers {var IO:CoroutineDispatcher=object:CoroutineDispatcher(){override fun dispatch(context:kotlin.coroutines.CoroutineContext,block:Runnable)=block.run()}}
class ProductViewModel(val graph:Graph,val viewModelScope:CoroutineScope) {
''' + '\n'.join(block(vm, '    fun ' + name) for name in ['loadReleaseRadar(', 'searchSources(', 'findReleaseSources(']) + '\n}\n')
for node in ast.walk(ast.parse(text)):
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'emit' and isinstance(node.args[0], ast.Constant) and node.args[0].value in ['HttpUrl.kt', 'History.kt', 'Transport.kt', 'Lifecycle.kt']:
        value = ast.literal_eval(node.args[1])
        if node.args[0].value == 'Transport.kt':
            # Keep the actual acknowledged Library-row callback producer. Only its
            # wire/parser declarations are facades; TLS/parser coverage lives in JUnit/native.
            api = source('data/SoundQApi.kt')
            value = value.replace('class LibraryCollection', '''data class LibraryPayload(val rows:List<com.soundq.android.data.trackdetails.TrackDetails>)
class LibraryCollection''')
            value = value.replace('class SoundQApi(val session:AccountSession) {', '''class SoundQApi(val session:AccountSession) {
 var libraryOwnershipReadback:(AccountScope)->Unit={}
 var libraryBody=LibraryPayload(listOf(com.soundq.android.data.trackdetails.TrackDetails(Track(TrackId(1),"owned","artist"))))
 private fun authorized(scope:AccountScope,path:String,valid:()->Boolean,expectedStatus:Int):LibraryPayload {
  session.checkRemote(scope);check(valid());check(path.startsWith("/library?limit=100&offset=0&"));return libraryBody
 }
''' + block(api, '    fun trackDetailsSnapshot('))
        emit(node.args[0].value, value)
emit('TrackDetails.kt', '''package com.soundq.android.data.trackdetails
import com.soundq.android.data.*
data class TrackDetails(val track:Track)
object TrackDetailsJson {fun page(body:LibraryPayload,offset:Int)=body.rows to body.rows.size}
''')
app = source('SoundQApplication.kt')
callback = block(app, 'libraryOwnershipReadback=').split('=', 1)[1]
screen = source('product/discovery/DiscoverScreen.kt')
start = screen.index('    // A normal route visit,')
end = screen.index('    fun search()')
# This span includes the actual observer, acknowledgement and effect key expressions.
emit('Bindings.kt', '''package bindings
import androidx.lifecycle.*
import com.soundq.android.data.discovery.*
import com.soundq.android.product.*
private class RadarArtworkRoute {fun retire(){}}
private class RowActions {val surface:RadarArtworkRoute?=null;fun renew(){}}
private fun rememberDiscoveryRowActions(model:ProductViewModel,view:DiscoveryView?,root:RadarArtworkRoute,shown:Boolean)=RowActions()
fun bind(model:ProductViewModel,view:DiscoveryView?,catalogDetails:Any?=null,radarVisible:()->Boolean={true}) {
 val repository=model.graph.discovery
 val state=repository.state.value
 val radar=repository.radar.value
 val radarArtworkRoot=RadarArtworkRoute()
 var radarCollection=false
''' + screen[start:end] + '\n}\n')
emit('Effects.kt', '''package bindings
import kotlin.reflect.KProperty
class Box<T>(var value:T) {operator fun getValue(o:Any?,p:KProperty<*>)=value;operator fun setValue(o:Any?,p:KProperty<*>,v:T){value=v}}
fun <T> mutableStateOf(v:T)=Box(v)
fun <T> kotlinx.coroutines.flow.StateFlow<T>.collectAsStateWithLifecycle()=Box(value)
object Slots {
 var index=0
 val memory=mutableMapOf<Int,Pair<List<Any?>,Any?>>()
 val effects=mutableMapOf<Int,Pair<List<Any?>,()->Unit>>()
 fun reset(){effects.values.toList().forEach {it.second()};effects.clear();memory.clear();index=0}
}
fun <T> remember(vararg keys:Any?,block:()->Box<T>):Box<T> {
 val i=Slots.index++;val old=Slots.memory[i]
 if(old!=null&&old.first==keys.toList()){@Suppress("UNCHECKED_CAST") return old.second as Box<T>}
 return block().also {Slots.memory[i]=keys.toList() to it}
}
class Dispose {var cleanup:()->Unit={};fun onDispose(block:()->Unit){cleanup=block}}
fun DisposableEffect(vararg keys:Any?,block:Dispose.()->Unit){
 val i=Slots.index++;val old=Slots.effects[i]
 if(old?.first==keys.toList())return
 old?.second?.invoke();val d=Dispose();d.block();Slots.effects[i]=keys.toList() to d.cleanup
}
fun LaunchedEffect(vararg keys:Any?,block:()->Unit){
 val i=Slots.index++;val old=Slots.effects[i]
 if(old?.first==keys.toList())return
 Slots.effects[i]=keys.toList() to {};block()
}
''')
# Reuse the accepted synthetic page constructor, not predecessor behavioral expectations.
journey = next(ast.literal_eval(n.args[1]) for n in ast.walk(ast.parse(text)) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == 'emit' and isinstance(n.args[0], ast.Constant) and n.args[0].value == 'Journey.kt')
helpers = journey[:journey.index('class Fixture(')]
emit('Recovery.kt', helpers + r'''
fun await(l:CountDownLatch){check(l.await(5,TimeUnit.SECONDS))}
class Fixture {
 val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store()).apply {accept(beginIntent(),SecretTokens("a","r","A"))}
 val api=SoundQApi(session).apply {feed={page(6)}}
 val repo=DiscoveryRepository(session,api,radarAdmitted=true)
 val job=SupervisorJob();val model=ProductViewModel(Graph(repo),CoroutineScope(job))
 val view=repo.open()!!;val owner=Owner();var shown=true;var catalog:Any?=null
 val discovery get()=repo
 init {Slots.reset();LocalLifecycleOwner.current=owner;api.libraryOwnershipReadback=CALLBACK}
 fun render(times:Int=4){repeat(times){Slots.index=0;bind(model,view,catalogDetails=catalog,radarVisible={shown})}}
 fun readback(){check(api.trackDetailsSnapshot(session.capture()!!,TrackId(1)){true}!!.track.id==TrackId(1))}
 fun close(){Slots.reset();job.cancel()}
}
fun initialReadback(conflated:Boolean) {
 val f=Fixture();val entered=CountDownLatch(1);val release=CountDownLatch(1)
 val replacement=CountDownLatch(1);val finish=CountDownLatch(1);val calls=java.util.concurrent.atomic.AtomicInteger()
 val fresh=page(6,"fresh");val obsolete=page(6,"obsolete")
 com.soundq.android.product.Dispatchers.IO=kotlinx.coroutines.Dispatchers.IO
 f.api.feed={if(calls.incrementAndGet()==1){entered.countDown();await(release);obsolete}else{replacement.countDown();await(finish);fresh}}
 try {
  f.render(if(conflated)1 else 4);await(entered)
  val oldJobs=f.job.children.toList();check(f.repo.radar.value.page==null)
  val revision=f.repo.radarInvalidation.value
  f.readback();if(conflated)f.readback()
  f.render();
  check(replacement.await(2,TimeUnit.SECONDS)) {"Library readback stranded same-view first GET: reads=${f.api.reads}, phase=${f.repo.radar.value.phase}, revision=${f.repo.radarInvalidation.value}, conflated=$conflated"}
  check(f.api.reads==2&&f.repo.radar.value.phase==RadarPhase.Loading)
  check(f.repo.radarInvalidation.value==revision+if(conflated)2 else 1)
  repeat(5){f.render();f.owner.lifecycle.dispatch(Lifecycle.State.RESUMED)}
  check(f.api.reads==2)
  release.countDown();runBlocking {withTimeout(5000){oldJobs.forEach {it.join()}}}
  check(f.repo.radar.value.page==null&&f.repo.radar.value.phase==RadarPhase.Loading) {"obsolete completion cleared successor"}
  finish.countDown();runBlocking {withTimeout(5000){f.job.children.toList().forEach {it.join()}}};f.render()
  check(f.repo.radar.value.page===fresh&&f.api.reads==2)
  repeat(3){f.owner.lifecycle.dispatch(Lifecycle.State.STARTED);f.owner.lifecycle.dispatch(Lifecycle.State.RESUMED);f.render()}
  check(f.api.reads==2&&f.repo.radar.value.page===fresh)
 } finally {release.countDown();finish.countDown();f.close();runBlocking {withTimeout(5000){f.job.join()}}}
}
fun explicitRetryCancellation(boundary:String) {
 val f=Fixture();val entered=CountDownLatch(1);val release=CountDownLatch(1);val replacement=CountDownLatch(1)
 val fresh=page(6,"replacement");val calls=java.util.concurrent.atomic.AtomicInteger()
 com.soundq.android.product.Dispatchers.IO=object:CoroutineDispatcher(){override fun dispatch(context:kotlin.coroutines.CoroutineContext,block:Runnable)=block.run()}
 try {
  f.api.feed={throw SafeFailure(SafeFailure.Reason.Network)};f.render()
  check(f.api.reads==1&&f.repo.radar.value.phase==RadarPhase.Failed)
  com.soundq.android.product.Dispatchers.IO=kotlinx.coroutines.Dispatchers.IO
  f.api.feed={if(calls.incrementAndGet()==1){entered.countDown();await(release);page(6,"obsolete")}else{replacement.countDown();fresh}}
  f.model.loadReleaseRadar(f.view,true);await(entered);f.render()
  val oldJobs=f.job.children.toList()
  when(boundary) {
   "library"->f.readback()
   "draft"->{f.repo.edit(f.view,"query");f.render();f.repo.edit(f.view,"")}
   "hidden"->{f.shown=false;f.render();f.shown=true}
   "background"->{f.owner.lifecycle.dispatch(Lifecycle.State.STARTED);f.render();f.owner.lifecycle.dispatch(Lifecycle.State.RESUMED)}
   "catalog"->{f.catalog=Any();f.render();f.catalog=null}
   else->error("unknown boundary")
  }
  f.render()
  check(replacement.await(2,TimeUnit.SECONDS)) {"cancelled explicit first-page retry stranded $boundary landing"}
  runBlocking {withTimeout(5000){f.job.children.toList().filter {it !in oldJobs}.forEach {it.join()}}}
  check(f.repo.radar.value.page===fresh&&f.api.reads==3)
  release.countDown();runBlocking {withTimeout(5000){oldJobs.forEach {it.join()}}}
  repeat(5){f.render()}
  check(f.repo.radar.value.page===fresh&&f.api.reads==3) {"obsolete retry changed replacement or repeated the visit"}
 } finally {release.countDown();f.close();runBlocking {withTimeout(5000){f.job.join()}}}
}
fun main(args:Array<String>) {
 when(args.single()) {
 "initial-readback" -> initialReadback(false)
 "conflated-initial-readback" -> initialReadback(true)
 "initial-deferred" -> for(boundary in listOf("draft","hidden","background","catalog")) {
  val f=Fixture();val entered=CountDownLatch(1);val release=CountDownLatch(1)
  com.soundq.android.product.Dispatchers.IO=kotlinx.coroutines.Dispatchers.IO
  f.api.feed={entered.countDown();await(release);page(6,"obsolete")}
  try {
   f.render();await(entered)
   when(boundary) {
    "draft"->f.repo.edit(f.view,"held search")
    "hidden"->f.shown=false
    "background"->f.owner.lifecycle.dispatch(Lifecycle.State.STARTED)
    "catalog"->f.catalog=Any()
   }
   f.render();f.readback();f.render();check(f.api.reads==1)
   val jobs=f.job.children.toList();release.countDown();runBlocking {withTimeout(5000){jobs.forEach {it.join()}}}
   check(f.repo.radar.value.page==null)
   f.api.feed={page(6,"eligible")}
   com.soundq.android.product.Dispatchers.IO=object:CoroutineDispatcher(){override fun dispatch(c:kotlin.coroutines.CoroutineContext,b:Runnable)=b.run()}
   when(boundary) {
    "draft"->f.repo.edit(f.view,"")
    "hidden"->f.shown=true
    "background"->f.owner.lifecycle.dispatch(Lifecycle.State.RESUMED)
    "catalog"->f.catalog=null
   }
   f.render();check(f.api.reads==2&&f.repo.radar.value.page!!.songs.first().title=="eligible 1")
   repeat(5){f.render()};check(f.api.reads==2)
  } finally {release.countDown();f.close();runBlocking {withTimeout(5000){f.job.join()}}}
 }
 "initial-failure" -> {
  val f=Fixture();f.api.feed={throw SafeFailure(SafeFailure.Reason.Network)};f.render()
  check(f.api.reads==1&&f.repo.radar.value.phase==RadarPhase.Failed&&f.repo.radar.value.page==null)
  repeat(3){f.readback();f.render();f.owner.lifecycle.dispatch(Lifecycle.State.STARTED);f.owner.lifecycle.dispatch(Lifecycle.State.RESUMED);f.render()}
  check(f.api.reads==1&&f.repo.radar.value.phase==RadarPhase.Failed)
  f.api.feed={page(6,"explicit")};f.model.loadReleaseRadar(f.view,true);f.render()
  check(f.api.reads==2&&f.repo.radar.value.page!=null);f.close()
 }
 "explicit-retry-readback" -> explicitRetryCancellation("library")
 "explicit-retry-retirement" -> for(boundary in listOf("draft","hidden","background","catalog"))explicitRetryCancellation(boundary)
 "explicit-unentered" -> {
  val f=Fixture();f.api.feed={throw SafeFailure(SafeFailure.Reason.Network)};f.render()
  val old=f.repo.claimRadar(f.view,refresh=true)!!;f.repo.abandonRadar(old)
  f.render();check(f.api.reads==1&&f.repo.radar.value.phase==RadarPhase.Failed)
  check(f.repo.claimRadar(f.view,automatic=true)==null)
  val fresh=f.repo.claimRadar(f.view,refresh=true)!!;f.repo.abandonRadar(old)
  check(f.repo.radar.value.phase==RadarPhase.Loading)
  f.api.feed={page(6,"explicit")};f.repo.loadRadar(fresh);f.render()
  check(f.api.reads==2&&f.repo.radar.value.page!=null);f.close()
 }
 "readback-scope" -> {
  val f=Fixture();f.render();val page=f.repo.radar.value.page;val revision=f.repo.radarInvalidation.value
  f.api.libraryBody=LibraryPayload(emptyList());check(f.api.trackDetailsSnapshot(f.session.capture()!!,TrackId(1)){true}==null)
  val stale=f.session.capture()!!
  val foreign=AccountSession(ApiEndpoint.parse("https://foreign.invalid/api/v1"),Store()).apply {accept(beginIntent(),SecretTokens("f","r","A"))}.capture()!!
  f.api.libraryOwnershipReadback(foreign)
  check(f.repo.radarInvalidation.value==revision&&f.repo.radar.value.page===page)
  f.session.accept(f.session.beginIntent(),SecretTokens("a2","r2","A"))
  check(runCatching {f.api.trackDetailsSnapshot(stale,TrackId(1)){true}}.isFailure)
  f.api.libraryOwnershipReadback(stale);f.api.libraryOwnershipReadback(f.session.capture()!!)
  f.render();check(f.api.reads==1&&f.repo.radarInvalidation.value==revision);f.close()
 }
 "interrupted" -> {
  val f=Fixture();val entered=CountDownLatch(1);val release=CountDownLatch(1)
  val obsolete=page(6,"obsolete");val fresh=page(6,"fresh")
  f.api.feed={entered.countDown();await(release);obsolete}
  val old=Thread {f.render()};old.start();await(entered)
  f.owner.lifecycle.dispatch(Lifecycle.State.STARTED)
  f.api.feed={fresh}
  f.owner.lifecycle.dispatch(Lifecycle.State.RESUMED)
  check(f.api.reads==2) {"same-view RESUME stranded initial dispatched GET: reads=${f.api.reads}, phase=${f.repo.radar.value.phase}"}
  check(f.repo.radar.value.page===fresh)
  release.countDown();old.join(5000);check(!old.isAlive&&f.repo.radar.value.page===fresh)
  repeat(3){f.owner.lifecycle.dispatch(Lifecycle.State.STARTED);f.owner.lifecycle.dispatch(Lifecycle.State.RESUMED);f.render()}
  check(f.api.reads==2);f.close()
 }
 "blank" -> {
  val f=Fixture();f.render();check(f.api.reads==1)
  f.repo.edit(f.view,"held source search");f.render()
  f.repo.libraryChanged(f.session.capture()!!);f.render()
  check(f.api.reads==1&&f.repo.radar.value.stale)
  f.repo.edit(f.view,"");f.render()
  check(f.api.reads==2&&!f.repo.radar.value.stale) {"blank return missed deferred stale reload: reads=${f.api.reads}"}
  repeat(5){f.render()};check(f.api.reads==2);f.close()
 }
 "reinvalidated" -> for(observeLoading in listOf(true,false)) {
  val f=Fixture();f.render();val entered=CountDownLatch(1);val release=CountDownLatch(1)
  val obsolete=page(6,"obsolete");val fresh=page(6,"fresh")
  f.api.feed={entered.countDown();await(release);obsolete}
  f.repo.libraryChanged();val old=Thread {f.render()};old.start();await(entered)
  // Both observed and conflated Loading must retain a second readback invalidation.
  if(observeLoading)f.render()
  f.repo.libraryChanged();f.api.feed={fresh};f.render()
  check(f.api.reads==3&&f.repo.radar.value.page===fresh) {"second invalidation was not re-admitted from Ready+stale: reads=${f.api.reads}"}
  release.countDown();old.join(5000);check(!old.isAlive&&f.repo.radar.value.page===fresh)
  f.close()
 }
 "failure" -> {
  val f=Fixture();f.render();val prior=f.repo.radar.value.page
  f.api.feed={throw SafeFailure(SafeFailure.Reason.Network)};f.repo.libraryChanged();f.render()
  check(f.repo.radar.value.phase==RadarPhase.Failed&&f.repo.radar.value.page===prior)
  repeat(5){f.render()};f.owner.lifecycle.dispatch(Lifecycle.State.STARTED);f.owner.lifecycle.dispatch(Lifecycle.State.RESUMED);f.render()
  check(f.api.reads==2&&f.repo.radar.value.phase==RadarPhase.Failed)
  f.api.feed={page(6,"explicit")};f.model.loadReleaseRadar(f.view,true);f.render()
  check(f.api.reads==3&&!f.repo.radar.value.stale);f.close()
 }
 "visibility" -> {
  val f=Fixture();f.render();f.shown=false;f.render();f.repo.libraryChanged();f.render()
  check(f.api.reads==1);f.shown=true;f.render();check(f.api.reads==2)
  f.owner.lifecycle.dispatch(Lifecycle.State.STARTED);f.repo.libraryChanged();f.render();check(f.api.reads==2)
  f.owner.lifecycle.dispatch(Lifecycle.State.RESUMED);f.render();check(f.api.reads==3);f.close()
 }
 else -> error("unknown case")
 }
 println(args.single()+" PASS: exact production observer and keyed effect, host facades only")
}
'''.replace('CALLBACK', callback))
compiler = shutil.which('kotlinc')
assert compiler, 'Standalone kotlinc required'
kotlinc = Path(compiler).resolve()
coroutines = next(p / 'kotlinx-coroutines-core-jvm.jar' for p in [kotlinc.parent.parent/'lib',kotlinc.parent.parent/'libexec/lib'] if (p/'kotlinx-coroutines-core-jvm.jar').is_file())
env = {k:v for k,v in os.environ.items() if not k.startswith('GIT_')}
env.update(JAVA_OPTS='-Xmx3g -XX:ActiveProcessorCount=2 -Djava.io.tmpdir='+os.environ.get('TMPDIR',str(out)))
commands = [[str(kotlinc), *map(str, sorted(out.glob('*.kt'))), '-cp', str(coroutines), '-include-runtime', '-d', str(out/'recovery.jar')]]
commands += [['java','-XX:ActiveProcessorCount=2','-Xmx3g','-cp',str(out/'recovery.jar')+os.pathsep+str(coroutines),'bindings.RecoveryKt',c] for c in ['interrupted','blank','reinvalidated','failure','visibility','initial-readback','conflated-initial-readback','initial-deferred','initial-failure','readback-scope','explicit-retry-readback','explicit-retry-retirement','explicit-unentered']]
runs = []
for i,cmd in enumerate(commands):
    run = subprocess.run(cmd,env=env,text=True,capture_output=True,timeout=45)
    (out/f'run-{i}.log').write_text(run.stdout+run.stderr)
    runs.append({'argv':cmd,'exit':run.returncode})
    print(i,run.returncode,(run.stdout+run.stderr)[-1800:])
    if i==0 and run.returncode:break
(out/'receipt.json').write_text(json.dumps({'inputs':inputs,'runs':runs,'extracted':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.glob('*.kt')},'scope':__doc__,'native':'UNRUN'},indent=2)+'\n')
raise SystemExit(0 if len(runs)==14 and all(x['exit']==0 for x in runs) else 1)
