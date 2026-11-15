#!/usr/bin/env python3
"""Exercise the production Home section DSL/callbacks, not native Compose layout.
Requires a frozen host cohort containing the actual Home repository/API and the
existing HTTPS test fixture; --classpath lists those jars/directories. No SDK.
"""
import argparse
from pathlib import Path
import subprocess

p=argparse.ArgumentParser()
p.add_argument('--output',type=Path,required=True)
p.add_argument('--classpath',required=True)
p.add_argument('--friend',required=True)
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
root=Path(__file__).resolve().parents[2]
text=(root/'android/app/src/main/kotlin/com/soundq/android/product'/'home'/'HomeScreens.kt').read_text()
section=text[text.index('private fun LazyListScope.homeSection('):text.index('@Composable private fun HomeTrackRow(')]
vm=(root/'android/app/src/main/kotlin/com/soundq/android/product/ProductViewModel.kt').read_text()
load=vm[vm.index('    fun loadHome('):vm.index('    fun homePlay(')]
model='''package com.soundq.android.product
import com.soundq.android.data.home.*
import com.soundq.android.data.Track
class ProductViewModel(val home:HomeFeedRepository) {
 var plays=0;var queued=0;var context:List<Track> = emptyList();var index=-1
 val viewModelScope=HostScope()
 fun drain(){while(viewModelScope.pending.isNotEmpty())viewModelScope.pending.removeAt(0)()}
 fun homePlay(route:HomeRoute,section:HomeSection,rows:Any,row:HomeEntry)=home.playAction(route,section,rows,row,play={t,i->plays++;context=t;index=i})
 fun homeQueue(route:HomeRoute,section:HomeSection,rows:Any,row:HomeEntry)=home.queueAction(route,section,rows,row,queue={queued++})
}
class HostScope {
 val pending=mutableListOf<()->Unit>()
 fun launch(dispatcher:Any,block:()->Unit):HostJob {pending+=block;return HostJob()}
}
class HostJob {fun invokeOnCompletion(block:(Throwable?)->Unit){}}
object Dispatchers {val IO=Unit}
'''
model=model.replace(' val viewModelScope=HostScope()',load+'\n val viewModelScope=HostScope()')
facade='''package com.soundq.android.product.home
import com.soundq.android.data.*
import com.soundq.android.data.home.*
import com.soundq.android.product.ProductViewModel
object Modifier {
 fun fillMaxWidth()=this;fun heightIn(min:Int)=this;fun weight(value:Float)=this
 fun padding(horizontal:Int=0,vertical:Int=0)=this
 fun semantics(block:()->Unit)=this
}
val Int.dp:Int get()=this
object Alignment {val CenterVertically=0}
object SoundQ {object spacing {val gutter=0;val medium=0};object typography {val title=0}}
fun heading(){}
fun Row(modifier:Modifier,verticalAlignment:Int,content:()->Unit)=content()
fun Text(text:String,style:Int,modifier:Modifier){events+="text:$text"}
object SoundQIcon {val Retry=0}
class RowRevealOwner
object FeedbackKind {val Loading=0;val Error=1;val Empty=2}
object SoundQButtonVariant {val Secondary=0}
fun SoundQIconButton(icon:Int,label:String,action:()->Unit,enabled:Boolean,outlined:Boolean) {actions[label]=action}
fun SoundQFeedback(text:String,kind:Int,detail:String?=null,action:String?=null,onAction:(()->Unit)?=null) {events+="feedback:$text";if(action!=null&&onAction!=null)actions[action]=onAction}
fun SoundQButton(text:String,action:()->Unit,variant:Int,enabled:Boolean=true) {events+="button:$text";actions[text]=action}
fun HomeStateCell(content:()->Unit)=content()
val events=mutableListOf<String>()
val actions=mutableMapOf<String,()->Unit>()
data class Rendered(val accepted:Any,val row:HomeEntry,val play:()->Unit,val queue:()->Unit)
val rendered=mutableListOf<Rendered>()
class LazyListScope {
 fun item(content:()->Unit)=content()
 fun <T> itemsIndexed(items:List<T>,key:(Int,T)->Any,itemContent:(Int,T)->Unit)=items.forEachIndexed {i,t->itemContent(i,t)}
}
fun HomeTrackRow(model:ProductViewModel,route:HomeRoute,section:HomeSection,acceptedRows:Any,row:HomeEntry,onPlay:()->Unit,onQueue:()->Unit,revealOwner:RowRevealOwner) {
 events+="row:${row.track.id.value}";if(section==HomeSection.Recent)rendered+=Rendered(acceptedRows,row,onPlay,onQueue)
}
'''
probe='''
fun main() {
 HttpsFixture().use { f->
  val s=AccountSession(f.endpoint,MemoryStore()).also {it.accept(it.beginIntent(),SecretTokens("a","r","fixture"))}
  val repo=HomeFeedRepository(s,SoundQApi(s,f.client));val route=HomeRouteLifetime().enter(HomeDestination.Home);val model=ProductViewModel(repo)
  fun page(from:Int,to:Int,offset:Int,more:Boolean)="""{"tracks":[${(from..to).joinToString(","){"""{"id":$it,"title":"Same title","inLibrary":${it!=1}}"""}}],"limit":20,"offset":$offset,"revision":"${"a".repeat(64)}","hasMore":$more}"""
  f.reply(page(1,20,0,true));repo.load(route,HomeSection.Recent)
  fun render() {
   events.clear();actions.clear();rendered.clear()
   val scope=LazyListScope();scope.homeSection("Recently played",HomeSection.Recent,repo.recent.value,model,route,{},RowRevealOwner())
   scope.homeSection("Your top tracks",HomeSection.Top,HomeReadState(),model,route,{},RowRevealOwner())
  }
  render();check(rendered.size==5){"initial recent rows=${rendered.size}, expected five"}
  check(events.indexOf("button:Load more")>events.indexOf("row:5"))
  check(events.indexOf("button:Load more")<events.indexOf("text:Your top tracks"))
  val rows=repo.recent.value.rows
  val retained=rendered[1];retained.play();retained.queue()
  check(model.plays==1 && model.queued==1 && model.context.size==19 && model.index==0)
  check(rendered.all {it.accepted===rows}){"display projection replaced accepted rows"}
  rendered[0].play();rendered[0].queue();check(model.plays==1&&model.queued==1)
  val more=actions.getValue("Load more");more();more();render()
  check(rendered.size==10 && repo.recent.value.rows===rows && f.server.requestCount==1)
  retained.play();retained.queue();check(model.plays==2&&model.queued==2&&model.context.size==19)
  repeat(2){actions.getValue("Load more")();render()};check(rendered.size==20)
  f.reply("{}",503);val networkMore=actions.getValue("Load more");networkMore();networkMore()
  check(repo.recent.value.loading && model.viewModelScope.pending.size==1 && f.server.requestCount==1){"claim was deferred until IO"}
  model.drain();render()
  check(rendered.size==20 && repo.recent.value.rows===rows && repo.recent.value.retryAppend)
  check(events.indexOf("feedback:Could not load Recently played")>events.indexOf("row:20"))
  check(events.indexOf("feedback:Could not load Recently played")<events.indexOf("text:Your top tracks"))
  f.reply(page(21,23,20,false));val retry=actions.getValue("Retry Recently played");retry();retry()
  check(model.viewModelScope.pending.size==1);model.drain();render()
  check(rendered.size==23 && !actions.containsKey("Load more") && f.server.requestCount==3)
  check(rendered.all {it.accepted===repo.recent.value.rows})
  rendered.last().play();check(model.context.size==22&&model.index==21)
  retained.play();check(model.plays==3){"old rows still act after replacement"}
  val last=rendered.last();f.reply(page(1,20,0,true));actions.getValue("Refresh recent")();model.drain();render()
  check(rendered.size==5);last.play();last.queue();check(model.plays==3&&model.queued==2)
  println("PASS production section: five/ten/twenty/23; next-item continuation; exact accepted rows; full eligible context; queue; duplicate click; refresh/stale actions")
 }
}
'''
(a.output/'Model.kt').write_text(model)
(a.output/'Probe.kt').write_text(facade+'\n'+section+probe)
subprocess.run(['kotlinc','-nowarn','-Xfriend-paths='+a.friend,'-cp',a.classpath,str(a.output/'Model.kt'),str(a.output/'Probe.kt'),'-d',str(a.output/'probe.jar')],check=True)
subprocess.run(['kotlin','-cp',str(a.output/'probe.jar')+':'+a.classpath,'com.soundq.android.product.home.ProbeKt'],check=True)
subprocess.run(['python3',str(root/'android/scripts/test-home-action-source.py'),'--output',str(a.output/'action-source'),
                '--classpath',a.classpath,'--friend',a.friend],check=True)
