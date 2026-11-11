#!/usr/bin/env python3
"""Compile actual AnalysisSummary/AnalysisFact bodies against host layout/text boundaries.
This executes consuming presentation, not mounted Compose or Android runtime.
"""
from pathlib import Path
import argparse
p=argparse.ArgumentParser();p.add_argument('--generate',type=Path,required=True);p.add_argument('--source-root',type=Path);a=p.parse_args()
r=a.source_root or Path(__file__).resolve().parents[1]
s=(r/'app/src/main/kotlin/com/soundq/android/product/trackdetails/TrackDetailsSheet.kt').read_text()
summary=s[s.index('@Composable internal fun AnalysisSummary('):].replace('@Composable ','').replace('private fun AnalysisFact','fun AnalysisFact')
has_notation='keyNotation:KeyNotation' in summary
preamble='''package com.soundq.android.keynotationfixture
import com.soundq.android.data.trackdetails.*
import com.soundq.android.data.preferences.*
import org.junit.Assert.*
import org.junit.Test
import kotlinx.serialization.json.*
object Modifier {fun weight(value:Float)=this;fun semantics(block:Semantics.()->Unit)=this}
class Semantics {fun heading(){}}
object Arrangement {fun spacedBy(value:Int)=value}
object SoundQ {
 object typography {val title=0;val caption=0;val mono=0}
 object spacing {val medium=0}
 object colors {val muted=0}
}
val painted=mutableListOf<String>()
fun Text(text:String,modifier:Modifier=Modifier,style:Int=0,color:Int=0){painted.add(text)}
fun Column(modifier:Modifier=Modifier,verticalArrangement:Int=0,content:()->Unit){content()}
fun Row(horizontalArrangement:Int=0,content:()->Unit){content()}
'''
if has_notation:
 preamble=preamble.replace('import com.soundq.android.data.trackdetails.*','import com.soundq.android.data.trackdetails.*\nimport com.soundq.android.product.trackdetails.formatAnalysisKey')
