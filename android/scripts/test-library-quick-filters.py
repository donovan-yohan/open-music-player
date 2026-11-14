#!/usr/bin/env python3
"""Execute the exact LibraryFilters declaration against recording UI facades.

Checks callback bindings, selected roles, conditional count and modifier/slot
ownership. This does not measure Compose, font glyphs, pixels or touch geometry.
Standalone kotlinc/java only; no Gradle cache or Android SDK is consumed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path)
parser.add_argument('--components', type=Path)
parser.add_argument('--output', type=Path, required=True)
a = parser.parse_args()
source = a.source or Path(__file__).resolve().parents[1] / 'app/src/main/kotlin/com/soundq/android/product/ProductApp.kt'
text = source.read_text()
anchor = '@Composable private fun LibraryFilters('
assert text.count(anchor) == 1
start = text.index(anchor)
opening = text.index('{', start)
depth, end = 1, opening + 1
while depth:
    depth += (text[end] == '{') - (text[end] == '}')
    end += 1
body = text[start:end]
components = a.components or Path(__file__).resolve().parents[1] / 'designsystem/src/main/kotlin/com/soundq/designsystem/ProductComponents.kt'
component_text = components.read_text()

# Keep both the source-compatible overload and the exact new treatment, stopping at the next owner.
start_tabs = component_text.index('enum class SoundQTabsTreatment')
end_tabs = component_text.index('\nprivate val LocalMediaRowBottomRule', start_tabs)
tabs = component_text[start_tabs:end_tabs]
a.output.mkdir(parents=True, exist_ok=True)
(a.output / 'inputs.json').write_text(json.dumps({'source': str(source), 'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(), 'declaration_sha256': hashlib.sha256(body.encode()).hexdigest(), 'scope': 'Exact callbacks and recorded declarations only; not Compose measurement'}, indent=2) + '\n')
facade = r'''package libraryfiltersprobe
open class Modifier(val ops:List<String> = emptyList(),val select:(()->Unit)?=null,val selected:Boolean?=null) {
 companion object:Modifier()
 fun add(op:String)=Modifier(ops+op,select,selected)
}
fun Modifier.fillMaxWidth()=add("fillWidth")
fun Modifier.fillMaxHeight()=add("fillHeight")
fun Modifier.height(value:Int)=add("height:$value")
fun Modifier.heightIn(min:Int)=add("minHeight:$min")
fun Modifier.width(value:Int)=add("width:$value")
fun Modifier.sizeIn(minWidth:Int,minHeight:Int)=add("minSize:$minWidth:$minHeight")
fun Modifier.widthIn(min:Int=0,max:Int=Int.MAX_VALUE)=add("widthRange:$min:$max")
fun Modifier.weight(weight:Float)=add("weight:$weight")
fun Modifier.horizontalScroll(state:Int)=add("scroll")
fun rememberScrollState()=0
fun Modifier.selectableGroup()=add("group")
fun Modifier.background(color:Int)=add("background:$color")
fun Modifier.drawBehind(block:Draw.()->Unit)=add("rule")
fun Modifier.selectable(selected:Boolean,role:Role,onClick:()->Unit)=Modifier(ops+"role:$role",onClick,selected)
fun Modifier.padding(horizontal:Int,vertical:Int=0)=add("padding:$horizontal:$vertical")
class Draw {val size=Size(0f);fun drawLine(color:Int,start:Offset,end:Offset,width:Float){}}
class Size(val height:Float)
data class Offset(val x:Float,val y:Float){companion object {val Zero=Offset(0f,0f)}}
val Int.dp get()=this
object IntrinsicSize {val Min=-1;val Max=-2}
object Alignment {val CenterVertically=0;val CenterStart=1;val Center=2}
enum class Role {Tab}
object LocalDensity {val current=Density()}
class Density {var fontScale=1f;fun Int.toPx()=toFloat()}
object SoundQ {
 object colors {val border=0;val surface=1;val background=2;val text=3;val muted=4;val primary=5}
 object sizes {val border=1;val target=48}
 object spacing {val gutter=16;val small=8}
 object typography {val caption=0;val mono=1;val body=2}
}
class Node(val kind:String,val modifier:Modifier=Modifier,val label:String="",val alignment:Int=-1,val click:(()->Unit)?=null) {val children=mutableListOf<Node>()}
object UI {
 var width=400;var root=Node("root");var parent=root
 fun reset(){root=Node("root");parent=root}
 fun node(node:Node,body:()->Unit={}) {parent.children.add(node);val old=parent;parent=node;body();parent=old}
 fun all(n:Node=root):List<Node> = listOf(n)+n.children.flatMap {all(it)}
}
fun Column(modifier:Modifier,body:()->Unit)=UI.node(Node("column",modifier),body)
@DslMarker annotation class LayoutScopeMarker
@LayoutScopeMarker object RowScope
fun Row(modifier:Modifier,verticalAlignment:Int=0,body:RowScope.()->Unit)=UI.node(Node("row",modifier)){RowScope.body()}
@LayoutScopeMarker class Constraints {val maxWidth get()=UI.width}
fun BoxWithConstraints(modifier:Modifier,body:Constraints.()->Unit)=UI.node(Node("constraints",modifier)){Constraints().body()}
fun Box(modifier:Modifier,contentAlignment:Int=0,body:()->Unit={})=UI.node(Node("box",modifier,alignment=contentAlignment),body)
fun <T> remember(block:()->T)=block()
class FocusState {operator fun getValue(o:Any?,p:kotlin.reflect.KProperty<*>)=false}
fun androidx.compose.foundation.interaction.MutableInteractionSource.collectIsFocusedAsState()=FocusState()
object LocalIndication {val current=Any()}
fun Modifier.soundQCellFocus(focused:Boolean)=add("focus")
fun Modifier.selectable(selected:Boolean,interactionSource:Any,indication:Any,role:Role,onClick:()->Unit)=selectable(selected,role,onClick)
fun Text(text:String,modifier:Modifier=Modifier,style:Int,color:Int=0,maxLines:Int=Int.MAX_VALUE,softWrap:Boolean=true)=UI.node(Node("text",modifier,text))
enum class SoundQIcon {Filter}
fun LibraryIconCell(icon:SoundQIcon,label:String,onClick:()->Unit,modifier:Modifier)=UI.node(Node("icon",modifier,label,click=onClick))
fun SoundQDivider()=UI.node(Node("divider"))
'''
tests = r'''
fun main() {
 var passed=0;var failed=0
 fun case(name:String,body:()->Unit){try{body();passed++;println("PASS $name")}catch(e:Throwable){failed++;println("FAIL $name: ${e.message}")}}
 var refined=0;val liked=mutableListOf<Boolean>()
 fun render(width:Int=400,selected:Boolean=false,total:Int?=9){UI.width=width;UI.reset();LibraryFilters(selected,total,{liked.add(it)},{refined++})}
 fun cells()=UI.all().filter {it.modifier.select!=null}
 case("short_labels_and_selected_tab_callbacks_preserved") {
  for(selected in listOf(false,true)) {
   render(selected=selected);val tabs=cells()
   check(tabs.map {it.children.single().label}==listOf("All","Liked")) {"Quick-filter labels changed"}
   check(tabs.map {it.modifier.selected}==listOf(!selected,selected))
   liked.clear();tabs.forEach {it.modifier.select!!.invoke()};check(liked==listOf(false,true))
   check(tabs.all {"role:Tab" in it.modifier.ops})
  }
 }
 case("intrinsic_centered_cells_have_symmetric_padding_and_full_targets") {
  render()
  for(tab in cells()) {
   check(tab.modifier.ops.none {it.startsWith("weight:")}) {"Tab still stretches with weight"}
   check(tab.modifier.ops.none {it=="width:96"||it.startsWith("widthRange:96:")}) {"Short labels retain large minimum"}
   check("minSize:48:48" in tab.modifier.ops) {"Missing 48dp minimum target"}
   check("width:-2" in tab.modifier.ops) {"Cell not intrinsic content width"}
   check("padding:16:8" in tab.modifier.ops) {"Ordinary symmetric padding missing"}
   check(tab.alignment==Alignment.Center) {"Label not centered"}
  }
 }
 case("only_tab_viewport_flexes_and_scrolls_before_fixed_refine") {
  for(width in listOf(240,320,400,600)) {
   render(width);val scroll=UI.all().single {"scroll" in it.modifier.ops}
   check("group" in scroll.modifier.ops)
   val viewport=UI.all().single {"weight:1.0" in it.modifier.ops}
   check(scroll in UI.all(viewport)) {"Only tab viewport may flex before fixed Refine"}
   check(scroll.children==cells()) {"Count/refine placed inside scrolling tabs"}
   val refine=UI.all().single {it.kind=="icon"}
   check(refine.label=="Refine library"&&"rule" in refine.modifier.ops)
   check(refine !in UI.all(scroll));refine.click!!.invoke()
  }
  check(refined==4)
 }
 case("count_threshold_nullable_total_and_dividers_retained") {
  render(399);check(UI.all().none {it.label=="9 tracks"})
  render(400);check(UI.all().count {it.label=="9 tracks"}==1)
  check("widthRange:0:133" in UI.all().single {it.label=="9 tracks"}.modifier.ops) {"Count can starve the fixed Refine target"}
  render(400,total=Int.MAX_VALUE);check(UI.all().single {it.label=="2147483647 tracks"}.modifier.ops.contains("widthRange:0:133"))
  render(400,total=null);check(UI.all().filter {it.kind=="text"}.map {it.label}==listOf("All","Liked",""))
  check(UI.all().count {it.kind=="divider"}==1)
  check(cells().all {"rule" in it.modifier.ops&&"fillHeight" in it.modifier.ops})
 }
 case("enlarged_text_count_yields_before_refine_and_legacy_tabs_keep_default") {
  LocalDensity.current.fontScale=2f;render(600)
  check(UI.all().none {it.label=="9 tracks"})
  check(UI.all().single {it.kind=="icon"}.label=="Refine library")
  LocalDensity.current.fontScale=1f;UI.reset();SoundQTabs(listOf("A","B"),0){}
  check(cells().all {"widthRange:96:2147483647" in it.modifier.ops})
 }
 println("RESULT passed=$passed failed=$failed; recorded declarations/callbacks only, no native layout")
 check(failed==0)
}
'''
generated = facade + '\n' + tabs.replace('@Composable ', '') + '\n' + body.replace('@Composable private fun', 'fun', 1) + '\n' + tests
(a.output / 'Probe.kt').write_text(generated)
kotlinc, java = shutil.which('kotlinc'), shutil.which('java')
if not kotlinc or not java:
    parser.error('Standalone kotlinc and java must be on PATH')
(a.output / 'Interaction.kt').write_text('package androidx.compose.foundation.interaction\nclass MutableInteractionSource\n')
subprocess.run([kotlinc, str(a.output / 'Probe.kt'), str(a.output / 'Interaction.kt'), '-nowarn', '-include-runtime', '-d', str(a.output / 'probe.jar')], check=True)
result = subprocess.run([java, '-cp', str(a.output / 'probe.jar'), 'libraryfiltersprobe.ProbeKt'], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(a.output / 'result.log').write_text(result.stdout)
print(result.stdout, end='')
raise SystemExit(result.returncode)
