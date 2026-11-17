#!/usr/bin/env python3
"""Execute the real Home section DSL with presentation-only host boundaries.

This verifies slicing, labels and original-list callback arguments, not Compose
layout, lifecycle, native focus or service playback. No Android SDK is used.
"""
import argparse
from pathlib import Path
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parents[2]
product = root / 'android/app/src/main/kotlin/com/soundq/android/product'
text = (product / 'home' / 'HomeScreens.kt').read_text()
section = text[text.index('private fun LazyListScope.homeSection('):text.index('@Composable private fun HomeTrackRow(')]
scroll_selection = text[text.index('    val previewScroll ='):text.index('    BackHandler(collection!=null)')]
facade = '''
class Modifier {
 companion object {
  fun fillMaxWidth()=Modifier();fun weight(value:Float)=Modifier()
 }
 fun fillMaxWidth()=this;fun heightIn(min:Int)=this;fun weight(value:Float)=this
 fun padding(horizontal:Int=0,vertical:Int=0)=this
 fun semantics(block:()->Unit)=this
 fun clickable(enabled:Boolean=true,role:Any?=null,onClick:()->Unit)=this
}
val Int.dp:Int get()=this
object Alignment {val CenterVertically=0}
object Role {val Button=0}
object SoundQ {object spacing {val gutter=0;val medium=0};object typography {val title=0}}
fun heading(){}
fun Row(modifier:Modifier,verticalAlignment:Int,content:()->Unit)=content()
fun Text(text:String,style:Int,modifier:Modifier){events+="text:$text"}
enum class HomeSection {Recent,Top,History}
class HomeEntry(val id:Int)
class Failure(val message:String)
class HomeReadState(val rows:List<HomeEntry>,val visibleCount:Int=5,val loading:Boolean=false,val error:Failure?=null,val hasMore:Boolean=false,val serverHasMore:Boolean=false,val retryAppend:Boolean=false)
class HomeRoute
class RowRevealOwner
class ProductViewModel {
 val home=HomeOwner()
 fun loadHome(route:HomeRoute,section:HomeSection,state:HomeReadState,append:Boolean=false){}
 fun homePlay(route:HomeRoute,section:HomeSection,rows:Any,row:HomeEntry):()->Unit={}
 fun homeQueue(route:HomeRoute,section:HomeSection,rows:Any,row:HomeEntry):()->Unit={}
}
class Snapshot(val value:HomeReadState)
class HomeOwner {
 val recent=Snapshot(HomeReadState(emptyList()))
 fun owns(route:HomeRoute,section:HomeSection)=true
 fun revealRecent(route:HomeRoute,state:HomeReadState)=true
}
object SoundQIcon {val Retry=0}
object FeedbackKind {val Loading=0;val Error=1;val Empty=2}
object SoundQButtonVariant {val Secondary=0}
fun SoundQIconButton(icon:Int,label:String,action:()->Unit,enabled:Boolean,outlined:Boolean) {actions[label]=action}
fun SoundQFeedback(text:String,kind:Int,detail:String?=null,action:String?=null,onAction:(()->Unit)?=null) {events+="feedback:$text";if(action!=null&&onAction!=null)actions[action]=onAction}
fun SoundQButton(text:String,action:()->Unit,variant:Int,enabled:Boolean=true) {events+="button:$text";actions[text]=action}
fun SoundQListActionRow(label:String,onClick:()->Unit,enabled:Boolean=true,description:String=label) {events+="action:$label";if(enabled)actions[description]=onClick}
fun HomeStateCell(content:()->Unit)=content()
val events=mutableListOf<String>()
val actions=mutableMapOf<String,()->Unit>()
val rendered=mutableListOf<Pair<Any,HomeEntry>>()
class LazyListScope {
 fun item(content:()->Unit)=content()
 fun <T> itemsIndexed(items:List<T>,key:(Int,T)->Any,itemContent:(Int,T)->Unit)=items.forEachIndexed {i,t->itemContent(i,t)}
}
fun HomeTrackRow(model:ProductViewModel,route:HomeRoute,section:HomeSection,acceptedRows:Any,row:HomeEntry,onPlay:()->Unit,onQueue:()->Unit,revealOwner:RowRevealOwner) {rendered+=acceptedRows to row}
'''
# The actual rows expose track.id to the stable lazy key; model only that shape.
facade = facade.replace('class HomeEntry(val id:Int)', 'class Track(val id:Id);class Id(val value:Int);class HomeEntry(val id:Int) {val track=Track(Id(id))}')
# Call-site-retaining boundary for the native rememberLazyListState allocation;
# tests the real selection body, not mounted Compose or physical scrolling.
scroll_probe = '''
class ScrollPosition(var index:Int=0)
val scrollSlots=mutableListOf<ScrollPosition>()
var scrollSlot=0
fun rememberLazyListState():ScrollPosition {
 val index=scrollSlot++
 if(index==scrollSlots.size)scrollSlots.add(ScrollPosition())
 return scrollSlots[index]
}
fun selectedScroll(collection:HomeSection?):ScrollPosition {
 scrollSlot=0
''' + scroll_selection + '''
 return listState
}
fun checkScrollOwners() {
 val preview=selectedScroll(null);preview.index=3
 val recent=selectedScroll(HomeSection.Recent);check(recent.index==0);recent.index=20
 val top=selectedScroll(HomeSection.Top)
 check(top!==recent&&top!==preview) {"Recent and Top share a remembered scroll owner"}
 check(top.index==0) {"Top inherited Recent's scroll position"};top.index=7
 check(selectedScroll(null)===preview&&preview.index==3)
 check(selectedScroll(HomeSection.Recent)===recent&&recent.index==20)
 check(selectedScroll(HomeSection.Top)===top&&top.index==7)
 check(selectedScroll(HomeSection.History)===preview)
 println("PASS actual scroll selection: independent preview/Recent/Top owners and retained positions")
}
'''
probe = '''
fun main() {
 checkScrollOwners()
 val rows=(1..25).map {HomeEntry(it)}
 val state=HomeReadState(rows,hasMore=true)
 val scope=LazyListScope()
 var opened=false
 scope.homeSection("Your top tracks",HomeSection.Top,state,ProductViewModel(),HomeRoute(),{},RowRevealOwner(),onOpenCollection={opened=true})
 check(rendered.size==5) {"Top preview rendered ${rendered.size} instead of five"}
 check(rendered.map {it.second.id}==listOf(1,2,3,4,5))
 check(rendered.all {it.first===rows}) {"Preview replaced the authoritative accepted rows"}
 check("action:View all" in events) {"Missing media-shaped View all continuation: $events"}
 check("button:Load more" !in events)
 actions.getValue("View all Your top tracks")();check(opened)
 events.clear();actions.clear();rendered.clear()
 scope.homeSection("Your top tracks",HomeSection.Top,state,ProductViewModel(),HomeRoute(),{},RowRevealOwner(),full=true)
 check(rendered.size==25&&rendered.all {it.first===rows})
 check("action:View all" !in events)
 println("PASS actual Home section: five Top previews, original accepted rows, View all callback, complete 25-row view")
}
'''
source = a.output / 'CollectionPreview.kt'
source.write_text(facade + '\n' + scroll_probe + '\n' + section + '\n' + probe)
subprocess.run(['kotlinc', '-nowarn', str(source), '-d', str(a.output / 'probe.jar')], check=True)
subprocess.run(['kotlin', '-cp', str(a.output / 'probe.jar'), 'CollectionPreviewKt'], check=True)
