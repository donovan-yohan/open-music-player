#!/usr/bin/env python3
"""SDK-free extraction of Library projection, notices, refinement and chrome count.

Uses only standalone kotlinc/javac/java; never reads Gradle outputs/caches. The
small Compose facade retains remember slots across explicit recompositions and
throws them away on sheet close. It proves callbacks/draft policy, NOT Android
layout, native modal dismissal, saveable restoration or mounted interaction.
An old-signature bridge permits the identical sheet regression on the baseline.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--source-root', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=False)
root = a.source_root / 'android/app/src'
main = root / 'main/kotlin/com/soundq/android'
test = root / 'test/kotlin/com/soundq/android/product'
inputs = {}


def read(path):
    text = path.read_text()
    inputs[str(path.relative_to(a.source_root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return text


def emit(name, text):
    (a.output / name).write_text(text)


contracts = read(main / 'data/Contracts.kt')
emit('Contracts.kt', 'package com.soundq.android.data\n' + contracts[contracts.index('@JvmInline value class TrackId'):contracts.index('data class LibraryAnalysisFacts')])
collection = read(main / 'data/LibraryCollection.kt')
emit('Collection.kt', collection[:collection.index('/** Full server-refined')])
emit('DeviceAudioTypes.kt', read(main / 'data/deviceaudio/DeviceAudioTypes.kt'))
refs = read(main / 'playback/PlaybackRef.kt')
emit('PlaybackRef.kt', 'package com.soundq.android.playback\nimport com.soundq.android.data.TrackId\nimport java.util.UUID\n' + refs[refs.index('@Serializable sealed'):refs.index('    fun json()')].replace('@Serializable ', '') + '}\n')
phone = read(main / 'data/device/PhoneAudioRepository.kt')
emit('PhoneState.kt', 'package com.soundq.android.data.device\nimport com.soundq.android.data.deviceaudio.*\n' + phone[phone.index('internal data class PhoneAudioState'):phone.index('internal data class PhoneSourceAdmission')])
projection = read(main / 'product/UnifiedLibraryProjection.kt')
emit('Projection.kt', projection)
notice = read(main / 'product/LocalAudioNotice.kt')
emit('Notice.kt', 'package com.soundq.android.product\nimport com.soundq.android.data.LibraryQuery\nimport com.soundq.android.data.device.PhoneAudioState\n' + notice[notice.index('internal enum class LocalAudioNotice'):notice.index('@Composable internal fun LocalAudioNoticeContent')])
app = read(main / 'product/ProductApp.kt')
sheet = app[app.index('@Composable private fun RefineSheet'):]
index = next(line for line in app.splitlines() if line.startswith('internal fun libraryRowScrollIndex'))

new = 'source:LibrarySource' in projection
bridge = '''RefineSheet(query,{closed=true},source=LibrarySource.valueOf(appliedSource.name),recent=appliedRecent) {q,s,r-> appliedQuery=q;appliedSource=UiSource.valueOf(s.name);appliedRecent=r;closed=true}''' if new else '''RefineSheet(query,{closed=true},recent=appliedRecent,onRecentApply={appliedRecent=it}) {q->appliedQuery=q;closed=true}'''
project_arg = 'LibrarySource.valueOf(appliedSource.name)' if new else 'appliedSource==UiSource.Local'
facade = '''package com.soundq.android.product
import com.soundq.android.data.*
import com.soundq.android.data.deviceaudio.*
import kotlin.reflect.KProperty
import java.util.UUID
annotation class Composable
class State<T>(var value:T) {operator fun getValue(r:Any?,p:KProperty<*>)=value;operator fun setValue(r:Any?,p:KProperty<*>,v:T){value=v}}
fun <T> mutableStateOf(v:T)=State(v)
object Slots {val values=mutableListOf<Any?>();var index=0}
@Suppress("UNCHECKED_CAST") fun <T> remember(block:()->State<T>):State<T> {val i=Slots.index++;if(i==Slots.values.size)Slots.values.add(block());return Slots.values[i] as State<T>}
object Modifier {fun fillMaxWidth()=this;fun heightIn(min:Int)=this;fun selectable(selected:Boolean,role:Role,onClick:()->Unit)=this}
val Int.dp get()=this
object Alignment {val CenterVertically=0}
enum class Role {RadioButton}
object SoundQ {object typography {val title=0;val body=0}}
enum class SoundQButtonVariant {Secondary,Quiet}
val tabs=mutableListOf<Pair<List<String>,Pair<Int,(Int)->Unit>>>()
val buttons=mutableMapOf<String,()->Unit>()
var dismiss:()->Unit={}
fun SoundQSheet(title:String,onDismiss:()->Unit,content:()->Unit){dismiss=onDismiss;content()}
fun Text(text:String,style:Int){}
fun SoundQTabs(labels:List<String>,selected:Int,onSelect:(Int)->Unit){tabs.add(labels to (selected to onSelect))}
fun SoundQButton(label:String,onClick:()->Unit,variant:SoundQButtonVariant?=null){buttons[label]=onClick}
fun SoundQTextField(value:String,onChange:(String)->Unit,label:String){}
fun Row(modifier:Modifier,verticalAlignment:Int,content:()->Unit){content()}
fun RadioButton(selected:Boolean,onClick:()->Unit){}
enum class UiSource {All,Server,Local}
var appliedSource=UiSource.All
var appliedQuery=LibraryQuery()
var appliedRecent=false
var closed=false
fun render(){Slots.index=0;tabs.clear();buttons.clear();val query=appliedQuery;BRIDGE}
fun open(){Slots.values.clear();closed=false;render()}
fun choose(s:UiSource){tabs.firstOrNull {it.first==listOf("All","Server","Local")}?.second?.second?.invoke(s.ordinal);render()}
fun click(label:String){buttons.getValue(label)();if(!closed)render()}
fun expect(expected:Any?,actual:Any?){check(expected==actual){"expected <$expected> but was <$actual>"}}
internal fun rows():List<UnifiedLibraryRow> {
 val phone=DeviceAudio(DeviceFileId(UUID(0,1)),ProviderObjectId("fixture","1"),ContentRevision("a".repeat(64),40),1,OriginalMetadata("phone.wav","Phone"),1000,listOf(LocatorAccess(ScanGrantId(UUID(1,1)),ProviderLocator("fixture","1"),AccessState.AVAILABLE)))
 return unifiedLibraryRows("e","a",listOf(Track(TrackId(1),"Stream"),Track(TrackId(2),"Download")),listOf(Track(TrackId(2),"Download")),DeviceListeningSnapshot(1,listOf(phone),emptyList(),emptyList()),appliedQuery,PROJECT_ARG,appliedRecent)
}
fun resetApplied(){appliedSource=UiSource.All;appliedQuery=LibraryQuery();appliedRecent=false}
fun sheetCases(run:(String,()->Unit)->Unit) {
 run("sheetServerApplyExcludesPhoneThroughActualProjection") {
  resetApplied();open();choose(UiSource.Server)
  expect(listOf("Stream","Download","Phone"),rows().map {it.title})
  click("Apply refinement");expect(listOf("Stream","Download"),rows().map {it.title})
 }
 run("sheetCancelDismissAndResetAreDraftOnly") {
  resetApplied();open();choose(UiSource.Local);click("Cancel");expect(UiSource.All,appliedSource)
  open();choose(UiSource.Server);dismiss();expect(UiSource.All,appliedSource)
  open();choose(UiSource.Local);click("Apply refinement");expect(listOf("Download","Phone"),rows().map {it.title})
  open();click("Reset refinement");click("Cancel");expect(UiSource.Local,appliedSource)
  open();expect(2,tabs.first {it.first==listOf("All","Server","Local")}.second.first)
  click("Reset refinement");expect(UiSource.Local,appliedSource);click("Apply refinement");expect(UiSource.All,appliedSource)
 }
 run("sheetQueryRecentAndSourceCommitTogether") {
  resetApplied();appliedQuery=LibraryQuery(text="Download",liked=true,sort=LibrarySort.Title);appliedRecent=true
  open();choose(UiSource.Local);click("Apply refinement")
  expect(LibraryQuery(text="Download",liked=true,sort=LibrarySort.Title),appliedQuery);expect(true,appliedRecent);expect(UiSource.Local,appliedSource)
  open();click("Reset refinement");expect(true,appliedRecent);click("Apply refinement")
  expect(LibraryQuery(),appliedQuery);expect(false,appliedRecent);expect(UiSource.All,appliedSource)
 }
}
'''.replace('BRIDGE', bridge).replace('PROJECT_ARG', project_arg)
emit('Sheet.kt', facade + '\n' + index + '\n' + sheet)
# Execute the chrome journey's exact count assertions with independent literal
# cardinalities and the real projection. These boundary facades do not load files,
# run Compose, or substitute for the pending native chrome journeys.
chrome = read(root / 'androidTest/kotlin/com/soundq/android/LibraryChromeJourneyTest.kt')

def block(text, anchor):
    assert text.count(anchor) == 1, anchor
    start = text.index(anchor)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

count_start = '        assertTrue("Unused room remains to the right of quick labels",liked.right<refineBounds.left)\n'
count_end = '\n        tab("Liked").performClick()'
assert chrome.count(count_start) == chrome.count(count_end) == 1
count = chrome.split(count_start)[1].split(count_end)[0]
assert 'assertIsDisplayed()' in count and 'assertDoesNotExist()' in count
helper = block(chrome, '    private fun expectedServerCount(') if '    private fun expectedServerCount(' in chrome else ''
offline = read(main / 'data/offline/DeviceDownloads.kt')
session = read(main / 'data/AccountSession.kt')
def line(text, anchor):
    rows = [row for row in text.splitlines() if anchor in row]
    assert len(rows) == 1, anchor
    return rows[0]
admission = offline[offline.index('    @Synchronized fun ownsComplete('):offline.index('    /** Off-main admission only.')]
emit('CountProbe.kt', '''package com.soundq.android.product
import com.soundq.android.data.*
import com.soundq.android.data.deviceaudio.*
import org.junit.Assert.*
class Value<T>(var value:T)
class TokenAccount(val accountId:String)
''' + line(session, 'class AccountScope internal constructor(') + '''
class AccountSession {
 var localLocked=false;var epoch=1L;var deviceAccount:String?=null;var tokens:TokenAccount?=TokenAccount("fixture-account")
''' + line(session, '@Synchronized fun capture():') + '\n' + line(session, '@Synchronized fun current(') + '''
}
''' + offline[offline.index('enum class DownloadStatus'):offline.index('class DownloadTicket')] + '''
class Stored(val row:DeviceDownload,val artifact:Any?)
class DownloadBoundary(val session:AccountSession) {
 var owner=session.capture();var writable=true
 val entries=mutableMapOf<TrackId,Stored>();val state=Value(DownloadsState(ready=true))
 fun admit(row:DeviceDownload,artifact:Boolean=true) {entries[row.track.id]=Stored(row,if(artifact)Any()else null);state.value=state.value.copy(rows=state.value.rows+row)}
''' + line(offline, 'private fun same(scope:AccountScope)') + '\n' + admission + '''
}
data class LibraryState(val query:LibraryQuery,val rows:List<Track>,val total:Int?)
class LibraryBoundary(val state:Value<LibraryState>,val session:AccountSession) {
 fun projectionScope(expected:LibraryState)=session.capture()?.takeIf {state.value===expected}
}
class Graph(val library:LibraryBoundary,val downloads:DownloadBoundary)
class ProductViewModel(val graph:Graph) {val library=graph.library.state;val downloads=graph.downloads.state}
class Bounds(val right:Float=0f,val left:Float=100f)
class Node(val label:String,val rendered:Int?) {
 fun assertIsDisplayed():Node {check(label=="$rendered tracks") {"count label <$label> does not match rendered <$rendered tracks>"};return this}
 fun assertDoesNotExist() {check(label!="$rendered tracks") {"count should be hidden"}}
 fun fetchSemanticsNode()=this
 val boundsInRoot=Bounds()
}
class CountCompose(val rendered:Int?) {
 fun <T> runOnIdle(body:()->T)=body()
 fun onNodeWithText(label:String,useUnmergedTree:Boolean)=Node(label,rendered)
}
''' + helper + '''
fun countAssertions(width:Int,scale:Float,model:ProductViewModel,rendered:Int?) {
 val compose=CountCompose(rendered);val refineBounds=Bounds()
''' + count + '''
}
fun chromeCases(run:(String,()->Unit)->Unit) {
 fun track(id:Long,title:String="Fixture $id",liked:Boolean?=false,artist:String="Synthetic ensemble",album:String="Album")=Track(TrackId(id),title,artist,album,12000,liked)
 fun test(name:String,expected:Int,server:List<Track> = listOf(track(1),track(2),track(3)),query:LibraryQuery=LibraryQuery(),setup:(DownloadBoundary)->Unit={})=run("chromeCount."+name) {
  val session=AccountSession();val downloads=DownloadBoundary(session);setup(downloads)
  val state=Value(LibraryState(query,server,server.size));val model=ProductViewModel(Graph(LibraryBoundary(state,session),downloads))
  val phone=DeviceAudio(DeviceFileId(java.util.UUID(0,99)),ProviderObjectId("fixture","99"),ContentRevision("a".repeat(64),40),1,OriginalMetadata("phone.wav","Phone"),1000,listOf(LocatorAccess(ScanGrantId(java.util.UUID(1,1)),ProviderLocator("fixture","99"),AccessState.AVAILABLE)))
  val owned=downloads.state.value.rows.filter {downloads.ownsComplete(requireNotNull(session.capture()),it)}.map {it.track}
  val rows=unifiedLibraryRows("fixture-endpoint","fixture-account",server,owned,DeviceListeningSnapshot(1,listOf(phone),emptyList(),emptyList()),query,LibrarySource.Server,false)
  expect(expected,rows.size) // independent literal expectation, not the oracle under repair
  check(rows.all {it.ref is com.soundq.android.playback.PlaybackRef.Server})
  countAssertions(412,1f,model,rows.size) // exact displayed-count + before-Refine assertions
  countAssertions(412,2f,model,null) // exact hidden-count assertion
 }
 fun complete(t:Track)=DeviceDownload(t,DownloadStatus.Complete)
 test("distinctOwnedDownload",4) {it.admit(complete(track(4)))}
 test("duplicateServerIdentity",3) {it.admit(complete(track(2,"Stale download metadata")))}
 test("distinctIdentitySameMetadata",4) {it.admit(complete(track(4,"Fixture 1")))}
 test("phoneOnlyExcluded",3)
 test("foreignSession",3) {it.owner=AccountSession().capture();it.admit(complete(track(4)))}
 test("foreignAccount",3) {it.owner=AccountScope(it.session,it.session.epoch,"other");it.session.tokens=TokenAccount("other");it.admit(complete(track(4)));it.session.tokens=TokenAccount("fixture-account");it.session.epoch++}
 test("retiredEpoch",3) {it.admit(complete(track(4)));it.session.epoch++}
 test("unownedRow",3) {it.state.value=DownloadsState(listOf(complete(track(4))),ready=true)}
 test("staleRowObject",3) {val row=complete(track(4));it.admit(row);it.state.value=it.state.value.copy(rows=listOf(row.copy()))}
 test("missingArtifact",3) {it.admit(complete(track(4)),artifact=false)}
 test("rejectedStore",3) {it.admit(complete(track(4)));it.writable=false}
 for(status in DownloadStatus.entries.filter {it!=DownloadStatus.Complete})test("status"+status,3) {it.admit(DeviceDownload(track(4),status))}
 test("textNonmatchExcluded",3,query=LibraryQuery(text="Fixture")) {it.admit(complete(track(4,"Other")))}
 test("textMatchTrimCase",4,query=LibraryQuery(text="  fIXture  ")) {it.admit(complete(track(4)))}
 test("serverSearchAuthorityRetained",3,query=LibraryQuery(text="server indexed term"))
 test("likedFalseAndUnknownExcluded",3,server=listOf(track(1,liked=true),track(2,liked=true),track(3,liked=true)),query=LibraryQuery(liked=true)) {it.admit(complete(track(4,liked=false)));it.admit(complete(track(5,liked=null)))}
 test("likedTrueIncluded",4,server=listOf(track(1,liked=true),track(2,liked=true),track(3,liked=true)),query=LibraryQuery(liked=true)) {it.admit(complete(track(4,liked=true)))}
 test("acknowledgedLikeOverridesStaleDownload",2,server=listOf(track(1,liked=true),track(2,liked=true),track(3,liked=false)),query=LibraryQuery(liked=true)) {it.admit(complete(track(3,liked=true)))}
 test("collectionExactMembership",4,query=LibraryQuery(collection=LibraryCollection(album="Album"))) {it.admit(complete(track(4)));it.admit(complete(track(5,album="Elsewhere")))}
 test("genreNeedsAcknowledgement",3,query=LibraryQuery(genre="Jazz")) {it.admit(complete(track(4)))}
 for(verified in listOf(false,true))test("verifiedNeedsAcknowledgement"+verified,3,query=LibraryQuery(verified=verified)) {it.admit(complete(track(4)))}
}
''')
# These are assertion/annotation facades only. The original test bodies execute
# unchanged; this is not a claim to have run the registered Gradle JUnit task.
emit('Assert.java', '''package org.junit;
public class Assert {
 public static void assertEquals(Object e,Object a){if(!java.util.Objects.equals(e,a))throw new AssertionError("expected <"+e+"> but was <"+a+">");}
 public static void assertTrue(boolean a){if(!a)throw new AssertionError("expected true");}
 public static void assertTrue(String message,boolean a){if(!a)throw new AssertionError(message);}
 public static void assertFalse(boolean a){if(a)throw new AssertionError("expected false");}
 public static void assertNull(Object a){if(a!=null)throw new AssertionError("expected null: "+a);}
}
''')
emit('Test.java', 'package org.junit; public @interface Test {}\n')
classes = a.output / 'classes'
classes.mkdir()
subprocess.run(['javac', '-d', str(classes), str(a.output/'Assert.java'), str(a.output/'Test.java')], check=True)
calls = []
for name in ['UnifiedLibraryProjectionTest', 'LocalAudioNoticeTest', 'LibraryShellIndexTest']:
    text = read(test / (name + '.kt'))
    emit(name + '.kt', text)
    for method in re.findall(r'@Test fun (\w+)\(', text):
        calls.append(f'run("{name}.{method}"){{{name}().{method}()}}')
emit('Run.kt', '''package com.soundq.android.product
fun main(){var failures=0;var total=0
 fun run(name:String,body:()->Unit){total++;try{body();println("PASS "+name)}catch(e:Throwable){failures++;println("FAIL "+name+" "+e)}}
 sheetCases(::run)
 chromeCases(::run)
''' + '\n'.join(calls) + '\nprintln("RESULT total=$total failures=$failures");check(failures==0)}\n')
(a.output / 'inputs.json').write_text(json.dumps({'inputs': inputs, 'signatureBridge': 'typed' if new else 'baseline Boolean',
    'chromeCountRegions': {name: hashlib.sha256(text.encode()).hexdigest() for name, text in [('assertions', count), ('oracle', helper), ('ownsComplete', admission)]},
    'chromeScope': 'Exact journey count assertions and oracle, actual projection/admission predicates; in-memory owner/state/UI facades, not persisted artifact validation or mounted Compose'}, indent=2)+'\n')
subprocess.run(['kotlinc', *map(str, a.output.glob('*.kt')), '-cp', str(classes), '-nowarn', '-include-runtime', '-d', str(a.output/'probe.jar')], check=True)
result = subprocess.run(['java', '-cp', str(a.output/'probe.jar')+':'+str(classes), 'com.soundq.android.product.RunKt'], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(a.output / 'result.txt').write_text(result.stdout)
print(result.stdout)
raise SystemExit(result.returncode)
