#!/usr/bin/env python3
"""Real caller adoption + exact input regions, standalone Kotlin only.

No Compose/Android/IME/rendering claim: UI declarations and repository publications
are recording facades. Production callback/effect bodies are extracted unchanged.
"""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import unittest

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
parser.add_argument('--output', type=Path, required=True)
a = parser.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
p = a.root / 'app/src/main/kotlin/com/soundq/android/product'
files = {name: (p / path).read_text() for name, path in {
    'library': 'ProductApp.kt', 'home': 'home/HomeScreens.kt',
    'discover': 'discovery/DiscoverScreen.kt', 'playlists': 'playlists/PlaylistsScreen.kt',
    'wrapper': 'MainPageComponents.kt'}.items()}
files['components'] = (a.root / 'designsystem/src/main/kotlin/com/soundq/designsystem/ProductComponents.kt').read_text()


def masked(text):
    # Preserve positions while ignoring delimiters in comments and Kotlin strings.
    return re.sub(r'//[^\n]*|/\*.*?\*/|""".*?"""|"(?:\\.|[^"\\])*"',
                  lambda m: ' ' * len(m[0]), text, flags=re.S)


def closing(text, opening):
    code = masked(text)
    left, right = code[opening], {'(': ')', '{': '}', '[': ']'}[code[opening]]
    depth = 1
    for i in range(opening + 1, len(code)):
        depth += (code[i] == left) - (code[i] == right)
        if not depth:
            return i + 1
    raise AssertionError('Unbalanced source region')


def function(text, name):
    start = re.search(r'@Composable (?:private |internal )?fun ' + name + r'\(', text).start()
    args = text.index('(', start)
    opening = text.index('{', closing(text, args))
    return text[start:closing(text, opening)]


def call(text, name):
    start = text.index(name + '(')
    return text[start:closing(text, text.index('(', start))]


class Adoption(unittest.TestCase):
    def test_four_real_headers_and_no_local_root_title_drawing(self):
        for key, title in [('library', 'Library'), ('home', 'Home'), ('discover', 'Discover'), ('playlists', 'Playlists')]:
            with self.subTest(page=key):
                self.assertEqual(files[key].count('MainPageHeader("' + title + '"'), 1)
                self.assertNotRegex(files[key], r'Text\("' + title + r'"\s*[,)]')
        wrapper = function(files['wrapper'], 'MainPageHeader')
        self.assertIn('SoundQMainPageHeader(title,brand=', wrapper)
        self.assertIn('Image(painterResource(R.drawable.soundq_logo),null', wrapper)
        shared = function(files['components'], 'SoundQMainPageHeader')
        for required in ['heightIn(min=56.dp)', 'Box(Modifier.size(24.dp))', 'SoundQ.typography.title', 'heading()', 'SoundQDivider()', 'navigation?.invoke()', 'actions()']:
            self.assertIn(required, shared)

    def test_three_search_consumers_and_adjacent_history_use_actual_owner(self):
        for key in ['library', 'discover', 'playlists', 'home']:
            with self.subTest(page=key):
                self.assertEqual(files[key].count('SoundQSearchStrip('), 1)
        for key, name in [('library', 'LibrarySearch'), ('home', 'HistorySearch')]:
            self.assertNotIn('BasicTextField(', function(files[key], name))
        self.assertNotIn('SoundQEntryField(', files['discover'])
        self.assertNotIn('SoundQTextField(search', files['playlists'])
        strip = function(files['components'], 'SoundQSearchStrip')
        self.assertEqual(strip.count('BasicTextField('), 1)
        self.assertIn('editorModifier.weight(1f)', strip)
        self.assertIn('if(value.text.isEmpty())Text(placeholder', strip)
        self.assertIn('contentAlignment=Alignment.CenterStart', strip)
        self.assertIn('KeyboardActions(onSearch=', strip)
        self.assertIn('clearAndSetSemantics', strip)

    def test_fixed_chrome_precedes_one_bounded_discover_playlist_body(self):
        for key in ['discover', 'playlists']:
            source = files[key]
            self.assertEqual(source.count('LazyColumn('), 1)
            lazy = source.index('LazyColumn(')
            self.assertLess(source.index('MainPageHeader('), lazy)
            self.assertLess(source.index('SoundQSearchStrip('), lazy)
            self.assertIn('weight(1f)', call(source, 'LazyColumn'))
        self.assertLess(files['discover'].index('SoundQTabs('), files['discover'].index('LazyColumn('))
        self.assertNotIn('SoundQTabs(', files['playlists'])
        home = files['home'].split('} else MainPageHeader("Home")', 1)[1].split('if(route.destination==HomeDestination.History)', 1)[0]
        self.assertNotIn('SearchStrip', home)

    def test_opt_in_tabs_media_and_parent_chrome_owners_retained(self):
        self.assertIn('SoundQTabsTreatment.MainPageCells', function(files['library'], 'LibraryFilters'))
        self.assertIn('SoundQTabsTreatment.MainPageCells', files['discover'])
        self.assertIn('DiscoveryResultType.entries.map {it.label}', files['discover'])
        self.assertIn('SoundQTabsTreatment.Existing,onSelect=onSelect', files['components'])
        for key in ['library', 'home', 'discover', 'playlists']:
            self.assertIn('SoundQMediaRow(', files[key])
        for key in ['home', 'discover', 'playlists']:
            self.assertNotIn('SoundQCompactPlayer(', files[key])
            self.assertNotIn('SoundQBottomNavigation(', files[key])
        self.assertIn('SoundQSwipeQueue(', files['home'])
        self.assertIn('model.home.recent.value.rows===acceptedRows', files['home'])


