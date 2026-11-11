#!/usr/bin/env python3
"""Compile the exact LibrarySearch body; exercise explicit-submit/edit/ACK callbacks.

Private Kotlin outputs only. UI declarations are facades, not mounted Compose or
an Android IME. Focus-induced edits establish causal sufficiency, not device cause.
Remember slots persist and keyed effects run after render, never per initialization.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
source = args.source or root / 'app/src/main/kotlin/com/soundq/android/product/ProductApp.kt'
text = source.read_text()
anchor = '@Composable private fun LibrarySearch('
assert text.count(anchor) == 1
start = text.index(anchor)
opening = text.index('{', start)
depth, end = 1, opening + 1
while depth:
    depth += (text[end] == '{') - (text[end] == '}')
    end += 1
body = text[start:end]
args.output.mkdir(parents=True, exist_ok=True)
(args.output / 'LibrarySearch.extracted.kt').write_text(body)
(args.output / 'inputs.json').write_text(json.dumps({
    'source': str(source), 'source_sha256': hashlib.sha256(text.encode()).hexdigest(),
    'callback_sha256': hashlib.sha256(body.encode()).hexdigest(),
    'scope': 'Exact callback execution with declaration-only UI/IME facades; no repository or network replacement',
}, indent=2) + '\n')
prelude = r'''package librarysearchprobe
import kotlin.reflect.KProperty
class State<T>(var value:T) {
 operator fun getValue(o:Any?,p:KProperty<*>)=value
 operator fun setValue(o:Any?,p:KProperty<*>,v:T){value=v}
}
fun <T> mutableStateOf(v:T)=State(v)
object Memory {
 val slots=mutableListOf<Any?>();var cursor=0
 val effects=mutableMapOf<Int,Any?>();val pending=mutableListOf<()->Unit>()
 fun reset(){slots.clear();effects.clear();pending.clear();cursor=0}
}
@Suppress("UNCHECKED_CAST") fun <T> remember(block:()->State<T>):State<T> {
 val i=Memory.cursor++;if(i==Memory.slots.size)Memory.slots.add(block())
 return Memory.slots[i] as State<T>
}
fun <T> rememberSaveable(stateSaver:Any?,block:()->State<T>)=remember(block)
fun LaunchedEffect(key:Any?,body:()->Unit) {
 val i=Memory.cursor++
 if(!Memory.effects.containsKey(i)||Memory.effects[i]!=key){Memory.effects[i]=key;Memory.pending.add(body)}
}
data class TextRange(val start:Int,val end:Int=start)
data class TextFieldValue(val text:String,val selection:TextRange=TextRange(0),val composition:TextRange?=null) {
 companion object {val Saver=Any()}
}
open class Modifier {companion object:Modifier()}
fun Modifier.fillMaxWidth()=this
fun Modifier.heightIn(min:Int)=this
fun Modifier.weight(weight:Float)=this
fun Modifier.padding(horizontal:Int,vertical:Int)=this
class Semantics {var contentDescription=""}
fun Modifier.semantics(body:Semantics.()->Unit)=apply {Semantics().body()}
val Int.dp get()=this
object Alignment {val CenterVertically=0}
object Arrangement {val Center=0}
fun Column(modifier:Modifier,verticalArrangement:Int=0,body:()->Unit){body()}
fun Row(modifier:Modifier,verticalAlignment:Int,body:()->Unit){body()}
class Style {fun copy(color:Int)=this}
object SoundQ {
 object typography {val body=Style();val caption=Style()}
 object colors {val text=0;val focus=0;val muted=0}
 object spacing {val gutter=0;val small=0}
}
enum class SoundQIcon {Search,Close}
fun Text(text:String,style:Style,color:Int){}
fun SoundQDivider(){}
enum class ImeAction {Search}
class KeyboardOptions(val imeAction:ImeAction)
class KeyboardActions(val onSearch:()->Unit)
data class Action(val enabled:Boolean,val click:()->Unit)
data class Editor(val value:TextFieldValue,val edit:(TextFieldValue)->Unit,val keyboard:KeyboardActions)
object UI {val actions=mutableMapOf<String,Action>();lateinit var editor:Editor}
fun LibraryIconCell(icon:SoundQIcon,label:String,onClick:()->Unit,modifier:Modifier,enabled:Boolean=true){UI.actions[label]=Action(enabled,onClick)}
fun BasicTextField(value:TextFieldValue,onValueChange:(TextFieldValue)->Unit,modifier:Modifier,singleLine:Boolean,textStyle:Style,cursorBrush:Any,keyboardOptions:KeyboardOptions,keyboardActions:KeyboardActions,decorationBox:(()->Unit)->Unit) {
 UI.editor=Editor(value,onValueChange,keyboardActions);decorationBox({})
}
object Focus {var clears=0;var duringClear:()->Unit={};fun clearFocus(){clears++;duringClear()}}
object LocalFocusManager {val current=Focus}
'''
tests = r'''
object Journey {
 var committed="";val sent=mutableListOf<String>()
 fun render(){Memory.cursor=0;UI.actions.clear();LibrarySearch(committed){sent.add(it)}
  val effects=Memory.pending.toList();Memory.pending.clear();effects.forEach {it()}}
 fun start(initial:String=""){Memory.reset();sent.clear();Focus.clears=0;Focus.duringClear={};committed=initial;render()}
 fun edit(value:TextFieldValue){UI.editor.edit(value);render()}
 fun click(label:String="Search library"){val action=UI.actions.getValue(label);check(action.enabled);action.click();render()}
 fun ack(value:String){committed=value;render();render()}
}
fun verify(condition:Boolean,message:String){check(condition){message}}
fun main() {
 var failures=0;var passed=0
 fun case(name:String,test:()->Unit){try {test();passed++;println("PASS $name")}catch(e:Throwable){failures++;println("FAIL $name: ${e.message}")}}
 case("editing_committed_composing_empty_never_submits") {
  Journey.start("accepted")
  for(value in listOf(TextFieldValue("typed",TextRange(2,4)),TextFieldValue("replacement",TextRange(5),TextRange(0,11)),TextFieldValue(""))) {
   Journey.edit(value);verify(UI.editor.value===value,"Native edit value/selection/composition replaced")
  }
  verify(Journey.sent.isEmpty()&&Focus.clears==0,"Editing submitted or cleared focus")
 }
 case("button_submits_visible_composing_text_once") {
  Journey.start();Journey.edit(TextFieldValue("replacement",TextRange(4),TextRange(0,11)));Journey.click()
  verify(Journey.sent==listOf("replacement"),"Explicit button ignored visible composing query: ${Journey.sent}")
  verify(Focus.clears==1,"Explicit button did not clear focus")
 }
 case("ime_search_submits_visible_composing_text_once") {
  Journey.start();Journey.edit(TextFieldValue("café 東京",TextRange(4),TextRange(5,7)))
  UI.editor.keyboard.onSearch();Journey.render()
  verify(Journey.sent==listOf("café 東京"),"Explicit IME action ignored visible text: ${Journey.sent}")
 }
 case("committed_and_empty_explicit_drafts_submit_exactly") {
  for(text in listOf("replacement","  café 東京  ","")) {
   Journey.start("accepted");Journey.edit(TextFieldValue(text));Journey.click()
   verify(Journey.sent==listOf(text),"Explicit intent normalized or ignored: ${Journey.sent}")
  }
 }
 case("submit_captures_intent_before_focus_callback") {
  Journey.start();Journey.edit(TextFieldValue("replacement",TextRange(3)))
  // Controlled focus/IME boundary: a callback may publish another native value.
  // This is a sufficiency probe, not a trace of the reported Android device.
  val newer=TextFieldValue("newer native value",TextRange(1,5),TextRange(6,12))
  Focus.duringClear={UI.editor.edit(newer)};Journey.click()
  verify(Journey.sent==listOf("replacement"),"Submission read text after focus side effect: ${Journey.sent}")
  verify(UI.editor.value===newer,"Submission discarded focus-boundary native edit")
 }
 case("own_ack_preserves_newer_native_selection_and_composition") {
  Journey.start();Journey.edit(TextFieldValue("replacement"));Journey.click()
  val newer=TextFieldValue("replacement next",TextRange(2,5),TextRange(12,16))
  Journey.edit(newer);Journey.ack("replacement")
  verify(UI.editor.value===newer,"Search ACK overwrote newer native draft/selection/composition")
  verify(Journey.sent==listOf("replacement"),"ACK auto-submitted newer edit")
 }
 case("matching_ack_preserves_same_text_native_selection_and_composition") {
  Journey.start();Journey.edit(TextFieldValue("replacement"));Journey.click()
  val newer=TextFieldValue("replacement",TextRange(1,4),TextRange(0,11))
  Journey.edit(newer);Journey.ack("replacement")
  verify(UI.editor.value===newer,"Matching ACK reset native editing state")
 }
 case("external_refinement_updates_editor_without_submitting") {
  Journey.start("accepted");Journey.edit(TextFieldValue("local draft"));Journey.ack("external")
  verify(UI.editor.value.text=="external","External accepted refinement not reflected")
  verify(Journey.sent.isEmpty(),"Accepted publication auto-submitted")
 }
 case("clear_is_explicit_and_its_ack_preserves_newer_edit") {
  Journey.start("accepted");Journey.click("Clear library search")
  verify(Journey.sent==listOf("")&&UI.editor.value.text=="","Clear did not submit empty intent")
  val newer=TextFieldValue("after clear",TextRange(3),TextRange(0,5));Journey.edit(newer);Journey.ack("")
  verify(UI.editor.value===newer,"Clear ACK discarded newer edit")
 }
 println("RESULT passed=$passed failed=$failures; exact callback body, simulated native boundary only")
 check(failures==0){"$failures behavioral failures"}
}
'''
cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
def jar(name, version='*'):
    return next(cache.glob(f'*/{name}/{version}/*/*.jar'))
compiler = [jar('kotlin-compiler-embeddable','2.3.21'), jar('kotlin-stdlib','2.3.21'), jar('kotlin-script-runtime','2.3.21'), jar('kotlin-reflect'), jar('kotlinx-coroutines-core-jvm'), jar('annotations','23.0.0')]
java = '/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java'
with tempfile.TemporaryDirectory(prefix='library-submit-', dir=os.environ['TMPDIR']) as out:
    d = Path(out)
    generated = prelude + '\n' + body.replace('@Composable private fun', 'fun', 1) + '\n' + tests
    (d / 'Probe.kt').write_text(generated)
    (d / 'Brush.kt').write_text('package androidx.compose.ui.graphics\nclass SolidColor(color:Int)\n')
    (args.output / 'Probe.kt').write_text(generated)
    subprocess.run([java, '-cp', ':'.join(map(str, compiler)), 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-nowarn', '-no-stdlib', '-no-reflect', '-classpath', str(jar('kotlin-stdlib','2.3.21')), '-d', str(d / 'classes'), str(d / 'Probe.kt'), str(d / 'Brush.kt')], check=True)
    result = subprocess.run([java, '-cp', str(d / 'classes') + ':' + str(jar('kotlin-stdlib','2.3.21')), 'librarysearchprobe.ProbeKt'], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (args.output / 'result.log').write_text(result.stdout)
    print(result.stdout, end='')
    raise SystemExit(result.returncode)
