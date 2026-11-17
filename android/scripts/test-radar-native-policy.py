#!/usr/bin/env python3
"""Standalone exact-source radar owner/binding checks. No SDK/Gradle/network.

Only the installed Kotlin compiler and its bundled coroutines jar are used.
Platform, transport, history storage and Compose declarations are closed facades.
This is source-body/callback execution, NOT mounted/native or TLS qualification.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
base = root / 'app/src/main/kotlin/com/soundq/android'
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
inputs = {}
def source(path):
    p = base / path
    text = p.read_text()
    inputs[path] = hashlib.sha256(p.read_bytes()).hexdigest()
    return text
def emit(name, text):
    (out / name).write_text(text)
def block(text, anchor):
    start = text.index(anchor)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

# Unchanged domain bodies. No serialization runtime is needed for owner tests.
for p in ['data/AccountSession.kt', 'data/Contracts.kt', 'data/catalog/Catalog.kt',
          'data/discovery/Discovery.kt', 'data/discovery/DiscoveryRepository.kt', 'data/imports/Imports.kt']:
    emit(Path(p).name, source(p).replace('import kotlinx.serialization.json.*\n', ''))
radar = source('data/discovery/ReleaseRadar.kt')
emit('ReleaseRadar.kt', radar[:radar.index('/** Strict Go wire projection.')].replace('import kotlinx.serialization.json.*\n', ''))
vm = source('product/ProductViewModel.kt')
emit('ProductViewModel.kt', '''package com.soundq.android.product
import kotlinx.coroutines.*
import com.soundq.android.data.discovery.*
class Graph(val discovery:DiscoveryRepository) {val mediaClient=Any()}
object Dispatchers {var IO:CoroutineDispatcher=object:CoroutineDispatcher(){override fun dispatch(context:kotlin.coroutines.CoroutineContext,block:Runnable)=block.run()}}
class ProductViewModel(val graph:Graph,val viewModelScope:CoroutineScope) {
''' + '\n'.join(block(vm, '    fun ' + name) for name in ['loadReleaseRadar(', 'searchSources(', 'findReleaseSources(']) + '\n}\n')
screen = source('product/discovery/DiscoverScreen.kt')
lifecycle = block(screen, '    DisposableEffect(view,radarLifecycle,catalogDetails,radarShown)')
presentation = block(screen, '            visibleRadarPage?.let {page->')
invalidation = block(screen, '    LaunchedEffect(view,radarInvalidation,radar.stale,radar.phase,')
surface = screen[screen.index('    val radarSurfaceOwner='):screen.index('    BackHandler(state.canBack')]
emit('Bindings.kt', '''package bindings
import androidx.lifecycle.*
import com.soundq.android.data.discovery.*
import com.soundq.android.product.*
var radarActive=false
var radarSurfaceVisit:Any?=null
var radarCollection=false
fun bind(model:ProductViewModel,view:DiscoveryView?,catalogDetails:Any?=null,radarVisible:()->Boolean={true}):()->Unit {
 val repository=model.graph.discovery
 var radarDetails:Any?=null
 val radarLifecycle=LocalLifecycleOwner.current
 val radarShown=radarVisible()
''' + lifecycle + '\n return Effect.dispose\n}\n' + '''
fun render(model:ProductViewModel,view:DiscoveryView?,full:Boolean=false,shown:Boolean=true,catalogDetails:Any?=null):()->Triple<RadarPage,RadarSong,DiscoveryDraft>? {
 val repository=model.graph.discovery
 val radar=repository.radar.value
 val state=repository.state.value
 val visibleRadarPage=radar.page?.takeIf {view?.let(repository::current)==true}
 val showRadarCollection=full
 val radarShown=shown
 val focus=Focus()
 var radarDetails:Triple<RadarPage,RadarSong,DiscoveryDraft>?=null
 UI.rows.clear();UI.actions.clear();UI.messages.clear();UI.artwork.clear()
 if(catalogDetails!=null){UI.forget();return {null}}
 if(!radarActive||!radarShown||state.draft.text.isNotBlank()||radarSurfaceVisit==null)UI.forget()
''' + surface + '\n if(state.draft.text.isBlank()) {\n' + presentation + '\n}\n return {radarDetails}\n}\n' + '''
fun invalidation(model:ProductViewModel,view:DiscoveryView?) {
 val radar=model.graph.discovery.radar.value
 val state=model.graph.discovery.state.value
 val radarInvalidation=model.graph.discovery.radarInvalidation.value
 val radarShown=true
 val catalogDetails:Any?=null
''' + invalidation + '\n}\n')
# The AppGraph declaration is the real normal constructor wiring, not fixture-only.
app = source('SoundQApplication.kt')
line = next(x for x in app.splitlines() if x.strip().startswith('val discovery='))
assert 'radarAdmitted=true' in line
emit('NormalGraph.kt', '''package bindings
import com.soundq.android.data.*
import java.io.File
class NormalGraph(val session:AccountSession,val api:SoundQApi,val directory:File) {
''' + line + '\n}\n')
route = source('product/ProductApp.kt')
assert 'destination=="Discover" && importView==null && auth is AuthState.SignedIn' in route
assert 'remember(model,accountVersion,discoveryVisit){model.graph.discovery.open()}' in route
assert 'com.soundq.android.product.discovery.DiscoverScreen(model,discoveryView,discoveryIntake,' in route
assert 'radarVisible={destination=="Discover"&&importView==null&&panel==null&&picker==null&&detailsRoute==null&&settingsRoutes.isEmpty()&&!gallery}' in route
assert 'discoveryView?.let(model.graph.discovery::close)' in block(route, '    fun leaveDiscovery()')
route_line = next(x for x in route.splitlines() if x.strip().startswith('val discoveryView='))
visibility = block(route, 'radarVisible={').split('=', 1)[1]
emit('NormalRoute.kt', '''package bindings
import com.soundq.android.data.*
import com.soundq.android.data.discovery.*
import com.soundq.android.product.*
fun normalRoute(model:ProductViewModel,destination:String,auth:AuthState,importView:Any?=null,accountVersion:Long=0,discoveryVisit:Long=0):DiscoveryView? {
''' + route_line + '\n return discoveryView\n}\n' + '''
class Visibility {
 var destination="Discover";var importView:Any?=null;var panel:String?=null;var picker:Any?=null
 var detailsRoute:Any?=null;var settingsRoutes=emptyList<String>();var gallery=false
 fun capture():()->Boolean=
''' + visibility + '\n}\n')
assert 'LaunchedEffect(view,state.draft,radar.stale)' not in screen
assert 'state.draft' not in lifecycle
assert 'radarFixtureAdmission' not in line
assert 'items(page.songs.take(if(showRadarCollection)20 else 5)' in presentation
assert 'RadarArtwork(model.graph.mediaClient,repository,view,page,song,draft,radarSurfaceOwner)' in presentation
# Full normal text-change/debounce/submit owners stay in the delivered source.
assert 'val changed=next.text!=editor.text;editor=next;if(changed)view?.let {repository.edit(it,next.text)}' in screen
assert 'LaunchedEffect(view,state.draft) {' in screen and 'delay(350)' in screen
assert 'if(latest.draft===draft&&latest.phase==DiscoveryPhase.Idle)model.searchSources(route,draft)' in screen
emit('HttpUrl.kt', '''package okhttp3
class HttpUrl(private val uri:java.net.URI) {
 val scheme get()=uri.scheme
 val host get()=uri.host?:""
 val username get()=uri.rawUserInfo?.substringBefore(':')?:""
 val password get()=uri.rawUserInfo?.substringAfter(':',"")?:""
 val encodedPath get()=uri.rawPath
 override fun toString()=uri.toString()
 fun newBuilder()=Builder(uri)
 class Builder(private var uri:java.net.URI) {fun fragment(value:String?):Builder {uri=java.net.URI(uri.scheme,uri.rawAuthority,uri.rawPath,uri.rawQuery,value);return this};fun build()=HttpUrl(uri)}
 companion object {
  fun String.toHttpUrl()=HttpUrl(java.net.URI(this))
  fun String.toHttpUrlOrNull()=runCatching {toHttpUrl()}.getOrNull()
 }
}
''')
emit('History.kt', '''package com.soundq.android.data.discovery
internal class DiscoveryHistory(directory:java.io.File?) {
 private var owner:Pair<String,String>?=null;private var rows=emptyList<String>()
 fun load(e:String,a:String):List<String>{if(owner!=e to a){owner=e to a;rows=emptyList()};return rows}
 fun add(e:String,a:String,q:String):List<String>{load(e,a);rows=(listOf(q)+rows.filterNot {it.equals(q,true)}).take(20);return rows}
 fun clear(e:String,a:String):List<String>{load(e,a);rows=emptyList();return rows}
}
''')
emit('Transport.kt', '''package com.soundq.android.data
import com.soundq.android.data.discovery.*
import com.soundq.android.data.imports.ImportSource
class LibraryCollection
class SoundQApi(val session:AccountSession) {
 var reads=0;var memberships=0;var searches=0;var resolves=0
 var feed:(()->Boolean)->RadarPage={error("unconfigured synthetic feed")}
 var membership:(()->Boolean)->Boolean={false}
 var results:SourceResults?=null
 fun releaseRadar(scope:AccountScope,valid:()->Boolean):RadarPage {check(session.remoteCurrent(scope)&&valid());reads++;return feed(valid)}
 fun radarMembership(scope:AccountScope,id:com.soundq.android.data.catalog.RecordingMbid,valid:()->Boolean):Boolean {check(session.remoteCurrent(scope)&&valid());memberships++;return membership(valid)}
 fun discoverySearch(scope:AccountScope,q:String,valid:()->Boolean,grouped:Boolean):SourceResults {check(session.remoteCurrent(scope)&&valid());searches++;return results!!}
 fun resolveSource(scope:AccountScope,s:ImportSource,valid:()->Boolean):SourceResults {check(session.remoteCurrent(scope)&&valid());resolves++;return results!!}
}
''')
emit('Lifecycle.kt', '''package androidx.lifecycle
class Owner(val lifecycle:Lifecycle=Lifecycle())
class Lifecycle {
 enum class State {DESTROYED,CREATED,STARTED,RESUMED;fun isAtLeast(s:State)=ordinal>=s.ordinal}
 var currentState=State.RESUMED;private val observers=mutableListOf<LifecycleEventObserver>()
 fun addObserver(o:LifecycleEventObserver){observers+=o}
 fun removeObserver(o:LifecycleEventObserver){observers-=o}
 fun dispatch(s:State){currentState=s;observers.toList().forEach {it.event(Any(),Any())}}
}
fun interface LifecycleEventObserver {fun event(owner:Any,event:Any)}
object LocalLifecycleOwner {var current=Owner()}
''')
emit('UI.kt', '''package bindings
import com.soundq.android.data.discovery.*
object Effect {var dispose:()->Unit={}}
class Dispose {fun onDispose(block:()->Unit){Effect.dispose=block}}
fun DisposableEffect(vararg keys:Any?,block:Dispose.()->Unit){Dispose().block()}
fun LaunchedEffect(vararg keys:Any?,block:()->Unit)=block()
object UI {
 data class Row(val title:String,val open:()->Unit,val more:()->Unit,val enabled:Boolean)
 data class Art(val client:Any,val repository:DiscoveryRepository,val view:DiscoveryView,val page:RadarPage,val song:RadarSong,val draft:DiscoveryDraft,val owner:Any)
 val rows=mutableListOf<Row>();val actions=mutableMapOf<String,()->Unit>();val messages=mutableListOf<String>();val artwork=mutableListOf<Art>()
 var keys:List<Any?>?=null;var remembered:Any?=null
 fun forget(){keys=null;remembered=null}
}
fun <T> remember(vararg keys:Any?,block:()->T):T {
 // Normal route construction is a fresh host visit; only the extracted surface slot is retained.
 if(keys.firstOrNull() is com.soundq.android.product.ProductViewModel)return block()
 if(UI.keys!=keys.toList()){UI.keys=keys.toList();UI.remembered=block()}
 @Suppress("UNCHECKED_CAST") return UI.remembered as T
}
class Focus {fun clearFocus(){}}
fun RadarArtwork(client:Any,repository:DiscoveryRepository,view:DiscoveryView,page:RadarPage,song:RadarSong,draft:DiscoveryDraft,surfaceOwner:Any){UI.artwork+=UI.Art(client,repository,view,page,song,draft,surfaceOwner)}
object SoundQ {object typography {val title=Any()}}
enum class FeedbackKind {Notice,Empty,Error}
enum class SoundQButtonVariant {Secondary}
fun Text(value:String,style:Any){UI.messages+=value}
fun SoundQFeedback(value:String,kind:FeedbackKind){UI.messages+=value}
fun discoverHeader(block:()->Unit)=block()
fun item(block:()->Unit)=block()
fun <T> items(rows:List<T>,key:(T)->Any,block:(T)->Unit){rows.forEach {key(it);block(it)}}
fun SoundQMediaRow(title:String,artist:String,current:Boolean,onActivate:()->Unit,onMore:()->Unit,artwork:()->Unit,supporting:String,enabled:Boolean){UI.rows+=UI.Row(title,onActivate,onMore,enabled);artwork()}
fun SoundQListActionRow(label:String,onClick:()->Unit,enabled:Boolean,description:String){if(enabled)UI.actions[label]=onClick}
fun SoundQButton(label:String,onClick:()->Unit,variant:SoundQButtonVariant,enabled:Boolean){if(enabled)UI.actions[label]=onClick}
''')
# These fixtures exercise production domain bodies and exact lifecycle/VM/row callbacks.
emit('Journey.kt', r'''package bindings
import androidx.lifecycle.*
import com.soundq.android.data.*
import com.soundq.android.data.catalog.*
import com.soundq.android.data.discovery.*
import com.soundq.android.product.*
import kotlinx.coroutines.*
import java.time.*
import java.util.concurrent.*
class Store(val saved:SecretTokens?=null):SessionStore {override fun load(endpoint:ApiEndpoint):SecretTokens?=saved;override fun save(endpoint:ApiEndpoint,tokens:SecretTokens){};override fun clear(){}}
fun page(n:Int,tag:String="feed"):RadarPage {
 val artist=ArtistMbid("11111111-1111-4111-8111-111111111111")
 val day=LocalDate.of(2026,11,14)
 val songs=(1..n).map {i->RadarSong(RecordingMbid("33333333-3333-4333-8333-"+i.toString().padStart(12,'0')),"$tag $i","artist",listOf(artist),RadarDate(day.minusDays(i.toLong()).toString(),"day",day.minusDays(i.toLong()),day.minusDays(i.toLong())))}
 return RadarPage(songs,RadarCoverage(true,listOf("catalog_budget"),"ok",5,1,1,0,0,1,null,n,n,0,0,0,n),Instant.parse("2026-11-14T12:00:00Z"),listOf(artist))
}
class Fixture(n:Int=20) {
 val session=AccountSession(ApiEndpoint.parse("https://fixture.invalid/api/v1"),Store()).apply {accept(beginIntent(),SecretTokens("fixture-a","fixture-r","A"))}
 val api=SoundQApi(session)
 val repository=NormalGraph(session,api,java.io.File("unused-declaration-only-history")).discovery
 val job=SupervisorJob();val model=ProductViewModel(Graph(repository),CoroutineScope(job))
 val owner=Owner();val visibility=Visibility();var dispose:()->Unit={}
 init {api.feed={page(n)};LocalLifecycleOwner.current=owner}
 fun open():DiscoveryView {val v=normalRoute(model,"Discover",session.state.value,accountVersion=session.version())!!;dispose=bind(model,v,radarVisible=visibility.capture());return v}
 fun close(){dispose();job.cancel()}
}
class Held:CoroutineDispatcher() {val work=java.util.ArrayDeque<Runnable>();override fun dispatch(c:kotlin.coroutines.CoroutineContext,b:Runnable){work.add(b)};fun drain(){while(work.isNotEmpty())work.removeFirst().run()}}
fun await(l:CountDownLatch){check(l.await(5,TimeUnit.SECONDS))}
fun main(){
 run {
  val f=Fixture();check(normalRoute(f.model,"Home",f.session.state.value)==null)
  check(normalRoute(f.model,"Discover",AuthState.SignedOut())==null)
  check(normalRoute(f.model,"Discover",AuthState.DeviceOnly("A"))==null)
  check(normalRoute(f.model,"Discover",f.session.state.value,Any())==null&&f.api.reads==0)
  val offline=AccountSession(f.session.endpoint,Store(SecretTokens("saved","saved","A")))
  check(offline.useDeviceDownloads());val r=DiscoveryRepository(offline,SoundQApi(offline),radarAdmitted=true)
  val v=r.open()!!;check(r.showRadar(v){true}==null&&r.claimRadar(v,true)==null)
  val live=f.open();check(f.session.lockLocal());check(f.repository.claimRadar(live,true)==null)
  f.close();println("actual normal route Home/import/auth guards plus remote-only/local-lock refusal PASS")
 }
 for(n in listOf(0,1,5,6,20)) {
  val f=Fixture(n);val v=f.open();val r=f.repository;val p=r.radar.value.page!!;val d=r.state.value.draft
  check(f.api.reads==1);var details=render(f.model,v)
  check(UI.rows.map {it.title}==p.songs.take(5).map {it.title});check(("View all" in UI.actions)==(n>0))
  check("Load more" !in UI.actions&&"Some releases may be missing" !in UI.messages)
  radarCollection=false;UI.actions["View all"]?.invoke();check(radarCollection==(n>0))
  repeat(6) {
   details=render(f.model,v,full=true)
   check(UI.rows.map {it.title}==p.songs.map {it.title})
   check("View all" !in UI.actions);check(r.radar.value.page===p);check(f.api.reads==1)
   UI.rows.lastOrNull()?.let {it.open();check(details()!!.first===p&&details()!!.second===p.songs[UI.rows.lastIndex]&&details()!!.third===d)}
  }
  check("Some releases may be missing" !in UI.messages);check(p.songs.size==n)
  // Playback-like rerenders retain the budget, as do query-only changes.
  val count=r.radar.value.visibleCount;repeat(5){render(f.model,v);check(r.radar.value.visibleCount==count)}
  r.edit(v,"query");r.edit(v,"");render(f.model,v);check(f.api.reads==1&&r.radar.value.visibleCount==count)
  r.close(v);val successor=f.open();check(r.radar.value.visibleCount==5&&f.api.reads==2)
  r.moreRadar(v,p,d);check(r.radar.value.visibleCount==5)
  // Explicit accepted feed replacement resets, including equivalent ordered identities.
  val first=r.radar.value.page!!;val freshDraft=r.state.value.draft
  r.moreRadar(successor,first,freshDraft);f.api.feed={page(n,"replacement")};f.model.loadReleaseRadar(successor,true)
  check(r.radar.value.page!==first&&r.radar.value.visibleCount==5)
  r.moreRadar(successor,first,freshDraft);check(r.radar.value.visibleCount==5)
  f.close();println("size/order/local expansion/canonical callbacks/reset $n PASS")
 }
 run {
  val f=Fixture();f.visibility.panel="Player";val v=f.open();check(f.api.reads==0)
  f.dispose();f.visibility.panel=null;f.dispose=bind(f.model,v,radarVisible=f.visibility.capture());check(f.api.reads==1)
  val p=f.repository.radar.value.page!!;val d=f.repository.state.value.draft
  // Evaluate the exact root predicate before recomposition/disposal can run.
  for(hide in listOf<()->Unit>({f.visibility.panel="Queue"},{f.visibility.picker=Any()},{f.visibility.detailsRoute=Any()},{f.visibility.settingsRoutes=listOf("Root")},{f.visibility.gallery=true},{f.visibility.destination="Home"},{f.visibility.importView=Any()})) {
   f.visibility.panel=null;f.visibility.picker=null;f.visibility.detailsRoute=null;f.visibility.settingsRoutes=emptyList();f.visibility.gallery=false;f.visibility.destination="Discover";f.visibility.importView=null
   hide();check(f.repository.claimRadar(v,true)==null&&!f.repository.radarCurrent(v,p,p.songs.first(),d))
  }
  f.close();println("actual root overlay predicate blocks entry and retained actions before recomposition PASS")
 }
 run {
  val f=Fixture();f.api.feed={f.visibility.panel="Player";page(6,"hidden")}
  f.open();check(f.repository.radar.value.page==null&&f.api.reads==1)
  f.close();println("automatic read publication refused immediately when root panel hides landing PASS")
 }
 run {
  val f=Fixture();val r=f.repository;val v=r.open()!!
  check(r.claimRadar(v,automatic=true)==null&&f.api.reads==0) // No mounted landing/Home.
  f.owner.lifecycle.dispatch(Lifecycle.State.STARTED);f.dispose=bind(f.model,v);check(f.api.reads==0)
  f.owner.lifecycle.dispatch(Lifecycle.State.RESUMED);check(f.api.reads==1)
  repeat(3){f.owner.lifecycle.dispatch(Lifecycle.State.RESUMED);f.model.loadReleaseRadar(v,automatic=true)}
  check(f.api.reads==1)
  f.owner.lifecycle.dispatch(Lifecycle.State.STARTED);val p=r.radar.value.page!!;val d=r.state.value.draft
  check(!r.radarCurrent(v,p,p.songs.first(),d)&&r.claimRadar(v,true)==null)
  f.owner.lifecycle.dispatch(Lifecycle.State.RESUMED);check(f.api.reads==1)
  f.close();check(r.claimRadar(v,true)==null)
  println("normal automatic first landing/background refusal/reentry/coalescing PASS")
 }
 run {
  val f=Fixture();val r=f.repository;val v=r.open()!!;r.edit(v,"entered search")
  f.dispose=bind(f.model,v);check(f.api.reads==0);r.edit(v,"");check(f.api.reads==0)
  f.close();println("search mount/typing/clear never triggers radar PASS")
 }
 run {
  val held=Held();com.soundq.android.product.Dispatchers.IO=held
  val f=Fixture();val v=f.open();check(f.repository.radar.value.phase==RadarPhase.Loading)
  f.job.cancel();held.drain();check(f.api.reads==0&&f.repository.radar.value.phase==RadarPhase.Idle)
  // Completion cleanup must not clear a newer reservation.
  val r=f.repository;val old=r.claimRadar(v,automatic=true)!!;r.abandonRadar(old)
  val next=r.claimRadar(v,automatic=true)!!;r.abandonRadar(old);r.loadRadar(next);check(f.api.reads==1)
  f.close();com.soundq.android.product.Dispatchers.IO=object:CoroutineDispatcher(){override fun dispatch(c:kotlin.coroutines.CoroutineContext,b:Runnable)=b.run()}
  println("actual ViewModel pre-entry Job cancellation/one-shot abandonment/newer reservation PASS")
 }
 run {
  val f=Fixture();val r=f.repository;val entered=CountDownLatch(1);val release=CountDownLatch(1)
  val oldPage=page(20,"retired");val renewedPage=page(6,"resumed")
  f.api.feed={valid->if(f.api.reads==1){entered.countDown();await(release);oldPage}else renewedPage}
  val v=r.open()!!;val t=Thread {LocalLifecycleOwner.current=f.owner;f.dispose=bind(f.model,v)};t.start();await(entered)
  f.owner.lifecycle.dispatch(Lifecycle.State.STARTED);f.owner.lifecycle.dispatch(Lifecycle.State.RESUMED)
  release.countDown();t.join(5000);check(!t.isAlive&&r.radar.value.page===renewedPage&&r.radar.value.page!==oldPage&&f.api.reads==2)
  // A genuine new route asks the authoritative backend again, without any wall clock.
  r.close(v);f.api.feed={page(6,"new")};val successor=f.open();val p=r.radar.value.page!!;check(p!==oldPage&&p!==renewedPage&&f.api.reads==3)
  r.close(v);r.moreRadar(v,p,r.state.value.draft);check(r.current(successor))
  f.close();println("held IO STOP/RESUME permanent retirement/new normal visit PASS")
 }
 run {
  val f=Fixture();val v=f.open();val r=f.repository;val p=r.radar.value.page!!;val d=r.state.value.draft
  render(f.model,v);val oldOpen=UI.rows.first().open;r.moreRadar(v,p,d)
  f.session.accept(f.session.beginIntent(),SecretTokens("fixture-b","fixture-r","B"))
  check(r.claimRadar(v,true)==null&&!r.radarCurrent(v,p,p.songs.first(),d));oldOpen();check(r.radar.value.visibleCount==10)
  val b=f.open();check(r.radar.value.visibleCount==5&&r.radar.value.page!==p)
  f.session.accept(f.session.beginIntent(),SecretTokens("fixture-a2","fixture-r","A"))
  check(r.claimFindSources(v,p,p.songs.first(),d)==null&&r.claimRadar(b,true)==null)
  f.close();println("account/source ABA/reset/retained callback refusal PASS")
 }
 run {
  val f=Fixture();val r=f.repository;f.api.feed={throw SafeFailure(SafeFailure.Reason.Network)};val v=f.open()
  check(r.radar.value.phase==RadarPhase.Failed);f.owner.lifecycle.dispatch(Lifecycle.State.STARTED);f.owner.lifecycle.dispatch(Lifecycle.State.RESUMED)
  f.model.loadReleaseRadar(v,automatic=true);check(f.api.reads==1&&r.radar.value.phase==RadarPhase.Failed)
  f.close();println("failed automatic attempt not silently retried PASS")
 }
 run {
  val f=Fixture(6);val r=f.repository;val v=f.open();val prior=r.radar.value.page!!
  f.api.feed={throw SafeFailure(SafeFailure.Reason.Network)};f.model.loadReleaseRadar(v,true)
  check(r.radar.value.page===prior&&r.radar.value.stale&&r.radar.value.phase==RadarPhase.Failed)
  val reads=f.api.reads;invalidation(f.model,v);check(f.api.reads==reads) // No fast-failure stale-effect retry.
  // Existing wire coverage can report a failed refresh alongside fresh-membership cached rows.
  val c=prior.coverage;val failed=RadarPage(prior.songs,RadarCoverage(true,listOf("provider_unavailable"),"unavailable",c.serverEvents,c.seedsAvailable,c.seedsSelected,c.unresolvedSeedTracks,c.unlinkedLibraryTracks,c.pagesFetched,c.knownTotal,c.retrieved,c.deduped,c.dateRejected,c.identityRejected,c.ownedExcluded,c.returned),prior.generatedAt,prior.selectedArtists)
  f.api.feed={failed};f.model.loadReleaseRadar(v,true);render(f.model,v)
  check("Could not update new releases" in UI.messages&&"Some releases may be missing" !in UI.messages)
  check(UI.rows.size==5&&r.radar.value.page===failed)
  f.close();println("last good cache retention/provider failure honesty with existing coverage DTO PASS")
 }
 run {
  val f=Fixture();val r=f.repository
  f.api.feed={f.session.accept(f.session.beginIntent(),SecretTokens("new","new","B"));page(6,"retired")}
  f.open();check(r.radar.value.page==null)
  f.close();println("actual normal automatic completion after account replacement refused PASS")
 }
 run {
  val f=Fixture();val r=f.repository;val v=r.open()!!
  f.api.feed={r.edit(v,"typed");r.edit(v,"");page(6,"query retired")}
  f.dispose=bind(f.model,v);check(r.radar.value.page==null&&f.api.reads==1)
  r.edit(v,"still typing");invalidation(f.model,v);check(f.api.reads==1)
  r.edit(v,"");f.api.feed={page(6)};invalidation(f.model,v);check(f.api.reads==2)
  val p=r.radar.value.page!!;val draft=r.state.value.draft
  val find=r.claimFindSources(v,p,p.songs.first(),draft)!!
  f.api.membership={r.edit(v,"other");r.edit(v,"");false}
  check(r.findSources(find)==null&&f.api.searches==0&&r.claimFindSources(v,p,p.songs.first(),draft)==null)
  r.libraryChanged();check(r.radar.value.stale)
  val before=f.api.reads;invalidation(f.model,v);check(f.api.reads==before+1&&r.radar.value.visibleCount==5)
  f.close();println("held read/action query ABA, no typing retry, retained explicit invalidation consumer PASS")
 }
 run {
  val f=Fixture();val v=f.open();val r=f.repository;val p=r.radar.value.page!!;val d=r.state.value.draft;val song=p.songs.first()
  val find=r.claimFindSources(v,p,song,d)!!;val entered=CountDownLatch(1);val release=CountDownLatch(1)
  f.api.membership={entered.countDown();await(release);false};var result:DiscoverySearchRequest?=null
  val t=Thread {result=r.findSources(find)};t.start();await(entered)
  f.owner.lifecycle.dispatch(Lifecycle.State.STARTED);f.owner.lifecycle.dispatch(Lifecycle.State.RESUMED);release.countDown();t.join(5000)
  check(!t.isAlive&&result==null&&r.state.value.draft===d&&f.api.searches==0)
  f.close();println("held Find sources retired through lifecycle PASS")
 }
 run {
  val f=Fixture(6);val v=f.open();val r=f.repository;val p=r.radar.value.page!!;val d=r.state.value.draft
  val old=r.claimFindSources(v,p,p.songs.last(),d)!!;r.moreRadar(v,p,d)
  // Hidden rows stay canonical, reveal never changes source ownership.
  val request=r.findSources(old)!!;check(request.draft.text=="feed 6 artist")
  val candidate=SourceCandidate("id",SourceProvider.YouTube,com.soundq.android.data.imports.ImportSource.parse("https://youtu.be/synthetic")!!,"source","artist",1000,true)
  val selection=SourceSession("selection",Instant.parse("2030-01-01T00:00:00Z"))
  val artist=DiscoveryEntity(DiscoveryResultType.Artist,"11111111-1111-4111-8111-111111111111","Exact artist","")
  val album=DiscoveryEntity(DiscoveryResultType.Album,"22222222-2222-4222-8222-222222222222","Exact album","")
  val results=SourceResults(request.draft.text,listOf(candidate),selection,emptyList(),listOf(artist,album));f.api.results=results
  r.search(request);val choice=r.inspect(v,candidate)!!;check(r.preview(v,choice){})
  r.selectType(v,DiscoveryResultType.Artist);check(r.details(v,artist)!!.valid())
  val refined=r.refine(v,artist)!!;check(refined.text=="Exact artist"&&!choice.valid());check(r.back(v))
  r.selectType(v,DiscoveryResultType.Album);check(r.details(v,album)!=null)
  r.edit(v,"https://youtu.be/synthetic");r.search(v,r.state.value.draft);check(f.api.resolves==1)
  check(r.back(v));check(r.radar.value.page===p)
  f.close();println("canonical hidden-row Find/search/inspect/Preview/Artist/Album/refine/URL owners PASS")
 }
 run {
  val f=Fixture();val v=f.open();val r=f.repository;val p=r.radar.value.page!!;val d=r.state.value.draft
  fun art(full:Boolean=false):Any {
   render(f.model,v,full=full)
   check(UI.artwork.size==if(full)20 else 5)
   UI.artwork.forEachIndexed {i,a->check(a.client===f.model.graph.mediaClient&&a.repository===r&&a.view===v&&a.page===p&&a.song===p.songs[i]&&a.draft===r.state.value.draft)}
   return UI.artwork.first().owner.also {owner->check(UI.artwork.all {it.owner===owner})}
  }
  val preview=art();repeat(5){check(art()===preview)}
  val full=art(true);check(full!==preview);check(art(true)===full)
  val returned=art();check(returned!==preview&&returned!==full)
  render(f.model,v,shown=false);check(UI.artwork.isEmpty());val overlayReturn=art();check(overlayReturn!==returned)
  render(f.model,v,catalogDetails=Any());check(UI.rows.isEmpty()&&UI.artwork.isEmpty());val catalogReturn=art();check(catalogReturn!==overlayReturn)
  r.edit(v,"query");render(f.model,v);check(UI.artwork.isEmpty());check(!r.radarCurrent(v,p,p.songs.first(),d))
  r.edit(v,"");val queryReturn=art();check(queryReturn!==catalogReturn)
  val oldVisit=radarSurfaceVisit;f.owner.lifecycle.dispatch(Lifecycle.State.STARTED)
  check(radarSurfaceVisit==null&&!r.radarCurrent(v,p,p.songs.first(),r.state.value.draft))
  render(f.model,v);check(UI.artwork.isEmpty())
  f.owner.lifecycle.dispatch(Lifecycle.State.RESUMED);check(radarSurfaceVisit!=null&&radarSurfaceVisit!==oldVisit)
  check(art()!==queryReturn);check(f.api.reads==1)
  val oldOpen=UI.rows.first().open;f.dispose();render(f.model,v);check(UI.artwork.isEmpty());oldOpen()
  f.close();println("actual canonical preview/full artwork parameters, stable/distinct incarnation, hidden/catalog/query/foreground retirement PASS")
 }
 run {
  val f=Fixture();val r=f.repository;val entered=CountDownLatch(1);val release=CountDownLatch(1)
  val v=r.open()!!;val t=Thread {LocalLifecycleOwner.current=f.owner;f.api.feed={entered.countDown();await(release);page(6)};f.dispose=bind(f.model,v)}
  t.start();await(entered);r.libraryChanged();release.countDown();t.join(5000)
  check(!t.isAlive&&r.radar.value.page==null&&r.radar.value.phase==RadarPhase.Idle)
  f.api.feed={page(6,"replacement")};invalidation(f.model,v)
  check(f.api.reads==2&&r.radar.value.phase==RadarPhase.Ready&&r.radar.value.page!=null)
  invalidation(f.model,v);check(f.api.reads==2)
  f.close();println("actual invalidation effect restores canceled first read at live Idle/no-page landing without repeat PASS")
 }
 println("ALL SOURCE-ONLY RADAR POLICY CHECKS PASS; native/SDK/transport unrun")
}
''')
compiler_path = shutil.which('kotlinc')
assert compiler_path, 'Standalone kotlinc is required'
kotlinc = Path(compiler_path).resolve()
libs = [kotlinc.parent.parent / 'lib', kotlinc.parent.parent / 'libexec/lib']
coroutines = next((p / 'kotlinx-coroutines-core-jvm.jar' for p in libs if (p / 'kotlinx-coroutines-core-jvm.jar').is_file()), None)
assert coroutines is not None, 'Use the compiler-bundled coroutine jar, never Gradle caches'
env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
env['TMPDIR'] = str(out)
env['JAVA_OPTS'] = '-Xmx512m -XX:ActiveProcessorCount=2 -Djava.io.tmpdir=' + str(out)
private_coroutines=out/'kotlinx-coroutines-core-jvm.jar'
shutil.copyfile(coroutines,private_coroutines)
assert hashlib.sha256(coroutines.read_bytes()).digest()==hashlib.sha256(private_coroutines.read_bytes()).digest()
coroutines=private_coroutines
commands = [[str(kotlinc), *map(str, sorted(out.glob('*.kt'))), '-cp', str(coroutines), '-include-runtime', '-d', str(out / 'policy.jar')],
            ['java', '-Xmx512m', '-XX:ActiveProcessorCount=2', '-Djava.io.tmpdir=' + str(out), '-cp', str(out / 'policy.jar') + os.pathsep + str(coroutines), 'bindings.JourneyKt']]
runs = []
for index, cmd in enumerate(commands):
    run = subprocess.run(cmd, env=env, text=True, capture_output=True)
    (out / ('compile.log' if index == 0 else 'tests.log')).write_text(run.stdout + run.stderr)
    runs.append({'command': cmd, 'exit': run.returncode})
    print(run.stdout if run.returncode == 0 else run.stdout + run.stderr)
    if run.returncode:
        break
(out / 'receipt.json').write_text(json.dumps({'inputs': inputs, 'compiler': str(kotlinc), 'coroutines_sha256': hashlib.sha256(coroutines.read_bytes()).hexdigest(), 'runs': runs, 'extracted': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in out.glob('*.kt')}, 'scope': __doc__, 'native': 'UNRUN'}, indent=2) + '\n')
assert len(runs) == 2 and all(x['exit'] == 0 for x in runs), 'See preserved compile/tests log'