suite = unittest.defaultTestLoader.loadTestsFromTestCase(Adoption)
with (a.output / 'adoption.log').open('w') as log:
    result = unittest.TextTestRunner(stream=log, verbosity=2).run(suite)
print((a.output / 'adoption.log').read_text())
if not result.wasSuccessful():
    raise SystemExit(1)

# Reuse the retained Library declaration facade, not its callback implementation.
parsed = ast.parse((a.root / 'scripts/test-library-search-submit.py').read_text())
prelude = next(ast.literal_eval(n.value) for n in parsed.body if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'prelude' for t in n.targets))
prelude = prelude.replace('import kotlin.reflect.KProperty', 'import kotlin.reflect.KProperty\nimport kotlin.coroutines.*')
prelude = prelude.replace('''class State<T>(var value:T) {
 operator fun getValue(o:Any?,p:KProperty<*>)=value
 operator fun setValue(o:Any?,p:KProperty<*>,v:T){value=v}
}''', '''class State<T>(var value:T)
operator fun <T> State<T>.getValue(o:Any?,p:KProperty<*>)=value
operator fun <T> State<T>.setValue(o:Any?,p:KProperty<*>,v:T){value=v}''')
start = prelude.index('object Memory {')
end = prelude.index('data class TextRange', start)
prelude = prelude[:start] + r'''
object Memory {
 data class Slot(val keys:List<Any?>,val value:Any?)
 val slots=mutableMapOf<Int,Slot>();var cursor=0
 data class Job(val keys:List<Any?>,var active:Boolean=true)
 val effects=mutableMapOf<Int,Job>();val pending=mutableListOf<()->Unit>()
 data class Wait(val at:Long,val job:Job,val resume:()->Unit)
 var now=0L;var current:Job?=null;val waits=mutableListOf<Wait>()
 fun reset(){slots.clear();effects.clear();pending.clear();waits.clear();cursor=0;now=0}
 fun flush(){val work=pending.toList();pending.clear();work.forEach{it()}}
 fun advance(ms:Long){now+=ms;val ready=waits.filter{it.at<=now};waits.removeAll(ready.toSet());ready.forEach{if(it.job.active){current=it.job;it.resume()}}}
}
@Suppress("UNCHECKED_CAST") inline fun <T> remember(vararg keys:Any?,block:()->T):T {
 val i=Memory.cursor++;val k=keys.toList()
 if(Memory.slots[i]?.keys!=k)Memory.slots[i]=Memory.Slot(k,block())
 return Memory.slots.getValue(i).value as T
}

fun LaunchedEffect(vararg keys:Any?,body:suspend ()->Unit) {
 val i=Memory.cursor++;val k=keys.toList();val old=Memory.effects[i]
 if(old==null||old.keys!=k){old?.active=false;val job=Memory.Job(k);Memory.effects[i]=job
 Memory.pending.add {if(job.active){Memory.current=job;body.startCoroutine(object:Continuation<Unit>{
 override val context=EmptyCoroutineContext
 override fun resumeWith(result:Result<Unit>){result.getOrThrow()}
 })}}}
}
suspend fun delay(ms:Long)=suspendCoroutine<Unit>{cont->Memory.waits.add(Memory.Wait(Memory.now+ms,Memory.current!!){cont.resume(Unit)})}
''' + prelude[end:]
prelude = prelude.replace('enum class SoundQIcon {Search,Close}', 'enum class SoundQIcon {Search,Close,Sort}')
prelude = prelude.replace('object spacing {val gutter=0;val small=0}', 'object spacing {val gutter=0;val small=0;val medium=0}')
prelude = prelude.replace('val body=Style();val caption=Style()', 'val body=Style();val caption=Style();val title=Style()')
prelude = prelude.replace('var testTag=""}', 'var testTag="";fun heading(){}}')
prelude = prelude.replace('object Arrangement {val Center=0}', 'object Arrangement {val Center=0;fun spacedBy(value:Int)=value}')
prelude = prelude.replace('verticalAlignment:Int,body:RowScope.', 'verticalAlignment:Int,horizontalArrangement:Int=0,body:RowScope.')
prelude = prelude.replace('contentAlignment:Int,body:()->Unit)', 'contentAlignment:Int=0,body:()->Unit)')
prelude = prelude.replace('padding(horizontal:Int,vertical:Int)', 'padding(horizontal:Int,vertical:Int=0)')
prelude = prelude.replace('UI.editor=Editor(value,onValueChange,keyboardActions);', 'UIExtra.editorEnabled=enabled;UI.editor=Editor(value,onValueChange,keyboardActions);')
prelude += r'''
fun Modifier.size(size:Int)=this
fun Modifier.fillMaxSize()=this
object R {object drawable {val soundq_logo=1}}
fun painterResource(id:Int)=id
var brands=0
fun Image(painter:Int,description:String?,modifier:Modifier){check(description==null);brands++}
class FocusRequester {var requests=0;fun requestFocus(){requests++}}
fun Modifier.focusRequester(requester:FocusRequester)=apply{UIExtra.focus=requester}
class FocusState(val hasFocus:Boolean)
fun Modifier.onFocusChanged(callback:(FocusState)->Unit)=apply{UIExtra.focusChanged=callback}
object UIExtra {var editorEnabled=true;var focus:FocusRequester?=null;var focusChanged:((FocusState)->Unit)?=null}
object LocalContext {val current=Any()}
fun DisposableEffect(vararg keys:Any?,body:DisposeScope.()->Unit){}
class DisposeScope {fun onDispose(block:()->Unit){}}
fun <T> State<T>.collectAsStateWithLifecycle()=this
class DiscoveryView(val id:Int)
class DiscoveryEntity
class DiscoveryDetails
class SourceResults
class LazyListState
class Draft(val text:String)
enum class DiscoveryPhase {Idle,Loading,Ready}
enum class DiscoveryResultType {Song,Artist,Album}
data class DiscoveryState(val draft:Draft=Draft(""),val phase:DiscoveryPhase=DiscoveryPhase.Idle,val resultType:DiscoveryResultType=DiscoveryResultType.Song,val results:SourceResults?=null)
class Repository {
 val state=State(DiscoveryState());val edits=mutableListOf<String>();var current:DiscoveryView?=null
 fun edit(route:DiscoveryView,text:String){if(route===current){edits.add(text);state.value=state.value.copy(draft=Draft(text),phase=DiscoveryPhase.Idle)}}
 fun close(route:DiscoveryView){}
}
class Imports {fun close(route:Any){}}
class Graph(val discovery:Repository=Repository(),val imports:Imports=Imports())
class ProductViewModel {
 val graph=Graph();val imports=State(0);val sent=mutableListOf<String>()
 fun searchSources(route:DiscoveryView,draft:Draft){val repo=graph.discovery;if(route===repo.current&&draft===repo.state.value.draft){sent.add(draft.text);repo.state.value=repo.state.value.copy(phase=DiscoveryPhase.Loading)}}
}
data class PlaylistQuery(val text:String="",val sort:Int=7,val ascending:Boolean=true)
data class PlaylistState(val query:PlaylistQuery=PlaylistQuery())
class PlaylistCapture(val scope:Int)
'''
strip = function(files['components'], 'SoundQSearchStrip').replace('@Composable ', '')
header = function(files['components'], 'SoundQMainPageHeader').replace('@Composable ', '')
wrapper = function(files['wrapper'], 'MainPageHeader').replace('@Composable ', '')
discover = files['discover']
prefix = discover[discover.index('    val repository=model.graph.discovery'):discover.index('    val openedCatalog=catalogDetails')]
discover_body = 'fun DiscoverInput(model:ProductViewModel,view:DiscoveryView?,intake:Any?) {\n' + prefix + '\n' + call(discover, 'SoundQSearchStrip') + '\n}\n'
playlist = files['playlists']
playlist_prefix = playlist[playlist.index('    var search by remember'):playlist.index('    var sorting by remember')]
playlist_body = 'fun PlaylistInput(state:PlaylistState,capture:PlaylistCapture?,pending:Boolean,onRefine:(PlaylistQuery)->Unit) {\nval scope=capture?.scope\nvar sorting=false\n' + playlist_prefix + call(playlist, 'SoundQSearchStrip') + '\n}\n'
tests = r'''
object D {
 lateinit var model:ProductViewModel;var route:DiscoveryView?=null
 fun render(){Memory.cursor=0;UI.actions.clear();DiscoverInput(model,route,null);Memory.flush()}
 fun start(){Memory.reset();Focus.clears=0;Focus.duringClear={};model=ProductViewModel();route=DiscoveryView(1);model.graph.discovery.current=route;render()}
 fun edit(value:TextFieldValue){UI.editor.edit(value);render()}
 fun click(label:String="Search music"){val action=UI.actions.getValue(label);check(action.enabled);action.click();render()}
}
object P {
 var state=PlaylistState();var capture:PlaylistCapture?=null;var pending=false;val sent=mutableListOf<PlaylistQuery>()
 fun render(){Memory.cursor=0;UI.actions.clear();PlaylistInput(state,capture,pending){sent.add(it)};Memory.flush()}
 fun start(){Memory.reset();Focus.duringClear={};sent.clear();state=PlaylistState();capture=PlaylistCapture(1);pending=false;render()}
 fun edit(value:TextFieldValue){UI.editor.edit(value);render()}
}
fun main(){
 var passed=0;var failed=0
 fun case(name:String,body:()->Unit){try{body();passed++;println("PASS $name")}catch(e:Throwable){failed++;println("FAIL $name: ${e.message}")}}
 case("canonical_header_brand_navigation_and_action_slots_execute_once") {
  var navigation=0;var actions=0;brands=0;UI.decorations.clear()
  for(title in listOf("Home","Discover","Library","Playlists")) {
   MainPageHeader(title,navigation={navigation++}){actions++}
  }
  check(brands==4&&navigation==4&&actions==4)
  check(UI.decorations==listOf("Home","Discover","Library","Playlists"))
 }
 case("discover_text_only_debounce_at_350ms_preserves_native_value") {
  D.start();val first=TextFieldValue("café 東京",TextRange(2),TextRange(0,4));D.edit(first)
  check(UI.editor.value===first);Memory.advance(200)
  val composing=first.copy(selection=TextRange(1,3),composition=TextRange(5,7));D.edit(composing)
  check(UI.editor.value===composing);check(D.model.graph.discovery.edits==listOf(first.text))
  Memory.advance(149);check(D.model.sent.isEmpty());Memory.advance(1);check(D.model.sent==listOf(first.text))
 }
 case("discover_replacement_cancels_old_debounce_and_route") {
  D.start();D.edit(TextFieldValue("A"));Memory.advance(200);D.edit(TextFieldValue("B"));Memory.advance(150);check(D.model.sent.isEmpty())
  Memory.advance(200);check(D.model.sent==listOf("B"))
  D.start();D.edit(TextFieldValue("old"));D.route=null;D.model.graph.discovery.current=null;D.render();Memory.advance(350)
  check(D.model.sent.none{it=="old"})
 }
 case("discover_explicit_submit_captures_before_focus_callback_and_no_duplicate_timer") {
  D.start();D.edit(TextFieldValue("visible",TextRange(3),TextRange(0,7)))
  Focus.duringClear={UI.editor.edit(TextFieldValue("new native value",TextRange(1),TextRange(0,3)))}
  D.click();check(D.model.sent==listOf("visible"));check(UI.editor.value.text=="new native value")
  // A focus callback publishing NEW text deliberately creates a NEW debounce intent.
  Focus.duringClear={};Memory.advance(350);check(D.model.sent==listOf("visible","new native value"))
  D.start();D.edit(TextFieldValue("visible",TextRange(3),TextRange(0,7)))
  UI.editor.keyboard.onSearch();D.render();Memory.advance(350)
  check(D.model.sent==listOf("visible"));check(Focus.clears==1)
 }
 case("discover_clear_focus_attachment_authoritative_refinement_and_loading_gate") {
  D.start();D.edit(TextFieldValue("x"));UIExtra.focusChanged!!(FocusState(true));D.click("Clear search")
  check(UI.editor.value.text=="");check(UIExtra.focus!!.requests==1);check(D.model.graph.discovery.edits==listOf("x",""))
  Memory.advance(350);check(D.model.sent.isEmpty())
  D.model.graph.discovery.state.value=DiscoveryState(Draft("refined"));D.render();D.render();check(UI.editor.value.text=="refined")
  D.model.graph.discovery.state.value=D.model.graph.discovery.state.value.copy(phase=DiscoveryPhase.Loading);D.render()
  check(!UI.actions.getValue("Search music").enabled);UI.editor.keyboard.onSearch();check(D.model.sent.isEmpty())
 }
 case("playlist_native_selection_and_composition_stay_local_until_explicit_ime") {
  P.start();val value=TextFieldValue("  café 東京  ",TextRange(2,5),TextRange(7,9));P.edit(value)
  check(UI.editor.value===value);check(P.sent.isEmpty());UI.editor.keyboard.onSearch();P.render()
  check(P.sent==listOf(P.state.query.copy(text=value.text)))
 }
 case("playlist_button_captures_before_focus_clear_and_clear_preserves_sort") {
  P.start();P.edit(TextFieldValue("visible",TextRange(2),TextRange(0,7)))
  Focus.duringClear={UI.editor.edit(TextFieldValue("newer"))};UI.actions.getValue("Search playlists").click();P.render()
  check(P.sent.single().text=="visible");check(UI.editor.value.text=="newer")
  UI.actions.getValue("Clear playlist search").click();P.render()
  check(P.sent.last()==P.state.query.copy(text=""));check(UI.editor.value.text=="")
 }
 case("playlist_pending_and_missing_capture_gate_search_clear_sort_and_ime") {
  for(noCapture in listOf(false,true)) {
   P.start();P.edit(TextFieldValue("query"));if(noCapture)P.capture=null else P.pending=true;P.render()
   check(UIExtra.editorEnabled==!P.pending)
   check(listOf("Search playlists","Clear playlist search","Sort playlists").all{!UI.actions.getValue(it).enabled})
   UI.editor.keyboard.onSearch();check(P.sent.isEmpty())
  }
 }
 case("playlist_query_and_scope_replacement_reset_native_draft_without_submit") {
  P.start();P.edit(TextFieldValue("local"));P.state=PlaylistState(PlaylistQuery("accepted",9,false));P.render()
  check(UI.editor.value.text=="accepted");check(P.sent.isEmpty())
  P.edit(TextFieldValue("other local"));P.capture=PlaylistCapture(2);P.render();check(UI.editor.value.text=="accepted")
 }
 println("RESULT passed=$passed failed=$failed; exact caller input/effect regions and shared strip; simulated framework only")
 check(failed==0)
}
'''
generated = prelude + '\n' + header + '\n' + wrapper + '\n' + strip + '\n' + discover_body + '\n' + playlist_body + tests
(a.output / 'Probe.kt').write_text(generated)
(a.output / 'Brush.kt').write_text('package androidx.compose.ui.graphics\nclass SolidColor(color:Int)\n')
(a.output / 'inputs.json').write_text(json.dumps({
    'files': {name: hashlib.sha256(text.encode()).hexdigest() for name, text in files.items()},
    'regions': {name: hashlib.sha256(text.encode()).hexdigest() for name, text in [('strip', strip), ('discover', discover_body), ('playlists', playlist_body)]},
    'scope': 'source adoption + exact callback/effect execution with declaration facades, NOT mounted/native'}, indent=2) + '\n')
kotlinc, java = shutil.which('kotlinc'), shutil.which('java')
if not kotlinc or not java:
    parser.error('Standalone kotlinc/java required; no Gradle fallback')
compile_result = subprocess.run([kotlinc, '-nowarn', '-include-runtime', '-d', str(a.output / 'probe.jar'), str(a.output / 'Probe.kt'), str(a.output / 'Brush.kt')], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(a.output / 'compile.log').write_text(compile_result.stdout)
print(compile_result.stdout, end='')
if compile_result.returncode:
    raise SystemExit(compile_result.returncode)
run = subprocess.run([java, '-cp', str(a.output / 'probe.jar'), 'librarysearchprobe.ProbeKt'], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(a.output / 'result.log').write_text(run.stdout)
print(run.stdout, end='')
raise SystemExit(run.returncode)
