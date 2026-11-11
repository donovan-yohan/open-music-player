#!/usr/bin/env python3
"""Generate exact harmonic sheet snapshot regression with deferred content boundaries.

Configuration/body execution, not Android Compose scheduling or native acceptance.
"""
from pathlib import Path
import argparse
p=argparse.ArgumentParser();p.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[1]);p.add_argument('--generate',type=Path,required=True);p.add_argument('--standalone',action='store_true');a=p.parse_args()
s=(a.root/'app/src/main/kotlin/com/soundq/android/product/playlists/HarmonicDiscovery.kt').read_text()
state=[l.strip()for l in s.splitlines()if 'owner.state.collectAsStateWithLifecycle()'in l]
focus=[l.strip()for l in s.splitlines()if 'val resultFocus=remember('in l]
assert len(state)==len(focus)==1
anchor='            state.result?.let {result->';assert s.count(anchor)==1
start=s.index(anchor);opening=s.index('{',start);depth=1;end=opening+1
while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
body=s[start:end]
prelude='package com.soundq.android.harmonicpresentation\nimport kotlin.reflect.KProperty\nANNOTATIONS\nclass Slot<T>(var value:T) {operator fun getValue(o:Any?,p:KProperty<*>)=value}\ndata class Row(val title:String,val artist:String?=null,val bpm:Double?=null,val camelot:String?=null)\ndata class Result(val tracks:List<Row>,val orderedByHistory:Boolean=true)\ndata class State(val result:Result?=null)\nclass Flow(val slot:Slot<State>) {fun collectAsStateWithLifecycle()=slot}\nclass Owner {val state=Flow(Slot(State()));fun capture(route:Any,index:Int,row:Row):Any?=row;fun current(captured:Any)=true}\nclass FocusRequester {fun requestFocus(){}}\nclass Modifier {companion object {fun semantics(block:Semantics.()->Unit):Modifier {Semantics().block();return Modifier()};fun focusRequester(f:FocusRequester)=Modifier()}}\nclass Semantics {var liveRegion=LiveRegionMode.Polite}\nenum class LiveRegionMode {Polite}\nobject SoundQ {object typography {val caption=0;val mono=0}}\nenum class FeedbackKind {Empty}\nobject SoundQIcon {val More=0}\nvar rows=mutableListOf<String>()\nfun Text(s:String,modifier:Modifier=Modifier(),style:Int=0){}\nfun SoundQFeedback(s:String,k:FeedbackKind,d:String){}\nfun Column(block:()->Unit){block()}\nfun SoundQMediaRow(title:String,artist:String,selected:Boolean,onClick:()->Unit,onMore:()->Unit,enabled:Boolean,modifier:Modifier,supporting:String){rows.add(title)}\nfun SoundQIconButton(i:Int,label:String,onClick:()->Unit,enabled:Boolean){}\nfun <T> remember(key:Any?,block:()->T)=block()\nclass Selection {fun replace(c:Any?){}}\nclass Alive {fun get()=true}\nfun bind(owner:Owner):()->List<String> {\n'
post='\n val current=Any();val panelAlive=Alive();val selectionOwner=Selection()\n var returnFocus:FocusRequester?=null;var refusal:String?=null\n return {rows=mutableListOf();\n'
tests='\n rows.toList()}\n}\nclass HarmonicPresentationSnapshotTest {\n @TEST fun heldEmptySheetNeverIndexesNewRowsAgainstOldFocusList() {\n  val owner=Owner();val held=bind(owner)\n  owner.state.slot.value=State(Result(listOf(Row("new"))))\n  check(held().isEmpty()) {"Old content must retain its original presentation snapshot"}\n  check(bind(owner)()==listOf("new")) {"Renewed parent must render the published result"}\n }\n @TEST fun heldPopulatedSheetRetainsMatchedRowsAcrossResultReplacement() {\n  val owner=Owner();owner.state.slot.value=State(Result(listOf(Row("old"))))\n  val held=bind(owner);owner.state.slot.value=State(Result(listOf(Row("next"),Row("extra"))))\n  check(held()==listOf("old"));check(bind(owner)()==listOf("next","extra"))\n }\n @TEST fun unchangedResultRendersEveryOrderedDuplicate() {\n  val owner=Owner();owner.state.slot.value=State(Result(listOf(Row("same"),Row("same"))))\n  check(bind(owner)()==listOf("same","same"))\n }\n}\n'
main='\nfun main(){val test=HarmonicPresentationSnapshotTest();var failures=0\n for(name in listOf("heldEmptySheetNeverIndexesNewRowsAgainstOldFocusList","heldPopulatedSheetRetainsMatchedRowsAcrossResultReplacement","unchangedResultRendersEveryOrderedDuplicate")) {\n  try {test.javaClass.getMethod(name).invoke(test);println("PASS $name")}\n  catch(e:Throwable){failures++;println("FAIL $name ${e.cause?.javaClass?.simpleName}: ${e.cause?.message}")}\n }\n check(failures==0){"$failures presentation snapshot failures"}\n}\n'
text=prelude.replace('ANNOTATIONS',''if a.standalone else 'import org.junit.Test')+state[0]+'\n'+focus[0]+post+body+tests.replace('@TEST',''if a.standalone else '@Test')+(main if a.standalone else '')
a.generate.mkdir(parents=True,exist_ok=True)
(a.generate/'HarmonicPresentationSnapshotTest.kt').write_text(text)
print('Generated 3 exact harmonic presentation snapshot cases')
