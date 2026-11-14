#!/usr/bin/env python3
"""SDK-free extraction of the real Library projection, notices and refinement sheet.

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
# These are assertion/annotation facades only. The original test bodies execute
# unchanged; this is not a claim to have run the registered Gradle JUnit task.
emit('Assert.java', '''package org.junit;
public class Assert {
 public static void assertEquals(Object e,Object a){if(!java.util.Objects.equals(e,a))throw new AssertionError("expected <"+e+"> but was <"+a+">");}
 public static void assertTrue(boolean a){if(!a)throw new AssertionError("expected true");}
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
''' + '\n'.join(calls) + '\nprintln("RESULT total=$total failures=$failures");check(failures==0)}\n')
(a.output / 'inputs.json').write_text(json.dumps({'inputs': inputs, 'signatureBridge': 'typed' if new else 'baseline Boolean'}, indent=2)+'\n')
subprocess.run(['kotlinc', *map(str, a.output.glob('*.kt')), '-cp', str(classes), '-nowarn', '-include-runtime', '-d', str(a.output/'probe.jar')], check=True)
result = subprocess.run(['java', '-cp', str(a.output/'probe.jar')+':'+str(classes), 'com.soundq.android.product.RunKt'], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(a.output / 'result.txt').write_text(result.stdout)
print(result.stdout)
raise SystemExit(result.returncode)