test='''
class KeyNotationPresentationExtractedTest {
 private fun facts()=AnalysisDetail(3,"analyzed",
  buildJsonObject {putJsonObject("key"){put("value","Am")};putJsonObject("camelot"){put("value"," 8a ")}},
  buildJsonObject{},buildJsonObject{})
 @Test fun defaultReadShowsOnlyPreferredCamelotInsteadOfTwoRawFacts() {
  painted.clear();AnalysisSummary(facts())
  assertTrue("Actual read presentation must show Camelot alone. Painted: $painted",painted.contains("8A"))
  assertTrue(painted.contains("Key"));assertFalse(painted.contains("Am ·  8a "))
 }
'''
if has_notation:
 test+='''
 @Test fun acceptedOwnerChoiceChangesActualReadWithoutChangingRawCorrectionFacts() {
  val dir=java.nio.file.Files.createTempDirectory("notation-presentation").toFile()
  try {
   val owner=KeyNotationPreferences(dir.resolve("notation"));owner.load();val analysis=facts()
   painted.clear();AnalysisSummary(analysis,owner.state.value.choice)
   assertTrue(painted.contains("8A"));assertFalse(painted.contains("Am"))
   assertTrue(owner.setChoice(owner.capture()!!,KeyNotation.Musical){true})
   painted.clear();AnalysisSummary(analysis,owner.state.value.choice)
   assertTrue(painted.contains("Am"));assertFalse(painted.contains("8A"))
   assertEquals("Am",analysis.text("key"));assertEquals(" 8a ",analysis.text("camelot"))
   painted.clear();AnalysisSummary(null,owner.state.value.choice);assertEquals(listOf("Analysis"),painted)
  }finally {dir.deleteRecursively()}
 }
'''
test+='}\n'
a.generate.mkdir(parents=True,exist_ok=True)
(a.generate/'KeyNotationPresentationExtractedTest.kt').write_text(preamble+summary+test)
print('Extracted actual consuming summary, notation parameter:',has_notation)
settings=(r/'app/src/main/kotlin/com/soundq/android/product/preferences/PreferencesScreen.kt').read_text()
if '@Composable private fun KeyNotationSetting(' in settings:
 block=settings[settings.index('@Composable private fun KeyNotationSetting('):settings.index('@Composable fun LocalUnlockScreen')].replace('@Composable private fun','fun')
 # Give the host-only generic remember facade explicit cell types. Actions stay byte-for-byte.
 block=block.replace('remember(owner){mutableStateOf(false)}','remember<Cell<Boolean>>(owner){mutableStateOf(false)}').replace('remember(owner){mutableStateOf<KeyNotation?>(null)}','remember<Cell<KeyNotation?>>(owner){mutableStateOf<KeyNotation?>(null)}')
 fixture='''package com.soundq.android.keynotationsettingsfixture
import com.soundq.android.data.preferences.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.StateFlow
import kotlin.reflect.KProperty
import org.junit.Assert.*
import org.junit.Test
class Cell<T>(var value:T) {
 operator fun getValue(thisRef:Any?,property:KProperty<*>)=value
 operator fun setValue(thisRef:Any?,property:KProperty<*>,next:T){value=next}
}
fun <T> mutableStateOf(value:T)=Cell(value)
val memory=mutableListOf<Any?>();var cursor=0
@Suppress("UNCHECKED_CAST") fun <T> remember(vararg keys:Any?,block:()->T):T {
 val index=cursor++;if(index==memory.size)memory.add(block());return memory[index] as T
}
fun <T> StateFlow<T>.collectAsStateWithLifecycle()=Cell(value)
lateinit var work:CoroutineScope
fun rememberCoroutineScope()=work
val disposals=mutableListOf<()->Unit>()
class Disposal {fun onDispose(block:()->Unit){disposals.add(block)}}
fun DisposableEffect(vararg keys:Any?,block:Disposal.()->Unit){Disposal().block()}
object Modifier {fun selectableGroup()=this}
object Role {val RadioButton=0}
object SoundQ {
 object typography {val title=0}
 object colors {val primary=0;val muted=0;val disabled=0}
}
object RadioButtonDefaults {fun colors(selectedColor:Int,unselectedColor:Int,disabledSelectedColor:Int,disabledUnselectedColor:Int)=0}
fun RadioButton(selected:Boolean,onClick:(()->Unit)?,enabled:Boolean,colors:Int){}
fun Column(modifier:Modifier,content:()->Unit){content()}
fun SettingsChoices(content:()->Unit){content()}
fun Text(text:String,style:Int){}
val rows=mutableMapOf<String,()->Unit>()
fun SoundQRow(label:String,description:String,selected:Boolean,onClick:()->Unit,enabled:Boolean,trailing:()->Unit,role:Int){rows[label]=onClick;trailing()}
enum class FeedbackKind { Loading,Error }
enum class SoundQButtonVariant { Quiet }
fun SoundQFeedback(title:String,kind:FeedbackKind,detail:String="",label:String="",action:()->Unit={}){if(label.isNotEmpty())rows[label]=action}
fun SoundQButton(label:String,action:()->Unit,variant:SoundQButtonVariant,enabled:Boolean){rows[label]=action}
'''
 tests='''
class KeyNotationSettingsExtractedTest {
 private fun drain()=runBlocking {work.coroutineContext[Job]!!.children.toList().joinAll()}
 private fun render(owner:KeyNotationPreferences,valid:()->Boolean){cursor=0;KeyNotationSetting(owner,valid)}
 @Test fun actualSettingCallbackPersistsAndRetainedRevisionDismissalAndAccountCallbacksRefuse() {
  val dir=java.nio.file.Files.createTempDirectory("notation-setting").toFile()
  work=CoroutineScope(SupervisorJob()+Dispatchers.Unconfined)
  try {
   val file=dir.resolve("notation");val owner=KeyNotationPreferences(file);owner.load()
   var account=true
   render(owner){account}
   rows.getValue("Musical key")();drain()
   assertEquals(KeyNotation.Musical,owner.state.value.choice)
   val bytes=file.readBytes();val old=rows.getValue("Camelot")
   owner.load();old();drain();assertArrayEquals(bytes,file.readBytes())
   render(owner){account};val dismissed=rows.getValue("Camelot")
   disposals.toList().forEach {it()};dismissed();drain();assertArrayEquals(bytes,file.readBytes())
   memory.clear();render(owner){account};account=false;rows.getValue("Camelot")();drain()
   assertArrayEquals(bytes,file.readBytes())
  }finally {work.cancel();disposals.clear();memory.clear();rows.clear();dir.deleteRecursively()}
 }
 @Test fun failedSaveRequiresExplicitRetryOrReloadThroughActualSettingActions() {
  val dir=java.nio.file.Files.createTempDirectory("notation-retry").toFile()
  work=CoroutineScope(SupervisorJob()+Dispatchers.Unconfined)
  try {
   val parent=dir.resolve("blocked");parent.writeText("blocked")
   val file=parent.resolve("notation");val owner=KeyNotationPreferences(file);owner.load()
   render(owner){true};rows.getValue("Musical key")();drain()
   assertEquals(KeyNotation.Camelot,owner.state.value.choice);assertEquals(KeyNotationError.Write,owner.state.value.error)
   parent.delete();parent.mkdir();assertFalse(file.exists())
   render(owner){true};rows.getValue("Retry key notation")();drain()
   assertEquals(KeyNotation.Musical,owner.state.value.choice)
   file.writeText("future");owner.load();rows.clear();render(owner){true}
   assertTrue(rows.containsKey("Reload key notation"));rows.getValue("Camelot")();drain()
   assertEquals("future",file.readText());assertEquals(KeyNotation.Musical,owner.state.value.choice)
   file.writeText("{\\"version\\":1,\\"keyNotation\\":\\"camelot\\"}")
   rows.getValue("Reload key notation")();drain();assertEquals(KeyNotation.Camelot,owner.state.value.choice)
  }finally {work.cancel();disposals.clear();memory.clear();rows.clear();dir.deleteRecursively()}
 }
}
'''
 (a.generate/'KeyNotationSettingsExtractedTest.kt').write_text(fixture+block+tests)
 # Keep graph observation and the actual route argument bound to the executable consumer.
 app=(r/'app/src/main/kotlin/com/soundq/android/product/ProductApp.kt').read_text()
 assert 'val keyNotation by model.graph.keyNotationPreferences.state.collectAsStateWithLifecycle()' in app
 assert 'keyNotation=keyNotation.choice' in app
 assert 'AnalysisSummary(state.analysis,keyNotation)' in s
 assert 'KeyNotationSetting(graph.keyNotationPreferences,valid)' in settings
 print('Extracted actual Settings block and bound ProductApp read consumer')
