#!/usr/bin/env python3
"""Run extracted shared callbacks with the pinned Material3 Back completion.

The host SheetState facade models settled hide/veto only, not Compose lifetime,
Android windows or animation. Native Appearance remains the mounted acceptance.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
from host_probe import directory, gradle_cache, scratch_root

p=argparse.ArgumentParser()
p.add_argument('--source-root',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False)
s=(a.source_root/'android/designsystem/src/main/kotlin/com/soundq/designsystem/ProductComponents.kt').read_text()
def balanced(start,op='(',cl=')'):
    i=s.index(op,start);depth=1;j=i+1
    while depth:
        depth+=(s[j]==op)-(s[j]==cl);j+=1
    return s[i:j]
start=s.index('    val admit by rememberUpdatedState(dismissAdmission)')
end=s.index('    ModalBottomSheet(',start)
locals_=s[start:end]
state_start=s.index('sheetState=',end)+len('sheetState=')
if s[state_start:].startswith('rememberModalBottomSheetState'):
    state='rememberModalBottomSheetState'+balanced(state_start)
else:
    state=s[state_start:s.index(')',state_start)]
callback='onDismissRequest='
cb_start=s.index(callback,end)+len(callback)
completion=balanced(cb_start,'{','}')
key_start=s.index('else if(it.key==Key.Escape',end)
escape=balanced(key_start,'{','}')
# Use the actual shipped unconditional completion, not a rewritten mock callback.
expected='5293787ad0dcb97d245586942135fd3e3aaa6f0faadef5fd1a1c981413e3242c'
jars=list(gradle_cache().glob('*/transforms/*/transformed/*/jars/*.jar'))
material=next((x for x in jars if '/material3/' in str(x) and hashlib.sha256(x.read_bytes()).hexdigest()==expected), None)
if material is None:raise SystemExit('Pinned Material3 transformed jar unavailable in GRADLE_USER_HOME; this historical probe must not run against different bytes')
source='''import kotlin.reflect.KProperty
class Updated<T>(val value:T) {operator fun getValue(receiver:Any?,property:KProperty<*>)=value}
fun <T> rememberUpdatedState(value:T)=Updated(value)
enum class SheetValue {Hidden,Expanded}
class SheetState(val confirm:(SheetValue)->Boolean) {
 var currentValue=SheetValue.Expanded
 val isVisible get()=currentValue!=SheetValue.Hidden
 fun hide(){if(confirm(SheetValue.Hidden))currentValue=SheetValue.Hidden}
}
fun rememberModalBottomSheetState(skipPartiallyExpanded:Boolean,confirmValueChange:(SheetValue)->Boolean)=SheetState(confirmValueChange)
class QueueGestureState {var active=true;var cancels=0;fun cancel():Boolean {if(!active)return false;active=false;cancels++;return true}}
class Binding(val state:SheetState,val complete:()->Unit,val explicit:()->Unit,val escape:()->Boolean)
fun bind(dismissAdmission:()->Boolean,onDismiss:()->Unit,queueGesture:QueueGestureState?=null,onEscape:(()->Unit)?=null):Binding {
'''+locals_+'''
 val capturedState='''+state+'''
 val complete:()->Unit='''+completion+'''
 val escape:()->Boolean='''+escape+'''
 return Binding(capturedState,complete,requestDismiss,escape)
}
fun pinnedCompletion(callback:()->Unit) {
 val c=Class.forName("androidx.compose.material3.ModalBottomSheetKt")
 val name="ModalBottomSheet_YbuCTN8"+'$'+"lambda"+'$'+"11"+'$'+"lambda"+'$'+"10"+'$'+"lambda"+'$'+"9"
 val m=c.getDeclaredMethod(name,kotlin.jvm.functions.Function0::class.java,Throwable::class.java)
 m.isAccessible=true;m.invoke(null,callback,null)
}
fun back(b:Binding){b.state.hide();pinnedCompletion(b.complete)}
fun main() {
 var failures=0;var cases=0
 fun test(name:String,body:()->Unit){cases++;try{body();println("PASS "+name)}catch(e:Throwable){failures++;println("FAIL "+name+" "+e)}}
 fun expect(ok:Boolean,message:String){check(ok){message}}
 test("appearanceVetoSurvivesPinnedBackAndLaterDismisses") {
  var appearance=true;var admissions=0;var dismissals=0
  val b=bind({admissions++;if(appearance){appearance=false;false}else true},{dismissals++})
  back(b);expect(!appearance&&b.state.isVisible&&dismissals==0&&admissions==1,"Vetoed Back must close only Appearance, without second admission")
  back(b);expect(!b.state.isVisible&&dismissals==1&&admissions==2,"Later genuine Back must dismiss exactly once")
 }
 test("persistentDirtyVetoAndLaterAcceptedBack") {
  var dirty=true;var admissions=0;var dismissals=0
  val b=bind({admissions++;!dirty},{dismissals++})
  back(b);expect(dismissals==0&&b.state.isVisible&&admissions==1,"Dirty veto must not be consulted again on completion")
  dirty=false;back(b);expect(dismissals==1&&admissions==2,"Clean independent dismissal")
 }
 test("allowedBackAdmitsOnceAndDismissesOnce") {
  var admissions=0;var dismissals=0;val b=bind({admissions++;true},{dismissals++});back(b)
  expect(admissions==1&&dismissals==1&&!b.state.isVisible,"Successful hide must not re-admit")
 }
 test("queueCancellationKeepsModalThenIndependentBackDismisses") {
  val queue=QueueGestureState();var admissions=0;var dismissals=0
  val b=bind({admissions++;true},{dismissals++},queue);back(b)
  expect(queue.cancels==1&&admissions==0&&dismissals==0&&b.state.isVisible,"Cancelled queue gesture must not dismiss on completion")
  back(b);expect(dismissals==1&&admissions==1,"Next independent Back")
 }
 test("explicitCloseAndEscapeKeepAdmission") {
  var subpage=true;var dismissals=0;val b=bind({if(subpage){subpage=false;false}else true},{dismissals++})
  b.explicit();expect(!subpage&&dismissals==0,"Close veto");expect(b.escape()&&dismissals==1,"Later Escape")
  var dirty=true;var count=0;val d=bind({!dirty},{count++});d.explicit();d.escape();expect(count==0,"Dirty Close/Escape veto");dirty=false;d.explicit();expect(count==1,"Clean Close")
 }
 test("harmonicEscapeReturnsWithoutExplicitCloseLosingDismissal") {
  var selected=true;var dismissals=0
  val b=bind({true},{dismissals++},onEscape={if(selected)selected=false else dismissals++})
  expect(b.escape()&&!selected&&dismissals==0,"Actions Escape returns to query")
  b.explicit();expect(dismissals==1,"Close still dismisses from the actions/query host")
 }
 test("scrimSwipeSettledCompletionDoesNotReadmit") {
  for(scrim in listOf(true,false)) {
   var admissions=0;var dismissals=0;val b=bind({admissions++;true},{dismissals++})
   if(scrim)check(b.state.confirm(SheetValue.Hidden))
   b.state.hide();if(!b.state.isVisible)b.complete()
   expect(dismissals==1&&admissions==(if(scrim)2 else 1),"Material3 preflight and hide remain guarded, completion is not new intent")
  }
 }
 println("CASES $cases FAILURES $failures");check(failures==0)
}
'''
kt=a.output/'SheetDismissal.kt';kt.write_text(source)
env=dict(os.environ,JAVA_HOME=str(directory('JAVA_HOME')),JAVA_OPTS='-Xmx512m -XX:ActiveProcessorCount=1',JAVA_TOOL_OPTIONS='-XX:ActiveProcessorCount=1',TMPDIR=str(scratch_root()))
compile_=subprocess.run(['kotlinc',str(kt),'-include-runtime','-d',str(a.output/'probe.jar')],env=env,capture_output=True,text=True,timeout=120)
(a.output/'compile.log').write_text(compile_.stdout+compile_.stderr)
result={'compilerExit':compile_.returncode,'sourceSha256':hashlib.sha256(s.encode()).hexdigest(),'fixtureSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'pinnedMaterial3JarSha256':expected}
if compile_.returncode==0:
    modules=gradle_cache()/'modules-2/files-2.1'
    dependencies=[*modules.glob('org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/*/*/*.jar'),*modules.glob('org.jetbrains/annotations/*/*/*.jar')]
    cp=os.pathsep.join([str(a.output/'probe.jar'),str(material),*map(str,(x for x in jars if x!=material)),*map(str,dependencies)])
    run=subprocess.run([env['JAVA_HOME']+'/bin/java','-Xmx512m','-XX:ActiveProcessorCount=1','-cp',cp,'SheetDismissalKt'],env=env,capture_output=True,text=True,timeout=60)
    (a.output/'run.log').write_text(run.stdout+run.stderr);result.update(exit=run.returncode,output=run.stdout+run.stderr)
else:result.update(exit=compile_.returncode,output=compile_.stdout+compile_.stderr)
(a.output/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2));raise SystemExit(result['exit'])
